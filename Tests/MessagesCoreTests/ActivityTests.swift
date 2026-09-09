import CSQLite
import Foundation
import XCTest
@testable import MessagesCore

final class ActivityTests: XCTestCase {
    func testAggregationReconcilesWithPagedHistorySourceIdentity() throws {
        let fixture = try ActivityFixture()
        try fixture.message(1, at: 1, sent: true)
        try fixture.message(2, at: 2, text: "NULL")
        try fixture.exec("INSERT INTO attachment VALUES (1, NULL); INSERT INTO message_attachment_join VALUES (2, 1)")
        try fixture.message(3, at: 3, edited: true)
        try fixture.message(4, at: 4, associated: "2000")
        try fixture.message(5, at: 5, associated: "3006")
        try fixture.message(6, at: 6, balloon: "'com.apple.messages.URLBalloonProvider'")
        try fixture.message(7, at: 7, item: "1")
        try fixture.message(8, at: 8, item: "NULL")
        try fixture.message(9, at: 9, text: "NULL")
        try fixture.exec("UPDATE message SET attributedBody = X'040b00' WHERE ROWID = 9")
        try fixture.message(10, at: 10, sent: true)
        try fixture.exec("UPDATE message SET guid = 'message-1' WHERE ROWID = 10; INSERT INTO chat_message_join VALUES (2, 1); INSERT INTO chat_message_join VALUES (1, 1)")
        let store = MessageStore(path: fixture.url.path)
        let input = CountMessageActivityInput(dateRange: fixture.range(0, 11), timeZone: "UTC")
        let overall = try fixture.count(store, input)
        XCTAssertEqual(overall.rows.map(\.counts), [ActivityCounts(sent: 2, received: 3)])
        var cursor: MessagePageCursor?
        var ordinary = Set<Int64>()
        var associations: [String: Set<Int64>] = [:]
        repeat {
            let page = try store.readMessages(.init(filter: .init(startDate: fixture.date(0), endDate: fixture.date(11)), limit: 3, cursor: cursor))
            for row in page.messages where MessageNormalizer.countsAsActivity(row.kind, isRetracted: row.isRetracted) {
                ordinary.insert(row.sourceRowID)
                associations[row.chatID.rawValue, default: []].insert(row.sourceRowID)
            }
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(ordinary.count, overall.rows[0].counts.total)
        let perChat = try fixture.count(store, .init(dateRange: fixture.range(0, 11), timeZone: "UTC", groupBy: .chat))
        XCTAssertEqual(perChat.rows.map { $0.counts.total }, [5, 1, 0])
        for row in perChat.rows { XCTAssertEqual(row.counts.total, associations[row.chatID!, default: []].count) }
    }

    func testHalfOpenPartialDatesEmptyAndInferredBounds() throws {
        let fixture = try ActivityFixture()
        for value in [0.5, 1, 1.5, 2] { try fixture.message(Int64(value * 10 + 1), at: value) }
        let store = MessageStore(path: fixture.url.path)
        let input = CountMessageActivityInput(dateRange: fixture.range(1, 2), timeZone: "UTC")
        XCTAssertEqual(try fixture.count(store, input).rows[0].counts.total, 2)
        let empty = try fixture.count(store, .init(dateRange: fixture.range(1, 1), timeZone: "UTC"))
        XCTAssertEqual(empty.rows[0].counts.total, 0)
        XCTAssertEqual(empty.rows[0].start, empty.rows[0].end)
        XCTAssertTrue(try fixture.count(store, .init(dateRange: fixture.range(1, 1), timeZone: "UTC", bucket: .day)).rows.isEmpty)
        XCTAssertThrowsError(try fixture.count(store, .init(dateRange: fixture.range(2, 1), timeZone: "UTC"))) {
            guard case MessageStoreError.invalidDateRange = $0 else { return XCTFail("\($0)") }
        }
        let inferred = try fixture.count(store, .init(timeZone: "UTC"), now: fixture.date(3))
        XCTAssertEqual(inferred.range, fixture.range(0.5, 3))
        let absent = try fixture.count(store, .init(dateRange: .init(end: fixture.date(-1)), timeZone: "UTC"))
        XCTAssertEqual(absent.range, fixture.range(-1, -1))
        XCTAssertEqual(absent.rows[0].counts.total, 0)
    }

    func testCalendarDSTMondayMonthAndZeroBuckets() throws {
        let fixture = try ActivityFixture()
        let store = MessageStore(path: fixture.url.path)
        func rows(_ start: String, _ end: String, bucket: ActivityBucket) throws -> [ActivityRow] {
            try fixture.count(store, .init(dateRange: .init(start: iso(start), end: iso(end)), timeZone: "America/Halifax", bucket: bucket)).rows
        }
        let spring = try rows("2026-03-07T00:00:00-04:00", "2026-03-10T00:00:00-03:00", bucket: .day)
        XCTAssertEqual(spring.map { $0.end.timeIntervalSince($0.start) / 3600 }, [24, 23, 24])
        XCTAssertEqual(spring.map { $0.counts.total }, [0, 0, 0])
        let fall = try rows("2026-10-31T00:00:00-03:00", "2026-11-03T00:00:00-04:00", bucket: .day)
        XCTAssertEqual(fall.map { $0.end.timeIntervalSince($0.start) / 3600 }, [24, 25, 24])
        let weeks = try rows("2026-03-08T12:00:00-03:00", "2026-03-17T06:00:00-03:00", bucket: .week)
        XCTAssertEqual(weeks.map(\.start), [iso("2026-03-08T12:00:00-03:00"), iso("2026-03-09T00:00:00-03:00"), iso("2026-03-16T00:00:00-03:00")])
        XCTAssertEqual(weeks.last?.end, iso("2026-03-17T06:00:00-03:00"))
        let months = try rows("2026-01-31T12:00:00-04:00", "2026-03-01T06:00:00-04:00", bucket: .month)
        XCTAssertEqual(months.map(\.end), [iso("2026-02-01T00:00:00-04:00"), iso("2026-03-01T00:00:00-04:00"), iso("2026-03-01T06:00:00-04:00")])
    }

    func testCalendarCountsUseExactBoundariesAndFullRangeRanking() throws {
        let fixture = try ActivityFixture()
        let start = iso("2026-03-08T00:00:00-04:00")
        let monday = iso("2026-03-09T00:00:00-03:00")
        try fixture.message(1, date: start, chat: 2, sent: true)
        try fixture.message(2, date: monday.addingTimeInterval(-1), chat: 2)
        try fixture.message(3, date: monday, chat: 1, sent: true)
        try fixture.message(4, date: monday.addingTimeInterval(1), chat: 1, sent: true)
        try fixture.message(5, date: monday.addingTimeInterval(2), chat: 2)
        let store = MessageStore(path: fixture.url.path)
        let dates = DateRange(start: start, end: monday.addingTimeInterval(86_400))
        let ranked = try fixture.count(store, .init(dateRange: dates, timeZone: "America/Halifax", groupBy: .chat, bucket: .day, ranking: .total))
        XCTAssertEqual(ranked.rows.map(\.chatID), ["chat-b", "chat-b", "chat-a", "chat-a", "chat-empty", "chat-empty"])
        XCTAssertEqual(ranked.rows.map { $0.counts.total }, [2, 1, 0, 2, 0, 0])
        let sent = try fixture.count(store, .init(dateRange: dates, timeZone: "America/Halifax", groupBy: .chat, bucket: .day, ranking: .sent))
        XCTAssertEqual(sent.rows.prefix(2).map(\.chatID), ["chat-a", "chat-a"])
        let received = try fixture.count(store, .init(dateRange: dates, timeZone: "America/Halifax", groupBy: .chat, ranking: .received))
        XCTAssertEqual(received.rows.map(\.chatID), ["chat-b", "chat-a", "chat-empty"])
        let overall = try fixture.count(store, .init(dateRange: dates, timeZone: "America/Halifax", bucket: .day, ranking: .total))
        XCTAssertEqual(overall.rows.map { $0.counts.total }, [2, 3])
    }

    func testContinuationFreezesArrivalsBoundsZoneAndRanks() throws {
        let fixture = try ActivityFixture()
        try fixture.message(1, at: 1, sent: true)
        try fixture.message(2, at: 2, chat: 2)
        let store = MessageStore(path: fixture.url.path)
        let input = CountMessageActivityInput(groupBy: .chat, ranking: .total, limit: 1)
        let first = try fixture.count(store, input, now: fixture.date(10))
        XCTAssertEqual(first.rows[0].chatID, "chat-a") // equal total -> GUID
        let cursor = try XCTUnwrap(first.cursor)
        XCTAssertEqual(cursor.timeZone, TimeZone.current.identifier)
        try fixture.message(3, at: 0.5, chat: 2)
        try fixture.message(4, at: 20, chat: 2)
        try fixture.exec("INSERT INTO chat_message_join VALUES (2, 1); INSERT INTO chat VALUES (4, 'chat-new', 'new', NULL, 'iMessage')")
        let second = try fixture.count(store, input, cursor: cursor, now: fixture.date(99))
        XCTAssertEqual(second.rows[0].chatID, "chat-b")
        XCTAssertEqual(second.rows[0].counts.total, 1)
        XCTAssertEqual(first.range, second.range)
        XCTAssertEqual(first.timeZone, second.timeZone)
        let third = try fixture.count(store, input, cursor: XCTUnwrap(second.cursor))
        XCTAssertEqual(third.rows[0].chatID, "chat-empty")
        XCTAssertNil(third.cursor)
        let fresh = try fixture.count(store, input, now: fixture.date(99))
        XCTAssertEqual(fresh.rows[0].chatID, "chat-b")
        XCTAssertEqual(fresh.rows[0].counts.total, 4)
        XCTAssertThrowsError(try fixture.count(MessageStore(path: fixture.url.path), input, cursor: cursor)) {
            guard case MessageStoreError.cursorFilterMismatch = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try fixture.count(store, .init(timeZone: "UTC", groupBy: .chat, ranking: .total, limit: 1), cursor: cursor)) {
            guard case MessageStoreError.cursorFilterMismatch = $0 else { return XCTFail("\($0)") }
        }
    }

    func testMembershipArrivalsDoNotChangeContinuationChatUniverse() throws {
        let fixture = try ActivityFixture()
        try fixture.message(1, at: 1)
        try fixture.message(2, at: 2, chat: 2)
        let store = MessageStore(path: fixture.url.path)
        let input = CountMessageActivityInput(dateRange: fixture.range(0, 10), timeZone: "UTC", groupBy: .chat, limit: 1)
        let filter = MessageFilter(participantHandleGroups: [["a@example.test"]], startDate: fixture.date(0), endDate: fixture.date(10))
        let first = try store.countMessageActivity(input, filter: filter, cursor: nil, now: fixture.date(10))
        try fixture.exec("INSERT INTO chat_handle_join VALUES (3, 1)")
        let second = try store.countMessageActivity(input, filter: filter, cursor: XCTUnwrap(first.cursor), now: fixture.date(10))
        XCTAssertEqual(second.rows.map(\.chatID), ["chat-b"])
        XCTAssertNil(second.cursor)
        let fresh = try store.countMessageActivity(input, filter: filter, cursor: nil, now: fixture.date(10))
        let secondFresh = try store.countMessageActivity(input, filter: filter, cursor: XCTUnwrap(fresh.cursor), now: fixture.date(10))
        XCTAssertNotNil(secondFresh.cursor)
    }

    func testRepeatedGUIDsDoNotMergeDistinctPhysicalChatAssociations() throws {
        let fixture = try ActivityFixture()
        try fixture.exec("UPDATE chat SET guid = 'chat-a' WHERE ROWID = 2")
        try fixture.message(1, at: 1)
        try fixture.exec("INSERT INTO chat_message_join VALUES (2, 1)")
        let store = MessageStore(path: fixture.url.path)
        let rows = try fixture.count(store, .init(dateRange: fixture.range(0, 10), timeZone: "UTC", groupBy: .chat)).rows
        XCTAssertEqual(rows.map(\.chatID), ["chat-a", "chat-a", "chat-empty"])
        XCTAssertEqual(rows.map { $0.counts.total }, [1, 1, 0])
    }

    func testRankMutationRequiresRestartButBodyOnlyChangeDoesNot() throws {
        let fixture = try ActivityFixture()
        try fixture.message(1, at: 1, sent: true)
        try fixture.message(2, at: 2, chat: 2)
        let store = MessageStore(path: fixture.url.path)
        let input = CountMessageActivityInput(dateRange: fixture.range(0, 10), timeZone: "UTC", groupBy: .chat, ranking: .sent, limit: 1)
        let first = try fixture.count(store, input)
        try fixture.exec("UPDATE message SET text = 'new text', date_edited = 2 WHERE ROWID = 1")
        let unchanged = try fixture.count(store, input, cursor: XCTUnwrap(first.cursor))
        XCTAssertEqual(unchanged.rows[0].chatID, "chat-b")
        try fixture.exec("UPDATE message SET is_from_me = CASE WHEN ROWID = 1 THEN 0 ELSE 1 END")
        XCTAssertThrowsError(try fixture.count(store, input, cursor: XCTUnwrap(first.cursor))) {
            guard case ActivityError.continuationInvalidated = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try fixture.count(store, input).rows[0].chatID, "chat-b")
    }

    func testDeletionAndExistingMembershipRemovalRequireRestart() throws {
        for mutation in ["DELETE FROM message WHERE ROWID = 2", "DELETE FROM chat_handle_join WHERE chat_id = 2 AND handle_id = 1"] {
            let fixture = try ActivityFixture()
            try fixture.message(1, at: 1)
            try fixture.message(2, at: 2, chat: 2)
            let store = MessageStore(path: fixture.url.path)
            let input = CountMessageActivityInput(dateRange: fixture.range(0, 10), timeZone: "UTC", groupBy: .chat, ranking: .total, limit: 1)
            let filter = MessageFilter(participantHandleGroups: [["a@example.test"]], startDate: fixture.date(0), endDate: fixture.date(10))
            let first = try store.countMessageActivity(input, filter: filter, cursor: nil, now: fixture.date(10))
            try fixture.exec(mutation)
            XCTAssertThrowsError(try store.countMessageActivity(input, filter: filter, cursor: XCTUnwrap(first.cursor), now: fixture.date(10))) {
                guard case ActivityError.continuationInvalidated = $0 else { return XCTFail("\($0)") }
            }
        }
    }

    func testRankedBucketSeriesPagesThroughTerminalZeroRows() throws {
        let fixture = try ActivityFixture()
        try fixture.message(1, at: 1, chat: 2)
        let store = MessageStore(path: fixture.url.path)
        let fullInput = CountMessageActivityInput(dateRange: fixture.range(0, 3 * 86_400), timeZone: "UTC", groupBy: .chat, bucket: .day, ranking: .total)
        let full = try fixture.count(store, fullInput)
        let pagedInput = CountMessageActivityInput(dateRange: fullInput.dateRange, timeZone: "UTC", groupBy: .chat, bucket: .day, ranking: .total, limit: 2)
        var cursor: ActivityCursor?
        var rows: [ActivityRow] = []
        repeat {
            let page = try fixture.count(store, pagedInput, cursor: cursor)
            XCTAssertFalse(page.rows.isEmpty)
            rows += page.rows
            cursor = page.cursor
        } while cursor != nil
        XCTAssertEqual(rows, full.rows)
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows.prefix(3).map(\.chatID), ["chat-b", "chat-b", "chat-b"])
    }

