import Foundation

extension MessageStore {
  /// Returns all structurally filtered chats. Adapters must apply aliases/name
  /// resolution before their own pagination rather than truncating here.
  public func allChats(_ filter: ChatFilter = ChatFilter()) throws -> [ChatRecord] {
    try validate(filter: filter, limit: 1)
    return try findChatsInternal(filter: filter, limit: nil)
  }

  public func chatSnapshot(
    filter: ChatFilter = ChatFilter(), arrivalFenceRowID: Int64? = nil, databaseGeneration: Int64? = nil
  ) throws -> ChatSnapshot {
    try withSnapshot { database, schema, generation in
      if let databaseGeneration, databaseGeneration != generation { throw MessageStoreError.cursorFilterMismatch }
      let fence: Int64
      if let arrivalFenceRowID { fence = arrivalFenceRowID }
      else { fence = try latestMessageID(database: database) }
      return ChatSnapshot(chats: try chats(filter: filter, limit: nil, database: database, schema: schema, fence: fence), databaseGeneration: generation, arrivalFenceRowID: fence)
    }
  }

  public func findChats(_ request: FindChatsRequest) throws -> [ChatRecord] {
    try validate(filter: request.filter, limit: request.limit)
    return try findChatsInternal(filter: request.filter, limit: request.limit)
  }

  public func chat(id: ChatID) throws -> ChatRecord? {
    try allChats().first { $0.id == id }
  }

  /// Counts interaction rows for each handle in conversations active since the
  /// supplied date; group conversations contribute to each member's baseline.
  public func frequentContactHandles(since: Date) throws -> [String: Int] {
    try withSnapshot { database, _, _ in
      let statement = try SQLiteStatement(database, """
        SELECT h.id, COUNT(*) FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat_handle_join chj ON chj.chat_id = cmj.chat_id
        JOIN handle h ON h.ROWID = chj.handle_id
        WHERE m.date >= ? GROUP BY h.id
        """)
      defer { statement.finalize() }
      try statement.bind([.integer(try appleEpoch(since))])
      var result: [String: Int] = [:]
      while try statement.step() { if let handle = statement.text(at: 0) { result[handle] = Int(statement.integer(at: 1)) } }
      return result
    }
  }

  private func findChatsInternal(filter: ChatFilter, limit: Int?) throws -> [ChatRecord] {
    try withSnapshot { database, schema, _ in
      try chats(filter: filter, limit: limit, database: database, schema: schema, fence: try latestMessageID(database: database))
    }
  }

  private func chats(filter: ChatFilter, limit: Int?, database: OpaquePointer, schema: MessageSchema, fence: Int64) throws -> [ChatRecord] {
      let clause = try chatClause(filter: filter, schema: schema, chatAlias: "c", fence: fence)
      let sql = """
        SELECT c.ROWID, c.guid, IFNULL(c.chat_identifier, ''), NULLIF(c.display_name, ''), NULLIF(c.service_name, ''), MAX(m.date)
        FROM chat c
        JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
        JOIN message m ON m.ROWID = cmj.message_id
        WHERE \(clause.sql)
        GROUP BY c.ROWID
        ORDER BY MAX(m.date) DESC, c.ROWID DESC
        \(limit == nil ? "" : "LIMIT ?")
        """
      let statement = try SQLiteStatement(database, sql)
      defer { statement.finalize() }
      try statement.bind(clause.values + (limit.map { [.integer(Int64($0))] } ?? []))
      var result: [ChatRecord] = []
      while try statement.step() {
        let rowID = statement.integer(at: 0)
        let id = ChatID(rawValue: statement.text(at: 1) ?? "")
        result.append(ChatRecord(
          id: id,
          sourceRowID: rowID,
          identifier: statement.text(at: 2) ?? "",
          nativeName: statement.text(at: 3),
          service: statement.text(at: 4),
          participants: try participants(chatRowID: rowID, database: database),
          lastActivityAt: appleDate(statement.integer(at: 5)),
          lastActivityNanos: statement.isNull(at: 5) ? nil : statement.integer(at: 5),
          unreadCount: schema.has("is_read") ? try unreadCount(chatRowID: rowID, database: database) : nil
        ))
      }
      return result
  }

  public func readMessages(_ request: ReadMessagesRequest) throws -> MessagePage {
    try validate(filter: request.filter, limit: request.limit, cursor: request.cursor)
    if let cursor = request.cursor, cursor.searchQuery != nil || cursor.searchMode != nil {
      throw MessageStoreError.cursorFilterMismatch
    }
    return try page(filter: request.filter, limit: request.limit, cursor: request.cursor, search: nil)
  }

