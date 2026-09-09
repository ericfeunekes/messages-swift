import Foundation

public struct OutgoingMessageStatus: Sendable, Equatable {
    public let messageID: String
    public let isSent: Bool?
    public let isDelivered: Bool?
    public let deliveryErrorCode: Int?
    public let service: String?
}

public enum OutgoingStatusObservation: Sendable, Equatable {
    case none
    case unique(OutgoingMessageStatus)
    case ambiguous
}

extension MessageStore {
    func latestRouteHistory(chatID: String?, handle: String?) throws -> (service: String?, basis: String) {
        try withSnapshot { database, schema, _ in
            guard schema.has("is_sent") else { return (nil, "no_history") }
            let errorColumn = schema.has("error") ? "m.error" : "NULL"
            let serviceColumn = schema.has("service") ? "m.service" : "NULL"
            let sql: String
            let values: [SQLiteValue]
            if let chatID {
                sql = "SELECT m.is_sent, \(errorColumn), \(serviceColumn) FROM message m JOIN chat_message_join cmj ON cmj.message_id=m.ROWID JOIN chat c ON c.ROWID=cmj.chat_id WHERE c.guid=? AND m.is_from_me!=0 ORDER BY m.date DESC, m.ROWID DESC LIMIT 1"
                values = [.text(chatID)]
            } else if let handle {
                sql = "SELECT m.is_sent, \(errorColumn), \(serviceColumn) FROM message m JOIN chat_message_join cmj ON cmj.message_id=m.ROWID WHERE cmj.chat_id IN (SELECT chj.chat_id FROM chat_handle_join chj JOIN chat dc ON dc.ROWID=chj.chat_id GROUP BY chj.chat_id HAVING COUNT(*)=1 AND lower(MAX(dc.chat_identifier))=? AND MAX(chj.handle_id) IN (SELECT h.ROWID FROM handle h WHERE lower(h.id)=?)) AND m.is_from_me!=0 ORDER BY m.date DESC, m.ROWID DESC LIMIT 1"
                values = [.text(handle.lowercased()), .text(handle.lowercased())]
            } else { return (nil, "no_history") }
            let statement = try SQLiteStatement(database, sql); defer { statement.finalize() }
            try statement.bind(values); guard try statement.step() else { return (nil, "no_history") }
            let sent = !statement.isNull(at: 0) && statement.integer(at: 0) != 0
            let error = statement.isNull(at: 1) ? nil : statement.integer(at: 1)
            let service = statement.text(at: 2)
            return sent && (error == nil || error == 0) && service != nil ? (service, "latest_successful") : (nil, sent ? "history_conflicted" : "last_attempt_unconfirmed")
        }
    }
    func outgoingMatchFence() throws -> Int64 {
        try withSnapshot { database, _, _ in try latestMessageID(database: database) }
    }

    /// This only treats a source status as relevant after finding exactly one
    /// post-dispatch candidate. It deliberately does not choose a newest row
    /// when another process could have created an identical one concurrently.
    func outgoingMessageStatus(afterRowID fence: Int64, target: SendTarget, expectedService: String?, payload: SendPayload) throws -> OutgoingStatusObservation {
        try withSnapshot { database, schema, generation in
            guard schema.has("guid") else { return .none }
            let targetSQL: String
            let targetValues: [SQLiteValue]
            switch target {
            case .chat(let chatID):
                targetSQL = "JOIN chat_message_join cmj ON cmj.message_id = m.ROWID JOIN chat c ON c.ROWID = cmj.chat_id WHERE c.guid = ?"
                targetValues = [.text(chatID)]
            case .individual(let handle, _):
                targetSQL = """
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id IN (
                    SELECT chj.chat_id
                    FROM chat_handle_join chj JOIN chat dc ON dc.ROWID = chj.chat_id
                    GROUP BY chj.chat_id
                    HAVING COUNT(*) = 1 AND lower(MAX(dc.chat_identifier)) = ? AND MAX(chj.handle_id) IN (
                        SELECT h.ROWID FROM handle h WHERE lower(h.id) = ?
                    )
                )
                """
                targetValues = [.text(handle.lowercased()), .text(handle.lowercased())]
            }
            let payloadSQL: String
            let payloadValues: [SQLiteValue]
            switch payload {
            case .text:
                payloadSQL = "1 = 1"
                payloadValues = []
            case .file(let path):
                guard schema.hasAttachmentTables else { return .none }
                let normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
                let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
                payloadSQL = "EXISTS (SELECT 1 FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id WHERE maj.message_id = m.ROWID AND (a.filename = ? OR (a.filename LIKE '~/%' AND ? || substr(a.filename, 3) = ?)))"
                payloadValues = [.text(normalized), .text(home), .text(normalized)]
            }
            let serviceSQL: String
            switch expectedService {
            case "iMessage": serviceSQL = " AND m.service = 'iMessage'"
            case "SMS", "RCS": serviceSQL = " AND m.service IN ('SMS', 'RCS')"
            default: serviceSQL = ""
            }
            let status = try SQLiteStatement(database, """
                SELECT DISTINCT m.ROWID, m.guid, \(schema.has("text") ? "m.text" : "NULL"), \(schema.has("attributedbody") ? "m.attributedbody" : "NULL"), \(schema.has("is_sent") ? "m.is_sent" : "NULL"), \(schema.has("is_delivered") ? "m.is_delivered" : "NULL"), \(schema.has("error") ? "m.error" : "NULL"), \(schema.has("service") ? "m.service" : "NULL")
                FROM message m
                \(targetSQL) AND m.ROWID > ? AND m.is_from_me != 0\(serviceSQL) AND \(payloadSQL)
                ORDER BY m.ROWID ASC
                LIMIT 33
                """)
            defer { status.finalize() }
            try status.bind(targetValues + [.integer(fence)] + payloadValues)
            var matches: [OutgoingMessageStatus] = []
            var scanned = 0
            while try status.step() {
                scanned += 1
                // The bounded window is a safety limit, not a selection rule:
                // a busier window is ambiguous rather than silently truncated.
                if scanned > 32 { return .ambiguous }
                if case let .text(expected) = payload,
                   BodyDecoder.decode(plainText: status.text(at: 2), attributedBody: status.data(at: 3)).text != expected {
                    continue
                }
            let rowID = status.integer(at: 0)
            let messageID = status.text(at: 1).flatMap { $0.isEmpty ? nil : $0 } ?? "\(generation):\(rowID)"
                matches.append(OutgoingMessageStatus(
                messageID: messageID,
                isSent: status.isNull(at: 4) ? nil : status.integer(at: 4) != 0,
                isDelivered: status.isNull(at: 5) ? nil : status.integer(at: 5) != 0,
                deliveryErrorCode: status.isNull(at: 6) ? nil : Int(status.integer(at: 6)),
                service: status.text(at: 7)
                ))
            }
            if matches.count == 1 { return .unique(matches[0]) }
            return matches.isEmpty ? .none : .ambiguous
        }
    }
}
