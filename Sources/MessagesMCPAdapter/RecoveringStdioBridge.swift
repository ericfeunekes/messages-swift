import Darwin
import Foundation

/// Keeps the client's stdio session alive across backend loss. Only initialization
/// is repeated; any request admitted to a lost connection has an unknown outcome.
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
        var pending: [String: Any] = [:]
        var initialization: Data?
        var initializationID: String?
        var initializationPending = false
        var negotiated: NSDictionary?
        var handshakeDeadline: ContinuousClock.Instant?
        var waiting = Data()

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
        func lost() throws {
            if socket >= 0 { close(socket); socket = -1 }
            backend.removeAll(); backendScan = 0; outbound.removeAll(); waiting.removeAll(); handshakeDeadline = nil
            for id in pending.values {
                try append(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "Messages Swift connection interrupted or unavailable. Operation outcome may be unknown; no request was replayed. Check source state before retrying a send."]], to: &frontend)
            }
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
        func writeTo(_ fd: Int32, data: inout Data) throws {
            guard !data.isEmpty else { return }
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { data.removeFirst(n); return }
            if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { return }
            throw StdioSocketBridge.Failure.io
        }
        func clientFrame(_ frame: Data) throws {
            if frame.isEmpty { return }
            let message = try object(frame)
            let method = message["method"] as? String
            // SDK 0.12.1 deliberately sends no response for cancelled requests.
            if method == "notifications/cancelled", let params = message["params"] as? [String: Any], let id = params["requestId"] {
                pending.removeValue(forKey: try key(id))
            }
            if let id = message["id"], method != nil {
                let requestKey = try key(id)
                guard pending[requestKey] == nil else { throw StdioSocketBridge.Failure.io }
                if pending.count >= 128 {
                    try append(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "Too many outstanding requests; this request was not submitted."]], to: &frontend)
                    return
                }
                pending[requestKey] = id
                if method == "initialize" {
                    initialization = frame; initializationID = requestKey; initializationPending = true; negotiated = nil
                }
                if socket < 0 {
                    do { try connect() } catch { try lost(); return }
                    if let initialization, negotiated != nil, method != "initialize" {
                        outbound.append(initialization); outbound.append(10)
                        waiting.append(frame); waiting.append(10)
                        handshakeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                        return
                    }
                }
            }
            // Notifications and client responses never trigger reconnection.
            guard socket >= 0 else { return }
            outbound.append(frame); outbound.append(10)
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
                try append(["jsonrpc": "2.0", "method": "notifications/initialized"], to: &outbound)
                outbound.append(waiting); waiting.removeAll()
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
                do {
                    while frontend.count < frameLimit, let frame = try takeFrame(&backend, scan: &backendScan) { try backendFrame(frame) }
                } catch { try lost() }
                // Process socket EOF before admitting another request to that socket.
                // Poll timeout zero when complete client frames are already buffered.
                let canAdmit = handshakeDeadline == nil && outbound.isEmpty && frontend.count < frameLimit
                let ready = canAdmit && lineEnd(incoming, scan: &inputScan) != nil
                var fds = [
                    pollfd(fd: input, events: incoming.count <= frameLimit ? Int16(POLLIN) : 0, revents: 0),
                    pollfd(fd: socket, events: (frontend.count < frameLimit ? Int16(POLLIN) : 0) | (outbound.isEmpty ? 0 : Int16(POLLOUT)), revents: 0),
                    pollfd(fd: frontend.isEmpty ? -1 : output, events: Int16(POLLOUT), revents: 0)
                ]
                let timeout: Int32 = ready ? 0 : (handshakeDeadline == nil ? -1 : 100)
                let n = poll(&fds, nfds_t(fds.count), timeout)
                if n < 0 && errno == EINTR { continue }
                guard n >= 0, !fds.contains(where: { $0.revents & Int16(POLLNVAL) != 0 }) else { throw StdioSocketBridge.Failure.io }
                if fds[2].revents & Int16(POLLOUT | POLLHUP | POLLERR) != 0 { try writeTo(output, data: &frontend) }
                if fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                    do {
                        let ended = try receive(socket, into: &backend)
                        while frontend.count < frameLimit, let frame = try takeFrame(&backend, scan: &backendScan) { try backendFrame(frame) }
                        if ended { try lost() }
                    } catch { try lost() }
                }
                if socket >= 0 && fds[1].revents & Int16(POLLOUT) != 0 {
                    do { try writeTo(socket, data: &outbound) } catch { try lost() }
                }
                if let deadline = handshakeDeadline, ContinuousClock.now >= deadline { try lost() }
                if fds[0].revents & Int16(POLLHUP | POLLERR) != 0 { return }
                if fds[0].revents & Int16(POLLIN) != 0 {
                    if try receive(input, into: &incoming) { return }
                }
                if handshakeDeadline == nil && outbound.isEmpty && frontend.count < frameLimit,
                   let frame = try takeFrame(&incoming, scan: &inputScan) { try clientFrame(frame) }
            }
        }
    }
}
