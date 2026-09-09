import Darwin
import Foundation

/// Validates and connects to the app-owned private Unix socket.
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

}
