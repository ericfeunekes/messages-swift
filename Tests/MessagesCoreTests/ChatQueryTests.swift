import CSQLite
import Foundation
import XCTest
@testable import MessagesCore

final class ChatQueryTests: XCTestCase {
  func testExactSetRetrievalIncludesEmptyChatsAndUsesBoundedQueryWork() throws {
    let fixture = try ChatFixture()
    try fixture.exec("CREATE UNIQUE INDEX chat_guid ON chat(guid); CREATE INDEX cmj_chat ON chat_message_join(chat_id, message_id); CREATE INDEX chj_chat ON chat_handle_join(chat_id, handle_id)")
    try fixture.exec("INSERT INTO chat VALUES (1, 'wanted', 'identifier-is-not-guid', 'Wanted', 'iMessage'); INSERT INTO chat VALUES (2, 'empty', 'empty-id', NULL, 'iMessage'); INSERT INTO handle VALUES (1, 'direct@example.test'); INSERT INTO chat_handle_join VALUES (1, 1)")
    try fixture.message(1, date: 100_000_000_000, guid: "message", text: "hello")
    let store = MessageStore(path: fixture.url.path)
    func work() throws -> Int {
      let steps = UnsafeMutablePointer<Int>.allocate(capacity: 1)
      steps.initialize(to: 0)
      defer { steps.deinitialize(count: 1); steps.deallocate() }
      try store.withSnapshot { database, _, _ in
        sqlite3_progress_handler(database, 1, { context in
          context!.assumingMemoryBound(to: Int.self).pointee += 1
          return 0
        }, steps)
      }
      defer { try? store.withSnapshot { database, _, _ in sqlite3_progress_handler(database, 0, nil, nil) } }
      let rows = try store.chats(ids: [ChatID(rawValue: "wanted"), ChatID(rawValue: "empty")])
      XCTAssertEqual(Set(rows.map(\.id.rawValue)), ["wanted", "empty"])
      XCTAssertEqual(rows.first?.participants, ["direct@example.test"])
      XCTAssertNil(rows.last?.lastActivityAt)
      return steps.pointee
    }
    let small = try work()
    try fixture.exec("WITH RECURSIVE n(x) AS (VALUES(3) UNION ALL SELECT x+1 FROM n WHERE x<10002) INSERT INTO chat SELECT x, 'unrelated-'||x, 'id-'||x, 'Other', 'iMessage' FROM n")
    try fixture.exec("INSERT INTO message (ROWID, date, is_from_me, text, guid, handle_id, is_read) SELECT ROWID + 100, 1, 0, 'unrelated', 'unrelated-message-'||ROWID, 1, 0 FROM chat WHERE ROWID >= 3; INSERT INTO chat_message_join SELECT ROWID, ROWID + 100 FROM chat WHERE ROWID >= 3; INSERT INTO chat_handle_join SELECT ROWID, 1 FROM chat WHERE ROWID >= 3")
    let large = try work()
    XCTAssertGreaterThan(small, 0)
    XCTAssertLessThan(large, small + 200, "Indexed exact retrieval must not scan unrelated chats")
    XCTAssertNil(try store.chat(id: ChatID(rawValue: "identifier-is-not-guid")))
    XCTAssertEqual(try store.chat(id: ChatID(rawValue: "wanted"))?.id.rawValue, "wanted")
    XCTAssertTrue(try store.chats(ids: []).isEmpty)
  }

  func testBaselineCreditsDirectCounterpartAndOnlyIncomingGroupAuthor() throws {
    let fixture = try ChatFixture()
    try fixture.exec("INSERT INTO chat VALUES (1, 'group', 'group-id', NULL, 'iMessage'); INSERT INTO chat VALUES (2, 'direct', 'direct-id', NULL, 'iMessage'); INSERT INTO handle VALUES (1, 'author@example.test'); INSERT INTO handle VALUES (2, 'passive@example.test'); INSERT INTO handle VALUES (3, 'direct@example.test'); INSERT INTO chat_handle_join VALUES (1, 1), (1, 2), (1, 3), (2, 3)")
    for id in 1...50 { try fixture.message(Int64(id), date: 100_000_000_000, guid: "group-\(id)", text: "group", handleID: 1) }
    try fixture.message(51, date: 100_000_000_000, guid: "outgoing-group", text: "outgoing", handleID: 0)
    try fixture.exec("UPDATE message SET is_from_me = 1 WHERE ROWID = 51")
    try fixture.message(52, date: 100_000_000_000, guid: "incoming-direct", text: "direct", handleID: 3)
    try fixture.message(53, date: 100_000_000_000, guid: "outgoing-direct", text: "direct", handleID: 0)
    try fixture.exec("UPDATE chat_message_join SET chat_id = 2 WHERE message_id IN (52,53); UPDATE message SET is_from_me = 1 WHERE ROWID = 53")
    try fixture.message(54, date: 1, guid: "old", text: "old", handleID: 2)
    let counts = try MessageStore(path: fixture.url.path).frequentContactHandles(since: Date(timeIntervalSince1970: 978307250))
    XCTAssertEqual(counts, ["author@example.test": 50, "direct@example.test": 2])
  }
}

private final class ChatFixture {
  let url: URL
  var database: OpaquePointer?

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
