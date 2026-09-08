import Foundation

extension MessageStore {
  /// Returns all structurally filtered chats for name discovery.
  public func allChats(_ filter: ChatFilter = ChatFilter()) throws -> [ChatRecord] {
    try validate(filter: filter, limit: 1)
    return try findChatsInternal(filter: filter, limit: nil)
  }

  public func chatSnapshot(
    filter: ChatFilter = ChatFilter(), arrivalFenceRowID: Int64? = nil, databaseGeneration: String? = nil
  ) throws -> ChatSnapshot {
    try validate(filter: filter, limit: 1)
    return try withSnapshot { database, schema, generation in
      if let databaseGeneration, databaseGeneration != generation { throw MessageStoreError.cursorFilterMismatch }
      let fence = try arrivalFenceRowID ?? latestMessageID(database: database)
      return ChatSnapshot(chats: try chats(filter: filter, limit: nil, database: database, schema: schema, fence: fence), databaseGeneration: generation, arrivalFenceRowID: fence)
    }
  }

  public func findChats(_ request: FindChatsRequest) throws -> [ChatRecord] {
    try validate(filter: request.filter, limit: request.limit)
    return try findChatsInternal(filter: request.filter, limit: request.limit)
  }

  public func chat(id: ChatID) throws -> ChatRecord? { try chats(ids: [id]).first }

  /// Fetch only the requested durable GUIDs, including chats without messages.
  public func chats(ids: Set<ChatID>) throws -> [ChatRecord] {
    guard !ids.isEmpty else { return [] }
    return try withSnapshot { database, schema, _ in
      var result: [ChatRecord] = []
      let sorted = ids.sorted { $0.rawValue < $1.rawValue }
      for start in stride(from: 0, to: sorted.count, by: 400) {
        let batch = Array(sorted[start..<min(start + 400, sorted.count)])
        result += try chats(filter: ChatFilter(), limit: nil, database: database, schema: schema, fence: try latestMessageID(database: database), ids: batch)
      }
      return result.sorted { ($0.lastActivityNanos ?? Int64.min, $0.sourceRowID) > ($1.lastActivityNanos ?? Int64.min, $1.sourceRowID) }
    }
  }

  /// The initial contact-cache baseline credits direct counterparts in both
  /// directions and only the actual incoming author in groups. This is not the
  /// future logical activity-count normalizer.
  public func frequentContactHandles(since: Date) throws -> [String: Int] {
    try withSnapshot { database, _, _ in
      let statement = try SQLiteStatement(database, """
        WITH membership AS (
          SELECT chat_id, COUNT(DISTINCT handle_id) AS members, MIN(handle_id) AS counterpart
          FROM chat_handle_join GROUP BY chat_id
        ), credited AS (
          SELECT m.ROWID AS message_id,
            CASE WHEN membership.members = 1 THEN membership.counterpart ELSE m.handle_id END AS handle_id
          FROM message m
          JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
          JOIN membership ON membership.chat_id = cmj.chat_id
          WHERE m.date >= ? AND (membership.members = 1 OR (membership.members > 1 AND m.is_from_me = 0))
        )
        SELECT h.id, COUNT(DISTINCT credited.message_id) FROM credited
        JOIN handle h ON h.ROWID = credited.handle_id GROUP BY h.id
        """)
      defer { statement.finalize() }
      try statement.bind([.integer(try appleEpoch(since))])
      var result: [String: Int] = [:]
      while try statement.step() { if let handle = statement.text(at: 0) { result[handle] = Int(statement.integer(at: 1)) } }
      return result
    }
  }

  private func validate(filter: ChatFilter, limit: Int) throws {
    guard (1...500).contains(limit) else { throw MessageStoreError.invalidLimit(limit) }
    if let start = filter.startDate, let end = filter.endDate, start >= end { throw MessageStoreError.invalidDateRange }
  }

  private func findChatsInternal(filter: ChatFilter, limit: Int?) throws -> [ChatRecord] {
    try withSnapshot { database, schema, _ in
      try chats(filter: filter, limit: limit, database: database, schema: schema, fence: try latestMessageID(database: database))
    }
  }

  private func chats(filter: ChatFilter, limit: Int?, database: OpaquePointer, schema: MessageSchema, fence: Int64, ids: [ChatID]? = nil) throws -> [ChatRecord] {
    let clause = try chatClause(filter: filter, schema: schema, chatAlias: "c", fence: fence)
    let placeholders = ids.map { Array(repeating: "?", count: $0.count).joined(separator: ",") }
    // Exact retrieval starts at chat.guid; message joins remain bounded to those chats.
    let statement = try SQLiteStatement(database, """
      SELECT c.ROWID, c.guid, IFNULL(c.chat_identifier, ''), NULLIF(c.display_name, ''), NULLIF(c.service_name, ''), MAX(m.date)
      FROM chat c
      \(ids == nil ? "JOIN" : "LEFT JOIN") chat_message_join cmj ON cmj.chat_id = c.ROWID
      \(ids == nil ? "JOIN" : "LEFT JOIN") message m ON m.ROWID = cmj.message_id AND m.ROWID <= ?
      WHERE \(placeholders.map { "c.guid IN (\($0))" } ?? clause.sql)
      GROUP BY c.ROWID
      ORDER BY MAX(m.date) DESC, c.ROWID DESC
      \(limit == nil ? "" : "LIMIT ?")
      """)
    defer { statement.finalize() }
    try statement.bind([.integer(fence)] + (ids.map { $0.map { SQLiteValue.text($0.rawValue) } } ?? clause.values) + (limit.map { [.integer(Int64($0))] } ?? []))
    var rows: [(Int64, ChatID, String, String?, String?, Int64?)] = []
    while try statement.step() {
      rows.append((statement.integer(at: 0), ChatID(rawValue: statement.text(at: 1) ?? ""), statement.text(at: 2) ?? "", statement.text(at: 3), statement.text(at: 4), statement.isNull(at: 5) ? nil : statement.integer(at: 5)))
    }
    var members: [Int64: [String]] = [:]
    var unread: [Int64: Int] = [:]
    for start in stride(from: 0, to: rows.count, by: 400) {
      let batch = Array(rows[start..<min(start + 400, rows.count)])
      let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
      let values = batch.map { SQLiteValue.integer($0.0) }
      let participants = try SQLiteStatement(database, "SELECT chj.chat_id, h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id WHERE chj.chat_id IN (\(marks)) ORDER BY h.id COLLATE NOCASE ASC")
      defer { participants.finalize() }
      try participants.bind(values)
      while try participants.step() { if let handle = participants.text(at: 1) { members[participants.integer(at: 0), default: []].append(handle) } }
      if schema.has("is_read") {
        let counts = try SQLiteStatement(database, "SELECT cmj.chat_id, COUNT(*) FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id WHERE cmj.chat_id IN (\(marks)) AND m.ROWID <= ? AND m.is_from_me = 0 AND m.is_read = 0 GROUP BY cmj.chat_id")
        defer { counts.finalize() }
        try counts.bind(values + [.integer(fence)])
        while try counts.step() { unread[counts.integer(at: 0)] = Int(counts.integer(at: 1)) }
      }
    }
    return rows.map { row in
      ChatRecord(id: row.1, sourceRowID: row.0, identifier: row.2, nativeName: row.3, service: row.4, participants: members[row.0] ?? [], lastActivityAt: row.5.map(appleDate), lastActivityNanos: row.5, unreadCount: schema.has("is_read") ? unread[row.0, default: 0] : nil)
    }
  }
}
