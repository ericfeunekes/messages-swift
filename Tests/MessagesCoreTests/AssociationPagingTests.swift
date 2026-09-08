import CSQLite
import Foundation
import Darwin
import Dispatch
import XCTest
@testable import MessagesCore

/// Real SQLite association, snapshot and diagnostic boundaries; all rows are synthetic.
final class AssociationPagingTests: XCTestCase {
  func testCompositeAssociationPaginationEqualsFullResultAndRespectsMembershipAndExactGUID() throws {
    let fixture = try AssociationFixture()
    try fixture.add(1, date: 90, text: "needle older")
    try fixture.add(2, date: 100, text: "needle shared", chats: [1, 2])
    try fixture.add(3, date: 100, text: "needle tied")
    let store = MessageStore(path: fixture.url.path)
    let full = try store.searchMessages(SearchMessagesRequest(query: "needle", limit: 100))
    XCTAssertEqual(pairs(full), ["m3@chat-a", "m2@chat-b", "m2@chat-a", "m1@chat-a"])
    let pages = try drain(store, query: "needle")
    XCTAssertEqual(pages.flatMap(pairs), pairs(full))
    XCTAssertEqual(pages.reduce(0) { $0 + $1.scannedAssociationCount }, 4)
    let member = MessageFilter(participantHandles: ["b@example.test"])
    XCTAssertEqual(try drain(store, query: "needle", filter: member).flatMap(pairs), ["m2@chat-b"])
    let exact = MessageFilter(participantHandles: ["a@example.test"], exactMembership: true)
    XCTAssertEqual(try drain(store, query: "needle", filter: exact).flatMap(pairs), ["m3@chat-a", "m2@chat-a", "m1@chat-a"])
    for (guid, expected) in [("chat-a", ["m3@chat-a", "m2@chat-a", "m1@chat-a"]), ("chat-b", ["m2@chat-b"])] {
      let page = try store.readMessages(ReadMessagesRequest(filter: MessageFilter(chatID: ChatID(rawValue: guid))))
      XCTAssertEqual(pairs(page), expected)
    }
  }

  func testAllFailureHistoryHasBoundedExamplesAndExactTotal() throws {
    let fixture = try AssociationFixture()
    try fixture.exec("BEGIN")
    for row in 1...10_000 { try fixture.add(row, date: row, text: nil, failed: true) }
    try fixture.exec("COMMIT")
    let pages = try drain(MessageStore(path: fixture.url.path), query: "needle")
    XCTAssertEqual(pages.count, 1)
    let page = try XCTUnwrap(pages.first)
    XCTAssertTrue(page.messages.isEmpty)
    XCTAssertEqual(page.decodingFailureCount, 10_000)
    XCTAssertEqual(page.scannedAssociationCount, 10_000)
    XCTAssertEqual(page.decodingFailures.count, 10)
    XCTAssertEqual(page.decodingFailures.map(\.messageID.rawValue), (9_991...10_000).reversed().map { "m\($0)" })
    XCTAssertNil(page.nextCursor)
  }

  func testSparseHistoryDiagnosticsBelongOnlyToConsumedIntervalIncludingTerminalEmptyPage() throws {
    let fixture = try AssociationFixture()
    // Descending: failure(shared), ordinary match, failure, nonmatch, preview
    // match, reaction match, ordinary match, failure(shared), nonmatch, failure.
    try fixture.add(10, date: 10, text: nil, failed: true, chats: [1, 2])
    try fixture.add(9, date: 9, text: "needle")
    try fixture.add(8, date: 8, text: nil, failed: true)
    try fixture.add(7, date: 7, text: "other")
    try fixture.add(6, date: 6, text: "needle preview", balloon: "com.apple.messages.URLBalloonProvider")
    try fixture.add(5, date: 5, text: "needle reaction", associatedType: 2000)
    try fixture.add(4, date: 4, text: "needle")
    try fixture.add(3, date: 3, text: nil, failed: true, chats: [1, 2])
    try fixture.add(2, date: 2, text: "other")
    try fixture.add(1, date: 1, text: nil, failed: true)
    let pages = try drain(MessageStore(path: fixture.url.path), query: "needle")
    XCTAssertEqual(pages.map { $0.messages.map(\.id.rawValue) }, [["m9"], ["m6"], ["m5"], ["m4"], []])
    XCTAssertEqual(pages.map(\.scannedAssociationCount), [3, 3, 1, 1, 4])
    XCTAssertEqual(pages.map(\.decodingFailureCount), [2, 1, 0, 0, 3])
    XCTAssertEqual(pages.flatMap { $0.decodingFailures.map { "\($0.messageID.rawValue)@\($0.chatID.rawValue)" } }, ["m10@chat-b", "m10@chat-a", "m8@chat-a", "m3@chat-b", "m3@chat-a", "m1@chat-a"])
    XCTAssertEqual(pages[1].messages.first?.kind, .preview)
    XCTAssertEqual(pages[2].messages.first?.kind, .reaction)
    XCTAssertNil(pages.last?.nextCursor)
  }

