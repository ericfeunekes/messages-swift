import Foundation

/// Agent-facing schemas. Dates use RFC 3339 / ISO-8601 strings when encoded;
/// the storage adapter keeps its native timestamp representation private.
public struct DateRange: Codable, Sendable, Equatable {
    public let start: Date?
    public let end: Date?

    public init(start: Date? = nil, end: Date? = nil) {
        self.start = start
        self.end = end
    }
}

public enum MembershipMode: String, Codable, Sendable, Equatable {
    case containsAll = "contains_all"
    case exact
}

/// A name, handle, native chat name, or local chat alias. A source contact ID
/// can disambiguate same-named people without conflating selected-container records.
public struct PersonSelector: Codable, Sendable, Equatable {
    public let query: String?
    public let sourceIdentity: ContactIdentity?

    public init(query: String? = nil, sourceIdentity: ContactIdentity? = nil) {
        self.query = query
        self.sourceIdentity = sourceIdentity
    }
}

public struct FindChatsInput: Codable, Sendable, Equatable {
    public let query: String?
    public let participants: [PersonSelector]
    public let membership: MembershipMode
    public let dateRange: DateRange
    public let unreadOnly: Bool
    public let limit: Int
    public let cursor: String?

    public init(query: String? = nil, participants: [PersonSelector] = [], membership: MembershipMode = .containsAll, dateRange: DateRange = DateRange(), unreadOnly: Bool = false, limit: Int = 50, cursor: String? = nil) {
        self.query = query
        self.participants = participants
        self.membership = membership
        self.dateRange = dateRange
        self.unreadOnly = unreadOnly
        self.limit = limit
        self.cursor = cursor
    }
}

public struct ReadMessagesInput: Codable, Sendable, Equatable {
    public let chatID: String
    public let dateRange: DateRange
    public let unreadOnly: Bool
    public let limit: Int
    public let cursor: String?

    public init(chatID: String, dateRange: DateRange = DateRange(), unreadOnly: Bool = false, limit: Int = 50, cursor: String? = nil) {
        self.chatID = chatID
        self.dateRange = dateRange
        self.unreadOnly = unreadOnly
        self.limit = limit
        self.cursor = cursor
    }
}

public struct SearchMessagesInput: Codable, Sendable, Equatable {
    public let query: String
    public let chatID: String?
    public let participants: [PersonSelector]
    public let membership: MembershipMode
    public let dateRange: DateRange
    public let unreadOnly: Bool
    public let limit: Int
    public let cursor: String?

    public init(query: String, chatID: String? = nil, participants: [PersonSelector] = [], membership: MembershipMode = .containsAll, dateRange: DateRange = DateRange(), unreadOnly: Bool = false, limit: Int = 50, cursor: String? = nil) {
        self.query = query
        self.chatID = chatID
        self.participants = participants
        self.membership = membership
        self.dateRange = dateRange
        self.unreadOnly = unreadOnly
        self.limit = limit
        self.cursor = cursor
    }
}

public struct SetChatAliasInput: Codable, Sendable, Equatable {
    public let chatID: String
    /// `nil` removes the local alias.
    public let alias: String?

    public init(chatID: String, alias: String?) {
        self.chatID = chatID
        self.alias = alias
    }
}

public struct SetChatAliasResult: Codable, Sendable, Equatable {
    public let chatID: String
    public let alias: String?
    public init(chatID: String, alias: String?) { self.chatID = chatID; self.alias = alias }
}

public struct ContactCandidate: Codable, Sendable, Equatable {
    public let identity: ContactIdentity
    public let displayName: String
    public let handles: [String]

    public init(person: ContactPerson) {
        identity = person.identity
        displayName = person.displayName
        handles = person.handles
    }
}

public struct Participant: Codable, Sendable, Equatable {
    public let handle: String
    public let displayName: String?
    public let sourceIdentity: ContactIdentity?

    public init(handle: String, displayName: String? = nil, sourceIdentity: ContactIdentity? = nil) {
        self.handle = handle
        self.displayName = displayName
        self.sourceIdentity = sourceIdentity
    }
}

public struct ChatResult: Codable, Sendable, Equatable {
    public let chatID: String
    public let label: String
    public let nativeName: String?
    public let alias: String?
    public let participants: [Participant]
    public let service: String?
    public let lastActivity: Date?
    public let unreadCount: Int?

    public init(chatID: String, label: String, nativeName: String?, alias: String?, participants: [Participant], service: String?, lastActivity: Date?, unreadCount: Int?) {
        self.chatID = chatID
        self.label = label
        self.nativeName = nativeName
        self.alias = alias
        self.participants = participants
        self.service = service
        self.lastActivity = lastActivity
        self.unreadCount = unreadCount
    }
}

public struct AttachmentResult: Codable, Sendable, Equatable {
    public let id: String
    public let filename: String?
    public let mimeType: String?
    public let availability: AttachmentAvailability

    public init(id: String, filename: String? = nil, mimeType: String? = nil, availability: AttachmentAvailability = .unknown) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.availability = availability
    }
}

public enum MessageKind: String, Codable, Sendable, Equatable {
    case ordinary
    case attachment
}

