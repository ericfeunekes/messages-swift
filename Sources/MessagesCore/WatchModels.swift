import Foundation

public struct WatchMessagesInput: Codable, Sendable {
    public let chatID: String
    public let waitSeconds: Int
    public let limit: Int
    public let cursor: String?

    public init(chatID: String, waitSeconds: Int = 20, limit: Int = 50, cursor: String? = nil) {
        self.chatID = chatID
        self.waitSeconds = waitSeconds
        self.limit = limit
        self.cursor = cursor
    }
}

public struct WatchMessagesResult: Codable, Sendable {
    public let status: String
    public let cursor: String
    public let page: MessagePageResult
}

public enum WatchError: String, Error, Sendable {
    case invalidWait = "invalid_wait"
    case positionInvalidated = "watch_position_invalidated"
}

struct WatchAnchor: Codable, Sendable, Equatable {
    let row: Int64
    let messageRow: Int64
    let chatRow: Int64
    let messageGUID: String?
    let chatGUID: String
}

struct WatchCursor: Codable, Sendable {
    let generation: String
    let chatID: String
    var anchor: WatchAnchor?
}

struct WatchBatch: Sendable {
    let cursor: WatchCursor
    let records: [MessageRecord]
    let scannedAssociationCount: Int
}
