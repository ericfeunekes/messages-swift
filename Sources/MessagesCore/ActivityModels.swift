import Foundation

public enum ActivityGrouping: String, Codable, Sendable { case overall, chat }
public enum ActivityBucket: String, Codable, Sendable { case none, day, week, month }
public enum ActivityRanking: String, Codable, Sendable { case chronological, total, sent, received }

public struct CountMessageActivityInput: Codable, Equatable, Sendable {
    public let chatID: String?
    public let participants: [PersonSelector]
    public let membership: MembershipMode
    public let dateRange: DateRange
    public let unreadOnly: Bool
    public let timeZone: String?
    public let groupBy: ActivityGrouping
    public let bucket: ActivityBucket
    public let ranking: ActivityRanking
    public let limit: Int
    public let cursor: String?

    public init(chatID: String? = nil, participants: [PersonSelector] = [], membership: MembershipMode = .containsAll,
                dateRange: DateRange = DateRange(), unreadOnly: Bool = false, timeZone: String? = nil,
                groupBy: ActivityGrouping = .overall, bucket: ActivityBucket = .none,
                ranking: ActivityRanking = .chronological, limit: Int = 50, cursor: String? = nil) {
        self.chatID = chatID; self.participants = participants; self.membership = membership
        self.dateRange = dateRange; self.unreadOnly = unreadOnly; self.timeZone = timeZone
        self.groupBy = groupBy; self.bucket = bucket; self.ranking = ranking; self.limit = limit; self.cursor = cursor
    }

    var withoutCursor: Self {
        Self(chatID: chatID, participants: participants, membership: membership, dateRange: dateRange,
             unreadOnly: unreadOnly, timeZone: timeZone, groupBy: groupBy, bucket: bucket, ranking: ranking, limit: limit)
    }
}

public struct ActivityCounts: Codable, Equatable, Sendable {
    public var sent: Int = 0
    public var received: Int = 0
    public var total: Int { sent + received }
    enum CodingKeys: String, CodingKey { case total, sent, received }
    public init(sent: Int = 0, received: Int = 0) { self.sent = sent; self.received = received }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        sent = try fields.decode(Int.self, forKey: .sent); received = try fields.decode(Int.self, forKey: .received)
    }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(total, forKey: .total); try fields.encode(sent, forKey: .sent); try fields.encode(received, forKey: .received)
    }
}

public struct ActivityRow: Codable, Equatable, Sendable {
    public let chatID: String?
    public let start: Date
    public let end: Date
    public let counts: ActivityCounts
}

public struct CountMessageActivityResult: Codable, Equatable, Sendable {
    public let resolvedDateRange: DateRange?
    public let timeZone: String
    public let groupBy: ActivityGrouping
    public let bucket: ActivityBucket
    public let ranking: ActivityRanking
    public let rows: [ActivityRow]
    public let chats: [ChatResult]
    public let contactCandidates: [ContactCandidate]
    public let nextCursor: String?
}

struct ActivityCursor: Codable {
    let input: CountMessageActivityInput
    let filter: MessageFilter
    let generation: String
    let messageFence: Int64
    let associationFence: Int64
    let chatFence: Int64
    let membershipFence: Int64
    let timeZone: String
    let startNanos: Int64
    let endNanos: Int64
    let offset: Int
    let resultDigest: String
}

struct ActivityPage {
    let rows: [ActivityRow]
    let range: DateRange
    let timeZone: String
    let cursor: ActivityCursor?
}

public enum ActivityError: Error, Sendable {
    case invalidTimeZone
    case continuationInvalidated
}