public struct MessageResult: Codable, Sendable, Equatable {
    public let id: String
    public let chatID: String
    public let date: Date
    public let sender: Participant?
    public let isFromMe: Bool
    public let text: String?
    public let attachments: [AttachmentResult]
    public let kind: MessageKind

    public let decodingStatus: DecodedBodyStatus
    public let isEdited: Bool
    public let isRetracted: Bool

    public init(id: String, chatID: String, date: Date, sender: Participant?, isFromMe: Bool, text: String?, attachments: [AttachmentResult], kind: MessageKind, decodingStatus: DecodedBodyStatus, isEdited: Bool, isRetracted: Bool) {
        self.id = id
        self.chatID = chatID
        self.date = date
        self.sender = sender
        self.isFromMe = isFromMe
        self.text = text
        self.attachments = attachments
        self.kind = kind
        self.decodingStatus = decodingStatus
        self.isEdited = isEdited
        self.isRetracted = isRetracted
    }
}

/// Proven non-message rows are retained separately. Unknown source row kinds
/// are represented as events until their interpretation is accepted.
public struct MessageEventResult: Codable, Sendable, Equatable {
    public let id: String
    public let chatID: String
    public let date: Date
    public let kind: String
    public let text: String?
    public let sender: Participant?
    public let associatedMessageID: String?
    public let associatedMessageType: Int?
    public let attachments: [AttachmentResult]
    public let isEdited: Bool
    public let isRetracted: Bool
    public let diagnostic: String?
    public let decodingStatus: DecodedBodyStatus

    public init(id: String, chatID: String, date: Date, kind: String, text: String?, sender: Participant?, associatedMessageID: String?, associatedMessageType: Int?, decodingStatus: DecodedBodyStatus, attachments: [AttachmentResult] = [], isEdited: Bool = false, isRetracted: Bool = false, diagnostic: String? = nil) {
        self.id = id
        self.chatID = chatID
        self.date = date
        self.kind = kind
        self.text = text
        self.sender = sender
        self.associatedMessageID = associatedMessageID
        self.associatedMessageType = associatedMessageType
        self.attachments = attachments
        self.isEdited = isEdited
        self.isRetracted = isRetracted
        self.diagnostic = diagnostic
        self.decodingStatus = decodingStatus
    }
}

public struct DecodingDiagnostic: Codable, Sendable, Equatable {
    public let messageID: String
    public let chatID: String
    public let reason: String

    public init(messageID: String, chatID: String, reason: String) {
        self.messageID = messageID
        self.chatID = chatID
        self.reason = reason
    }
}

public struct MessagePageResult: Codable, Sendable, Equatable {
    public let chat: ChatResult
    public let messages: [MessageResult]
    public let events: [MessageEventResult]
    public let decodingDiagnostics: [DecodingDiagnostic]
    public let decodingFailureCount: Int
    public let scannedAssociationCount: Int
    public let contactCandidates: [ContactCandidate]
    public let unresolvedContactHandles: [String]
    public let nextCursor: String?

    public init(chat: ChatResult, messages: [MessageResult], events: [MessageEventResult], decodingDiagnostics: [DecodingDiagnostic], decodingFailureCount: Int = 0, scannedAssociationCount: Int = 0, unresolvedContactHandles: [String] = [], contactCandidates: [ContactCandidate] = [], nextCursor: String?) {
        self.chat = chat
        self.messages = messages
        self.events = events
        self.decodingDiagnostics = decodingDiagnostics
        self.decodingFailureCount = decodingFailureCount
        self.scannedAssociationCount = scannedAssociationCount
        self.contactCandidates = contactCandidates
        self.unresolvedContactHandles = unresolvedContactHandles
        self.nextCursor = nextCursor
    }
}

public struct FindChatsResult: Codable, Sendable, Equatable {
    public let chats: [ChatResult]
    public let contactCandidates: [ContactCandidate]
    public let nextCursor: String?

    public init(chats: [ChatResult], contactCandidates: [ContactCandidate], nextCursor: String?) {
        self.chats = chats
        self.contactCandidates = contactCandidates
        self.nextCursor = nextCursor
    }
}

public struct SearchMessagesResult: Codable, Sendable, Equatable {
    public let chats: [ChatResult]
    public let messages: [MessageResult]
    public let events: [MessageEventResult]
    public let decodingDiagnostics: [DecodingDiagnostic]
    public let decodingFailureCount: Int
    public let scannedAssociationCount: Int
    public let contactCandidates: [ContactCandidate]
    public let nextCursor: String?

    public init(chats: [ChatResult], messages: [MessageResult], events: [MessageEventResult], decodingDiagnostics: [DecodingDiagnostic], contactCandidates: [ContactCandidate], decodingFailureCount: Int = 0, scannedAssociationCount: Int = 0, nextCursor: String?) {
        self.chats = chats
        self.messages = messages
        self.events = events
        self.decodingDiagnostics = decodingDiagnostics
        self.decodingFailureCount = decodingFailureCount
        self.scannedAssociationCount = scannedAssociationCount
        self.contactCandidates = contactCandidates
        self.nextCursor = nextCursor
    }
}
