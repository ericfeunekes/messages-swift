import Carbon
import Foundation

/// A destination already resolved by the operation layer. A chat target is an
/// exact Messages chat identifier; a direct target names both its handle and
/// the service that is allowed to carry it.
public enum SendTarget: Sendable, Equatable {
    case chat(String)
    case individual(handle: String, service: String)
}

/// One independently dispatched Messages item. Callers report multi-part
/// results themselves because Messages does not make a text-and-files batch
/// atomic.
public enum SendPayload: Sendable, Equatable {
    case text(String)
    case file(String)
}

public enum SendDispatchOutcome: String, Codable, Sendable {
    case accepted
    case rejected
    /// No exact chat or uniquely enabled requested service route was available,
    /// and dispatch has not started. Callers may try another route. Once dispatch
    /// starts, a route error must be reported as unknown instead.
    case unavailable
    case unknown
}

/// Implementations must preserve SendDispatchOutcome timing semantics. In
/// particular, unavailable guarantees that no dispatch was attempted; a failed
/// or interrupted dispatch whose effects are uncertain must return unknown.
public protocol MessagesSending: Sendable {
    func send(target: SendTarget, payload: SendPayload) async -> SendDispatchOutcome
}
public protocol MessagesRouteDiscovering: Sendable { func availableServices() async throws -> [String] }

/// Public Messages.app Automation transport. It deliberately reports only
/// acceptance by Messages, never delivery to the recipient.
public struct MessagesScriptingSender: MessagesSending, MessagesRouteDiscovering {
    private let permission: @Sendable () -> Bool
    private let executor: AppleScriptExecuting

    public init() {
        permission = MessagesAutomationPermission.isGrantedWithoutPrompt
        executor = AppleScriptExecutor(source: MessagesScriptingScript.productionSource)
    }

    init(permission: @escaping @Sendable () -> Bool, executor: AppleScriptExecuting) {
        self.permission = permission
        self.executor = executor
    }

    public func send(target: SendTarget, payload: SendPayload) async -> SendDispatchOutcome {
        let permitted = await Task.detached(priority: nil, operation: permission).value
        guard permitted else { return .rejected }
        guard !Task.isCancelled else { return .rejected }

        let arguments = MessagesScriptingScript.arguments(target: target, payload: payload)
        let result = await Task.detached(priority: nil) { executor.execute(arguments: arguments) }.value
        return result
    }

