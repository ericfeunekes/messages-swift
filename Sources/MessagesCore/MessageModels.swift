import Foundation

/// Durable chat identity from `chat.guid`; `chat_identifier` remains separate
/// because it is a routing/display field, not the alias key.
public struct ChatID: Codable, Hashable, Sendable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct MessageID: Codable, Hashable, Sendable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
}

public enum DecodedBodyStatus: String, Codable, Sendable {
  case text
  case absent
  case failed
}

/// A successful empty string remains `.text`; it is distinct from an absent body
/// and from a body whose stored representation could not be decoded.
public struct DecodedBody: Codable, Sendable {
  public let status: DecodedBodyStatus
  public let text: String?

  public init(status: DecodedBodyStatus, text: String? = nil) {
    self.status = status
    self.text = text
  }
}

/// Source classification is deliberately conservative. Operations decides which
/// raw rows are ordinary agent-facing messages and which are typed events.
public enum MessageRowKind: String, Codable, Sendable {
  case ordinary
  case attachmentOnly
  case reaction
  case preview
  case unknown
}

public enum AttachmentAvailability: String, Codable, Sendable {
  case available
  case unavailable
  case unknown
}

public struct AttachmentMetadata: Codable, Sendable {
  public let id: String
  public let filename: String?
  public let transferName: String?
  public let uniformTypeIdentifier: String?
  public let mimeType: String?
  public let byteCount: Int64?
  public let isSticker: Bool?
  public let availability: AttachmentAvailability
}

public struct ChatRecord: Codable, Sendable {
  public let id: ChatID
  public let sourceRowID: Int64
  public let identifier: String
  public let nativeName: String?
  public let service: String?
  public let participants: [String]
  public let lastActivityAt: Date?
  public let lastActivityNanos: Int64?
  public let unreadCount: Int?
}

public struct ChatSnapshot: Codable, Sendable {
  public let chats: [ChatRecord]
  public let databaseGeneration: String
  public let arrivalFenceRowID: Int64
}

public struct MessageRecord: Codable, Sendable {
  public let id: MessageID
  /// Raw SQLite coordinate used for pagination and diagnostics. It is not a
  /// durable cross-database identity; use `id`/`guid` for that purpose.
  public let sourceRowID: Int64
  public let sourceChatRowID: Int64
  /// Exact raw Apple-epoch nanoseconds from `message.date`.
  public let sourceDateNanos: Int64
  public let chatID: ChatID
  public let guid: String?
  public let date: Date
  public let sender: String?
  public let isFromMe: Bool
  public let service: String?
  public let body: DecodedBody
  public let kind: MessageRowKind
  public let associatedMessageGUID: String?
  public let associatedMessageType: Int?
  public let sourceItemType: Int?
  public let balloonBundleID: String?
  public let isEdited: Bool
  public let isRetracted: Bool
  public let attachments: [AttachmentMetadata]
}

public struct ChatFilter: Codable, Sendable, Equatable {
  public var participantHandles: [String]
  /// Every group represents one selected person/contact: any handle in that
  /// group qualifies, while every group must qualify the conversation.
  public var participantHandleGroups: [[String]]
  public var exactMembership: Bool
  public var startDate: Date?
  public var endDate: Date?
  public var unreadOnly: Bool

  public init(
    participantHandles: [String] = [],
    participantHandleGroups: [[String]] = [],
    exactMembership: Bool = false,
    startDate: Date? = nil,
    endDate: Date? = nil,
    unreadOnly: Bool = false
  ) {
    self.participantHandles = participantHandles
    self.participantHandleGroups = participantHandleGroups
    self.exactMembership = exactMembership
    self.startDate = startDate
    self.endDate = endDate
    self.unreadOnly = unreadOnly
  }
}

public struct FindChatsRequest: Codable, Sendable {
  public var filter: ChatFilter
  public var limit: Int

  public init(filter: ChatFilter = ChatFilter(), limit: Int = 50) {
    self.filter = filter
    self.limit = limit
  }
}

public enum MessageSearchMode: String, Codable, Sendable {
  case substring
  case exact
}

public struct MessageFilter: Codable, Sendable, Equatable {
  public var chatID: ChatID?
  public var participantHandles: [String]
  public var participantHandleGroups: [[String]]
  public var exactMembership: Bool
  public var startDate: Date?
  public var endDate: Date?
  public var unreadOnly: Bool

  public init(
    chatID: ChatID? = nil,
    participantHandles: [String] = [],
    participantHandleGroups: [[String]] = [],
    exactMembership: Bool = false,
    startDate: Date? = nil,
    endDate: Date? = nil,
    unreadOnly: Bool = false
  ) {
    self.chatID = chatID
    self.participantHandles = participantHandles
    self.participantHandleGroups = participantHandleGroups
    self.exactMembership = exactMembership
    self.startDate = startDate
    self.endDate = endDate
    self.unreadOnly = unreadOnly
  }
}

/// The cursor carries its own filter so a continuation cannot silently change
/// ordering or scope. `arrivalFenceRowID` excludes arrivals, including rows
/// inserted later with an older date, from the paging session.
public struct MessagePageCursor: Codable, Sendable, Equatable {
  public let filter: MessageFilter
  public let searchQuery: String?
  public let searchMode: MessageSearchMode?
  /// Apple Messages' raw nanosecond timestamp; retaining it avoids Date rounding
  /// from skipping or repeating tied rows.
  public let beforeDateNanos: Int64
  /// Private SQLite coordinate used only as the deterministic tie-breaker.
  public let beforeRowID: Int64
  public let beforeChatRowID: Int64
  public let arrivalFenceRowID: Int64
  /// Opaque identity of the owning MessageStore connection. A new store/process
  /// requires a fresh query; a cursor never binds to a reopened pathname.
  public let databaseGeneration: String
}

public struct ReadMessagesRequest: Codable, Sendable {
  public var filter: MessageFilter
  public var limit: Int
  public var cursor: MessagePageCursor?

  public init(filter: MessageFilter, limit: Int = 50, cursor: MessagePageCursor? = nil) {
    self.filter = filter
    self.limit = limit
    self.cursor = cursor
  }
}

public struct SearchMessagesRequest: Codable, Sendable {
  public var filter: MessageFilter
  public var query: String
  public var mode: MessageSearchMode
  public var limit: Int
  public var cursor: MessagePageCursor?

  public init(
    filter: MessageFilter = MessageFilter(),
    query: String,
    mode: MessageSearchMode = .substring,
    limit: Int = 50,
    cursor: MessagePageCursor? = nil
  ) {
    self.filter = filter
    self.query = query
    self.mode = mode
    self.limit = limit
    self.cursor = cursor
  }
}

public struct MessagePage: Codable, Sendable {
  public let messages: [MessageRecord]
  public let nextCursor: MessagePageCursor?
  public let decodingFailures: [BodyDecodingFailure]
  public let decodingFailureCount: Int
  public let scannedAssociationCount: Int
}

public struct BodyDecodingFailure: Codable, Sendable {
  public let messageID: MessageID
  public let chatID: ChatID
}
