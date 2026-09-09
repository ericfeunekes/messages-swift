import Darwin
import Foundation

/// Keeps the client's stdio session alive across backend loss. Only initialization
/// is repeated. A request becomes uncertain only after bytes reach its socket.
public enum RecoveringStdioBridge {
    public static func relay(path: String, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) throws {
        try Session(path: path, input: input, output: output).run()
    }

    private final class Session {
        // An 8 MiB attachment expands to over 11 MiB in JSON. Bound complete frames,
        // not socket reads, and apply backpressure between frames.
        let frameLimit = 32 * 1024 * 1024
        let path: String
        let input: Int32
        let output: Int32
        var socket: Int32 = -1
        var incoming = Data(), backend = Data(), outbound = Data(), frontend = Data()
        var inputScan = 0, backendScan = 0
        struct Request { let id: Any; var submitted = false }
        struct Frame { let data: Data; let requestKey: String? }
        var pending: [String: Request] = [:]
        var queued: [Frame] = []
        var queuedBytes = 0
        var writingRequest: String?
        var backendReady = false
        var writingInitialized = false
        var initialization: Data?
        var initializationID: String?
        var initializationPending = false
        var negotiated: NSDictionary?
        var handshakeDeadline: ContinuousClock.Instant?

        init(path: String, input: Int32, output: Int32) {
            self.path = path; self.input = input; self.output = output
        }
        deinit { if socket >= 0 { close(socket) } }

