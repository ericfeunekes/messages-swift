import XCTest
import Foundation
import CSQLite
@testable import MessagesCore

private struct ContinuationDirectory: ContactsDirectorySource, Sendable {
    func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] { [] }
}

final class ContinuationTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var path: String { root.appendingPathComponent("chat.db").path }
    private let epoch = Date(timeIntervalSince1970: 978_307_200)
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/continuation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func sql(_ text: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "SQLiteFixture", code: 1) }
        defer { sqlite3_close(db) }
        let status = sqlite3_exec(db, text, nil, nil, nil)
        guard status == SQLITE_OK else { throw NSError(domain: "SQLiteFixture", code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) }
    }
    private func schema() throws {
        try sql("""
        CREATE TABLE chat (guid TEXT,chat_identifier TEXT,display_name TEXT,service_name TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER,handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER,message_id INTEGER);
        CREATE TABLE message (guid TEXT,date INTEGER,text TEXT,attributedBody BLOB,is_from_me INTEGER DEFAULT 0,is_read INTEGER DEFAULT 0,handle_id INTEGER,service TEXT,item_type INTEGER DEFAULT 0,associated_message_type INTEGER DEFAULT 0,balloon_bundle_id TEXT);
        INSERT INTO chat VALUES ('chat','address','Target One','iMessage');
        INSERT INTO handle VALUES ('fixture@example.test');
        INSERT INTO chat_handle_join VALUES (1,1);
        """)
    }
    private func operations() throws -> MessagesOperations {
        MessagesOperations(store: MessageStore(path: path), directory: ContinuationDirectory(), binding: ContactsContainerBinding(containerID: "fixture"), state: try LocalState(directory: root.appendingPathComponent("state")))
    }
    private func add(_ row: Int, date: Int64, chat: Int = 1, read: Int = 0, fromMe: Int = 0) throws {
        try sql("INSERT INTO message (ROWID,guid,date,text,handle_id,is_read,is_from_me) VALUES (\(row),'m\(row)',\(date),'needle \(row)',1,\(read),\(fromMe)); INSERT INTO chat_message_join VALUES (\(chat),\(row));")
    }
    func testReadDrainsTiedNanosecondsAndExcludesAllBackdatedArrivals() async throws {
        try schema()
        for row in 1...7 { try add(row, date: row <= 3 ? 1_000_000_001 : 1_000_000_002) }
        let ops = try operations()
        var page = try await ops.readMessages(ReadMessagesInput(chatID: "chat", limit: 2))
        var ids = page.messages.map(\.id)
        XCTAssertEqual(ids, ["m7", "m6"])
        try add(8, date: 1_000_000_001)
        try add(9, date: 0)
        var pages = 1
        while let cursor = page.nextCursor {
            XCTAssertLessThan(pages, 10)
            guard pages < 10 else { break }
            page = try await ops.readMessages(ReadMessagesInput(chatID: "chat", limit: 2, cursor: cursor))
            ids += page.messages.map(\.id)
            pages += 1
        }
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(ids, ["m7", "m6", "m5", "m4", "m3", "m2", "m1"])
        XCTAssertEqual(Set(ids).count, ids.count)
    }
    func testSearchDrainsTiesAndFenceThroughTerminalPage() async throws {
        try schema()
        for row in 1...7 { try add(row, date: 1_000_000_001) }
        let ops = try operations()
        var page = try await ops.searchMessages(SearchMessagesInput(query: "needle", limit: 2))
        var ids = page.messages.map(\.id)
        try add(8, date: 0)
        var pages = 1
        while let cursor = page.nextCursor {
            guard pages < 10 else { XCTFail("Continuation never terminates"); break }
            page = try await ops.searchMessages(SearchMessagesInput(query: "needle", limit: 2, cursor: cursor))
            ids += page.messages.map(\.id)
            pages += 1
        }
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(ids, ["m7", "m6", "m5", "m4", "m3", "m2", "m1"])
    }
    func testSearchRejectsChangedQueryAndChangedFilter() async throws {
        try schema(); try add(1, date: 1); try add(2, date: 2)
        let ops = try operations()
        let first = try await ops.searchMessages(SearchMessagesInput(query: "needle", limit: 1))
        let cursor = try XCTUnwrap(first.nextCursor)
        do { _ = try await ops.searchMessages(SearchMessagesInput(query: "other", limit: 1, cursor: cursor)); XCTFail("Changed query accepted") } catch MessageStoreError.cursorFilterMismatch { } catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await ops.searchMessages(SearchMessagesInput(query: "needle", unreadOnly: true, limit: 1, cursor: cursor)); XCTFail("Changed unread filter accepted") } catch MessageStoreError.cursorFilterMismatch { } catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await ops.searchMessages(SearchMessagesInput(query: "needle", chatID: "chat", limit: 1, cursor: cursor)); XCTFail("Changed conversation scope accepted") } catch MessageStoreError.cursorFilterMismatch { } catch { XCTFail("Unexpected error: \(error)") }
        let read = try await ops.readMessages(ReadMessagesInput(chatID: "chat", limit: 1))
        let readCursor = try XCTUnwrap(read.nextCursor)
        do { _ = try await ops.readMessages(ReadMessagesInput(chatID: "chat", unreadOnly: true, limit: 1, cursor: readCursor)); XCTFail("Changed read filter accepted") } catch MessageStoreError.cursorFilterMismatch { } catch { XCTFail("Unexpected error: \(error)") }
    }
    func testReplacementDatabaseRejectsOldCursorEvenWithSameRowsAndChatGUID() async throws {
        try schema(); try add(1, date: 1); try add(2, date: 2)
        let ops = try operations()
        let search = try await ops.searchMessages(SearchMessagesInput(query: "needle", limit: 1))
        let read = try await ops.readMessages(ReadMessagesInput(chatID: "chat", limit: 1))
        let searchCursor = try XCTUnwrap(search.nextCursor)
        let readCursor = try XCTUnwrap(read.nextCursor)
        try FileManager.default.moveItem(atPath: path, toPath: root.appendingPathComponent("original.db").path)
        try schema(); try add(1, date: 1); try add(2, date: 2)
        try sql("UPDATE message SET guid='replacement-' || guid")
        do { _ = try await ops.searchMessages(SearchMessagesInput(query: "needle", limit: 1, cursor: searchCursor)); XCTFail("Replaced database accepted search cursor") } catch MessageStoreError.databaseReplaced { } catch MessageStoreError.databaseIdentityUnavailable(let code) { XCTAssertEqual(code, SQLITE_IOERR | (27 << 8)) } catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await ops.readMessages(ReadMessagesInput(chatID: "chat", limit: 1, cursor: readCursor)); XCTFail("Replaced database accepted read cursor") } catch MessageStoreError.databaseReplaced { } catch MessageStoreError.databaseIdentityUnavailable(let code) { XCTAssertEqual(code, SQLITE_IOERR | (27 << 8)) } catch { XCTFail("Unexpected error: \(error)") }
    }
    func testHalfOpenDatesAndUnreadApplyBeforeLimit() async throws {
        try schema()
        try add(1, date: 999_999_999)
        try add(2, date: 1_000_000_000)
        try add(3, date: 1_500_000_000, read: 1)
        try add(4, date: 1_750_000_000, fromMe: 1)
        try add(5, date: 2_000_000_000)
        let ops = try operations()
        let dates = DateRange(start: epoch.addingTimeInterval(1), end: epoch.addingTimeInterval(2))
        let read = try await ops.readMessages(ReadMessagesInput(chatID: "chat", dateRange: dates, unreadOnly: true, limit: 1))
        XCTAssertEqual(read.messages.map(\.id), ["m2"])
        XCTAssertNil(read.nextCursor)
        let search = try await ops.searchMessages(SearchMessagesInput(query: "needle", dateRange: dates, unreadOnly: true, limit: 1))
        XCTAssertEqual(search.messages.map(\.id), ["m2"])
        XCTAssertNil(search.nextCursor)
    }
    func testFindNamePaginationKeepsArrivalFenceThroughTerminalPage() async throws {
        try schema()
        try sql("INSERT INTO chat VALUES ('chat2','a2','Target Two','iMessage'),('chat3','a3','Target Three','iMessage'),('other','a4','Unrelated','iMessage'); INSERT INTO chat_handle_join VALUES (2,1),(3,1),(4,1);")
        try add(1, date: 1_000_000_001)
        try add(2, date: 1_000_000_001, chat: 2)
        try add(3, date: 1_000_000_001, chat: 3)
        try add(4, date: 2_000_000_000, chat: 4)
        let ops = try operations()
        var page = try await ops.findChats(FindChatsInput(query: "Target", limit: 1))
        var ids = page.chats.map(\.chatID)
        XCTAssertEqual(ids, ["chat3"])
        try sql("INSERT INTO chat VALUES ('new-chat','a5','Target New','iMessage'); INSERT INTO chat_handle_join VALUES (5,1);")
        try add(5, date: 0, chat: 5)
        try add(6, date: 3_000_000_000, chat: 1)
        var pages = 1
        while let cursor = page.nextCursor {
            guard pages < 10 else { XCTFail("Find continuation never terminates"); break }
            page = try await ops.findChats(FindChatsInput(query: "Target", limit: 1, cursor: cursor))
            ids += page.chats.map(\.chatID)
            pages += 1
        }
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(ids, ["chat3", "chat2", "chat"])
    }
    func testFarFutureDateThrowsInsteadOfOverflowing() async throws {
        try schema(); try add(1, date: 1)
        let ops = try operations()
        let dates = DateRange(start: Date(timeIntervalSince1970: 1e15))
        do { _ = try await ops.readMessages(ReadMessagesInput(chatID: "chat", dateRange: dates)); XCTFail("Unrepresentable date accepted") } catch MessageStoreError.invalidDateRange { } catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await ops.searchMessages(SearchMessagesInput(query: "needle", dateRange: dates)); XCTFail("Unrepresentable date accepted") } catch MessageStoreError.invalidDateRange { } catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await ops.findChats(FindChatsInput(dateRange: dates)); XCTFail("Unrepresentable date accepted") } catch MessageStoreError.invalidDateRange { } catch { XCTFail("Unexpected error: \(error)") }
    }
}