  func testChangedQueryAndFilterAndNewConnectionHaveExactErrors() throws {
    let fixture = try AssociationFixture()
    try fixture.add(1, date: 1, text: "needle")
    try fixture.add(2, date: 2, text: "needle")
    let store = MessageStore(path: fixture.url.path)
    let cursor = try XCTUnwrap(store.searchMessages(SearchMessagesRequest(query: "needle", limit: 1)).nextCursor)
    assertMismatch { _ = try store.searchMessages(SearchMessagesRequest(query: "other", cursor: cursor)) }
    assertMismatch { _ = try store.searchMessages(SearchMessagesRequest(filter: MessageFilter(unreadOnly: true), query: "needle", cursor: cursor)) }
    assertMismatch { _ = try store.searchMessages(SearchMessagesRequest(query: "needle", mode: .exact, cursor: cursor)) }
    assertMismatch { _ = try MessageStore(path: fixture.url.path).searchMessages(SearchMessagesRequest(query: "needle", cursor: cursor)) }
  }

  func testReplacementInsideOpenSnapshotRejectsResultAndSubsequentContinuation() throws {
    let fixture = try AssociationFixture()
    try fixture.add(1, date: 1, text: "needle")
    try fixture.add(2, date: 2, text: "needle")
    let store = MessageStore(path: fixture.url.path)
    let cursor = try XCTUnwrap(store.searchMessages(SearchMessagesRequest(query: "needle", limit: 1)).nextCursor)
    let replacement = try AssociationFixture()
    try replacement.add(1, date: 1, text: "replacement")
    assertReplaced {
      _ = try store.withSnapshot { database, _, _ in
        let statement = try SQLiteStatement(database, "SELECT guid FROM message ORDER BY ROWID")
        defer { statement.finalize() }
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.text(at: 0), "m1")
        try FileManager.default.moveItem(at: fixture.url, to: fixture.url.appendingPathExtension("original"))
        try FileManager.default.copyItem(at: replacement.url, to: fixture.url)
        return "must never escape replaced snapshot"
      }
    }
    assertReplaced { _ = try store.searchMessages(SearchMessagesRequest(query: "needle", cursor: cursor)) }
  }

  func testConcurrentPathExchangeNeverReturnsAnotherDatabase() throws {
    let fixture = try AssociationFixture()
    try fixture.add(1, date: 1, text: "needle")
    try fixture.add(2, date: 2, text: "needle")
    let replacement = try AssociationFixture()
    try replacement.add(1, date: 1, text: "needle")
    try replacement.add(2, date: 2, text: "needle")
    try replacement.exec("UPDATE message SET guid='B-' || guid")
    let store = MessageStore(path: fixture.url.path)
    let cursor = try XCTUnwrap(store.searchMessages(SearchMessagesRequest(query: "needle", limit: 1)).nextCursor)
    let live = fixture.url.path
    let spare = replacement.url.path
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    finished.enter()
    DispatchQueue.global().async {
      for index in 0..<100_000 {
        _ = renameatx_np(AT_FDCWD, live, AT_FDCWD, spare, UInt32(RENAME_SWAP))
        if index == 0 { started.signal() }
      }
      finished.leave()
    }
    started.wait()
    var wrong = 0
    var rejected = 0
    for _ in 0..<20_000 {
      do {
        let page = try store.searchMessages(SearchMessagesRequest(query: "needle", limit: 1, cursor: cursor))
        if page.messages.contains(where: { $0.id.rawValue.hasPrefix("B-") }) { wrong += 1 }
      } catch MessageStoreError.databaseReplaced { rejected += 1 }
      catch MessageStoreError.databaseIdentityUnavailable(let code) {
        XCTAssertEqual(code, SQLITE_IOERR | (27 << 8))
        rejected += 1
      } catch { XCTFail("Unexpected replacement error: \(error)"); break }
    }
    finished.wait()
    XCTAssertEqual(wrong, 0, "A cursor must never return B data during pathname exchange")
    XCTAssertGreaterThan(rejected, 0)
  }

  func testWALFreshSnapshotSeesCommitsAndContinuationKeepsArrivalFence() throws {
    let fixture = try AssociationFixture()
    try fixture.exec("PRAGMA journal_mode=WAL")
    try fixture.add(1, date: 100, text: "needle")
    try fixture.add(2, date: 100, text: "needle", chats: [1, 2])
    let store = MessageStore(path: fixture.url.path)
    let first = try store.searchMessages(SearchMessagesRequest(query: "needle", limit: 1))
    XCTAssertEqual(pairs(first), ["m2@chat-b"])
    try fixture.add(3, date: 50, text: "needle backdated")
    let fresh = try store.searchMessages(SearchMessagesRequest(query: "needle"))
    XCTAssertEqual(pairs(fresh), ["m2@chat-b", "m2@chat-a", "m1@chat-a", "m3@chat-a"])
    let remainder = try drain(store, query: "needle", cursor: try XCTUnwrap(first.nextCursor))
    XCTAssertEqual(remainder.flatMap(pairs), ["m2@chat-a", "m1@chat-a"])
  }

  private func pairs(_ page: MessagePage) -> [String] { page.messages.map { "\($0.id.rawValue)@\($0.chatID.rawValue)" } }
  private func drain(_ store: MessageStore, query: String, filter: MessageFilter = MessageFilter(), cursor initial: MessagePageCursor? = nil) throws -> [MessagePage] {
    var cursor = initial
    var pages: [MessagePage] = []
    repeat {
      let page = try store.searchMessages(SearchMessagesRequest(filter: filter, query: query, limit: 1, cursor: cursor))
      pages.append(page)
      cursor = page.nextCursor
      if pages.count > 100 { XCTFail("Continuation did not terminate"); break }
    } while cursor != nil
    return pages
  }
  private func assertMismatch(_ work: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try work(), file: file, line: line) { error in
      guard case MessageStoreError.cursorFilterMismatch = error else { return XCTFail("Expected cursorFilterMismatch, got \(error)", file: file, line: line) }
    }
  }
  private func assertReplaced(_ work: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try work(), file: file, line: line) { error in
      switch error {
      case MessageStoreError.databaseReplaced: break
      case MessageStoreError.databaseIdentityUnavailable(let code):
        XCTAssertEqual(code, SQLITE_IOERR | (27 << 8), "Expected macOS vnode invalidation", file: file, line: line)
      default: XCTFail("Expected opened-file invalidation, got \(error)", file: file, line: line)
      }
    }
  }
}

