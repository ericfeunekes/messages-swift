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

public enum SendStatus: String, Codable, Sendable { case accepted, rejected, partial, unknown; case needsChoice = "needs_choice" }
public enum SendPartOutcome: String, Codable, Sendable { case accepted, rejected, unknown; case notAttempted = "not_attempted" }
public struct SendPartResult: Codable, Sendable, Equatable {
    public let index: Int
    public let kind: String
    public let fileIndex: Int?
    public var outcome: SendPartOutcome
    public var errorCode: String?
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
}
