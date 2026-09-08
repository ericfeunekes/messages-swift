import CSQLite
import Foundation
import XCTest
@testable import MessagesCore

final class MessageStoreTests: XCTestCase {
  func testNewestFirstPaginationPreservesEqualTimestampTiesAndArrivalFence() throws {
    let fixture = try Fixture()
    try fixture.exec("INSERT INTO chat VALUES (1, 'chat-guid', 'chat-id', 'Family', 'iMessage')")
    try fixture.exec("INSERT INTO handle VALUES (1, 'a@example.test')")
    try fixture.exec("INSERT INTO chat_handle_join VALUES (1, 1)")
    try fixture.message(1, date: 100, guid: "one", text: "first")
    try fixture.message(2, date: 100, guid: "two", text: "second")

    let store = MessageStore(path: fixture.url.path)
    let first = try store.readMessages(ReadMessagesRequest(filter: MessageFilter(chatID: ChatID(rawValue: "chat-guid")), limit: 1))
    XCTAssertEqual(first.messages.map(\.guid), ["two"])
    let cursor = try XCTUnwrap(first.nextCursor)
    try fixture.message(3, date: 50, guid: "late", text: "backdated")
    let second = try store.readMessages(ReadMessagesRequest(filter: cursor.filter, limit: 1, cursor: cursor))
    XCTAssertEqual(second.messages.map(\.guid), ["one"])
  }

  func testMembershipUsesChatParticipantsNotMessageSenderAndExactExcludesExtra() throws {
    let fixture = try Fixture()
    try fixture.exec("INSERT INTO chat VALUES (1, 'group', 'group-id', NULL, 'iMessage')")
    try fixture.exec("INSERT INTO handle VALUES (1, 'a@example.test'); INSERT INTO handle VALUES (2, 'b@example.test'); INSERT INTO handle VALUES (3, 'c@example.test')")
    try fixture.exec("INSERT INTO chat_handle_join VALUES (1, 1); INSERT INTO chat_handle_join VALUES (1, 2); INSERT INTO chat_handle_join VALUES (1, 3)")
    try fixture.message(1, date: 1, guid: "from-a", text: "hello", handleID: 1)
    let store = MessageStore(path: fixture.url.path)
    let contains = try store.searchMessages(SearchMessagesRequest(filter: MessageFilter(participantHandles: ["b@example.test"]), query: "hello"))
    XCTAssertEqual(contains.messages.map(\.guid), ["from-a"])
    let exact = try store.searchMessages(SearchMessagesRequest(filter: MessageFilter(participantHandles: ["a@example.test", "b@example.test"], exactMembership: true), query: "hello"))
    XCTAssertTrue(exact.messages.isEmpty)
  }

  func testFailedBodyIsDiagnosedWithoutBeingReturnedAsBlankSearchText() throws {
    let fixture = try Fixture()
    try fixture.exec("INSERT INTO chat VALUES (1, 'chat-guid', 'chat-id', NULL, 'iMessage'); INSERT INTO handle VALUES (1, 'a@example.test'); INSERT INTO chat_handle_join VALUES (1, 1)")
    try fixture.message(1, date: 1, guid: "bad", text: "", body: [4, 11, 0])
    let page = try MessageStore(path: fixture.url.path).searchMessages(SearchMessagesRequest(query: "anything"))
    XCTAssertTrue(page.messages.isEmpty)
    XCTAssertEqual(page.decodingFailures.map(\.messageID.rawValue), ["bad"])
    XCTAssertEqual(page.decodingFailures.map(\.chatID.rawValue), ["chat-guid"])
  }
}

private final class Fixture {
  let url: URL
  private var database: OpaquePointer?

  init() throws {
    let scratch = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    url = scratch.appendingPathComponent("messages-store-\(UUID().uuidString).sqlite")
    guard sqlite3_open(url.path, &database) == SQLITE_OK, database != nil else { throw MessageStoreError.sqlite("fixture open") }
    try exec("""
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER, is_from_me INTEGER, text TEXT, attributedBody BLOB, guid TEXT, service TEXT, handle_id INTEGER, associated_message_guid TEXT, associated_message_type INTEGER, item_type INTEGER, balloon_bundle_id TEXT, date_edited INTEGER, date_retracted INTEGER, is_read INTEGER);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      """)
  }

  deinit { sqlite3_close_v2(database); try? FileManager.default.removeItem(at: url) }

  func exec(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
      defer { sqlite3_free(error) }
      throw MessageStoreError.sqlite(error.map { String(cString: $0) } ?? "fixture SQL")
    }
  }

  func message(_ rowID: Int64, date: Int64, guid: String, text: String, handleID: Int64 = 1, body: [UInt8]? = nil) throws {
    let bodySQL = body.map { "X'" + $0.map { String(format: "%02x", $0) }.joined() + "'" } ?? "NULL"
    try exec("INSERT INTO message VALUES (\(rowID), \(date), 0, '\(text)', \(bodySQL), '\(guid)', 'iMessage', \(handleID), NULL, NULL, 0, NULL, NULL, NULL, 0); INSERT INTO chat_message_join VALUES (1, \(rowID))")
  }
}