private final class AssociationFixture {
  let root: URL
  let url: URL
  private var database: OpaquePointer?
  init() throws {
    root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/association-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    url = root.appendingPathComponent("chat.db")
    guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw MessageStoreError.sqlite("fixture open failed") }
    try exec("""
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, PRIMARY KEY(chat_id,message_id));
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, handle_id INTEGER DEFAULT 1, service TEXT, item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT, balloon_bundle_id TEXT);
      INSERT INTO chat VALUES (1,'chat-a','address-a',NULL,'iMessage'),(2,'chat-b','address-b',NULL,'iMessage');
      INSERT INTO handle VALUES (1,'a@example.test'),(2,'b@example.test');
      INSERT INTO chat_handle_join VALUES (1,1),(2,1),(2,2);
      """)
  }
  deinit { sqlite3_close_v2(database); try? FileManager.default.removeItem(at: root) }
  func exec(_ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw MessageStoreError.sqlite(String(cString: sqlite3_errmsg(database))) }
  }
  func add(_ row: Int, date: Int, text: String?, failed: Bool = false, chats: [Int] = [1], balloon: String? = nil, associatedType: Int = 0) throws {
    let quoted: (String?) -> String = { value in value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
    try exec("INSERT INTO message (ROWID,guid,date,text,attributedBody,balloon_bundle_id,associated_message_type) VALUES (\(row),'m\(row)',\(date),\(quoted(text)),\(failed ? "X'040b00'" : "NULL"),\(quoted(balloon)),\(associatedType))")
    for chat in chats { try exec("INSERT INTO chat_message_join VALUES (\(chat),\(row))") }
  }
}
