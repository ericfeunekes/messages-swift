import Foundation

extension MessageStore {
    /// Scan association arrivals, not message dates or message-row arrivals. A
    /// late chat join is therefore visible even after newer messages were read.
    func watchBatch(chatID: String, cursor: WatchCursor?, limit: Int) throws -> WatchBatch {
        try withSnapshot { database, schema, generation in
            if let cursor, cursor.generation != generation || cursor.chatID != chatID {
                throw MessageStoreError.cursorFilterMismatch
            }
            let anchorSelect = "cmj.ROWID, cmj.message_id, cmj.chat_id, m.guid, c.guid"
            let joins = "FROM chat_message_join cmj LEFT JOIN message m ON m.ROWID = cmj.message_id LEFT JOIN chat c ON c.ROWID = cmj.chat_id"
            func anchor(_ statement: SQLiteStatement, offset: Int32 = 0) throws -> WatchAnchor {
                guard !statement.isNull(at: offset + 1), !statement.isNull(at: offset + 2),
                      let chat = statement.text(at: offset + 4) else { throw WatchError.positionInvalidated }
                return WatchAnchor(row: statement.integer(at: offset), messageRow: statement.integer(at: offset + 1),
                                   chatRow: statement.integer(at: offset + 2), messageGUID: statement.text(at: offset + 3), chatGUID: chat)
            }
            // GUID is optional in history; preserve that compatibility in anchors.
            let select = schema.has("guid") ? anchorSelect : anchorSelect.replacingOccurrences(of: "m.guid", with: "NULL")
            if let previous = cursor?.anchor {
                let check = try SQLiteStatement(database, "SELECT \(select), m.ROWID \(joins) WHERE cmj.ROWID = ?")
                defer { check.finalize() }
                try check.bind([.integer(previous.row)])
                guard try check.step(), !check.isNull(at: 5), try anchor(check) == previous else { throw WatchError.positionInvalidated }
            }
            guard var position = cursor else {
                let latest = try SQLiteStatement(database, "SELECT \(select), m.ROWID \(joins) ORDER BY cmj.ROWID DESC LIMIT 1")
                defer { latest.finalize() }
                var baseline: WatchAnchor?
                if try latest.step() {
                    guard !latest.isNull(at: 5) else { throw WatchError.positionInvalidated }
                    baseline = try anchor(latest)
                }
                return WatchBatch(cursor: WatchCursor(generation: generation, chatID: chatID, anchor: baseline), records: [])
            }
            let statement = try SQLiteStatement(database, """
                SELECT \(messageSelect(schema: schema)), cmj.ROWID, cmj.message_id
                \(joins) LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE cmj.ROWID > ? ORDER BY cmj.ROWID ASC LIMIT 256
                """)
            defer { statement.finalize() }
            try statement.bind([.integer(position.anchor?.row ?? 0)])
            var records: [MessageRecord] = []
            while try statement.step() {
                try Task.checkCancellation()
                guard !statement.isNull(at: 0), let currentChat = statement.text(at: 2) else { throw WatchError.positionInvalidated }
                position.anchor = WatchAnchor(row: statement.integer(at: 19), messageRow: statement.integer(at: 20),
                                              chatRow: statement.integer(at: 1), messageGUID: statement.text(at: 3), chatGUID: currentChat)
                if currentChat == chatID && !statement.isNull(at: 7) && statement.integer(at: 7) == 0 {
                    records.append(try message(from: statement, database: database, schema: schema, generation: generation))
                    if records.count == limit { break }
                }
            }
            return WatchBatch(cursor: position, records: records)
        }
    }
}
