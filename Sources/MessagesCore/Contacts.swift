import Foundation

/// The device-local identity assigned by the selected macOS Contacts container.
/// It is deliberately scoped to its container: the same contact identifier in
/// a different container is a different person for directory purposes.
public struct ContactIdentity: Codable, Sendable, Hashable {
    public let containerID: String
    public let id: String

    public init(containerID: String, id: String) {
        self.containerID = containerID
        self.id = id
    }
}

/// A non-unified record from the user-selected Contacts container.
public struct ContactPerson: Codable, Sendable, Hashable {
    public let identity: ContactIdentity
    public let displayName: String
    public let handles: [String]

    public init(identity: ContactIdentity, displayName: String, handles: [String]) {
        self.identity = identity
        self.displayName = displayName
        self.handles = handles
    }
}

/// Results from a source lookup. Unresolved handles must not be treated as
/// uniquely resolved: no single exact owner was established from the returned selected-source records.
public struct ContactLookup: Sendable {
    public let people: [ContactPerson]
    public let unresolvedHandles: Set<String>
    public let candidatesByHandle: [String: [ContactPerson]]

    public init(people: [ContactPerson], unresolvedHandles: Set<String> = [], candidatesByHandle: [String: [ContactPerson]] = [:]) {
        self.people = people
        self.unresolvedHandles = unresolvedHandles
        self.candidatesByHandle = candidatesByHandle
    }
}

/// Explicit setup binding. The application never derives this value from a
/// container display name or type.
public struct ContactsContainerBinding: Codable, Sendable, Hashable {
    public let containerID: String

    public init(containerID: String) {
        self.containerID = containerID
    }
}

public enum ContactsDirectoryError: Error, Equatable, Sendable {
    case permissionNotGranted
    case selectedContainerMissing(String)
}

/// Reads the complete selected source snapshot. Callers select and refresh the
/// people they use from this snapshot; this protocol does not merge sources.
public protocol ContactsDirectorySource {
    func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson]
    func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String>) throws -> ContactLookup
}

public extension ContactsDirectorySource {
    func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String> = []) throws -> ContactLookup {
        let people = try allContacts(in: binding).filter { person in
            identities.contains(person.identity) || person.handles.contains { matchingHandles.contains(normalizedContactHandle($0)) }
        }
        let candidates = Dictionary(uniqueKeysWithValues: matchingHandles.map { handle in
            (handle, people.filter { $0.handles.contains { normalizedContactHandle($0) == handle } })
        })
        return ContactLookup(people: people, unresolvedHandles: Set(candidates.filter { $0.value.count != 1 }.keys), candidatesByHandle: candidates)
    }
}

func normalizedContactHandle(_ handle: String) -> String {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("@") { return trimmed.lowercased() }
    let digits = trimmed.filter(\.isNumber)
    return digits.isEmpty ? trimmed.lowercased() : (trimmed.hasPrefix("+") ? "+" : "") + digits
}