    public func availableServices() async throws -> [String] {
        guard await Task.detached(priority: nil, operation: permission).value else { throw SendRouteError.accountDiscoveryFailed }
        return try await Task.detached(priority: nil) {
            let source = #"""
            tell application id "com.apple.MobileSMS"
                set enabledServiceNames to {}
                if (count of (every account whose enabled is true and service type is iMessage)) is 1 then set end of enabledServiceNames to "iMessage"
                if (count of (every account whose enabled is true and service type is SMS)) is 1 then set end of enabledServiceNames to "SMS"
                if (count of (every account whose enabled is true and service type is RCS)) is 1 then set end of enabledServiceNames to "RCS"
                return enabledServiceNames
            end tell
            """#
            var error: NSDictionary?
            guard let value = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else { throw SendRouteError.accountDiscoveryFailed }
            return try Self.serviceNames(from: value)
        }.value
    }

    static func serviceNames(from value: NSAppleEventDescriptor) throws -> [String] {
        guard value.descriptorType == typeAEList else { throw SendRouteError.accountDiscoveryFailed }
        var services: [String] = []
        if value.numberOfItems > 0 {
            for index in 1...value.numberOfItems {
                guard let service = value.atIndex(index)?.stringValue,
                      ["iMessage", "SMS", "RCS"].contains(service),
                      !services.contains(service) else { throw SendRouteError.accountDiscoveryFailed }
                services.append(service)
            }
        }
        return services
    }
}

protocol AppleScriptExecuting: Sendable {
    func execute(arguments: [String]) -> SendDispatchOutcome
}

struct AppleScriptExecutor: AppleScriptExecuting {
    let source: String

    func execute(arguments: [String]) -> SendDispatchOutcome {
        var compilationError: NSDictionary?
        guard let script = NSAppleScript(source: source), script.compileAndReturnError(&compilationError) else {
            return .rejected
        }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setDescriptor(NSAppleEventDescriptor(string: "dispatchmessage"), forKeyword: AEKeyword(keyASSubroutineName))
        let argv = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            argv.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        let parameters = NSAppleEventDescriptor.list()
        parameters.insert(argv, at: 1)
        event.setDescriptor(parameters, forKeyword: AEKeyword(keyDirectObject))

        var executionError: NSDictionary?
        let result = script.executeAppleEvent(event, error: &executionError)
        if let executionError {
            if (executionError[NSAppleScript.errorNumber] as? NSNumber)?.int32Value == -1743 {
                return .rejected
            }
            return .unknown
        }
        guard let string = result.stringValue else { return .unknown }
        return MessagesScriptingScript.interpret(string)
    }
}

enum MessagesAutomationPermission {
    static func isGrantedWithoutPrompt() -> Bool {
        let bundleID = Array("com.apple.MobileSMS".utf8)
        var target = AEDesc()
        let creation = bundleID.withUnsafeBytes {
            AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, Int(bundleID.count), &target)
        }
        guard creation == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        ) == noErr
    }
}

enum MessagesScriptingScript {
    static func arguments(target: SendTarget, payload: SendPayload) -> [String] {
        let destination: [String]
        switch target {
        case .chat(let id): destination = ["chat", id, ""]
        case .individual(let handle, let service): destination = ["individual", handle, service]
        }
        switch payload {
        case .text(let text): return destination + ["text", text]
        case .file(let path): return destination + ["file", path]
        }
    }

    static func interpret(_ value: String) -> SendDispatchOutcome {
        switch value {
        case "accepted": .accepted
        case "rejected": .rejected
        case "unavailable": .unavailable
        default: .unknown
        }
    }

    /// Routing is shared verbatim by production and inert scripts. Only the
    /// boundary handlers below it differ, so tests execute AppleScript's own
    /// argument decoding and route selection without contacting Messages.
    static let routingBody = #"""
    on dispatchMessage(argv)
        set dispatchStarted to false
        try
            if (count of argv) is not 5 then error number -50
            set targetKind to item 1 of argv
            set targetValue to item 2 of argv
            set serviceName to item 3 of argv
            set payloadKind to item 4 of argv
            set payloadValue to item 5 of argv
            if targetKind is "chat" then
                set targetReference to my exactChat(targetValue)
            else if targetKind is "individual" then
                set matchingAccounts to my enabledAccounts(serviceName)
                if (count of matchingAccounts) is not 1 then error number -1728
                set targetReference to my directTarget(targetValue, item 1 of matchingAccounts)
            else
                error number -50
            end if
            if payloadKind is not "text" and payloadKind is not "file" then error number -50
            set dispatchStarted to true
            my dispatchPayload(payloadKind, payloadValue, targetReference)
            return "accepted"
        on error errorMessage number errorNumber
            if dispatchStarted then return "unknown"
            if errorNumber is -1728 then return "unavailable"
            return "rejected"
        end try
    end dispatchMessage
    """#

    static let productionHandlers = #"""
    on exactChat(chatID)
        tell application id "com.apple.MobileSMS"
            set matches to every chat whose id is chatID
            if (count of matches) is not 1 then error number -1728
            return item 1 of matches
        end tell
    end exactChat

    on enabledAccounts(serviceName)
        tell application id "com.apple.MobileSMS"
            if serviceName is "iMessage" then
                return every account whose enabled is true and service type is iMessage
            else if serviceName is "SMS" then
                return every account whose enabled is true and service type is SMS
            else if serviceName is "RCS" then
                return every account whose enabled is true and service type is RCS
            end if
            error number -50
        end tell
    end enabledAccounts

    on directTarget(handleValue, targetAccount)
        tell application id "com.apple.MobileSMS"
            return buddy handleValue of targetAccount
        end tell
    end directTarget

    on dispatchPayload(payloadKind, payloadValue, targetReference)
        tell application id "com.apple.MobileSMS"
            if payloadKind is "text" then
                send payloadValue to targetReference
            else
                send (POSIX file payloadValue as alias) to targetReference
            end if
        end tell
    end dispatchPayload
    """#

    static let productionSource = routingBody + "\n" + productionHandlers
}
