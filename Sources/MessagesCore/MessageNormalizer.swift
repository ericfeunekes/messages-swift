import Foundation

/// Source semantics shared by history presentation and metadata-only activity.
/// Body/attachment details only distinguish the two user-message presentations.
enum MessageNormalizer {
    static func sourceKind(hasClassification: Bool, associatedType: Int?, itemType: Int?, balloonBundleID: String?) -> MessageRowKind {
        guard hasClassification, let itemType else { return .unknown }
        if let associatedType, (2000...2006).contains(associatedType) || (3000...3006).contains(associatedType) { return .reaction }
        if balloonBundleID?.contains("URLBalloonProvider") == true { return .preview }
        return itemType == 0 ? .ordinary : .unknown
    }

    static func countsAsActivity(_ kind: MessageRowKind, isRetracted: Bool) -> Bool {
        isMessage(kind) && !isRetracted
    }

    static func isMessage(_ kind: MessageRowKind) -> Bool {
        kind == .ordinary || kind == .attachmentOnly
    }
}
