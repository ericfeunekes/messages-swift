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

public struct ResolveSendRouteInput: Codable, Sendable, Equatable {
    public let chatID: String?
    public let recipients: [PersonSelector]?
    public init(chatID: String? = nil, recipients: [PersonSelector]? = nil) { self.chatID = chatID; self.recipients = recipients }
}
public struct ResolveSendRouteResult: Codable, Sendable, Equatable {
    public let kind: String
    public let destination: SendDestination?
    public let suggestedService: String?
    public let suggestionBasis: String
    public let serviceOptions: [String]
    public let contactCandidates: [ContactCandidate]
    public let handleCandidates: [String]

    public init(kind: String, destination: SendDestination?, suggestedService: String?, suggestionBasis: String, serviceOptions: [String], contactCandidates: [ContactCandidate] = [], handleCandidates: [String] = []) {
        self.kind = kind; self.destination = destination; self.suggestedService = suggestedService
        self.suggestionBasis = suggestionBasis; self.serviceOptions = serviceOptions
        self.contactCandidates = contactCandidates; self.handleCandidates = handleCandidates
    }
}
public enum SendRouteError: String, Error, Sendable { case accountDiscoveryFailed = "route_account_discovery_failed" }

/// `submitted` is only a successful public Automation command. `sent`,
/// `pending`, and `failed` require a uniquely matched outgoing source row; attribution remains inferred.
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
    /// Present only for the GUID of a uniquely matched post-dispatch source row.
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
    public var delivery: String
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
