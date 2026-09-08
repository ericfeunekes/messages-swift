import Darwin
import Foundation

/// Raw, bounded duplex relay. It never interprets or replays an MCP request.
public enum StdioSocketBridge {
    public enum Failure: Error { case unavailable, unsafeEndpoint, io }

    public static func connect(path: String) throws -> Int32 {
        let url = URL(fileURLWithPath: path)
        for directory in [url.deletingLastPathComponent(), url.deletingLastPathComponent().deletingLastPathComponent()] {
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafeEndpoint }
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Failure.unavailable }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafeEndpoint }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw Failure.unsafeEndpoint }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { target in
                target.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, source, capacity) }
            }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.io }
        do {
            var result: Int32
            repeat {
                result = withUnsafePointer(to: &address) { Darwin.connect(descriptor, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size)) }
            } while result < 0 && errno == EINTR
            guard result == 0 else { throw Failure.unavailable }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid() else { throw Failure.unsafeEndpoint }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    /// Caller owns all descriptors. EOF from either side terminates that direction;
    /// socket EOF also stops waiting for stdin. Pending received output is drained.
    public static func relay(socket descriptor: Int32, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) throws {
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw Failure.io }
        // stdout can be a pipe whose reader exits. Report EPIPE instead of a signal.
        signal(SIGPIPE, SIG_IGN)
        for fd in [descriptor, input, output] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure.io }
        }
        let capacity = 65_536
        var toSocket = Data(), toOutput = Data()
        var inputEnded = false, socketEnded = false, writeEnded = false
        while true {
            if socketEnded && toOutput.isEmpty { return }
            if inputEnded && toSocket.isEmpty && !writeEnded {
                _ = shutdown(descriptor, SHUT_WR)
                writeEnded = true
            }
            var entries = [
                pollfd(fd: !inputEnded && !socketEnded && toSocket.count < capacity ? input : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: socketEnded ? -1 : descriptor, events: (toOutput.count < capacity ? Int16(POLLIN) : 0) | (!toSocket.isEmpty ? Int16(POLLOUT) : 0), revents: 0),
                pollfd(fd: toOutput.isEmpty ? -1 : output, events: Int16(POLLOUT), revents: 0)
            ]
            let result = poll(&entries, nfds_t(entries.count), -1)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw Failure.io }
            if entries.contains(where: { $0.revents & Int16(POLLNVAL) != 0 }) { throw Failure.io }
            if entries[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                inputEnded = try readAvailable(input, into: &toSocket, limit: capacity)
            }
            if entries[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 && toOutput.count < capacity {
                socketEnded = try readAvailable(descriptor, into: &toOutput, limit: capacity)
                if socketEnded { toSocket.removeAll(); inputEnded = true }
            }
            if !socketEnded && entries[1].revents & Int16(POLLOUT) != 0 { try writeAvailable(descriptor, from: &toSocket) }
            if entries[2].revents & Int16(POLLOUT | POLLHUP | POLLERR) != 0 { try writeAvailable(output, from: &toOutput) }
        }
    }
    private static func readAvailable(_ fd: Int32, into buffer: inout Data, limit: Int) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: min(8192, limit - buffer.count))
        guard !bytes.isEmpty else { return false }
        let count = read(fd, &bytes, bytes.count)
        if count > 0 { buffer.append(bytes, count: count); return false }
        if count == 0 { return true }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return false }
        throw Failure.io
    }
    private static func writeAvailable(_ fd: Int32, from buffer: inout Data) throws {
        guard !buffer.isEmpty else { return }
        let count = buffer.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if count > 0 { buffer.removeFirst(count); return }
        if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { return }
        throw Failure.io
    }
}
