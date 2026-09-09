import Foundation
import Darwin

/// Detects changes between validation and subsequent commands, without claiming
/// to freeze the path after Messages takes responsibility for reading it.
struct OutgoingFile {
    let path: String
    private let initial: stat

    init(path: String) throws {
        self.path = path
        self.initial = try Self.inspect(path)
    }

    func isUnchanged() -> Bool {
        guard let current = try? Self.inspect(path) else { return false }
        return initial.st_dev == current.st_dev && initial.st_ino == current.st_ino &&
            initial.st_size == current.st_size &&
            initial.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec &&
            initial.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec &&
            initial.st_ctimespec.tv_sec == current.st_ctimespec.tv_sec &&
            initial.st_ctimespec.tv_nsec == current.st_ctimespec.tv_nsec
    }

    private static func inspect(_ path: String) throws -> stat {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw SendValidationError.invalidFile }
        // O_NOFOLLOW prevents the final component from silently changing target.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw SendValidationError.invalidFile }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw SendValidationError.invalidFile
        }
        return metadata
    }
}
