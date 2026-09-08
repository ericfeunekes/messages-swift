import Contacts
import XCTest
@testable import MessagesCore

final class IndexedContactsTests: XCTestCase {
    private let binding = ContactsContainerBinding(containerID: "selected")

    func testCandidateIDsAreScopedBeforeFieldsAndAllSelectedOwnersSurvive() throws {
        let first = contact("One", email: "shared@example.invalid")
        let second = contact("Two", email: "SHARED@example.invalid")
        let foreign = contact("Foreign", email: "shared@example.invalid")
        let unknown = contact("Unknown", email: "shared@example.invalid")
        let candidates: [CNContact] = [first, second, foreign, unknown]
        let source = FakeStore()
        source.containerResults = [["selected"]] + candidates.sorted { $0.identifier < $1.identifier }.map {
            $0.identifier == foreign.identifier ? ["other"] : ($0.identifier == unknown.identifier ? [] : ["selected"])
        }
        source.contactResults = [candidates, [first, second]]
        let lookup = try MacContactsDirectory(source: source).contacts(in: binding, identities: [], matchingHandles: ["shared@example.invalid"])
        XCTAssertEqual(Set(lookup.people.map(\.displayName)), ["One", "Two"])
        XCTAssertTrue(lookup.unresolvedHandles.isEmpty)
        XCTAssertEqual(source.events, ["container", "ids", "container", "container", "container", "container", "fields"])
        XCTAssertEqual(source.requests.count, 2)
        XCTAssertEqual(source.requests[0].predicate, CNContact.predicateForContacts(matchingEmailAddress: "shared@example.invalid"))
        XCTAssertEqual(source.requests[1].predicate, CNContact.predicateForContacts(withIdentifiers: [first.identifier, second.identifier].sorted()))
        XCTAssertEqual(source.containerLookups[0], .identifiers(["selected"]))
        for (index, candidate) in candidates.sorted(by: { $0.identifier < $1.identifier }).enumerated() {
            XCTAssertEqual(source.containerLookups[index + 1], .owningContact(candidate.identifier))
        }
        XCTAssertEqual(source.requests[0].keysToFetch.count, 1)
        XCTAssertEqual(source.requests[0].keysToFetch.first as? String, CNContactIdentifierKey)
        XCTAssertTrue(source.requests.allSatisfy { !$0.unifyResults && $0.predicate != nil })
    }

    func testPhoneCandidatesNeverProveUniquenessAndApproximateMatchesArePreserved() throws {
        let approximate = contact("Approximate", phone: "5555550123")
        let source = FakeStore()
        source.containerResults = [["selected"], ["selected"]]
        source.contactResults = [[approximate], [approximate]]
        let lookup = try MacContactsDirectory(source: source).contacts(in: binding, identities: [], matchingHandles: ["+1 (555) 555-0123"])
        XCTAssertEqual(lookup.people.map(\.displayName), ["Approximate"])
        XCTAssertEqual(lookup.people.first?.handles, ["5555550123"])
        XCTAssertEqual(lookup.unresolvedHandles, ["+15555550123"])
        let empty = FakeStore()
        empty.containerResults = [["selected"]]
        empty.contactResults = [[]]
        let noMatch = try MacContactsDirectory(source: empty).contacts(in: binding, identities: [], matchingHandles: ["+15555550123"])
        XCTAssertEqual(noMatch.unresolvedHandles, ["+15555550123"])
        XCTAssertEqual(empty.events, ["container", "ids"])
    }

    func testIdentityRefreshChecksMembershipWithoutHandleSearch() throws {
        let selected = contact("Current", email: "new@example.invalid")
        let source = FakeStore()
        source.containerResults = [["selected"], ["selected"]]
        source.contactResults = [[selected]]
        let lookup = try MacContactsDirectory(source: source).contacts(in: binding, identities: [ContactIdentity(containerID: "selected", id: selected.identifier), ContactIdentity(containerID: "foreign", id: "ignored")], matchingHandles: [])
        XCTAssertEqual(lookup.people.map(\.displayName), ["Current"])
        XCTAssertTrue(lookup.unresolvedHandles.isEmpty)
        XCTAssertEqual(source.events, ["container", "container", "fields"])
    }

    func testMissingIdentityDoesNotMaterializeAndPermissionErrorsAreExact() throws {
        let source = FakeStore()
        source.containerResults = [["selected"], []]
        let lookup = try MacContactsDirectory(source: source).contacts(in: binding, identities: [ContactIdentity(containerID: "selected", id: "deleted")], matchingHandles: [])
        XCTAssertTrue(lookup.people.isEmpty)
        XCTAssertEqual(source.events, ["container", "container"])
        let denied = FakeStore()
        denied.isAuthorized = false
        XCTAssertThrowsError(try MacContactsDirectory(source: denied).allContacts(in: binding)) {
            XCTAssertEqual($0 as? ContactsDirectoryError, .permissionNotGranted)
        }
        XCTAssertTrue(denied.events.isEmpty)
        let missing = FakeStore()
        missing.containerResults = [[]]
        XCTAssertThrowsError(try MacContactsDirectory(source: missing).allContacts(in: binding)) {
            XCTAssertEqual($0 as? ContactsDirectoryError, .selectedContainerMissing("selected"))
        }
    }

    private func contact(_ name: String, email: String? = nil, phone: String? = nil) -> CNContact {
        let person = CNMutableContact()
        person.givenName = name
        if let email { person.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)] }
        if let phone { person.phoneNumbers = [CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: phone))] }
        return person
    }

    private final class FakeStore: ContactsStoreAccess {
        var isAuthorized = true
        var containerResults: [[String]] = []
        var contactResults: [[CNContact]] = []
        var requests: [CNContactFetchRequest] = []
        var containerLookups: [ContainerLookup] = []
        var events: [String] = []
        func containerIDs(for lookup: ContainerLookup) throws -> [String] {
            events.append("container")
            containerLookups.append(lookup)
            return containerResults.removeFirst()
        }
        func contacts(matching request: CNContactFetchRequest) throws -> [CNContact] {
            requests.append(request)
            events.append(request.keysToFetch.count == 1 ? "ids" : "fields")
            return contactResults.removeFirst()
        }
    }
}
