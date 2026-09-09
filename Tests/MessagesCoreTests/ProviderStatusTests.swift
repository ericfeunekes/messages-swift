import CSQLite
import Foundation
import XCTest
@testable import MessagesCore

final class ProviderStatusTests: XCTestCase {
  func testReadAndSearchExposeRawMessageAndAttachmentProviderStatus() async throws {
    let fixture = try ProviderStatusFixture(includeStatusColumns: true)
    try fixture.insertMessage(id: 1, guid: "zero", text: "needle zero", isSent: 0, isDelivered: 0, error: 0)
    try fixture.insertAttachment(id: 1, messageID: 1, guid: "zero-attachment", transferState: 0, available: true)
    try fixture.insertMessage(id: 2, guid: "one", text: "needle one", isSent: 1, isDelivered: 1, error: 25)
    try fixture.insertAttachment(id: 2, messageID: 2, guid: "one-attachment", transferState: 6, available: true)
    try fixture.insertMessage(id: 3, guid: "null", text: "needle null", isSent: nil, isDelivered: nil, error: nil)
    try fixture.insertAttachment(id: 3, messageID: 3, guid: "null-attachment", transferState: nil, available: true)
    try fixture.insertMessage(id: 4, guid: "future", text: "needle future", isSent: 2, isDelivered: -1, error: 9_876_543)

    let operations = try fixture.operations()
    let read = try await operations.readMessages(.init(chatID: "status-chat", limit: 10))
    let search = try await operations.searchMessages(.init(query: "needle", chatID: "status-chat", limit: 10))

    assertMessageStatus(read.messages)
    assertMessageStatus(search.messages)
    assertAttachmentStatus(read.messages)
    assertAttachmentStatus(search.messages)
    try assertJSONStatus(read.messages)
    try assertJSONStatus(search.messages)
  }

  func testMissingProviderStatusColumnsRemainNilAndAreOmittedFromReadAndSearchJSON() async throws {
    let fixture = try ProviderStatusFixture(includeStatusColumns: false)
    try fixture.insertMessage(id: 1, guid: "missing", text: "needle missing")
    try fixture.insertAttachment(id: 1, messageID: 1, guid: "missing-attachment", available: true)

    let operations = try fixture.operations()
    let read = try await operations.readMessages(.init(chatID: "status-chat", limit: 10))
    let search = try await operations.searchMessages(.init(query: "needle", chatID: "status-chat", limit: 10))

    for message in [try XCTUnwrap(read.messages.first), try XCTUnwrap(search.messages.first)] {
      XCTAssertNil(message.isSent)
      XCTAssertNil(message.isDelivered)
      XCTAssertNil(message.deliveryErrorCode)
      let attachment = try XCTUnwrap(message.attachments.first)
      XCTAssertEqual(attachment.availability, .available)
      XCTAssertNil(attachment.transferState)

      let object = try jsonObject(message)
      XCTAssertNil(object["isSent"])
      XCTAssertNil(object["isDelivered"])
      XCTAssertNil(object["deliveryErrorCode"])
      let attachmentObject = try XCTUnwrap(object["attachments"] as? [[String: Any]]).first
      XCTAssertNil(attachmentObject?["transferState"])
    }
  }

  private func assertMessageStatus(_ messages: [MessageResult], file: StaticString = #filePath, line: UInt = #line) {
    let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
    XCTAssertEqual(byID["zero"]?.isSent, false, file: file, line: line)
    XCTAssertEqual(byID["zero"]?.isDelivered, false, file: file, line: line)
    XCTAssertEqual(byID["zero"]?.deliveryErrorCode, 0, file: file, line: line)
    XCTAssertEqual(byID["one"]?.isSent, true, file: file, line: line)
    XCTAssertEqual(byID["one"]?.isDelivered, true, file: file, line: line)
    XCTAssertEqual(byID["one"]?.deliveryErrorCode, 25, file: file, line: line)
    XCTAssertNil(byID["null"]?.isSent, file: file, line: line)
    XCTAssertNil(byID["null"]?.isDelivered, file: file, line: line)
    XCTAssertNil(byID["null"]?.deliveryErrorCode, file: file, line: line)
    XCTAssertEqual(byID["future"]?.isSent, true, file: file, line: line)
    XCTAssertEqual(byID["future"]?.isDelivered, true, file: file, line: line)
    XCTAssertEqual(byID["future"]?.deliveryErrorCode, 9_876_543, file: file, line: line)
  }

  private func assertAttachmentStatus(_ messages: [MessageResult], file: StaticString = #filePath, line: UInt = #line) {
    let attachments = Dictionary(uniqueKeysWithValues: messages.flatMap(\.attachments).map { ($0.id, $0) })
    XCTAssertEqual(attachments["zero-attachment"]?.availability, .available, file: file, line: line)
    XCTAssertEqual(attachments["zero-attachment"]?.transferState, 0, file: file, line: line)
    XCTAssertEqual(attachments["one-attachment"]?.availability, .available, file: file, line: line)
    XCTAssertEqual(attachments["one-attachment"]?.transferState, 6, file: file, line: line)
    XCTAssertNil(attachments["null-attachment"]?.transferState, file: file, line: line)
  }