  public func searchMessages(_ request: SearchMessagesRequest) throws -> MessagePage {
    try validate(filter: request.filter, limit: request.limit, cursor: request.cursor)
    let trimmed = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return MessagePage(messages: [], nextCursor: nil, decodingFailures: []) }
    if let cursor = request.cursor, cursor.searchQuery != request.query || cursor.searchMode != request.mode {
      throw MessageStoreError.cursorFilterMismatch
    }
    return try page(filter: request.filter, limit: request.limit, cursor: request.cursor, search: (request.query, request.mode))
  }

  private func page(
    filter: MessageFilter,
    limit: Int,
    cursor: MessagePageCursor?,
    search: (String, MessageSearchMode)?
  ) throws -> MessagePage {
    try withSnapshot { database, schema, generation in
      if let cursor, cursor.databaseGeneration != generation { throw MessageStoreError.cursorFilterMismatch }
      let fence: Int64
      if let cursor { fence = cursor.arrivalFenceRowID }
      else { fence = try latestMessageID(database: database) }
      let clause = try messageClause(filter: filter, cursor: cursor, fence: fence, schema: schema)
      let select = messageSelect(schema: schema)
      let limitClause = search == nil ? "LIMIT ?" : ""
      let sql = """
        SELECT \(select)
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE \(clause.sql)
        ORDER BY m.date DESC, m.ROWID DESC
        \(limitClause)
        """
      let statement = try SQLiteStatement(database, sql)
      defer { statement.finalize() }
      try statement.bind(clause.values + (search == nil ? [.integer(Int64(limit + 1))] : []))
      var records: [MessageRecord] = []
      var decodingFailures: [BodyDecodingFailure] = []
      while try statement.step() {
        let rowID = statement.integer(at: 0)
        let messageID = MessageID(rawValue: statement.text(at: 3).flatMap { $0.isEmpty ? nil : $0 } ?? "\(generation):\(rowID)")
        let chatID = ChatID(rawValue: statement.text(at: 2) ?? "")
        let body = BodyDecoder.decode(plainText: statement.text(at: 5), attributedBody: statement.data(at: 6))
        if body.status == .failed { decodingFailures.append(BodyDecodingFailure(messageID: messageID, chatID: chatID)) }
        if let search, !NativeMatcher.matches(body.text ?? "", query: search.0, mode: search.1) {
          continue
        }
        records.append(try message(from: statement, database: database, schema: schema, generation: generation, resolvedBody: body))
        if records.count > limit { break }
      }
      return makePage(records, filter: filter, search: search, fence: fence, generation: generation, limit: limit, decodingFailures: decodingFailures)
    }
  }
}

private extension MessageStore {
  func validate(filter: ChatFilter, limit: Int) throws {
    guard (1...500).contains(limit) else { throw MessageStoreError.invalidLimit(limit) }
    if let start = filter.startDate, let end = filter.endDate, start >= end { throw MessageStoreError.invalidDateRange }
  }

  func validate(filter: MessageFilter, limit: Int, cursor: MessagePageCursor?) throws {
    guard (1...500).contains(limit) else { throw MessageStoreError.invalidLimit(limit) }
    if let start = filter.startDate, let end = filter.endDate, start >= end { throw MessageStoreError.invalidDateRange }
    if let cursor, cursor.filter != filter { throw MessageStoreError.cursorFilterMismatch }
  }

  func latestMessageID(database: OpaquePointer) throws -> Int64 {
    let statement = try SQLiteStatement(database, "SELECT IFNULL(MAX(ROWID), 0) FROM message")
    defer { statement.finalize() }
    _ = try statement.step()
    return statement.integer(at: 0)
  }

  func participants(chatRowID: Int64, database: OpaquePointer) throws -> [String] {
    let statement = try SQLiteStatement(database, """
      SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
      WHERE chj.chat_id = ? ORDER BY h.id COLLATE NOCASE ASC
      """)
    defer { statement.finalize() }
    try statement.bind([.integer(chatRowID)])
    var result: [String] = []
    while try statement.step() { if let handle = statement.text(at: 0) { result.append(handle) } }
    return result
  }

  func unreadCount(chatRowID: Int64, database: OpaquePointer) throws -> Int {
    let statement = try SQLiteStatement(database, """
      SELECT COUNT(*) FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
      WHERE cmj.chat_id = ? AND m.is_from_me = 0 AND m.is_read = 0
      """)
    defer { statement.finalize() }
    try statement.bind([.integer(chatRowID)])
    _ = try statement.step()
    return Int(statement.integer(at: 0))
  }

