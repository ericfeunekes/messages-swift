import Foundation
import XCTest
@testable import MessagesCore

final class ActivityOperationsTests: XCTestCase, @unchecked Sendable {
    func testDeletedExactChatDuringPagingRequiresRestart() async throws {
        let fixture = try ActivityFixture()
        try fixture.message(1, at: 1)
        let stateURL = fixture.url.deletingLastPathComponent().appendingPathComponent("state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let operations = MessagesOperations(store: MessageStore(path: fixture.url.path), directory: ActivityDirectory([]),
            binding: .init(containerID: "fixture"), state: try LocalState(directory: stateURL))
        let range = fixture.range(0, 2 * 86_400)
        let first = try await operations.countMessageActivity(.init(chatID: "chat-a", dateRange: range, timeZone: "UTC", bucket: .day, limit: 1), now: fixture.date(10))
        try fixture.exec("DELETE FROM chat WHERE ROWID = 1")
        do {
            _ = try await operations.countMessageActivity(.init(chatID: "chat-a", dateRange: range, timeZone: "UTC", bucket: .day, limit: 1, cursor: XCTUnwrap(first.nextCursor)), now: fixture.date(10))
            XCTFail("Deleted selected chat did not invalidate continuation")
        } catch ActivityError.continuationInvalidated { }
    }

    func testForeignCursorRejectsBeforeMissingChatMutationClassification() async throws {
        let firstFixture = try ActivityFixture()
        let secondFixture = try ActivityFixture()
        try secondFixture.exec("DELETE FROM chat WHERE ROWID = 1")
        let firstState = firstFixture.url.appendingPathExtension("state")
        let secondState = secondFixture.url.appendingPathExtension("state")
        defer { try? FileManager.default.removeItem(at: firstState); try? FileManager.default.removeItem(at: secondState) }
        let firstOperations = MessagesOperations(store: MessageStore(path: firstFixture.url.path), directory: ActivityDirectory([]),
            binding: .init(containerID: "fixture"), state: try LocalState(directory: firstState))
        let secondOperations = MessagesOperations(store: MessageStore(path: secondFixture.url.path), directory: ActivityDirectory([]),
            binding: .init(containerID: "fixture"), state: try LocalState(directory: secondState))
        let range = firstFixture.range(0, 2 * 86_400)
        let first = try await firstOperations.countMessageActivity(.init(chatID: "chat-a", dateRange: range, timeZone: "UTC", bucket: .day, limit: 1), now: firstFixture.date(10))
        do {
            _ = try await secondOperations.countMessageActivity(.init(chatID: "chat-a", dateRange: range, timeZone: "UTC", bucket: .day, limit: 1, cursor: XCTUnwrap(first.nextCursor)), now: secondFixture.date(10))
            XCTFail("Foreign store cursor reported missing-chat mutation")
        } catch MessageStoreError.cursorFilterMismatch { }
    }

    func testAmbiguousSourceIdentityAliasAndChangedResolution() async throws {
        let fixture = try ActivityFixture()
        try fixture.message(1, at: 1)
        try fixture.message(2, at: 2, chat: 2)
        let directory = ActivityDirectory([
            .init(identity: .init(containerID: "fixture", id: "a"), displayName: "Same Name", handles: ["a@example.test"]),
            .init(identity: .init(containerID: "fixture", id: "b"), displayName: "Same Name", handles: ["b@example.test"]),
        ])
        let stateURL = fixture.url.deletingLastPathComponent().appendingPathComponent("state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let operations = MessagesOperations(store: MessageStore(path: fixture.url.path), directory: directory,
            binding: .init(containerID: "fixture"), state: try LocalState(directory: stateURL))
        let ambiguous = try await operations.countMessageActivity(.init(participants: [.init(query: "Same Name")], dateRange: fixture.range(0, 10)), now: fixture.date(10))
        do {
            _ = try await operations.countMessageActivity(.init(chatID: "missing", participants: [.init(query: "Same Name")]), now: fixture.date(10))
            XCTFail("Unknown chat was hidden by participant ambiguity")
        } catch OperationError.unknownChat("missing") { }
        XCTAssertEqual(ambiguous.contactCandidates.count, 2)
        XCTAssertTrue(ambiguous.rows.isEmpty)
        XCTAssertNil(ambiguous.resolvedDateRange)
        _ = try await operations.setChatAlias(.init(chatID: "chat-a", alias: "Family"))
        let identity = ContactIdentity(containerID: "fixture", id: "a")
        let first = try await operations.countMessageActivity(.init(participants: [.init(sourceIdentity: identity)], dateRange: fixture.range(0, 10), groupBy: .chat, limit: 1), now: fixture.date(10))
        XCTAssertEqual(first.rows[0].chatID, "chat-a")
        XCTAssertEqual(first.chats[0].alias, "Family")
        XCTAssertEqual(first.chats[0].participants[0].sourceIdentity, identity)
        let continuation = CountMessageActivityInput(participants: [.init(sourceIdentity: identity)], dateRange: fixture.range(0, 10), groupBy: .chat, limit: 1, cursor: try XCTUnwrap(first.nextCursor))
        directory.people[0] = .init(identity: identity, displayName: "Same Name", handles: ["b@example.test"])
        do { _ = try await operations.countMessageActivity(continuation, now: fixture.date(11)); XCTFail("Changed resolved membership was accepted") }
        catch MessageStoreError.cursorFilterMismatch { }
        directory.people.removeAll()
        do { _ = try await operations.countMessageActivity(continuation, now: fixture.date(12)); XCTFail("Removed source identity was accepted") }
        catch MessageStoreError.cursorFilterMismatch { }
    }
}

private final class ActivityDirectory: ContactsDirectorySource, @unchecked Sendable {
    var people: [ContactPerson]
    init(_ people: [ContactPerson]) { self.people = people }
    func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] { people }
}