    func testContemporaryMicrosecondEndpointsDoNotDriftAcrossSourceRows() throws {
        let fixture = try ActivityFixture()
        let store = MessageStore(path: fixture.url.path)
        let base: Int64 = 795_744_000
        try fixture.message(1, at: 0)
        for micro: Int64 in [1, 2, 3, 5, 7, 123, 123456, 123457, 999998] {
            let nanos = base * 1_000_000_000 + micro * 1000
            try fixture.exec("UPDATE message SET date = \(nanos) WHERE ROWID = 1")
            let start = Date(timeIntervalSinceReferenceDate: Double(base) + Double(micro) / 1_000_000)
            let end = Date(timeIntervalSinceReferenceDate: Double(base) + Double(micro + 1) / 1_000_000)
            let result = try fixture.count(store, .init(dateRange: .init(start: start, end: end), timeZone: "UTC"))
            XCTAssertEqual(result.rows[0].counts.total, 1, "microsecond \(micro)")
        }
    }

    func testSupportedDateLimitsAreValidatedForExplicitAndInferredBounds() throws {
        let fixture = try ActivityFixture()
        let store = MessageStore(path: fixture.url.path)
        let limit: Int64 = 8_589_934_592
        try fixture.message(1, at: 0)
        for seconds in [limit - 2, -limit + 1] {
            try fixture.exec("UPDATE message SET date = \(seconds * 1_000_000_000 + 123_456_000) WHERE ROWID = 1")
            let start = Date(timeIntervalSinceReferenceDate: Double(seconds) + 0.123456)
            let end = Date(timeIntervalSinceReferenceDate: Double(seconds) + 0.123457)
            XCTAssertEqual(try fixture.count(store, .init(dateRange: .init(start: start, end: end), timeZone: "UTC")).rows[0].counts.total, 1)
        }
        for seconds in [limit, -limit] {
            let boundary = Date(timeIntervalSinceReferenceDate: Double(seconds))
            XCTAssertThrowsError(try fixture.count(store, .init(dateRange: .init(start: boundary, end: boundary), timeZone: "UTC"))) {
                guard case MessageStoreError.invalidDateRange = $0 else { return XCTFail("\($0)") }
            }
        }
        try fixture.exec("UPDATE message SET date = \(-limit * 1_000_000_000) WHERE ROWID = 1")
        XCTAssertThrowsError(try fixture.count(store, .init(timeZone: "UTC"))) {
            guard case MessageStoreError.invalidDateRange = $0 else { return XCTFail("\($0)") }
        }
    }