        func configure(_ fd: Int32) throws {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw StdioSocketBridge.Failure.io }
        }
        func connect() throws {
            socket = try StdioSocketBridge.connect(path: path)
            do {
                try configure(socket)
                var yes: Int32 = 1
                guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw StdioSocketBridge.Failure.io }
            } catch { close(socket); socket = -1; throw error }
        }
        func object(_ data: Data) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["jsonrpc"] as? String == "2.0" else { throw StdioSocketBridge.Failure.io }
            return value
        }
        func key(_ id: Any) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [id], options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        func append(_ value: [String: Any], to data: inout Data) throws {
            data.append(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            data.append(10)
        }
        func failure(_ request: Request, reason: String) throws {
            let disposition = request.submitted ? "outcome_unknown" : "not_submitted"
            let message = request.submitted
                ? "Messages Swift connection interrupted. Operation outcome may be unknown; no request was replayed. Check source state before retrying a send."
                : "Messages Swift request was not submitted: \(reason)."
            try append(["jsonrpc": "2.0", "id": request.id, "error": ["code": -32000, "message": message, "data": ["disposition": disposition]]], to: &frontend)
        }
        func lost() throws {
            if socket >= 0 { close(socket); socket = -1 }
            backend.removeAll(); backendScan = 0; outbound.removeAll(); writingRequest = nil
            backendReady = false; writingInitialized = false
            queued.removeAll(); queuedBytes = 0; handshakeDeadline = nil
            for request in pending.values { try failure(request, reason: "connection or initialization unavailable") }
            pending.removeAll()
        }
        func lineEnd(_ data: Data, scan: inout Int) -> Int? {
            let offset = scan
            let found: Int? = data.withUnsafeBytes { bytes in
                guard bytes.count > offset, let base = bytes.baseAddress,
                      let end = memchr(base.advanced(by: offset), 10, bytes.count - offset) else { return nil }
                return base.distance(to: end)
            }
            scan = found ?? data.count
            return found.map { data.startIndex + $0 }
        }
        func takeFrame(_ data: inout Data, scan: inout Int) throws -> Data? {
            guard let end = lineEnd(data, scan: &scan) else {
                guard data.count <= frameLimit else { throw StdioSocketBridge.Failure.io }
                return nil
            }
            guard end - data.startIndex <= frameLimit else { throw StdioSocketBridge.Failure.io }
            let frame = Data(data[..<end])
            data.removeSubrange(...end); scan = 0
            return frame
        }
        func receive(_ fd: Int32, into data: inout Data) throws -> Bool {
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let n = read(fd, &bytes, bytes.count)
            if n > 0 { data.append(bytes, count: n); return false }
            if n == 0 { return true }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return false }
            throw StdioSocketBridge.Failure.io
        }
        @discardableResult
        func writeTo(_ fd: Int32, data: inout Data) throws -> Int {
            guard !data.isEmpty else { return 0 }
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { data.removeFirst(n); return n }
            if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { return 0 }
            throw StdioSocketBridge.Failure.io
        }
        func clientFrame(_ frame: Data) throws {
            if frame.isEmpty { return }
            let message = try object(frame)
            let method = message["method"] as? String
            if method == "notifications/cancelled", let params = message["params"] as? [String: Any], let id = params["requestId"] {
                let requestKey = try key(id)
                // Cancellation is a control message, not work waiting behind a
                // handshake. A never-written request must never reach the app.
                let request = pending.removeValue(forKey: requestKey)
                queued.removeAll { item in
                    if item.requestKey == requestKey { queuedBytes -= item.data.count + 1; return true }
                    return false
                }
                if writingRequest == requestKey && request?.submitted != true {
                    outbound.removeAll(); writingRequest = nil
                }
                // MCP cancellation has no required response. Forward only when
                // the app might have seen the request; otherwise it is complete.
                guard request?.submitted == true else { return }
            }
            let requestKey = try message["id"].flatMap { method == nil ? nil : try key($0) }
            if let requestKey, let id = message["id"] {
                guard pending[requestKey] == nil else { throw StdioSocketBridge.Failure.io }
                if pending.count >= 128 || queuedBytes + frame.count + 1 > frameLimit {
                    try failure(Request(id: id), reason: "too many queued or outstanding requests")
                    return
                }
                pending[requestKey] = Request(id: id)
            } else {
                // A queued new request does not make old-session traffic valid.
                // Only the initial client handshake notification may establish
                // readiness; restoration sends its own initialized notification.
                let initialReady = method == "notifications/initialized" && socket >= 0
                    && negotiated != nil && handshakeDeadline == nil && !writingInitialized
                guard backendReady || initialReady else { return }
            }
            guard queuedBytes + frame.count + 1 <= frameLimit else { throw StdioSocketBridge.Failure.io }
            queued.append(Frame(data: frame, requestKey: requestKey)); queuedBytes += frame.count + 1
        }
        func prepareWrite() throws {
            guard outbound.isEmpty, handshakeDeadline == nil, !queued.isEmpty else { return }
            writingRequest = nil
            let item = queued[0]
            let message = try object(item.data)
            let method = message["method"] as? String
            if socket < 0 {
                guard item.requestKey != nil else {
                    queued.removeFirst(); queuedBytes -= item.data.count + 1
                    return
                }
                do { try connect() } catch { try lost(); return }
                if let initialization, negotiated != nil, method != "initialize" {
                    outbound.append(initialization); outbound.append(10)
                    handshakeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                    return
                }
            }
            queued.removeFirst(); queuedBytes -= item.data.count + 1
            if method == "initialize" {
                backendReady = false
                initialization = item.data; initializationID = item.requestKey
                initializationPending = true; negotiated = nil
            }
            writingRequest = item.requestKey
            writingInitialized = method == "notifications/initialized"
            outbound.append(item.data); outbound.append(10)
        }
        func backendFrame(_ frame: Data) throws {
            if frame.isEmpty { return }
            let message = try object(frame)
            let responseKey = try message["id"].map { try key($0) }
            if handshakeDeadline != nil {
                guard responseKey == initializationID,
                      let result = message["result"] as? [String: Any],
                      let negotiated,
                      NSDictionary(dictionary: ["protocolVersion": result["protocolVersion"] ?? NSNull(), "capabilities": result["capabilities"] ?? NSNull()]) == negotiated else {
                    try lost(); return
                }
                handshakeDeadline = nil
                writingInitialized = true
                try append(["jsonrpc": "2.0", "method": "notifications/initialized"], to: &outbound)
                return
            }
            if message["method"] == nil, let responseKey {
                guard pending.removeValue(forKey: responseKey) != nil else { return }
                if initializationPending && responseKey == initializationID {
                    initializationPending = false
                    if let result = message["result"] as? [String: Any] {
                        negotiated = NSDictionary(dictionary: ["protocolVersion": result["protocolVersion"] ?? NSNull(), "capabilities": result["capabilities"] ?? NSNull()])
                    }
                }
            }
            frontend.append(frame); frontend.append(10)
        }
        func run() throws {
            signal(SIGPIPE, SIG_IGN)
            try configure(input); try configure(output)
            while true {
                let canRead = frontend.count < frameLimit
                let buffered = canRead && (lineEnd(incoming, scan: &inputScan) != nil || lineEnd(backend, scan: &backendScan) != nil)
                let runnable = canRead && handshakeDeadline == nil && outbound.isEmpty && !queued.isEmpty
                var fds = [
                    pollfd(fd: input, events: canRead ? Int16(POLLIN) : 0, revents: 0),
                    pollfd(fd: canRead ? socket : -1, events: Int16(POLLIN) | (outbound.isEmpty ? 0 : Int16(POLLOUT)), revents: 0),
                    pollfd(fd: frontend.isEmpty ? -1 : output, events: Int16(POLLOUT), revents: 0)
                ]
                let timeout: Int32 = buffered || runnable ? 0 : (handshakeDeadline == nil ? -1 : 100)
                let n = poll(&fds, nfds_t(fds.count), timeout)
                if n < 0 && errno == EINTR { continue }
                guard n >= 0, !fds.contains(where: { $0.revents & Int16(POLLNVAL) != 0 }) else { throw StdioSocketBridge.Failure.io }
                if fds[0].revents & Int16(POLLHUP | POLLERR) != 0 { return }
                if fds[0].revents & Int16(POLLIN) != 0 {
                    if try receive(input, into: &incoming) { return }
                }
                // Process all complete controls before any backend write. Queued
                // requests cannot hide a later cancellation during restoration.
                while frontend.count < frameLimit, let frame = try takeFrame(&incoming, scan: &inputScan) { try clientFrame(frame) }
                if fds[2].revents & Int16(POLLOUT | POLLHUP | POLLERR) != 0 { try writeTo(output, data: &frontend) }
                if fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                    do {
                        let ended = try receive(socket, into: &backend)
                        while frontend.count < frameLimit, let frame = try takeFrame(&backend, scan: &backendScan) { try backendFrame(frame) }
                        if ended { try lost() }
                    } catch { try lost() }
                } else {
                    do {
                        while frontend.count < frameLimit, let frame = try takeFrame(&backend, scan: &backendScan) { try backendFrame(frame) }
                    } catch { try lost() }
                }
                if let deadline = handshakeDeadline, ContinuousClock.now >= deadline { try lost() }
                // A readable stdin may still contain another complete control
                // frame beyond this read chunk. Drain it before releasing work.
                var inputReady = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
                if frontend.count < frameLimit && poll(&inputReady, 1, 0) > 0 && inputReady.revents != 0 { continue }
                if frontend.count < frameLimit && socket >= 0 && fds[1].revents & Int16(POLLOUT) != 0 {
                    do {
                        let written = try writeTo(socket, data: &outbound)
                        if written > 0, let writingRequest { pending[writingRequest]?.submitted = true }
                        if outbound.isEmpty && writingInitialized {
                            backendReady = true; writingInitialized = false
                        }
                    } catch { try lost() }
                }
                if frontend.count < frameLimit { try prepareWrite() }
            }
        }
    }
}