  func makePage(_ messages: [MessageRecord], filter: MessageFilter, search: (String, MessageSearchMode)?, fence: Int64, generation: Int64, limit: Int, decodingFailures: [BodyDecodingFailure]) -> MessagePage {
    guard messages.count > limit else { return MessagePage(messages: messages, nextCursor: nil, decodingFailures: decodingFailures) }
    let returned = Array(messages.prefix(limit))
    let last = returned[returned.count - 1]
    return MessagePage(messages: returned, nextCursor: MessagePageCursor(
      filter: filter, searchQuery: search?.0, searchMode: search?.1,
      beforeDateNanos: last.sourceDateNanos, beforeRowID: last.sourceRowID,
      arrivalFenceRowID: fence, databaseGeneration: generation), decodingFailures: decodingFailures)
  }
}

private struct SQLClause { let sql: String; let values: [SQLiteValue] }

private extension MessageStore {
  func normalizedHandles(_ input: [String]) -> [String] {
    Array(Set(input.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
  }

  func chatClause(filter: ChatFilter, schema: MessageSchema, chatAlias: String, fence: Int64) throws -> SQLClause {
    var conditions = ["m.ROWID <= ?"]
    var values: [SQLiteValue] = [.integer(fence)]
    appendMembership(filter.participantHandles, groups: filter.participantHandleGroups, exact: filter.exactMembership, chatAlias: "\(chatAlias).ROWID", conditions: &conditions, values: &values)
    if let start = filter.startDate { conditions.append("m.date >= ?"); values.append(.integer(try appleEpoch(start))) }
    if let end = filter.endDate { conditions.append("m.date < ?"); values.append(.integer(try appleEpoch(end))) }
    if filter.unreadOnly {
      guard schema.has("is_read") else { throw MessageStoreError.missingSchema("message.is_read for unread filter") }
      conditions.append("m.is_from_me = 0 AND m.is_read = 0")
    }
    return SQLClause(sql: conditions.joined(separator: " AND "), values: values)
  }

  func messageClause(filter: MessageFilter, cursor: MessagePageCursor?, fence: Int64, schema: MessageSchema) throws -> SQLClause {
    var conditions = ["m.ROWID <= ?"]
    var values: [SQLiteValue] = [.integer(fence)]
    if let chatID = filter.chatID { conditions.append("c.guid = ?"); values.append(.text(chatID.rawValue)) }
    appendMembership(filter.participantHandles, groups: filter.participantHandleGroups, exact: filter.exactMembership, chatAlias: "cmj.chat_id", conditions: &conditions, values: &values)
    if let start = filter.startDate { conditions.append("m.date >= ?"); values.append(.integer(try appleEpoch(start))) }
    if let end = filter.endDate { conditions.append("m.date < ?"); values.append(.integer(try appleEpoch(end))) }
    if filter.unreadOnly {
      guard schema.has("is_read") else { throw MessageStoreError.missingSchema("message.is_read for unread filter") }
      conditions.append("m.is_from_me = 0 AND m.is_read = 0")
    }
    if let cursor {
      conditions.append("(m.date < ? OR (m.date = ? AND m.ROWID < ?))")
      values += [.integer(cursor.beforeDateNanos), .integer(cursor.beforeDateNanos), .integer(cursor.beforeRowID)]
    }
    return SQLClause(sql: conditions.joined(separator: " AND "), values: values)
  }

  func appendMembership(_ input: [String], groups: [[String]], exact: Bool, chatAlias: String, conditions: inout [String], values: inout [SQLiteValue]) {
    let resolvedGroups = groups.filter { !$0.isEmpty } + input.map { [$0] }
    let handles = normalizedHandles(resolvedGroups.flatMap { $0 })
    for group in resolvedGroups.map(normalizedHandles).filter({ !$0.isEmpty }) {
      let placeholders = Array(repeating: "?", count: group.count).joined(separator: ",")
      conditions.append("EXISTS (SELECT 1 FROM chat_handle_join member_join JOIN handle member ON member.ROWID = member_join.handle_id WHERE member_join.chat_id = \(chatAlias) AND lower(member.id) IN (\(placeholders)))")
      values += group.map(SQLiteValue.text)
    }
    guard exact, !handles.isEmpty else { return }
    let placeholders = Array(repeating: "?", count: handles.count).joined(separator: ",")
    conditions.append("NOT EXISTS (SELECT 1 FROM chat_handle_join member_join JOIN handle member ON member.ROWID = member_join.handle_id WHERE member_join.chat_id = \(chatAlias) AND lower(member.id) NOT IN (\(placeholders)))")
    values += handles.map(SQLiteValue.text)
  }

  func appleEpoch(_ date: Date) throws -> Int64 {
    let value = (date.timeIntervalSince1970 - 978_307_200) * 1_000_000_000
    guard value.isFinite, value > Double(Int64.min), value < Double(Int64.max) else { throw MessageStoreError.invalidDateRange }
    return Int64(value)
  }
  func appleDate(_ value: Int64) -> Date { Date(timeIntervalSince1970: (Double(value) / 1_000_000_000) + 978_307_200) }
}
