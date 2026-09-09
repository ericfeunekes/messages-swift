import Foundation
import Darwin

/// Detects source changes between initial validation and dispatch. A separate
/// staged copy gives Messages' asynchronous consumer a readable, owned path.
struct OutgoingFile {
    let path: String
    private let initial: stat

    init(path: String) throws {
        self.path = path
        self.initial = try Self.inspect(path)
    }

    func isUnchanged() -> Bool {
        guard let current = try? Self.inspect(path) else { return false }
        return matches(current)
    }

    func copy(to destination: URL) throws {
        try withValidatedSource { source in
            let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw SendValidationError.fileStagingFailed }
            defer { close(output) }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SendValidationError.fileStagingFailed
                }
                var offset = 0
                while offset < count {
                    let written = buffer.withUnsafeBytes {
                        Darwin.write(output, $0.baseAddress!.advanced(by: offset), count - offset)
                    }
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw SendValidationError.fileStagingFailed }
                    offset += written
                }
            }
        }
    }

    /// The copy borrows one validated descriptor; changes during its use reject
    /// the snapshot, including pathname replacement while the old inode is open.
    func withValidatedSource(_ read: (Int32) throws -> Void) throws {
        let source: Int32
        do { source = try Self.openSource(path) }
        catch { throw SendValidationError.fileChanged }
        defer { close(source) }
        var before = stat()
        guard fstat(source, &before) == 0, matches(before) else { throw SendValidationError.fileChanged }
        try read(source)
        var after = stat()
        guard fstat(source, &after) == 0, matches(after), isUnchanged() else { throw SendValidationError.fileChanged }
    }

    private func matches(_ current: stat) -> Bool {
        initial.st_dev == current.st_dev && initial.st_ino == current.st_ino &&
            initial.st_size == current.st_size &&
            initial.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec &&
            initial.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec &&
            initial.st_ctimespec.tv_sec == current.st_ctimespec.tv_sec &&
            initial.st_ctimespec.tv_nsec == current.st_ctimespec.tv_nsec
    }

    private static func openSource(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw SendValidationError.invalidFile }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SendValidationError.invalidFile }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw SendValidationError.invalidFile
        }
        return descriptor
    }

    private static func inspect(_ path: String) throws -> stat {
        let descriptor = try openSource(path)
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw SendValidationError.invalidFile }
        return metadata
    }
}

/// Owns only this invocation's staged inputs. Accepted or uncertain transfers
/// outlive the AppleScript reply; unhanded files are removed without a TTL sweep.
final class StagedOutgoingFiles {
    let paths: [String]
    private let batch: URL?
    private var retained: Set<Int> = []

    init(files: [OutgoingFile], root: URL) throws {
        guard !files.isEmpty else { paths = []; batch = nil; return }
        let manager = FileManager.default
        let createdBatch = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var created = false
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw SendValidationError.fileStagingFailed }
            guard mkdir(createdBatch.path, 0o700) == 0 else { throw SendValidationError.fileStagingFailed }
            created = true
            var stagedPaths: [String] = []
            for (index, file) in files.enumerated() {
                let directory = createdBatch.appendingPathComponent(String(index), isDirectory: true)
                guard mkdir(directory.path, 0o700) == 0 else { throw SendValidationError.fileStagingFailed }
                let destination = directory.appendingPathComponent(URL(fileURLWithPath: file.path).lastPathComponent)
                try file.copy(to: destination)
                stagedPaths.append(destination.path)
            }
            paths = stagedPaths
            batch = createdBatch
        } catch {
            if created { try? manager.removeItem(at: createdBatch) }
            if let validation = error as? SendValidationError { throw validation }
            throw SendValidationError.fileStagingFailed
        }
    }

    func retain(index: Int) { retained.insert(index) }

    func cleanupUnhanded() {
        guard let batch else { return }
        if retained.isEmpty { try? FileManager.default.removeItem(at: batch); return }
        for index in paths.indices where !retained.contains(index) {
            try? FileManager.default.removeItem(at: batch.appendingPathComponent(String(index), isDirectory: true))
        }
    }
}
