import CSQLite
import Foundation

public enum MessageStoreError: Error, LocalizedError, Sendable {
  case invalidLimit(Int)
  case invalidDateRange
  case cursorFilterMismatch
  case databaseReplaced
  case databaseIdentityUnavailable(Int32)
  case missingSchema(String)
  case sqlite(String)

  public var errorDescription: String? {
    switch self {
    case .invalidLimit(let value): return "Page limit must be between 1 and 500, got \(value)."
    case .invalidDateRange: return "The start date must be earlier than the end date."
    case .databaseIdentityUnavailable: return "SQLite could not verify the opened database identity; restart with a fresh store."
    case .databaseReplaced: return "The opened Messages database was moved or replaced; create a new store and restart the query."
    case .cursorFilterMismatch: return "The continuation cursor does not match the requested filter."
    case .missingSchema(let detail): return "The Messages database is missing required schema: \(detail)."
    case .sqlite(let detail): return detail
    }
  }
}

public final class MessageStore: @unchecked Sendable {
  private let path: String
  private let lock = NSLock()
  private let instanceID = UUID().uuidString
  private var connection: OpaquePointer?

  public init(path: String) { self.path = path }

  deinit { if let connection { sqlite3_close_v2(connection) } }

  /// One connection owns the database instance for this store's lifetime. Never
  /// reopen by pathname: a cursor from another instance cannot select this one.
  func withSnapshot<T>(_ work: (OpaquePointer, MessageSchema, String) throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    let database = try openedConnection()
    try rejectMovedDatabase(database)
    try sqlite(database, "BEGIN")
    defer { _ = try? sqlite(database, "ROLLBACK") }
    let result = try work(database, try MessageSchema(database: database), instanceID)
    try rejectMovedDatabase(database)
    return result
  }

  private func openedConnection() throws -> OpaquePointer {
    if let connection { return connection }
    var opened: OpaquePointer?
    let status = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
    guard status == SQLITE_OK, let opened else {
      if let opened { sqlite3_close_v2(opened) }
      throw MessageStoreError.sqlite("Could not open Messages database")
    }
    connection = opened
    return opened
  }

  private func rejectMovedDatabase(_ database: OpaquePointer) throws {
    var moved: Int32 = 0
    let result = sqlite3_file_control(database, "main", SQLITE_FCNTL_HAS_MOVED, &moved)
    guard result == SQLITE_OK else { throw MessageStoreError.databaseIdentityUnavailable(result) }
    if moved != 0 { throw MessageStoreError.databaseReplaced }
  }
}

struct MessageSchema: Sendable {
  let messageColumns: Set<String>
  let chatColumns: Set<String>
  let attachmentColumns: Set<String>
  let hasAttachmentTables: Bool

  init(database: OpaquePointer) throws {
    self.messageColumns = try Self.columns(database: database, table: "message")
    guard !messageColumns.isEmpty else { throw MessageStoreError.missingSchema("message table") }
    for column in ["date", "is_from_me", "text"] where !messageColumns.contains(column) {
      throw MessageStoreError.missingSchema("message.\(column)")
    }
    guard try Self.tableExists(database: database, table: "chat_message_join"),
      try Self.tableExists(database: database, table: "chat")
    else { throw MessageStoreError.missingSchema("chat and chat_message_join tables") }
    self.chatColumns = try Self.columns(database: database, table: "chat")
    guard chatColumns.contains("guid") else { throw MessageStoreError.missingSchema("chat.guid") }
    self.hasAttachmentTables = try Self.tableExists(database: database, table: "message_attachment_join")
      && Self.tableExists(database: database, table: "attachment")
    self.attachmentColumns = hasAttachmentTables ? try Self.columns(database: database, table: "attachment") : []
  }

  func has(_ column: String) -> Bool { messageColumns.contains(column.lowercased()) }
  func chatHas(_ column: String) -> Bool { chatColumns.contains(column.lowercased()) }
  func attachmentHas(_ column: String) -> Bool { attachmentColumns.contains(column.lowercased()) }

  private static func tableExists(database: OpaquePointer, table: String) throws -> Bool {
    let statement = try SQLiteStatement(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
    defer { statement.finalize() }
    try statement.bind([.text(table)])
    return try statement.step()
  }

  private static func columns(database: OpaquePointer, table: String) throws -> Set<String> {
    let statement = try SQLiteStatement(database, "PRAGMA table_info(\(table))")
    defer { statement.finalize() }
    var result = Set<String>()
    while try statement.step() {
      if let name = statement.text(at: 1) { result.insert(name.lowercased()) }
    }
    return result
  }
}

enum SQLiteValue {
  case integer(Int64)
  case text(String)
  case null
}

final class SQLiteStatement {
  private let database: OpaquePointer
  private var statement: OpaquePointer?

  init(_ database: OpaquePointer, _ sql: String) throws {
    self.database = database
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard result == SQLITE_OK else { throw MessageStoreError.sqlite(sqliteMessage(database)) }
  }

  func finalize() { sqlite3_finalize(statement) }

  func bind(_ values: [SQLiteValue]) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
      case .text(let string):
        result = string.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
      case .null: result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else { throw MessageStoreError.sqlite(sqliteMessage(database)) }
    }
  }

  func step() throws -> Bool {
    let result = sqlite3_step(statement)
    if result == SQLITE_ROW { return true }
    if result == SQLITE_DONE { return false }
    throw MessageStoreError.sqlite(sqliteMessage(database))
  }

  func isNull(at index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
  func integer(at index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
  func text(at index: Int32) -> String? {
    guard let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: pointer)
  }
  func data(at index: Int32) -> Data? {
    guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func sqlite(_ database: OpaquePointer, _ sql: String) throws {
  var error: UnsafeMutablePointer<CChar>?
  let result = sqlite3_exec(database, sql, nil, nil, &error)
  defer { sqlite3_free(error) }
  guard result == SQLITE_OK else {
    throw MessageStoreError.sqlite(error.map { String(cString: $0) } ?? sqliteMessage(database))
  }
}

func sqliteMessage(_ database: OpaquePointer?) -> String {
  guard let database, let message = sqlite3_errmsg(database) else { return "SQLite error" }
  return String(cString: message)
}
