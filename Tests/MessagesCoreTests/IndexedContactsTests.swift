import Contacts
import CSQLite
import Foundation
import XCTest
@testable import MessagesCore

final class IndexedContactsTests: XCTestCase, @unchecked Sendable {
    private let binding = ContactsContainerBinding(containerID: "selected")

    func testCandidateIDsAreScopedBeforePersonFieldsAndAllSelectedOwnersSurvive() throws {
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
        XCTAssertEqual(lookup.unresolvedHandles, ["shared@example.invalid"])
        XCTAssertEqual(source.events, ["container", "matching", "container", "container", "container", "container", "fields"])
        XCTAssertEqual(source.requests.count, 2)
        XCTAssertEqual(source.requests[0].predicate, CNContact.predicateForContacts(matchingEmailAddress: "shared@example.invalid"))
        XCTAssertEqual(source.requests[1].predicate, CNContact.predicateForContacts(withIdentifiers: [first.identifier, second.identifier].sorted()))
        XCTAssertEqual(source.containerLookups[0], .identifiers(["selected"]))
        for (index, candidate) in candidates.sorted(by: { $0.identifier < $1.identifier }).enumerated() {
            XCTAssertEqual(source.containerLookups[index + 1], .owningContact(candidate.identifier))
        }
        XCTAssertEqual(source.requests[0].keysToFetch.compactMap { $0 as? String }, [CNContactIdentifierKey, CNContactEmailAddressesKey])
        XCTAssertEqual(Set(lookup.candidatesByHandle["shared@example.invalid", default: []].map(\.displayName)), ["One", "Two"])
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
        XCTAssertEqual(source.requests[0].keysToFetch.compactMap { $0 as? String }, [CNContactIdentifierKey, CNContactPhoneNumbersKey])
        XCTAssertEqual(lookup.unresolvedHandles, ["+15555550123"])
        XCTAssertEqual(lookup.candidatesByHandle["+15555550123"]?.first?.displayName, "Approximate")
        let empty = FakeStore()
        empty.containerResults = [["selected"]]
        empty.contactResults = [[]]
        let noMatch = try MacContactsDirectory(source: empty).contacts(in: binding, identities: [], matchingHandles: ["+15555550123"])
        XCTAssertEqual(noMatch.unresolvedHandles, ["+15555550123"])
        XCTAssertEqual(empty.events, ["container", "matching"])
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

    func testNativeAdapterCompositionPreservesExactPhoneNamesFromColdToWarm() async throws {
        let exact = contact("Exact owner", phone: "+1 (555) 555-0123")
        let expectedID = exact.identifier
        let pages = try await composedReads(snapshots: [[exact]], handle: "+15555550123")
        XCTAssertEqual(pages.0.chat.participants.first?.displayName, "Exact owner")
        XCTAssertEqual(pages.1.chat.participants.first?.displayName, "Exact owner")
        XCTAssertEqual(pages.1.messages.first?.sender?.sourceIdentity?.id, expectedID)
        XCTAssertTrue(pages.1.unresolvedContactHandles.isEmpty)
        XCTAssertEqual(pages.1.contactCandidates.first?.requestedHandle, "+15555550123")
        XCTAssertEqual(pages.1.contactCandidates.first?.match, .exact)
    }

    func testNativeAdapterCompositionKeepsSharedPhoneOwnersUnresolvedAndTiedToHandle() async throws {
        let first = contact("First", phone: "+15555550123")
        let second = contact("Second", phone: "+1 (555) 555-0123")
        let pages = try await composedReads(snapshots: [[first, second]], handle: "+15555550123")
        XCTAssertNil(pages.0.chat.participants.first?.sourceIdentity)
        XCTAssertNil(pages.1.messages.first?.sender?.sourceIdentity)
        XCTAssertEqual(pages.1.unresolvedContactHandles, ["+15555550123"])
        XCTAssertEqual(pages.1.contactCandidates.count, 2)
        XCTAssertTrue(pages.1.contactCandidates.allSatisfy { $0.requestedHandle == "+15555550123" && $0.match == .exact })
    }

    func testNativeAdapterCompositionKeepsApproximateWarmCandidateWithoutFalseLabel() async throws {
        let cold = contact("Owner", phone: "+15555550123")
        let changed = cold.mutableCopy() as! CNMutableContact
        changed.phoneNumbers = [CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "5555550123"))]
        let pages = try await composedReads(snapshots: [[cold], [changed]], handle: "+15555550123")
        XCTAssertEqual(pages.0.messages.first?.sender?.displayName, "Owner")
        XCTAssertNil(pages.1.messages.first?.sender?.sourceIdentity)
        XCTAssertEqual(pages.1.unresolvedContactHandles, ["+15555550123"])
        XCTAssertEqual(pages.1.contactCandidates.first?.requestedHandle, "+15555550123")
        XCTAssertEqual(pages.1.contactCandidates.first?.match, .approximate)
    }

    private func composedReads(snapshots: sending [[CNContact]], handle: String) async throws -> (MessagePageResult, MessagePageResult) {
        let people = snapshots[0]
        let warmPeople = snapshots.count > 1 ? snapshots[1] : people
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/indexed-composition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("chat.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE chat(guid TEXT,chat_identifier TEXT,display_name TEXT,service_name TEXT);
        CREATE TABLE handle(id TEXT);
        CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER,PRIMARY KEY(chat_id,message_id));
        CREATE TABLE message(guid TEXT,date INTEGER,text TEXT,is_from_me INTEGER,is_read INTEGER,handle_id INTEGER,item_type INTEGER,associated_message_type INTEGER,balloon_bundle_id TEXT);
        INSERT INTO chat VALUES('chat','routing',NULL,'iMessage');
        INSERT INTO handle VALUES('\(handle)');
        INSERT INTO chat_handle_join VALUES(1,1);
        INSERT INTO message VALUES('message',1000000000,'hello',0,0,1,0,0,NULL);
        INSERT INTO chat_message_join VALUES(1,1);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let source = FakeStore()
        source.containerResults = [["selected"], ["selected"]] + people.map { _ in ["selected"] }
        source.contactResults = [people, warmPeople, warmPeople]
        let ops = MessagesOperations(store: MessageStore(path: path), directory: MacContactsDirectory(source: source), binding: binding, state: try LocalState(directory: root.appendingPathComponent("state")))
        let now = Date(timeIntervalSince1970: 978307201)
        let cold = try await ops.readMessages(ReadMessagesInput(chatID: "chat"), now: now)
        let warm = try await ops.readMessages(ReadMessagesInput(chatID: "chat"), now: now)
        return (cold, warm)
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
            let keys = request.keysToFetch.compactMap { $0 as? String }
            if request.predicate == CNContact.predicateForContacts(matchingEmailAddress: "shared@example.invalid"), !keys.contains(CNContactEmailAddressesKey) {
                throw NSError(domain: CNErrorDomain, code: 2)
            }
            if request.predicate == CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: "+15555550123")), !keys.contains(CNContactPhoneNumbersKey) {
                throw NSError(domain: CNErrorDomain, code: 2)
            }
            events.append(keys.contains(CNContactGivenNameKey) ? "fields" : "matching")
            return contactResults.removeFirst()
        }
    }
}