    func testCalendarClipsBeforeConvertingNaturalBoundaryOutsideSupportedRange() throws {
        let fixture = try ActivityFixture()
        let store = MessageStore(path: fixture.url.path)
        let start = Date(timeIntervalSinceReferenceDate: 8_589_934_590)
        let end = Date(timeIntervalSinceReferenceDate: 8_589_934_591)
        for bucket in [ActivityBucket.day, .week, .month] {
            let page = try fixture.count(store, .init(dateRange: .init(start: start, end: end), timeZone: "UTC", bucket: bucket))
            XCTAssertEqual(page.rows.count, 1)
            XCTAssertEqual(page.rows[0].start, start)
            XCTAssertEqual(page.rows[0].end, end)
        }
    }

    func testRetractedOrdinaryAndAttachmentMessagesRemainHistoryButDoNotCount() throws {
        let fixture = try ActivityFixture()
        try fixture.message(1, at: 1, sent: true)
        try fixture.message(2, at: 2, text: "NULL", edited: true)
        try fixture.message(3, at: 3, edited: true)
        try fixture.exec("INSERT INTO attachment VALUES (1, NULL); INSERT INTO message_attachment_join VALUES (2, 1); UPDATE message SET date_retracted = 4 WHERE ROWID IN (1, 2); INSERT INTO chat_message_join VALUES (2, 1)")
        let store = MessageStore(path: fixture.url.path)
        let history = try store.readMessages(.init(filter: .init(chatID: .init(rawValue: "chat-a"))))
        XCTAssertEqual(history.messages.count, 3)
        XCTAssertEqual(history.messages.filter(\.isRetracted).count, 2)
        XCTAssertEqual(history.messages.first { $0.sourceRowID == 2 }?.kind, .attachmentOnly)
        let eligible = history.messages.filter { MessageNormalizer.countsAsActivity($0.kind, isRetracted: $0.isRetracted) }
        let overall = try fixture.count(store, .init(dateRange: fixture.range(0, 10), timeZone: "UTC"))
        XCTAssertEqual(overall.rows[0].counts, ActivityCounts(sent: 0, received: 1))
        XCTAssertEqual(overall.rows[0].counts.total, eligible.count)
        let chats = try fixture.count(store, .init(dateRange: fixture.range(0, 10), timeZone: "UTC", groupBy: .chat))
        XCTAssertEqual(chats.rows.map { $0.counts.total }, [1, 0, 0])
    }

