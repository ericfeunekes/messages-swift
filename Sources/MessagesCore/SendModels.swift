import Foundation

public struct SendMessageInput: Codable, Sendable, Equatable {
    public let chatID: String?
    public let recipients: [PersonSelector]?
    public let service: String?
    public let text: String?
    public let files: [String]

    public init(chatID: String? = nil, recipients: [PersonSelector]? = nil, service: String? = nil, text: String? = nil, files: [String] = []) {
        self.chatID = chatID; self.recipients = recipients; self.service = service
        self.text = text; self.files = files
    }
}

/// `submitted` is only a successful public Automation command. `sent`,
/// `pending`, and `failed` require an exact outgoing source row.
public enum SendStatus: String, Codable, Sendable {
    case submitted, pending, sent, failed, partial, unknown
    case needsChoice = "needs_choice"
}
public enum SendPartOutcome: String, Codable, Sendable {
    case submitted, pending, sent, failed, unknown
    case notAttempted = "not_attempted"
}
public struct SendPartResult: Codable, Sendable, Equatable {
    public let index: Int
    public let kind: String
    public let fileIndex: Int?
    public var outcome: SendPartOutcome
    public var errorCode: String?
    /// Present only when the sending boundary supplied an exact GUID and the
    /// source row was found. It is never inferred from body/date/chat matches.
    public var messageID: String?
    public var isSent: Bool?
    public var isDelivered: Bool?
    public var deliveryErrorCode: Int?
    /// The service recorded by the uniquely observed source row. It may differ
    /// from an explicitly selected account, for example after SMS relay/RCS
    /// negotiation.
    public var observedService: String?
    /// `unique_source_match` means exactly one bounded post-dispatch source
    /// candidate matched. It is evidence, not an AppleScript-issued receipt.
    public var correlation: String?
}
public struct SendDestination: Codable, Sendable, Equatable {
    public let chatID: String?
    public let service: String?
    public let recipients: [Participant]
}
public struct SendMessageResult: Codable, Sendable, Equatable {
    public var status: SendStatus
    public let delivery: String
    public let destination: SendDestination?
    public let contactCandidates: [ContactCandidate]
    public let handleCandidates: [String]
    public var parts: [SendPartResult]
    public var errorCode: String?
}
public enum SendValidationError: String, Error, Sendable {
    case invalidDestination = "invalid_send_destination"
    case invalidContent = "invalid_send_content"
    case invalidFile = "invalid_send_file"
    case fileChanged = "send_file_changed"
    case fileStagingFailed = "send_file_staging_failed"
}
