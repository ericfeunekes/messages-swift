import CSQLite
import Foundation
import XCTest
@testable import MessagesCore

/// Synthetic SQLite/WAL coverage of the public incoming-watch operation.
final class WatchTests: XCTestCase {
    func testZeroWaitEstablishesCursorWithoutReturningHistory() async throws {
        let fixture = try WatchFixture()
        try fixture.add(id: 1, text: "old")
        let result = try await fixture.operations().watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        XCTAssertEqual(result.status, "no_match")
        XCTAssertFalse(result.cursor.isEmpty)
        XCTAssertTrue(result.page.messages.isEmpty)
        XCTAssertNil(result.page.nextCursor)
    }

    func testUnknownChatFailsBeforeDefaultWaitEvenWithDanglingUnrelatedAssociation() async throws {
        let fixture = try WatchFixture()
        try fixture.exec("INSERT INTO chat_message_join (chat_id,message_id) VALUES (2,999)")
        let clock = ContinuousClock()
        let began = clock.now
        do { _ = try await fixture.operations().watchMessages(.init(chatID: "missing-chat")); XCTFail("Unknown chat waited or succeeded") }
        catch OperationError.unknownChat(let chatID) { XCTAssertEqual(chatID, "missing-chat") }
        catch { XCTFail("Expected unknown chat, got \(error)") }
        XCTAssertLessThan(began.duration(to: clock.now), .seconds(1))
    }

