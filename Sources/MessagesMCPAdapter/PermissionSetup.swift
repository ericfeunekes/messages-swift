import Darwin
import Foundation

/// A file read capability, not an assertion about the system's Full Disk Access grant.
public enum MessagesReadAccess: Equatable, Sendable {
    case readable, denied, missing, unavailable

    public static func check(path: String) -> Self {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return classify(errno: errno) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { return classify(errno: errno) }
        guard metadata.st_mode & S_IFMT == S_IFREG else { return .unavailable }
        var byte: UInt8 = 0
        guard read(descriptor, &byte, 1) >= 0 else { return classify(errno: errno) }
        return .readable
    }

    static func classify(errno code: Int32) -> Self {
        switch code {
        case EACCES, EPERM: .denied
        case ENOENT, ENOTDIR: .missing
        default: .unavailable
        }
    }
}

public enum ContactsSetupAccess: Sendable {
    case notRequested, denied, restricted, granted, unavailable

    public enum Action: Equatable, Sendable { case request, settings, explain, none }
    public var action: Action {
        switch self {
        case .notRequested: .request
        case .denied: .settings
        case .restricted, .unavailable: .explain
        case .granted: .none
        }
    }
}
