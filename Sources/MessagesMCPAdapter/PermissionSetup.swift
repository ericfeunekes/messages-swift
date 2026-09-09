import ApplicationServices
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

/// The app's public Apple Events permission to control Messages. This reports the
/// Automation boundary only; it does not establish that a message was sent.
public enum AutomationSetupAccess: Equatable, Sendable {
    case notRequested, denied, granted, unavailable

    public enum Action: Equatable, Sendable { case request, settings, explain, none }
    public var action: Action {
        switch self {
        case .notRequested: .request
        case .denied: .settings
        case .unavailable: .explain
        case .granted: .none
        }
    }

    /// Checks without presenting an Automation prompt.
    public static func check() async -> Self {
        await Task.detached(priority: .userInitiated) {
            determine(askUserIfNeeded: false)
        }.value
    }

    /// May present the system Automation prompt. Keep its public Apple Events
    /// call off the AppKit main actor because Apple documents it can block.
    public static func request() async -> Self {
        await Task.detached(priority: .userInitiated) {
            determine(askUserIfNeeded: true)
        }.value
    }

    private static func determine(askUserIfNeeded: Bool) -> Self {
        var target = AEAddressDesc()
        let createStatus = "com.apple.MobileSMS".withCString { identifier in
            AECreateDesc(DescType(typeApplicationBundleID), identifier, Int(strlen(identifier)), &target)
        }
        guard createStatus == noErr else { return .unavailable }
        defer { AEDisposeDesc(&target) }

        return classify(status: AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUserIfNeeded))
    }

    static func classify(status: OSStatus) -> Self {
        switch status {
        case noErr: .granted
        case OSStatus(errAEEventWouldRequireUserConsent): .notRequested
        case OSStatus(errAEEventNotPermitted): .denied
        default: .unavailable
        }
    }
}

/// The app's Accessibility trust for future native conversation organization.
/// This only reports or requests the system grant; it does not perform an
/// Accessibility action.
public enum AccessibilitySetupAccess: Equatable, Sendable {
    case denied, granted

    public enum Action: Equatable, Sendable { case request, none }
    public var action: Action {
        switch self {
        case .denied: .request
        case .granted: .none
        }
    }

    /// Checks trust without presenting a system prompt.
    public static func check() -> Self {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// May open the system Accessibility permission prompt and returns the
    /// current trust state. macOS may grant access later in System Settings.
    public static func request() -> Self {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) ? .granted : .denied
    }
}
