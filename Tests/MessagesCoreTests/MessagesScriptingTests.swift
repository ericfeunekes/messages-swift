import Dispatch
import Foundation
import XCTest
@testable import MessagesCore

final class MessagesScriptingTests: XCTestCase {
    func testArgumentsKeepUnicodeNewlinesAndQuotesAsData() {
        let text = "Ava said \"hi\"\n🙂 cafe\u{301} -- ; tell application \"Messages\""
        XCTAssertEqual(
            MessagesScriptingScript.arguments(target: .individual(handle: "ava@example.test", service: "iMessage"), payload: .text(text)),
            ["individual", "ava@example.test", "iMessage", "text", text]
        )
    }

    func testInertScriptExecutesSharedChatAndDirectRouting() async {
        let sender = MessagesScriptingSender(permission: { true }, executor: AppleScriptExecutor(source: inertSource))
        let chat = await sender.send(target: .chat("chat-guid-1"), payload: .text("line one\n\"quoted\" 🙂"))
        let direct = await sender.send(target: .individual(handle: "ava@example.test", service: "iMessage"), payload: .file("/synthetic/café \"one\" file.png"))
        XCTAssertEqual(chat, .accepted)
        XCTAssertEqual(direct, .accepted)
    }

    func testExactAndSingleEnabledRouteFailuresAreUnavailableBeforeDispatch() async {
        let sender = MessagesScriptingSender(permission: { true }, executor: AppleScriptExecutor(source: inertSource))
        let chat = await sender.send(target: .chat("display-name-is-not-an-id"), payload: .text("x"))
        let ambiguousSMS = await sender.send(target: .individual(handle: "ava@example.test", service: "SMS"), payload: .text("x"))
        let unavailableRCS = await sender.send(target: .individual(handle: "ava@example.test", service: "RCS"), payload: .text("x"))
        let invalidService = await sender.send(target: .individual(handle: "ava@example.test", service: "unknown"), payload: .text("x"))
        XCTAssertEqual(chat, .unavailable)
        XCTAssertEqual(ambiguousSMS, .unavailable)
        XCTAssertEqual(unavailableRCS, .unavailable)
        XCTAssertEqual(invalidService, .rejected)
    }

    func testDispatchFailureIsUnknownAndDoesNotRetry() async {
        let sender = MessagesScriptingSender(permission: { true }, executor: AppleScriptExecutor(source: failingDispatchSource))
        let result = await sender.send(target: .chat("chat-guid-1"), payload: .text("uncertain"))
        XCTAssertEqual(result, .unknown)
    }

    func testRouteLookupErrorAfterDispatchIsUnknownForBothDirectServices() async {
        let source = failingDispatchSource.replacingOccurrences(of: "error number -10000", with: "error number -1728")
        let sender = MessagesScriptingSender(permission: { true }, executor: AppleScriptExecutor(source: source))
        for service in ["SMS", "iMessage"] {
            let result = await sender.send(target: .individual(handle: "+15550009999", service: service), payload: .text("synthetic"))
            XCTAssertEqual(result, .unknown, "A dispatch error must not authorize another route")
        }
    }

    func testNonpromptingPermissionFailureRejectsWithoutExecutingScript() async {
        let sender = MessagesScriptingSender(permission: { false }, executor: CountingExecutor())
        let result = await sender.send(target: .chat("chat-guid-1"), payload: .text("x"))
        XCTAssertEqual(result, .rejected)
    }

    func testCancellationDuringPermissionCheckDoesNotStartDispatch() async {
        let gate = PermissionGate()
        let sender = MessagesScriptingSender(permission: gate.check, executor: CountingExecutor())
        let task = Task { await sender.send(target: .chat("chat-guid-1"), payload: .text("x")) }
        XCTAssertEqual(gate.started.wait(timeout: .now() + 1), .success)
        task.cancel()
        gate.continueCheck.signal()
        let result = await task.value
        XCTAssertEqual(result, .rejected)
    }

    func testProductionScriptCompilesAgainstInstalledMessagesDictionary() {
        var error: NSDictionary?
        let script = NSAppleScript(source: MessagesScriptingScript.productionSource)
        XCTAssertTrue(script?.compileAndReturnError(&error) == true, "\(error ?? [:])")
    }
}

private struct CountingExecutor: AppleScriptExecuting {
    func execute(arguments: [String]) -> SendDispatchOutcome {
        XCTFail("Permission failure must not invoke an AppleScript")
        return .unknown
    }
}

private final class PermissionGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let continueCheck = DispatchSemaphore(value: 0)

    func check() -> Bool {
        started.signal()
        continueCheck.wait()
        return true
    }
}

private let inertSource = MessagesScriptingScript.routingBody + "\n" + #"""
on exactChat(chatID)
    if chatID is "chat-guid-1" then return "fixture-chat"
    error number -1728
end exactChat
on enabledAccounts(serviceName)
    if serviceName is "iMessage" then return {"fixture-imessage"}
    if serviceName is "SMS" then return {"one", "two"}
    if serviceName is "RCS" then return {}
    error number -50
end enabledAccounts
on directTarget(handleValue, accountValue)
    if accountValue is "fixture-imessage" then return "fixture-direct:" & handleValue
    error number -1728
end directTarget
on dispatchPayload(payloadKind, payloadValue, targetReference)
    if targetReference is "fixture-chat" and payloadKind is "text" and payloadValue is "line one\n\"quoted\" 🙂" then return
    if targetReference is "fixture-direct:ava@example.test" and payloadKind is "file" and payloadValue is "/synthetic/café \"one\" file.png" then return
    error number -1728
end dispatchPayload
"""#

private let failingDispatchSource = MessagesScriptingScript.routingBody + "\n" + #"""
on exactChat(chatID)
    if chatID is "chat-guid-1" then return "fixture-chat"
    error number -1728
end exactChat
on enabledAccounts(serviceName)
    return {"fixture-imessage"}
end enabledAccounts
on directTarget(handleValue, accountValue)
    return "fixture-direct:" & handleValue
end directTarget
on dispatchPayload(payloadKind, payloadValue, targetReference)
    error number -10000
end dispatchPayload
"""#
