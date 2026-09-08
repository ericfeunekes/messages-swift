@preconcurrency import Contacts
import Foundation

/// Public Contacts adapter for the user-selected, already-synchronized source.
/// It never requests authorization and never changes account or sync settings.
public final class MacContactsDirectory: ContactsDirectorySource {
    private let store: CNContactStore

    public init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    public func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] {
        try fetch(in: binding, identities: nil, matchingHandles: [])
    }

    public func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String>) throws -> [ContactPerson] {
        try fetch(in: binding, identities: identities, matchingHandles: matchingHandles)
    }

    private func fetch(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>?, matchingHandles: Set<String>) throws -> [ContactPerson] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw ContactsDirectoryError.permissionNotGranted
        }

        let containers = try store.containers(matching: nil)
        guard containers.contains(where: { $0.identifier == binding.containerID }) else {
            throw ContactsDirectoryError.selectedContainerMissing(binding.containerID)
        }

        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: binding.containerID)
        request.unifyResults = false

        var people: [ContactPerson] = []
        try store.enumerateContacts(with: request) { contact, stop in
            let identity = ContactIdentity(containerID: binding.containerID, id: contact.identifier)
            let handles = (contact.phoneNumbers.map { $0.value.stringValue }
                + contact.emailAddresses.map { $0.value as String })
                .filter { !$0.isEmpty }
            if let identities, !identities.contains(identity), !handles.contains(where: { matchingHandles.contains(normalizedContactHandle($0)) }) { return }
            people.append(ContactPerson(
                identity: identity,
                displayName: Self.displayName(for: contact),
                handles: handles
            ))
            // A read must enumerate matching handles to retain ambiguity even
            // when a second owner was evicted from the bounded identity cache.
            if matchingHandles.isEmpty, let identities, people.count == identities.count { stop.pointee = true }
        }
        return people
    }

    private static func displayName(for contact: CNContact) -> String {
        let name = [contact.givenName, contact.middleName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty { return name }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        return "Unnamed contact"
    }
}