    func testBatchesIncomingRowsInAssociationOrderAndExcludesOutgoing() async throws {
        let fixture = try WatchFixture()
        let operations = try fixture.operations()
        let initial = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        try fixture.add(id: 1, text: "first")
        try fixture.add(id: 2, text: "outgoing", fromMe: true)
        try fixture.add(id: 3, text: "event", associatedType: 2000)
        try fixture.add(id: 4, text: "second")
        try fixture.add(id: 5, text: "third")

        let first = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, limit: 2, cursor: initial.cursor))
        XCTAssertEqual(first.status, "messages")
        XCTAssertEqual(first.page.messages.map(\.id), ["m1"])
        XCTAssertEqual(first.page.events.map(\.id), ["m3"])
        XCTAssertEqual(first.page.scannedAssociationCount, 3)
        let second = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, limit: 2, cursor: first.cursor))
        XCTAssertEqual(second.page.messages.map(\.id), ["m4", "m5"])
        XCTAssertEqual(second.page.scannedAssociationCount, 2)
    }

    func testScannedAssociationsAccumulateAcrossPollsIncludingUnmatchedRows() async throws {
        let fixture = try WatchFixture()
        let operations = try fixture.operations()
        let initial = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        XCTAssertEqual(initial.page.scannedAssociationCount, 0)
        for id in 1...257 {
            try fixture.add(id: id, text: "excluded", chat: id.isMultiple(of: 2) ? 1 : 2, fromMe: id.isMultiple(of: 2))
        }
        try fixture.add(id: 258, text: "incoming")
        let matched = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 1, limit: 1, cursor: initial.cursor))
        XCTAssertEqual(matched.page.messages.map(\.id), ["m258"])
        XCTAssertEqual(matched.page.scannedAssociationCount, 258)
        for id in 259...515 {
            try fixture.add(id: id, text: "excluded", chat: id.isMultiple(of: 2) ? 1 : 2, fromMe: id.isMultiple(of: 2))
        }
        let timeout = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 1, cursor: matched.cursor))
        XCTAssertEqual(timeout.status, "no_match")
        XCTAssertEqual(timeout.page.scannedAssociationCount, 257)
        let resumed = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: timeout.cursor))
        XCTAssertEqual(resumed.page.scannedAssociationCount, 0)
    }

    func testDelayedJoinAndBackdatedArrivalAppearAfterConsumedPosition() async throws {
        let fixture = try WatchFixture()
        let operations = try fixture.operations()
        let initial = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        try fixture.add(id: 1, text: "other", chat: 2)
        let advanced = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: initial.cursor))
        XCTAssertEqual(advanced.status, "no_match")
        try fixture.add(id: 2, text: "late join", date: -10_000, chat: 1)
        try fixture.addAssociation(messageID: 1, chat: 1)
        let result = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: advanced.cursor))
        XCTAssertEqual(result.page.messages.map(\.id), ["m2", "m1"])
        XCTAssertEqual(result.page.messages.map(\.text), ["late join", "other"])
    }

    func testReplayAndIndependentCallersEachSeeTheSameArrival() async throws {
        let fixture = try WatchFixture()
        let operations = try fixture.operations()
        let firstStart = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        let secondStart = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        try fixture.add(id: 1, text: "arrived")
        let first = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: firstStart.cursor))
        let replay = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: firstStart.cursor))
        let second = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: secondStart.cursor))
        XCTAssertEqual(first.page.messages.map(\.id), ["m1"])
        XCTAssertEqual(replay.page.messages.map(\.id), ["m1"])
        XCTAssertEqual(second.page.messages.map(\.id), ["m1"])
    }

    func testWaitTimeoutAndCancellation() async throws {
        let fixture = try WatchFixture()
        let operations = try fixture.operations()
        let start = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        let clock = ContinuousClock()
        let began = clock.now
        let timeout = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 1, cursor: start.cursor))
        XCTAssertEqual(timeout.status, "no_match")
        XCTAssertGreaterThanOrEqual(began.duration(to: clock.now), .milliseconds(700))

        let task = Task { try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 20, cursor: timeout.cursor)) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled watch returned") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected cancellation error: \(error)") }
    }

    func testChangedOrDeletedAnchorFailsClosed() async throws {
        let fixture = try WatchFixture()
        let operations = try fixture.operations()
        let initial = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        try fixture.add(id: 1, text: "anchor")
        let cursor = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: initial.cursor)).cursor
        try fixture.exec("DELETE FROM chat_message_join WHERE message_id = 1")
        await assertPositionInvalidated { _ = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: cursor)) }
    }

    func testChangedAnchorTupleAndDanglingAssociationFailClosed() async throws {
        let changed = try WatchFixture()
        let changedOperations = try changed.operations()
        let changedStart = try await changedOperations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        try changed.add(id: 1, text: "anchor")
        let changedCursor = try await changedOperations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: changedStart.cursor)).cursor
        try changed.exec("UPDATE message SET guid = 'changed-guid' WHERE ROWID = 1")
        await assertPositionInvalidated { _ = try await changedOperations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: changedCursor)) }

        let dangling = try WatchFixture()
        let danglingOperations = try dangling.operations()
        let danglingStart = try await danglingOperations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        try dangling.add(id: 1, text: "anchor")
        let danglingCursor = try await danglingOperations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: danglingStart.cursor)).cursor
        try dangling.exec("DELETE FROM message WHERE ROWID = 1")
        await assertPositionInvalidated { _ = try await danglingOperations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: danglingCursor)) }
    }

    func testBoundedPhysicalScanCarriesCursorPast256UnmatchedAssociations() async throws {
        let fixture = try WatchFixture()
        let operations = try fixture.operations()
        let start = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        for id in 1...257 { try fixture.add(id: id, text: "other", chat: 2) }
        try fixture.add(id: 258, text: "target")
        let first = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: start.cursor))
        XCTAssertEqual(first.status, "no_match")
        XCTAssertTrue(first.page.messages.isEmpty)
        let second = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: first.cursor))
        XCTAssertEqual(second.status, "messages")
        XCTAssertEqual(second.page.messages.map(\.id), ["m258"])
    }

    func testCursorRejectsDifferentScopeAndStoreConnection() async throws {
        let fixture = try WatchFixture()
        let operations = try fixture.operations()
        let cursor = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0)).cursor
        await assertCursorMismatch { _ = try await operations.watchMessages(.init(chatID: "other-chat", waitSeconds: 0, cursor: cursor)) }
        let replacement = try fixture.operations()
        await assertCursorMismatch { _ = try await replacement.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: cursor)) }
    }

    func testDatabaseReplacementRejectsAnExistingWatchCursor() async throws {
        let fixture = try WatchFixture()
        let operations = try fixture.operations()
        let cursor = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0)).cursor
        try fixture.replaceDatabaseAtPath()
        do { _ = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: cursor)); XCTFail("Replaced database accepted a cursor") }
        catch MessageStoreError.databaseReplaced { }
        catch MessageStoreError.databaseIdentityUnavailable { }
        catch { XCTFail("Expected database replacement failure, got \(error)") }
    }

    func testWatchRetainsRawProviderStatusAndDirectoryEnrichment() async throws {
        let fixture = try WatchFixture(directory: WatchDirectory())
        let operations = try fixture.operations()
        let start = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0))
        try fixture.add(id: 1, text: "status", isSent: 0, isDelivered: 1, error: 0)
        let result = try await operations.watchMessages(.init(chatID: "watch-chat", waitSeconds: 0, cursor: start.cursor))
        let message = try XCTUnwrap(result.page.messages.first)
        XCTAssertEqual(message.sender?.displayName, "Watch Person")
        XCTAssertEqual(message.isSent, false)
        XCTAssertEqual(message.isDelivered, true)
        XCTAssertEqual(message.deliveryErrorCode, 0)
    }

    private func assertPositionInvalidated(_ work: @escaping () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await work(); XCTFail("Expected invalidated position", file: file, line: line) }
        catch WatchError.positionInvalidated { }
        catch { XCTFail("Expected invalidated position, got \(error)", file: file, line: line) }
    }

    private func assertCursorMismatch(_ work: @escaping () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await work(); XCTFail("Expected cursor mismatch", file: file, line: line) }
        catch MessageStoreError.cursorFilterMismatch { }
        catch { XCTFail("Expected cursor mismatch, got \(error)", file: file, line: line) }
    }
}

