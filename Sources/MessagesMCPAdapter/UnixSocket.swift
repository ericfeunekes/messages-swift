import Foundation
import MCP
import Logging
import Darwin
import MessagesCore

public enum SocketError: Error { case disconnected, messageTooLarge, invalidPath, activeServer, unauthorizedPeer }

/// Nonblocking I/O keeps disconnect available even when a client stops reading.
public actor UnixSocketTransport: Transport {
    public nonisolated let logger = Logger(label: "messages-swift.socket", factory: { _ in SwiftLogNoOpLogHandler() })
    private var fd: Int32
    private let descriptorOwner: SocketDescriptor
    private var connected = false
    private var reader: Task<Void, Never>?
    private var sending = false
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    public init(fileDescriptor: Int32) {
        fd = fileDescriptor
        descriptorOwner = SocketDescriptor(fileDescriptor)
        configureSocket(fd)
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(16)) { captured = $0 }
        continuation = captured
    }
    public func connect() async throws {
        guard fd >= 0 else { throw SocketError.disconnected }
        guard !connected else { return }
        connected = true
        let descriptor = fd, output = continuation
        let owner = descriptorOwner
        reader = Task.detached {
            defer { withExtendedLifetime(owner) {} }
            var pending = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while !Task.isCancelled {
                let count = recv(descriptor, &bytes, bytes.count, 0)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        try? await Task.sleep(for: .milliseconds(5)); continue
                    }
                    output.finish(throwing: SocketError.disconnected); return
                }
                pending.append(bytes, count: count)
                while let newline = pending.firstIndex(of: 10) {
                    let message = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard message.count <= 1_048_576 else { output.finish(throwing: SocketError.messageTooLarge); return }
                    if !message.isEmpty, case .dropped = output.yield(message) {
                        output.finish(throwing: SocketError.disconnected); return
                    }
                }
                guard pending.count <= 1_048_576 else { output.finish(throwing: SocketError.messageTooLarge); return }
            }
            if !pending.isEmpty { output.finish(throwing: SocketError.disconnected) }
            else { output.finish() }
        }
    }
    public func disconnect() async {
        guard fd >= 0 else { return }
        connected = false
        let descriptor = fd
        // Remove actor access before suspension; only the retained reader can use it now.
        fd = -1
        shutdown(descriptor, SHUT_RDWR)
        reader?.cancel()
        await reader?.value
        descriptorOwner.close()
        continuation.finish()
    }
    public func send(_ data: Data) async throws {
        while sending {
            guard connected else { throw SocketError.disconnected }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard connected else { throw SocketError.disconnected }
        sending = true
        defer { sending = false }
        do {
            try Task.checkCancellation()
            var framed = data; framed.append(10)
            var offset = 0
            while offset < framed.count {
                guard connected else { throw SocketError.disconnected }
                let written = framed.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0) }
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    try await Task.sleep(for: .milliseconds(5)); continue
                }
                throw SocketError.disconnected
            }
        } catch {
            await disconnect()
            throw error
        }
    }
    public func receive() -> AsyncThrowingStream<Data, Error> { stream }
    deinit {
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        reader?.cancel()
    }
}


// A reader retains ownership even if its transport is released during a read.
private final class SocketDescriptor: @unchecked Sendable {
    private var descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
}

private func configureSocket(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

/// The lock and descriptor remain owned by the accept task until all clients finish.
public final class UnixSocketServer: @unchecked Sendable {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".messages-swift/runtime/mcp.sock")
    private let url: URL
    private let mutex = NSLock()
    private var stopping = false
    private var task: Task<Void, Error>?
    public init(url: URL = defaultURL) { self.url = url }
    public func start(operations: MessagesOperations) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard task == nil else { throw SocketError.activeServer }
        let directory = url.deletingLastPathComponent()
        var info = stat()
        for privateDirectory in [directory.deletingLastPathComponent(), directory] {
            guard mkdir(privateDirectory.path, 0o700) == 0 || errno == EEXIST else { throw SocketError.invalidPath }
            guard lstat(privateDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw SocketError.invalidPath }
        }
        guard url.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw SocketError.invalidPath }
        let lock = open(directory.appendingPathComponent("mcp.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw SocketError.invalidPath }
        var transferred = false
        defer { if !transferred { close(lock) } }
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw SocketError.invalidPath }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SocketError.activeServer }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        copySocketPath(url.path, into: &address)
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw SocketError.invalidPath }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw SocketError.activeServer }
            configureSocket(probe)
            let result = withUnsafePointer(to: &address) { connect(probe, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size)) }
            let failure = errno
            close(probe)
            guard result < 0, failure == ECONNREFUSED else { throw SocketError.activeServer }
            guard unlink(url.path) == 0 else { throw SocketError.invalidPath }
        } else if errno != ENOENT { throw SocketError.invalidPath }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SocketError.activeServer }
        configureSocket(listener)
        guard withUnsafePointer(to: &address, { bind(listener, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size)) }) == 0 else { close(listener); throw SocketError.activeServer }
        guard chmod(url.path, 0o600) == 0, listen(listener, SOMAXCONN) == 0 else { close(listener); unlink(url.path); throw SocketError.activeServer }
        transferred = true
        stopping = false
        let path = url.path
        task = Task.detached { [weak self] in
            var sessions = SocketSessions()
            var acceptFailed = false
            while self?.isStopping() == false {
                sessions.reap()
                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { try? await Task.sleep(for: .milliseconds(5)); continue }
                    acceptFailed = true; break
                }
                var uid: uid_t = 0; var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); continue }
                let transport = UnixSocketTransport(fileDescriptor: client)
                let completion = SocketSessionCompletion()
                let session = Task<Void, Never> {
                    defer { completion.finish() }
                    try? await MCPServerRunner.run(operations: operations, transport: transport)
                }
                sessions.append(transport: transport, task: session, completion: completion)
            }
            close(listener)
            await sessions.stop()
            unlink(path)
            close(lock)
            if acceptFailed { throw SocketError.disconnected }
        }
    }
    private func isStopping() -> Bool { mutex.lock(); defer { mutex.unlock() }; return stopping }
    public func stop() { mutex.lock(); stopping = true; mutex.unlock() }
    private func currentTask() -> Task<Void, Error>? { mutex.lock(); defer { mutex.unlock() }; return task }
    public func waitUntilStopped() async throws { try await currentTask()?.value }
    deinit { stop() }
}

private func copySocketPath(_ path: String, into address: inout sockaddr_un) {
    let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    _ = path.withCString { source in withUnsafeMutablePointer(to: &address.sun_path) { target in target.withMemoryRebound(to: CChar.self, capacity: capacity) { strncpy($0, source, capacity) } } }
}

// Only live sessions belong to the listener. Completion is published after runner cleanup.
final class SocketSessionCompletion: @unchecked Sendable {
    private let mutex = NSLock()
    private var finished = false
    func finish() { mutex.lock(); finished = true; mutex.unlock() }
    var isFinished: Bool { mutex.lock(); defer { mutex.unlock() }; return finished }
}

struct SocketSessions {
    private var entries: [(UnixSocketTransport, Task<Void, Never>, SocketSessionCompletion)] = []
    mutating func append(transport: UnixSocketTransport, task: Task<Void, Never>, completion: SocketSessionCompletion) {
        entries.append((transport, task, completion))
    }
    mutating func reap() { entries.removeAll { $0.2.isFinished } }
    func stop() async {
        for (transport, task, _) in entries { await transport.disconnect(); task.cancel() }
        for (_, task, _) in entries { await task.value }
    }
}
