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
        return try fetch(CNContact.predicateForContactsInContainer(withIdentifier: binding.containerID), full: true)
            .map { person($0, in: binding) }
    }

    public func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String>) throws -> ContactLookup {
        try validate(binding)
        let wanted = Set(matchingHandles.map(normalizedContactHandle))
        var candidates = Set(identities.filter { $0.containerID == binding.containerID }.map(\.id))
        var unresolved: Set<String> = []
        // Public Contacts predicates cannot be compounded with container scope.
        // Read only candidate IDs until their source container has been checked.
        for handle in wanted.sorted() {
            let predicate: NSPredicate
            if handle.contains("@") {
                predicate = CNContact.predicateForContacts(matchingEmailAddress: handle)
            } else {
                predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
                // Native phone matching is best effort, not complete proof of
                // this project's normalized-handle equivalence or uniqueness.
                unresolved.insert(handle)
            }
            candidates.formUnion(try fetch(predicate, full: false).map(\.identifier))
        }
        var selected: [String] = []
        for id in candidates.sorted() {
            let containers = try source.containerIDs(for: .owningContact(id))
            if containers.contains(binding.containerID) { selected.append(id) }
        }
        guard !selected.isEmpty else { return ContactLookup(people: [], unresolvedHandles: unresolved) }
        let selectedIDs = Set(selected)
        let people = try fetch(CNContact.predicateForContacts(withIdentifiers: selected), full: true)
            .filter { selectedIDs.contains($0.identifier) }
            .map { person($0, in: binding) }
        return ContactLookup(people: people, unresolvedHandles: unresolved)
    }

    private func validate(_ binding: ContactsContainerBinding) throws {
        guard source.isAuthorized else { throw ContactsDirectoryError.permissionNotGranted }
        let containers = try source.containerIDs(for: .identifiers([binding.containerID]))
        guard containers.contains(binding.containerID) else { throw ContactsDirectoryError.selectedContainerMissing(binding.containerID) }
    }

    private func fetch(_ predicate: NSPredicate, full: Bool) throws -> [CNContact] {
        let fields = full ? [CNContactIdentifierKey, CNContactGivenNameKey, CNContactMiddleNameKey,
                            CNContactFamilyNameKey, CNContactOrganizationNameKey,
                            CNContactPhoneNumbersKey, CNContactEmailAddressesKey] : [CNContactIdentifierKey]
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
