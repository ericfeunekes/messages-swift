import CryptoKit
import Foundation

extension MessageStore {
    func countMessageActivity(_ input: CountMessageActivityInput, filter: MessageFilter,
                              cursor: ActivityCursor?, now: Date) throws -> ActivityPage {
        guard (1...100).contains(input.limit) else { throw OperationError.invalidLimit(input.limit) }
        let resolvedZone = cursor?.timeZone ?? input.timeZone ?? TimeZone.current.identifier
        guard let zone = TimeZone(identifier: resolvedZone) else { throw ActivityError.invalidTimeZone }
        if let cursor, cursor.input != input.withoutCursor || cursor.filter != filter || cursor.offset < 0 {
            throw MessageStoreError.cursorFilterMismatch
        }
        return try withSnapshot { database, schema, generation in
            if let cursor, cursor.generation != generation { throw MessageStoreError.cursorFilterMismatch }
            if cursor != nil, let chatID = filter.chatID {
                let selected = try SQLiteStatement(database, "SELECT 1 FROM chat WHERE guid = ? LIMIT 1")
                defer { selected.finalize() }
                try selected.bind([.text(chatID.rawValue)])
                if try !selected.step() {
                    throw ActivityError.continuationInvalidated
                }
            }
            func maximum(_ table: String) throws -> Int64 {
                let statement = try SQLiteStatement(database, "SELECT IFNULL(MAX(ROWID), 0) FROM \(table)")
                defer { statement.finalize() }
                _ = try statement.step(); return statement.integer(at: 0)
            }
            let messageFence = try cursor?.messageFence ?? latestMessageID(database: database)
            let associationFence = try cursor?.associationFence ?? maximum("chat_message_join")
            let chatFence = try cursor?.chatFence ?? maximum("chat")
            let membershipFence = try cursor?.membershipFence ?? maximum("chat_handle_join")
            var baseFilter = filter
            baseFilter.startDate = nil; baseFilter.endDate = nil
            let base = try messageClause(filter: baseFilter, cursor: nil, fence: messageFence, schema: schema, membershipFence: membershipFence)
            let baseSQL = base.sql + " AND cmj.ROWID <= ? AND c.ROWID <= ?"
            let baseValues = base.values + [.integer(associationFence), .integer(chatFence)]
            let end = try cursor?.endNanos ?? activityEpoch(filter.endDate ?? now)
            let start: Int64
            if let cursor { start = cursor.startNanos }
            else if let requested = filter.startDate { start = try activityEpoch(requested) }
            else {
                let earliest = try SQLiteStatement(database, """
                    SELECT MIN(m.date) FROM message m
                    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                    JOIN chat c ON c.ROWID = cmj.chat_id
                    WHERE \(baseSQL) AND m.date < ?
                    """)
                defer { earliest.finalize() }
                try earliest.bind(baseValues + [.integer(end)])
                _ = try earliest.step()
                start = earliest.isNull(at: 0) ? end : earliest.integer(at: 0)
            }
            guard start <= end, start > -8_589_934_592_000_000_000, end < 8_589_934_592_000_000_000 else { throw MessageStoreError.invalidDateRange }
            let intervals = try activityIntervals(start: start, end: end, bucket: input.bucket, zone: zone)
            var chatIDs: [String] = []
            var chatRows: [Int64] = []
            if input.groupBy == .chat {
                var conditions = ["c.ROWID <= ?"]
                var values: [SQLiteValue] = [.integer(chatFence)]
                if let id = filter.chatID { conditions.append("c.guid = ?"); values.append(.text(id.rawValue)) }
                appendMembership(filter.participantHandles, groups: filter.participantHandleGroups,
                                 exact: filter.exactMembership, chatAlias: "c.ROWID", conditions: &conditions, values: &values, arrivalFence: membershipFence)
                let chats = try SQLiteStatement(database, "SELECT c.ROWID, c.guid FROM chat c WHERE \(conditions.joined(separator: " AND ")) ORDER BY c.guid COLLATE BINARY, c.ROWID")
                defer { chats.finalize() }
                try chats.bind(values)
                while try chats.step() { chatRows.append(chats.integer(at: 0)); chatIDs.append(chats.text(at: 1) ?? "") }
            }
            let groupCount = input.groupBy == .overall ? 1 : chatIDs.count
            let indices = Dictionary(uniqueKeysWithValues: chatRows.enumerated().map { ($0.element, $0.offset) })
            var counts: [Int: ActivityCounts] = [:]
            func column(_ name: String) -> String { schema.has(name) ? "m.\(name)" : "NULL" }
            let classificationAvailable = schema.has("item_type") && schema.has("associated_message_type") && schema.has("balloon_bundle_id")
            // DISTINCT operates on source coordinates, not bodies, GUIDs or dates.
            // Removing the chat coordinate in overall mode deduplicates a message
            // linked to multiple selected chats before Swift sees it.
            let statement = try SQLiteStatement(database, """
                SELECT DISTINCT m.ROWID, \(input.groupBy == .chat ? "c.ROWID" : "NULL"), m.date, m.is_from_me,
                    \(column("associated_message_type")), \(column("item_type")),
                    \(column("balloon_bundle_id")), \(column("date_retracted"))
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE \(baseSQL) AND m.date >= ? AND m.date < ?
                """)
            defer { statement.finalize() }
            try statement.bind(baseValues + [.integer(start), .integer(end)])
            while try statement.step() {
                let kind = MessageNormalizer.sourceKind(hasClassification: classificationAvailable,
                    associatedType: statement.isNull(at: 4) ? nil : Int(statement.integer(at: 4)),
                    itemType: statement.isNull(at: 5) ? nil : Int(statement.integer(at: 5)), balloonBundleID: statement.text(at: 6))
                guard MessageNormalizer.countsAsActivity(kind, isRetracted: statement.integer(at: 7) != 0) else { continue }
                let date = statement.integer(at: 2)
                // First interval whose exclusive end is after this exact source timestamp.
                var low = 0, high = intervals.count
                while low < high {
                    let middle = (low + high) / 2
                    if intervals[middle].end <= date { low = middle + 1 } else { high = middle }
                }
                guard low < intervals.count else { continue }
                let group = input.groupBy == .overall ? 0 : indices[statement.integer(at: 1)]!
                let key = low * groupCount + group
                if statement.integer(at: 3) != 0 { counts[key, default: ActivityCounts()].sent += 1 }
                else { counts[key, default: ActivityCounts()].received += 1 }
            }
            // The cursor holds only a digest of the count result and row universe.
            // It detects mutations that would invalidate offset/rank paging without
            // retaining bodies, source rows or a long-lived database snapshot.
            var digest = SHA256()
            func append(_ value: Int64) {
                withUnsafeBytes(of: value.bigEndian) { digest.update(bufferPointer: $0) }
            }
            append(Int64(chatRows.count))
            for (index, row) in chatRows.enumerated() {
                append(row)
                let bytes = Data(chatIDs[index].utf8)
                append(Int64(bytes.count)); digest.update(data: bytes)
            }
            append(Int64(intervals.count))
            for interval in intervals { append(interval.start); append(interval.end) }
            append(Int64(counts.count))
            for key in counts.keys.sorted() {
                append(Int64(key)); append(Int64(counts[key]!.sent)); append(Int64(counts[key]!.received))
            }
            let resultDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
            if let cursor, cursor.resultDigest != resultDigest { throw ActivityError.continuationInvalidated }
            let totalRows = intervals.count * groupCount
            let offset = cursor?.offset ?? 0
            guard offset <= totalRows else { throw MessageStoreError.cursorFilterMismatch }
            var groupTotals = Array(repeating: ActivityCounts(), count: groupCount)
            for (key, value) in counts {
                groupTotals[key % groupCount].sent += value.sent
                groupTotals[key % groupCount].received += value.received
            }
            func score(_ group: Int) -> Int {
                let value = groupTotals[group]
                switch input.ranking {
                case .chronological: return 0
                case .total: return value.total
                case .sent: return value.sent
                case .received: return value.received
                }
            }
            let groups = (0..<groupCount).sorted {
                let a = score($0), b = score($1)
                return a == b ? $0 < $1 : a > b
            }
            // Page over each whole-range-ranked chat's chronological series.
            // Zero buckets are generated only for the returned page.
            let selected = (offset..<min(offset + input.limit, totalRows)).map { ordinal in
                (ordinal % intervals.count) * groupCount + groups[ordinal / intervals.count]
            }
            let rows = selected.map { key in
                let interval = intervals[key / groupCount]
                return ActivityRow(chatID: input.groupBy == .overall ? nil : chatIDs[key % groupCount],
                                   start: activityDate(interval.start), end: activityDate(interval.end), counts: counts[key, default: ActivityCounts()])
            }
            let nextOffset = offset + rows.count
            let next = nextOffset < totalRows ? ActivityCursor(input: input.withoutCursor, filter: filter, generation: generation,
                messageFence: messageFence, associationFence: associationFence, chatFence: chatFence, membershipFence: membershipFence,
                timeZone: resolvedZone, startNanos: start, endNanos: end, offset: nextOffset, resultDigest: resultDigest) : nil
            return ActivityPage(rows: rows, range: DateRange(start: activityDate(start), end: activityDate(end)), timeZone: resolvedZone, cursor: next)
        }
    }