private final class WatchDirectory: ContactsDirectorySource, @unchecked Sendable {
    func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] {
        [ContactPerson(identity: .init(containerID: binding.containerID, id: "watch-person"), displayName: "Watch Person", handles: ["watch@example.test"])]
    }
    func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String>) throws -> ContactLookup {
        let person = try allContacts(in: binding)[0]
        let people = matchingHandles.contains("watch@example.test") || identities.contains(person.identity) ? [person] : []
        return .init(people: people, unresolvedHandles: [], candidatesByHandle: ["watch@example.test": people])
    }
}

private final class WatchFixture {
    let root: URL
    let url: URL
    private let directory: WatchDirectory
    private var database: OpaquePointer?

    init(directory: WatchDirectory = WatchDirectory()) throws {
        self.directory = directory
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("chat.db")
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw MessageStoreError.sqlite("fixture open") }
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
          CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
          CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
          CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
          CREATE TABLE chat_message_join (ROWID INTEGER PRIMARY KEY, chat_id INTEGER, message_id INTEGER);
          CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER, is_read INTEGER, handle_id INTEGER, service TEXT, associated_message_guid TEXT, associated_message_type INTEGER, item_type INTEGER, balloon_bundle_id TEXT, date_edited INTEGER, date_retracted INTEGER, is_sent INTEGER, is_delivered INTEGER, error INTEGER);
          INSERT INTO chat VALUES (1,'watch-chat','watch-thread',NULL,'iMessage'),(2,'other-chat','other-thread',NULL,'iMessage');
          INSERT INTO handle VALUES (1,'watch@example.test');
          INSERT INTO chat_handle_join VALUES (1,1),(2,1);
          """)
    }

    deinit { sqlite3_close_v2(database); try? FileManager.default.removeItem(at: root) }

    func operations() throws -> MessagesOperations {
        let state = try LocalState(directory: root.appendingPathComponent("state-\(UUID().uuidString)"))
        try state.bindContainer("watch-fixture")
        return .init(store: MessageStore(path: url.path), directory: directory, binding: .init(containerID: "watch-fixture"), state: state)
    }

    func add(id: Int, text: String, date: Int = 1, chat: Int = 1, fromMe: Bool = false, associatedType: Int = 0, isSent: Int? = nil, isDelivered: Int? = nil, error: Int? = nil) throws {
        let quote = text.replacingOccurrences(of: "'", with: "''")
        try exec("INSERT INTO message VALUES (\(id),'m\(id)',\(date),'\(quote)',NULL,\(fromMe ? 1 : 0),0,1,'iMessage',NULL,\(associatedType),0,NULL,0,0,\(isSent.map(String.init) ?? "NULL"),\(isDelivered.map(String.init) ?? "NULL"),\(error.map(String.init) ?? "NULL")); INSERT INTO chat_message_join (chat_id,message_id) VALUES (\(chat),\(id))")
    }

    func addAssociation(messageID: Int, chat: Int) throws { try exec("INSERT INTO chat_message_join (chat_id,message_id) VALUES (\(chat),\(messageID))") }
    func replaceDatabaseAtPath() throws {
        sqlite3_close_v2(database)
        database = nil
        let original = url.appendingPathExtension("original")
        try FileManager.default.moveItem(at: url, to: original)
        try FileManager.default.copyItem(at: original, to: url)
    }
    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw MessageStoreError.sqlite(error.map { String(cString: $0) } ?? "fixture SQL")
        }
    }
}
