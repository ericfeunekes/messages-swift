import XCTest
import Foundation
import CSQLite
@testable import MessagesCore

private final class OperationDirectory: ContactsDirectorySource, @unchecked Sendable {
    var people: [ContactPerson]
    var allCalls = 0
    var unresolvedHandles: Set<String> = []
    var subsetCalls: [Set<ContactIdentity>] = []
    init(_ people: [ContactPerson]) { self.people = people }
    func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] {
        guard binding.containerID == "fixture" else { throw ContactsDirectoryError.selectedContainerMissing(binding.containerID) }
        allCalls += 1
        return people
    }
    func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String>) throws -> ContactLookup {
        guard binding.containerID == "fixture" else { throw ContactsDirectoryError.selectedContainerMissing(binding.containerID) }
        subsetCalls.append(identities)
        return ContactLookup(people: people.filter { identities.contains($0.identity) || $0.handles.contains { matchingHandles.contains(normalizedContactHandle($0)) } }, unresolvedHandles: unresolvedHandles, candidatesByHandle: Dictionary(uniqueKeysWithValues: matchingHandles.map { ($0, people) }))
    }
}

final class OperationsTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/operations-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func person(_ id: String, _ name: String, _ handles: [String]) -> ContactPerson {
        ContactPerson(identity: ContactIdentity(containerID: "fixture", id: id), displayName: name, handles: handles)
    }
    private func sql(_ statements: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("chat.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let status = sqlite3_exec(db, statements, nil, nil, nil)
        guard status == SQLITE_OK else { throw NSError(domain: "FixtureSQLite", code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) }
    }
    private func fixture(_ people: [ContactPerson], seedPeople: [ContactPerson]? = nil, seedDate: Date? = nil) throws -> (MessagesOperations, OperationDirectory, URL) {
        let recent = Int64((now.timeIntervalSince1970 - 978_307_200) * 1_000_000_000)
        try sql("""
        CREATE TABLE chat (guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (guid TEXT, date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, handle_id INTEGER, service TEXT DEFAULT 'iMessage', associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, balloon_bundle_id TEXT, date_edited INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0);
        CREATE TABLE attachment (guid TEXT, filename TEXT, mime_type TEXT);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        INSERT INTO handle VALUES ('+15550000001'), ('alice@example.test'), ('bob@example.test'), ('old@example.test');
        INSERT INTO chat VALUES ('chat-phone', 'phone-thread', NULL, 'iMessage'), ('chat-email', 'email-thread', NULL, 'iMessage'), ('chat-group', 'group-thread', 'Team', 'iMessage'), ('chat-old', 'old-thread', NULL, 'iMessage');
        INSERT INTO chat_handle_join VALUES (1,1),(2,2),(3,1),(3,3),(4,4);
        INSERT INTO message (guid,date,text,handle_id) VALUES ('phone-msg',\(recent-300),'needle phone',1), ('email-msg',\(recent-200),'needle email',2), ('group-msg',\(recent-100),'needle from Bob',3), ('old-msg',\(recent-Int64(100*86400)*1_000_000_000),'needle old',4);
        INSERT INTO chat_message_join VALUES (1,1),(2,2),(3,3),(4,4);
        """)
        let directory = OperationDirectory(people)
        let stateDirectory = root.appendingPathComponent("state")
        let state = try LocalState(directory: stateDirectory)
        try state.bindContainer("fixture")
        if let seedPeople { try state.seedInitialCache(seedPeople, now: seedDate ?? now) }
        return (MessagesOperations(store: MessageStore(path: root.appendingPathComponent("chat.db").path), directory: directory, binding: ContactsContainerBinding(containerID: "fixture"), state: state), directory, stateDirectory)
    }
    func testUncertainPhoneLookupReturnsCandidatesWithoutAssigningIdentity() async throws {
        let alice = person("a", "Alice", ["+15550000001"])
        let (ops, directory, _) = try fixture([alice], seedPeople: [alice], seedDate: now)
        directory.unresolvedHandles = ["+15550000001"]
        let page = try await ops.readMessages(ReadMessagesInput(chatID: "chat-phone"), now: now)
        XCTAssertNil(page.chat.participants.first?.sourceIdentity)
        XCTAssertNil(page.messages.first?.sender?.sourceIdentity)
        XCTAssertEqual(page.unresolvedContactHandles, ["+15550000001"])
        XCTAssertEqual(page.contactCandidates.map(\.identity.id), ["a"])
    }

    func testWarmReadDoesNotLoseUncachedSharedHandleOwner() async throws {
        let alice = person("a", "Alice", ["+15550000001"])
        let bob = person("b", "Bob", ["+15550000001"])
        let (ops, directory, _) = try fixture([alice, bob], seedPeople: [alice], seedDate: now)
        let page = try await ops.readMessages(ReadMessagesInput(chatID: "chat-phone"), now: now)
        XCTAssertNil(page.chat.participants.first?.sourceIdentity)
        XCTAssertNil(page.messages.first?.sender?.sourceIdentity)
        XCTAssertEqual(directory.subsetCalls.count, 1)
        XCTAssertEqual(directory.allCalls, 0)
    }

    func testWarmReadRefreshesOnlyKnownIdentitiesAndScansForUnknownHandles() async throws {
        let alice = person("a", "Alice Before", ["+15550000001"])
        let (ops, directory, _) = try fixture([alice, person("b", "Bob", ["bob@example.test"])])
        _ = try await ops.readMessages(ReadMessagesInput(chatID: "chat-phone"), now: now)
        XCTAssertEqual(directory.allCalls, 1)
        XCTAssertTrue(directory.subsetCalls.isEmpty)
        directory.people = [person("a", "Alice After", ["+15550000001"]), person("b", "Bob", ["bob@example.test"])]
        let warm = try await ops.readMessages(ReadMessagesInput(chatID: "chat-phone"), now: now.addingTimeInterval(1))
        XCTAssertEqual(warm.chat.participants.first?.displayName, "Alice After")
        XCTAssertEqual(warm.messages.first?.sender?.displayName, "Alice After")
        XCTAssertEqual(directory.allCalls, 1, "Known warm read must not rescan complete directory")
        XCTAssertEqual(directory.subsetCalls, [Set([alice.identity])])
        directory.people = [person("a", "Alice After", ["new@example.test"])]
        let removed = try await ops.readMessages(ReadMessagesInput(chatID: "chat-phone"), now: now.addingTimeInterval(2))
        XCTAssertNil(removed.chat.participants.first?.displayName, "Removed handle must not retain cached identity")
        XCTAssertNil(removed.messages.first?.sender?.displayName)
        XCTAssertEqual(directory.allCalls, 2, "Removed known handle needs discovery against current directory")
        directory.people.append(person("new", "New Contact", ["alice@example.test"]))
        let unknown = try await ops.readMessages(ReadMessagesInput(chatID: "chat-email"), now: now.addingTimeInterval(3))
        XCTAssertEqual(unknown.chat.participants.first?.displayName, "New Contact")
        XCTAssertEqual(directory.allCalls, 3, "Uncached handle must remain discoverable")
    }
    func testMissingAssociationClassificationColumnKeepsReadableRowUnknown() async throws {
        let (ops, _, _) = try fixture([])
        try sql("ALTER TABLE message DROP COLUMN associated_message_type")
        let page = try await ops.readMessages(ReadMessagesInput(chatID: "chat-phone"), now: now)
        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertEqual(page.events.map(\.id), ["phone-msg"])
        XCTAssertEqual(page.events.first?.kind, "unknown")
        XCTAssertEqual(page.events.first?.text, "needle phone")
        XCTAssertNotNil(page.events.first?.diagnostic)
    }
    func testDuplicateNamesReturnCandidatesWithoutSearchingEverything() async throws {
        let (ops, _, _) = try fixture([person("a", "Alex", ["+15550000001"]), person("b", "Alex", ["bob@example.test"])])
        let result = try await ops.searchMessages(SearchMessagesInput(query: "needle", participants: [PersonSelector(query: "Alex")]), now: now)
        XCTAssertEqual(Set(result.contactCandidates.map(\.identity.id)), ["a", "b"])
        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertTrue(result.chats.isEmpty)
    }
    func testMissingAndEmptySelectorsNeverRemoveTheFilter() async throws {
        let (ops, _, _) = try fixture([person("a", "Alice", ["+15550000001"])])
        for selector in [PersonSelector(query: "Nobody"), PersonSelector(), PersonSelector(query: ""), PersonSelector(sourceIdentity: ContactIdentity(containerID: "other", id: "a"))] {
            do { _ = try await ops.searchMessages(SearchMessagesInput(query: "needle", participants: [selector]), now: now); XCTFail("Unresolved selector must not broaden search") }
            catch { }
        }
    }
    func testPersonHandlesAreAlternativesAndMembershipIncludesOtherSenders() async throws {
        let (ops, _, _) = try fixture([person("a", "Alice", ["+15550000001", "alice@example.test"]), person("b", "Bob", ["bob@example.test"])])
        let selector = PersonSelector(query: "Alice")
        let all = try await ops.searchMessages(SearchMessagesInput(query: "needle", participants: [selector]), now: now)
        XCTAssertEqual(Set(all.messages.map(\.id)), ["phone-msg", "email-msg", "group-msg"])
        XCTAssertEqual(all.messages.first(where: { $0.id == "group-msg" })?.sender?.displayName, "Bob")
        let exact = try await ops.findChats(FindChatsInput(participants: [selector], membership: .exact), now: now)
        XCTAssertEqual(Set(exact.chats.map(\.chatID)), ["chat-phone", "chat-email"])
        let pair = try await ops.findChats(FindChatsInput(participants: [selector, PersonSelector(query: "Bob")], membership: .exact), now: now)
        XCTAssertEqual(pair.chats.map(\.chatID), ["chat-group"])
    }
    func testContactNameAndAliasFiltersApplyBeforeLimit() async throws {
        let (ops, _, _) = try fixture([person("a", "Alice Unique", ["alice@example.test"])])
        let named = try await ops.findChats(FindChatsInput(query: "Alice Unique", limit: 1), now: now)
        XCTAssertEqual(named.chats.map(\.chatID), ["chat-email"])
        _ = try await ops.setChatAlias(SetChatAliasInput(chatID: "chat-phone", alias: "Rare Alias"))
        let aliased = try await ops.findChats(FindChatsInput(query: "Rare Alias", limit: 1), now: now)
        XCTAssertEqual(aliased.chats.map(\.chatID), ["chat-phone"])
    }
    func testAliasDoesNotRebindWhenPhysicalChatRowIsReused() async throws {
        let (ops, _, stateDirectory) = try fixture([])
        _ = try await ops.setChatAlias(SetChatAliasInput(chatID: "chat-phone", alias: "Family"))
        try sql("UPDATE chat SET guid='replacement-guid' WHERE ROWID=1")
        let result = try await ops.findChats(FindChatsInput(), now: now)
        XCTAssertNil(result.chats.first(where: { $0.chatID == "replacement-guid" })?.alias)
        XCTAssertEqual(try LocalState(directory: stateDirectory).alias(for: "chat-phone"), "Family")
        do { _ = try await ops.readMessages(ReadMessagesInput(chatID: "chat-phone"), now: now); XCTFail("Old GUID must not resolve to reused row") } catch { }
    }
    func testInitialBaselineIncludesGroupMembersAndExcludesOlderThan90Days() async throws {
        let (ops, _, stateDirectory) = try fixture([person("a", "Alice", ["+15550000001"]), person("b", "Bob", ["bob@example.test"]), person("old", "Old", ["old@example.test"])])
        _ = try await ops.findChats(FindChatsInput(query: "does not match"), now: now)
        let state = try LocalState(directory: stateDirectory)
        XCTAssertTrue(state.isSeeded)
        XCTAssertEqual(Set(state.cacheEntries.map(\.person.identity.id)), ["a", "b"])
    }
    func testOnUseEnrichmentRefreshesExistingCacheWithoutChangingAdmission() async throws {
        let alice = person("a", "Alice Before", ["+15550000001"])
        let (ops, directory, stateDirectory) = try fixture([alice], seedPeople: [alice], seedDate: now.addingTimeInterval(-100))
        directory.people = [person("a", "Alice After", ["+15550000001"])]
        let page = try await ops.readMessages(ReadMessagesInput(chatID: "chat-phone"), now: now)
        XCTAssertEqual(page.chat.participants.first?.displayName, "Alice After")
        let state = try LocalState(directory: stateDirectory)
        XCTAssertEqual(state.cacheEntries.first?.person.displayName, "Alice After")
        XCTAssertEqual(state.cacheEntries.first?.refreshedAt, now)
        XCTAssertEqual(state.cacheEntries.first?.admittedAt, now.addingTimeInterval(-100))
    }
    func testDailyRefreshCatchesUpAndRemovesMissingContacts() async throws {
        let alice = person("a", "Alice Before", ["+15550000001"])
        let bob = person("b", "Bob", ["bob@example.test"])
        let old = now.addingTimeInterval(-3 * 86400)
        let (ops, directory, stateDirectory) = try fixture([alice, bob], seedPeople: [alice, bob], seedDate: old)
        directory.people = [person("a", "Alice After", ["+15550000001"])]
        try await ops.refreshDueContacts(now: now)
        let state = try LocalState(directory: stateDirectory)
        XCTAssertEqual(state.cacheEntries.map(\.person.displayName), ["Alice After"])
        XCTAssertEqual(state.cacheEntries.first?.refreshedAt, now)
        XCTAssertEqual(state.cacheEntries.first?.admittedAt, old)
    }
    func testFailedDecodeOnlyReadPageHasDiagnosticAndNoInventedText() async throws {
        let (ops, _, _) = try fixture([])
        try sql("UPDATE message SET text=NULL, attributedBody=X'01020304' WHERE ROWID=1")
        let page = try await ops.readMessages(ReadMessagesInput(chatID: "chat-phone"), now: now)
        XCTAssertEqual(page.decodingDiagnostics.map(\.messageID), ["phone-msg"])
        XCTAssertFalse(page.messages.contains { $0.text != nil })
        XCTAssertEqual(page.messages.count + page.events.count, 1, "Failed source row must remain represented")
    }
    func testOrdinaryAttachmentsEventsAndFailedDecodeAreNotLost() async throws {
        let (ops, _, _) = try fixture([])
        try sql("""
        UPDATE message SET date_edited=1 WHERE ROWID=1;
        INSERT INTO message (ROWID,guid,date,text,handle_id,associated_message_type,associated_message_guid,item_type,balloon_bundle_id,attributedBody,date_retracted) VALUES
        (5,'attachment',1,'',1,0,NULL,0,NULL,NULL,0),
        (6,'reaction',2,NULL,1,2001,'phone-msg',0,NULL,NULL,0),
        (7,'unknown',3,'needle unknown',1,0,NULL,99,NULL,NULL,0),
        (8,'preview',4,'needle preview',1,0,NULL,0,'com.apple.messages.URLBalloonProvider',NULL,0),
        (9,'broken',5,NULL,1,0,NULL,0,NULL,X'01020304',0),
        (10,'retracted',6,NULL,1,0,NULL,0,NULL,NULL,1);
        INSERT INTO chat_message_join VALUES (1,5),(1,6),(1,7),(1,8),(1,9),(1,10);
        INSERT INTO attachment VALUES ('attachment-guid','/synthetic/unavailable.png','image/png');
        INSERT INTO message_attachment_join VALUES (5,1),(9,1);
        """)
        let page = try await ops.readMessages(ReadMessagesInput(chatID: "chat-phone"), now: now)
        XCTAssertTrue(page.messages.contains { $0.id == "phone-msg" && $0.isEdited && $0.kind == .ordinary })
        XCTAssertTrue(page.messages.contains { $0.id == "attachment" && $0.kind == .attachment && $0.attachments.count == 1 })
        XCTAssertFalse(page.messages.contains { $0.id == "broken" && $0.kind == .attachment })
        XCTAssertTrue(page.messages.contains { $0.id == "retracted" && $0.isRetracted && $0.text == nil })
        XCTAssertEqual(page.events.first(where: { $0.id == "reaction" })?.associatedMessageID, "phone-msg")
        XCTAssertEqual(Set(page.events.filter { $0.id == "unknown" || $0.id == "preview" }.map(\.id)), ["unknown", "preview"])
        XCTAssertNil(page.events.first(where: { $0.id == "preview" })?.associatedMessageID)
        XCTAssertEqual(page.decodingDiagnostics.map(\.messageID), ["broken"])
        let search = try await ops.searchMessages(SearchMessagesInput(query: "no such readable text", chatID: "chat-phone"), now: now)
        XCTAssertTrue(search.messages.isEmpty)
        XCTAssertTrue(search.events.isEmpty)
        XCTAssertEqual(search.decodingDiagnostics.map(\.messageID), ["broken"])
        XCTAssertEqual(search.decodingDiagnostics.first?.chatID, "chat-phone")
        let eventSearch = try await ops.searchMessages(SearchMessagesInput(query: "needle", chatID: "chat-phone"), now: now)
        XCTAssertEqual(Set(eventSearch.events.map(\.id)), ["unknown", "preview"])
    }
}