    /// Public Date bounds have microsecond resolution. Split whole seconds before
    /// scaling so Double multiplication cannot move an exact microsecond endpoint.
    private func activityEpoch(_ date: Date) throws -> Int64 {
        let reference = date.timeIntervalSinceReferenceDate
        let seconds = floor(reference)
        guard reference.isFinite, abs(reference) < 8_589_934_592 else { throw MessageStoreError.invalidDateRange }
        let micros = Int64(((reference - seconds) * 1_000_000).rounded())
        return Int64(seconds) * 1_000_000_000 + micros * 1000
    }

    private func activityDate(_ nanos: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(nanos / 1_000_000_000) + Double(nanos % 1_000_000_000) / 1_000_000_000)
    }

    private func activityIntervals(start: Int64, end: Int64, bucket: ActivityBucket, zone: TimeZone) throws -> [(start: Int64, end: Int64)] {
        if bucket == .none { return [(start, end)] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone; calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        let component: Calendar.Component
        switch bucket { case .day: component = .day; case .week: component = .weekOfYear; case .month: component = .month; case .none: return [(start, end)] }
        var intervals: [(start: Int64, end: Int64)] = []
        var current = start
        while current < end {
            let seconds = current / 1_000_000_000 - (current < 0 && current % 1_000_000_000 != 0 ? 1 : 0)
            let calendarDate = Date(timeIntervalSinceReferenceDate: Double(seconds))
            guard let boundary = calendar.dateInterval(of: component, for: calendarDate)?.end else { throw MessageStoreError.invalidDateRange }
            let next = boundary >= activityDate(end) ? end : try activityEpoch(boundary)
            guard next > current else { throw MessageStoreError.invalidDateRange }
            intervals.append((current, next)); current = next
        }
        return intervals
    }
}