  private func assertJSONStatus(_ messages: [MessageResult], file: StaticString = #filePath, line: UInt = #line) throws {
    let objects = try messages.map(jsonObject)
    let byID = Dictionary(uniqueKeysWithValues: objects.compactMap { object in
      (object["id"] as? String).map { ($0, object) }
    })
    XCTAssertEqual(byID["zero"]?["isSent"] as? Bool, false, file: file, line: line)
    XCTAssertEqual(byID["zero"]?["isDelivered"] as? Bool, false, file: file, line: line)
    XCTAssertEqual(byID["zero"]?["deliveryErrorCode"] as? Int, 0, file: file, line: line)
    XCTAssertEqual(byID["one"]?["isSent"] as? Bool, true, file: file, line: line)
    XCTAssertEqual(byID["one"]?["isDelivered"] as? Bool, true, file: file, line: line)
    XCTAssertEqual(byID["one"]?["deliveryErrorCode"] as? Int, 25, file: file, line: line)
    XCTAssertNil(byID["null"]?["isSent"], file: file, line: line)
    XCTAssertNil(byID["null"]?["isDelivered"], file: file, line: line)
    XCTAssertNil(byID["null"]?["deliveryErrorCode"], file: file, line: line)
    XCTAssertEqual(byID["future"]?["deliveryErrorCode"] as? Int, 9_876_543, file: file, line: line)
    let failedAttachment = try XCTUnwrap(byID["one"]?["attachments"] as? [[String: Any]]).first
    XCTAssertEqual(failedAttachment?["transferState"] as? Int, 6, file: file, line: line)
    XCTAssertEqual(failedAttachment?["availability"] as? String, "available", file: file, line: line)
  }

  private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
  }
}

private final class EmptySelectedProviderDirectory: ContactsDirectorySource, @unchecked Sendable {
  func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] {
    guard binding.containerID == "status-fixture" else { throw ContactsDirectoryError.selectedContainerMissing(binding.containerID) }
    return []
  }

  func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String>) throws -> ContactLookup {
    guard binding.containerID == "status-fixture" else { throw ContactsDirectoryError.selectedContainerMissing(binding.containerID) }
    return ContactLookup(people: [], unresolvedHandles: matchingHandles, candidatesByHandle: Dictionary(uniqueKeysWithValues: matchingHandles.map { ($0, []) }))
  }
}

private final class ProviderStatusFixture {
  private let root: URL
  private let databaseURL: URL
  private var database: OpaquePointer?
  private let includeStatusColumns: Bool

  init(includeStatusColumns: Bool) throws {
    self.includeStatusColumns = includeStatusColumns
    root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".scratch/provider-status-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    databaseURL = root.appendingPathComponent("chat.db")
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, database != nil else {
      throw MessageStoreError.sqlite("fixture open")
    }
    let messageStatusColumns = includeStatusColumns ? ", is_sent INTEGER, is_delivered INTEGER, error INTEGER" : ""
    let attachmentStatusColumn = includeStatusColumns ? ", transfer_state INTEGER" : ""
    try exec("""
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER, is_read INTEGER, handle_id INTEGER, service TEXT, associated_message_guid TEXT, associated_message_type INTEGER, item_type INTEGER, balloon_bundle_id TEXT, date_edited INTEGER, date_retracted INTEGER\(messageStatusColumns));
      CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT, total_bytes INTEGER, is_sticker INTEGER\(attachmentStatusColumn));
      CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
      INSERT INTO chat VALUES (1, 'status-chat', 'status-thread', NULL, 'iMessage');
      INSERT INTO handle VALUES (1, 'status@example.test');
      INSERT INTO chat_handle_join VALUES (1, 1);
      """)
  }

  deinit {
    sqlite3_close_v2(database)
    try? FileManager.default.removeItem(at: root)
  }

  func operations() throws -> MessagesOperations {
    let state = try LocalState(directory: root.appendingPathComponent("state"))
    try state.bindContainer("status-fixture")
    return MessagesOperations(
      store: MessageStore(path: databaseURL.path), directory: EmptySelectedProviderDirectory(),
      binding: ContactsContainerBinding(containerID: "status-fixture"), state: state
    )
  }

  func insertMessage(id: Int, guid: String, text: String, isSent: Int? = nil, isDelivered: Int? = nil, error: Int? = nil) throws {
    let sent = isSent.map(String.init) ?? "NULL"
    let delivered = isDelivered.map(String.init) ?? "NULL"
    let error = error.map(String.init) ?? "NULL"
    let statusValues = includeStatusColumns ? ", \(sent), \(delivered), \(error)" : ""
    try exec("INSERT INTO message VALUES (\(id), '\(guid)', \(id), '\(text)', NULL, 0, 0, 1, 'iMessage', NULL, 0, 0, NULL, 0, 0\(statusValues)); INSERT INTO chat_message_join VALUES (1, \(id))")
  }

  func insertAttachment(id: Int, messageID: Int, guid: String, transferState: Int? = nil, available: Bool) throws {
    let file = root.appendingPathComponent("attachment-\(id).txt")
    if available { try Data("synthetic".utf8).write(to: file) }
    let state = transferState.map(String.init) ?? "NULL"
    let statusValue = includeStatusColumns ? ", \(state)" : ""
    try exec("INSERT INTO attachment VALUES (\(id), '\(guid)', '\(file.path)', NULL, 'public.plain-text', 'text/plain', NULL, NULL\(statusValue)); INSERT INTO message_attachment_join VALUES (\(messageID), \(id))")
  }

  private func exec(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
      defer { sqlite3_free(error) }
      throw MessageStoreError.sqlite(error.map { String(cString: $0) } ?? "fixture SQL")
    }
  }
}