    func testRetractionDuringContinuationRequiresRestartAndFreshCountExcludesIt() throws {
        let fixture = try ActivityFixture()
        try fixture.message(1, at: 1, sent: true)
        try fixture.message(2, at: 2, chat: 2)
        let store = MessageStore(path: fixture.url.path)
        let input = CountMessageActivityInput(dateRange: fixture.range(0, 10), timeZone: "UTC", groupBy: .chat, ranking: .total, limit: 1)
        let first = try fixture.count(store, input)
        try fixture.exec("UPDATE message SET date_retracted = 3 WHERE ROWID = 1")
        XCTAssertThrowsError(try fixture.count(store, input, cursor: XCTUnwrap(first.cursor))) {
            guard case ActivityError.continuationInvalidated = $0 else { return XCTFail("\($0)") }
        }
        let fresh = try fixture.count(store, input)
        XCTAssertEqual(fresh.rows[0].chatID, "chat-b")
        XCTAssertEqual(fresh.rows[0].counts.total, 1)
    }

    func testMissingClassificationStaysUnknownAndMetadataCountNeedsNoBodies() throws {
        let fixture = try ActivityFixture()
        try fixture.message(1, at: 1)
        try fixture.exec("ALTER TABLE message DROP COLUMN balloon_bundle_id")
        let store = MessageStore(path: fixture.url.path)
        let page = try fixture.count(store, .init(dateRange: fixture.range(0, 10), timeZone: "UTC"))
        XCTAssertEqual(page.rows[0].counts.total, 0)
        let history = try store.readMessages(.init(filter: .init(chatID: .init(rawValue: "chat-a"))))
        XCTAssertEqual(history.messages[0].kind, .unknown)
    }

