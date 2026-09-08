@preconcurrency import Contacts
import Foundation

enum ContainerLookup: Equatable {
    case identifiers([String])
    case owningContact(String)
}

/// The native boundary is injectable without authorizing or reading Contacts in tests.
protocol ContactsStoreAccess {
    var isAuthorized: Bool { get }
    func containerIDs(for lookup: ContainerLookup) throws -> [String]
    func contacts(matching request: CNContactFetchRequest) throws -> [CNContact]
}

private struct NativeContactsStore: ContactsStoreAccess {
    let store: CNContactStore
    var isAuthorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }
    func containerIDs(for lookup: ContainerLookup) throws -> [String] {
        let predicate: NSPredicate
        switch lookup {
        case .identifiers(let ids): predicate = CNContainer.predicateForContainers(withIdentifiers: ids)
        case .owningContact(let id): predicate = CNContainer.predicateForContainerOfContact(withIdentifier: id)
        }
        return try store.containers(matching: predicate).map(\.identifier)
    }
    func contacts(matching request: CNContactFetchRequest) throws -> [CNContact] {
        var contacts: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in contacts.append(contact) }
        return contacts
    }
}

/// Public Contacts adapter for the user-selected, already-synchronized source.
/// It never requests authorization and never changes account or sync settings.
public final class MacContactsDirectory: ContactsDirectorySource {
    private let source: any ContactsStoreAccess

    public init(store: CNContactStore = CNContactStore()) {
        source = NativeContactsStore(store: store)
    }

    init(source: any ContactsStoreAccess) { self.source = source }

    public func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] {
        try validate(binding)
        return try fetch(CNContact.predicateForContactsInContainer(withIdentifier: binding.containerID), matchingField: nil)
            .map { person($0, in: binding) }
    }

    public func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String>) throws -> ContactLookup {
        try validate(binding)
        let wanted = Set(matchingHandles.map(normalizedContactHandle))
        var candidates = Set(identities.filter { $0.containerID == binding.containerID }.map(\.id))
        var candidateIDsByHandle: [String: Set<String>] = [:]
        // Public Contacts predicates cannot be compounded with container scope.
        // Fetch the predicate field for native matching, retaining only candidate IDs
        // until their source container has been checked.
        for handle in wanted.sorted() {
            let predicate: NSPredicate
            let matchingField: String
            if handle.contains("@") {
                predicate = CNContact.predicateForContacts(matchingEmailAddress: handle)
                matchingField = CNContactEmailAddressesKey
            } else {
                predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
                matchingField = CNContactPhoneNumbersKey
            }
            let ids = Set(try fetch(predicate, matchingField: matchingField).map(\.identifier))
            candidateIDsByHandle[handle] = ids
            candidates.formUnion(ids)
        }
        var selected: [String] = []
        for id in candidates.sorted() {
            let containers = try source.containerIDs(for: .owningContact(id))
            if containers.contains(binding.containerID) { selected.append(id) }
        }
        guard !selected.isEmpty else { return ContactLookup(people: [], unresolvedHandles: wanted, candidatesByHandle: Dictionary(uniqueKeysWithValues: wanted.map { ($0, []) })) }
        let selectedIDs = Set(selected)
        let people = try fetch(CNContact.predicateForContacts(withIdentifiers: selected), matchingField: nil)
            .filter { selectedIDs.contains($0.identifier) }
            .map { person($0, in: binding) }
        var unresolved: Set<String> = []
        var matches: [String: [ContactPerson]] = [:]
        for handle in wanted {
            let exact = people.filter { $0.handles.contains { normalizedContactHandle($0) == handle } }
            if exact.count != 1 { unresolved.insert(handle) }
            matches[handle] = people.filter { candidateIDsByHandle[handle, default: []].contains($0.identity.id) || exact.contains($0) }
        }
        return ContactLookup(people: people, unresolvedHandles: unresolved, candidatesByHandle: matches)
    }

    private func validate(_ binding: ContactsContainerBinding) throws {
        guard source.isAuthorized else { throw ContactsDirectoryError.permissionNotGranted }
        let containers = try source.containerIDs(for: .identifiers([binding.containerID]))
        guard containers.contains(binding.containerID) else { throw ContactsDirectoryError.selectedContainerMissing(binding.containerID) }
    }

    private func fetch(_ predicate: NSPredicate, matchingField: String?) throws -> [CNContact] {
        let fields = matchingField.map { [CNContactIdentifierKey, $0] } ?? [CNContactIdentifierKey, CNContactGivenNameKey, CNContactMiddleNameKey,
                            CNContactFamilyNameKey, CNContactOrganizationNameKey,
                            CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
        let request = CNContactFetchRequest(keysToFetch: fields.map { $0 as CNKeyDescriptor })
        request.predicate = predicate
        request.unifyResults = false
        return try source.contacts(matching: request)
    }

    private func person(_ contact: CNContact, in binding: ContactsContainerBinding) -> ContactPerson {
        let name = [contact.givenName, contact.middleName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let displayName = name.isEmpty ? (contact.organizationName.isEmpty ? "Unnamed contact" : contact.organizationName) : name
        return ContactPerson(identity: ContactIdentity(containerID: binding.containerID, id: contact.identifier),
                             displayName: displayName,
                             handles: (contact.phoneNumbers.map { $0.value.stringValue } + contact.emailAddresses.map { $0.value as String }).filter { !$0.isEmpty })
    }
}
