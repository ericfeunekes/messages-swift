import CSQLite
import Foundation
import XCTest
@testable import MessagesCore

private let decodedSearchSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Proves the real read-only Messages connection observes live body changes
/// without retaining a decoded-body cache between searches.
final class DecodedSearchUpdateTests: XCTestCase {
    func testSearchRefreshesSameRowAttributedBodyAndReportsMalformedReplacement() async throws {
        let fixture = try DecodedSearchFixture()
        let state = try LocalState(directory: fixture.root.appendingPathComponent("state", isDirectory: true))
        try state.bindContainer("fixture")
        let operations = MessagesOperations(
            store: MessageStore(path: fixture.databaseURL.path),
            directory: EmptyDecodedSearchDirectory(),
            binding: ContactsContainerBinding(containerID: "fixture"),
            state: state
        )

        // This opens the long-lived read-only connection while the source row
        // has only an empty plain-text body.
        let initiallyEmpty = try await operations.searchMessages(.init(query: "first archive", chatID: "decoded-chat"))
        XCTAssertTrue(initiallyEmpty.messages.isEmpty)
        XCTAssertTrue(initiallyEmpty.decodingDiagnostics.isEmpty)

        // A separate SQLite writer updates the existing source row in WAL mode.
        try fixture.replaceAttributedBody(with: archivedAttributedBody("first archive"))
        let firstArchive = try await operations.searchMessages(.init(query: "first archive", chatID: "decoded-chat"))
        XCTAssertEqual(firstArchive.messages.map(\.id), ["same-source-row"])
        XCTAssertEqual(firstArchive.messages.map(\.text), ["first archive"])
        XCTAssertTrue(firstArchive.decodingDiagnostics.isEmpty)

        // The source coordinate remains the same, so this fails if a prior
        // decoded value is cached instead of resolving the current archive.
        try fixture.replaceAttributedBody(with: archivedAttributedBody("second archive"))
        let oldQuery = try await operations.searchMessages(.init(query: "first archive", chatID: "decoded-chat"))
        XCTAssertTrue(oldQuery.messages.isEmpty)
        XCTAssertTrue(oldQuery.decodingDiagnostics.isEmpty)
        let secondArchive = try await operations.searchMessages(.init(query: "second archive", chatID: "decoded-chat"))
        XCTAssertEqual(secondArchive.messages.map(\.id), ["same-source-row"])
        XCTAssertEqual(secondArchive.messages.map(\.text), ["second archive"])

        // A malformed replacement must not become blank searchable content.
        try fixture.replaceAttributedBody(with: Data([0x01, 0x02, 0x03, 0x04]))
        let malformed = try await operations.searchMessages(.init(query: "second archive", chatID: "decoded-chat"))
        XCTAssertTrue(malformed.messages.isEmpty)
        XCTAssertEqual(malformed.decodingDiagnostics.map(\.messageID), ["same-source-row"])
        XCTAssertEqual(malformed.decodingDiagnostics.map(\.chatID), ["decoded-chat"])
        XCTAssertEqual(malformed.decodingFailureCount, 1)
    }
}

private final class EmptyDecodedSearchDirectory: ContactsDirectorySource, @unchecked Sendable {
    func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] { [] }

    func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String>) throws -> ContactLookup {
        ContactLookup(people: [])
    }
}

private final class DecodedSearchFixture {
    let root: URL
    let databaseURL: URL
    private var writer: OpaquePointer?

    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".scratch/decoded-search-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("chat.db")
        guard sqlite3_open(databaseURL.path, &writer) == SQLITE_OK, writer != nil else {
            throw MessageStoreError.sqlite("fixture writer open failed")
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER, is_read INTEGER, handle_id INTEGER, service TEXT, associated_message_guid TEXT, associated_message_type INTEGER, item_type INTEGER, balloon_bundle_id TEXT, date_edited INTEGER, date_retracted INTEGER);
            INSERT INTO chat VALUES (1, 'decoded-chat', 'decoded@example.test', NULL, 'iMessage');
            INSERT INTO handle VALUES (1, 'decoded@example.test');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message VALUES (1, 'same-source-row', 1, '', NULL, 0, 1, 1, 'iMessage', NULL, 0, 0, NULL, 0, 0);
            INSERT INTO chat_message_join VALUES (1, 1);
            """)
    }

    deinit {
        sqlite3_close_v2(writer)
        try? FileManager.default.removeItem(at: root)
    }

    func replaceAttributedBody(with data: Data) throws {
        guard let writer else { throw MessageStoreError.sqlite("fixture writer unavailable") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, "UPDATE message SET attributedBody = ? WHERE ROWID = 1", -1, &statement, nil) == SQLITE_OK else {
            throw MessageStoreError.sqlite(String(cString: sqlite3_errmsg(writer)))
        }
        defer { sqlite3_finalize(statement) }
        let status = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), decodedSearchSQLiteTransient)
        }
        guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw MessageStoreError.sqlite(String(cString: sqlite3_errmsg(writer)))
        }
    }

    private func execute(_ sql: String) throws {
        guard let writer, sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK else {
            throw MessageStoreError.sqlite(writer.map { String(cString: sqlite3_errmsg($0)) } ?? "fixture SQL failed")
        }
    }
}