    func testMembershipUnreadAndPerChatZeroSelection() throws {
        let fixture = try ActivityFixture()
        try fixture.message(1, at: 1, sent: true)
        try fixture.message(2, at: 2, chat: 2)
        let store = MessageStore(path: fixture.url.path)
        let input = CountMessageActivityInput(dateRange: fixture.range(0, 10), unreadOnly: true, timeZone: "UTC", groupBy: .chat)
        let filter = MessageFilter(participantHandleGroups: [["b@example.test"]], startDate: fixture.date(0), endDate: fixture.date(10), unreadOnly: true)
        let page = try store.countMessageActivity(input, filter: filter, cursor: nil, now: fixture.date(10))
        XCTAssertEqual(page.rows.map(\.chatID), ["chat-b"])
        XCTAssertEqual(page.rows[0].counts.received, 1) // author is A, member filter is B
        var exact = filter; exact.exactMembership = true
        XCTAssertTrue(try store.countMessageActivity(input, filter: exact, cursor: nil, now: fixture.date(10)).rows.isEmpty)
    }
}

private func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

final class ActivityFixture {
    let url: URL
    private var database: OpaquePointer?
    init() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/activity")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("fixture-\(UUID().uuidString).sqlite")
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw MessageStoreError.sqlite("fixture open") }
        try exec("""
          CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
          CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER, is_from_me INTEGER, text TEXT, attributedBody BLOB, guid TEXT, service TEXT, handle_id INTEGER, associated_message_guid TEXT, associated_message_type INTEGER, item_type INTEGER, balloon_bundle_id TEXT, date_edited INTEGER, date_retracted INTEGER, is_read INTEGER);
          CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
          CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
          CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
          CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT);
          CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
          INSERT INTO chat VALUES (1, 'chat-a', 'a', NULL, 'iMessage'), (2, 'chat-b', 'b', NULL, 'iMessage'), (3, 'chat-empty', 'empty', NULL, 'iMessage');
          INSERT INTO handle VALUES (1, 'a@example.test'), (2, 'b@example.test');
          INSERT INTO chat_handle_join VALUES (1, 1), (2, 1), (2, 2);
          """)
    }
    deinit { sqlite3_close_v2(database); try? FileManager.default.removeItem(at: url) }
    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }; throw MessageStoreError.sqlite(error.map { String(cString: $0) } ?? "fixture SQL")
        }
    }
    func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 978_307_200 + seconds) }
    func range(_ start: Double, _ end: Double) -> DateRange { .init(start: date(start), end: date(end)) }
    func message(_ row: Int64, at seconds: Double, chat: Int = 1, sent: Bool = false, text: String = "'body'", associated: String = "NULL", item: String = "0", balloon: String = "NULL", edited: Bool = false) throws {
        try exec("INSERT INTO message VALUES (\(row), \(Int64(seconds * 1e9)), \(sent ? 1 : 0), \(text), NULL, 'message-\(row)', 'iMessage', 1, NULL, \(associated), \(item), \(balloon), \(edited ? 1 : 0), 0, 0); INSERT INTO chat_message_join VALUES (\(chat), \(row))")
    }
    func message(_ row: Int64, date: Date, chat: Int = 1, sent: Bool = false) throws {
        try message(row, at: date.timeIntervalSince1970 - 978_307_200, chat: chat, sent: sent)
    }
    func count(_ store: MessageStore, _ input: CountMessageActivityInput, cursor: ActivityCursor? = nil, now: Date? = nil) throws -> ActivityPage {
        let filter = MessageFilter(chatID: input.chatID.map(ChatID.init(rawValue:)), startDate: input.dateRange.start, endDate: input.dateRange.end, unreadOnly: input.unreadOnly)
        return try store.countMessageActivity(input, filter: filter, cursor: cursor, now: now ?? date(100))
    }
}
