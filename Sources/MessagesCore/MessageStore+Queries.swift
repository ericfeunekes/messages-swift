import Foundation

extension MessageStore {
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
    guard !trimmed.isEmpty else { return MessagePage(messages: [], nextCursor: nil, decodingFailures: [], decodingFailureCount: 0, scannedAssociationCount: 0) }
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
        ORDER BY m.date DESC, m.ROWID DESC, cmj.chat_id DESC
        \(limitClause)
        """
      let statement = try SQLiteStatement(database, sql)
      defer { statement.finalize() }
      try statement.bind(clause.values + (search == nil ? [.integer(Int64(limit + 1))] : []))
      var records: [MessageRecord] = []
      var examples: [BodyDecodingFailure] = []
      var failureCount = 0
      var scannedCount = 0
      var nextCursor: MessagePageCursor?
      while try statement.step() {
        let rowID = statement.integer(at: 0)
        let messageID = MessageID(rawValue: statement.text(at: 3).flatMap { $0.isEmpty ? nil : $0 } ?? "\(generation):\(rowID)")
        let chatID = ChatID(rawValue: statement.text(at: 2) ?? "")
        let body = BodyDecoder.decode(plainText: statement.text(at: 5), attributedBody: statement.data(at: 6))
        scannedCount += 1
        if body.status == .failed {
          failureCount += 1
          if examples.count < 10 { examples.append(BodyDecodingFailure(messageID: messageID, chatID: chatID)) }
        }
        if let search, !NativeMatcher.matches(body.text ?? "", query: search.0, mode: search.1) { continue }
        let record = try message(from: statement, database: database, schema: schema, generation: generation, resolvedBody: body)
        records.append(record)
        if records.count == limit {
          // Look only for existence. This association is not consumed, decoded
          // or diagnosed until the next page starts after the last returned key.
          if try statement.step() {
            nextCursor = MessagePageCursor(filter: filter, searchQuery: search?.0, searchMode: search?.1,
              beforeDateNanos: record.sourceDateNanos, beforeRowID: record.sourceRowID,
              beforeChatRowID: record.sourceChatRowID, arrivalFenceRowID: fence, databaseGeneration: generation)
          }
          break
        }
      }
      return MessagePage(messages: records, nextCursor: nextCursor, decodingFailures: examples,
                         decodingFailureCount: failureCount, scannedAssociationCount: scannedCount)
    }
  }
}

extension MessageStore {
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


}

struct SQLClause { let sql: String; let values: [SQLiteValue] }

extension MessageStore {
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

  func messageClause(filter: MessageFilter, cursor: MessagePageCursor?, fence: Int64, schema: MessageSchema, membershipFence: Int64? = nil) throws -> SQLClause {
    var conditions = ["m.ROWID <= ?"]
    var values: [SQLiteValue] = [.integer(fence)]
    if let chatID = filter.chatID { conditions.append("c.guid = ?"); values.append(.text(chatID.rawValue)) }
    appendMembership(filter.participantHandles, groups: filter.participantHandleGroups, exact: filter.exactMembership, chatAlias: "cmj.chat_id", conditions: &conditions, values: &values, arrivalFence: membershipFence)
    if let start = filter.startDate { conditions.append("m.date >= ?"); values.append(.integer(try appleEpoch(start))) }
    if let end = filter.endDate { conditions.append("m.date < ?"); values.append(.integer(try appleEpoch(end))) }
    if filter.unreadOnly {
      guard schema.has("is_read") else { throw MessageStoreError.missingSchema("message.is_read for unread filter") }
      conditions.append("m.is_from_me = 0 AND m.is_read = 0")
    }
    if let cursor {
      conditions.append("(m.date < ? OR (m.date = ? AND (m.ROWID < ? OR (m.ROWID = ? AND cmj.chat_id < ?))))")
      values += [.integer(cursor.beforeDateNanos), .integer(cursor.beforeDateNanos), .integer(cursor.beforeRowID), .integer(cursor.beforeRowID), .integer(cursor.beforeChatRowID)]
    }
    return SQLClause(sql: conditions.joined(separator: " AND "), values: values)
  }

  func appendMembership(_ input: [String], groups: [[String]], exact: Bool, chatAlias: String, conditions: inout [String], values: inout [SQLiteValue], arrivalFence: Int64? = nil) {
    let fenceClause = arrivalFence.map { " AND member_join.ROWID <= \($0)" } ?? ""
    let resolvedGroups = groups.filter { !$0.isEmpty } + input.map { [$0] }
    let handles = normalizedHandles(resolvedGroups.flatMap { $0 })
    for group in resolvedGroups.map(normalizedHandles).filter({ !$0.isEmpty }) {
      let placeholders = Array(repeating: "?", count: group.count).joined(separator: ",")
      conditions.append("EXISTS (SELECT 1 FROM chat_handle_join member_join JOIN handle member ON member.ROWID = member_join.handle_id WHERE member_join.chat_id = \(chatAlias)\(fenceClause) AND lower(member.id) IN (\(placeholders)))")
      values += group.map(SQLiteValue.text)
    }
    guard exact, !handles.isEmpty else { return }
    let placeholders = Array(repeating: "?", count: handles.count).joined(separator: ",")
    conditions.append("NOT EXISTS (SELECT 1 FROM chat_handle_join member_join JOIN handle member ON member.ROWID = member_join.handle_id WHERE member_join.chat_id = \(chatAlias)\(fenceClause) AND lower(member.id) NOT IN (\(placeholders)))")
    values += handles.map(SQLiteValue.text)
  }

  func appleEpoch(_ date: Date) throws -> Int64 {
    let value = (date.timeIntervalSince1970 - 978_307_200) * 1_000_000_000
    guard value.isFinite, value > Double(Int64.min), value < Double(Int64.max) else { throw MessageStoreError.invalidDateRange }
    return Int64(value)
  }
  func appleDate(_ value: Int64) -> Date { Date(timeIntervalSince1970: (Double(value) / 1_000_000_000) + 978_307_200) }
}
