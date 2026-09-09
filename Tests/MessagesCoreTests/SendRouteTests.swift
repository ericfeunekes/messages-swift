import Foundation
import XCTest
@testable import MessagesCore

final class SendRouteTests: XCTestCase {
    func testPublicAppleScriptServiceListDecodesWithoutDispatch() throws {
        var error: NSDictionary?
        let descriptor = try XCTUnwrap(NSAppleScript(source: "return {\"iMessage\", \"SMS\"}")?.executeAndReturnError(&error))
        XCTAssertNil(error)
        XCTAssertEqual(try MessagesScriptingSender.serviceNames(from: descriptor), ["iMessage", "SMS"])
    }

    func testEmptyAndMalformedServiceRepliesAreRejectedOrEmpty() throws {
        var error: NSDictionary?
        let empty = try XCTUnwrap(NSAppleScript(source: "return {}")?.executeAndReturnError(&error))
        XCTAssertNil(error)
        XCTAssertEqual(try MessagesScriptingSender.serviceNames(from: empty), [])
        let malformed = try XCTUnwrap(NSAppleScript(source: "return \"iMessage\"")?.executeAndReturnError(&error))
        XCTAssertThrowsError(try MessagesScriptingSender.serviceNames(from: malformed))
    }
}
