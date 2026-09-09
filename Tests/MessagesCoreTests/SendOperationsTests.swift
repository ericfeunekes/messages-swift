import CSQLite
import Foundation
import XCTest
@testable import MessagesCore

private final class SendDirectory: ContactsDirectorySource, @unchecked Sendable {
    let people: [ContactPerson]

    init(_ people: [ContactPerson]) { self.people = people }

    func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] {
        guard binding.containerID == "fixture" else { throw ContactsDirectoryError.selectedContainerMissing(binding.containerID) }
        return people
    }

    func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String>) throws -> ContactLookup {
        ContactLookup(people: try allContacts(in: binding))
    }
}

private enum FileMutation: Sendable {
    case rewrite(URL)
    case replace(URL)
    case delete(URL)
}

private actor RecordingSender: MessagesSending {
    private var configuredOutcomes: [SendDispatchOutcome]
    private let mutation: FileMutation?
    private var didMutate = false
    private var recorded: [(SendTarget, SendPayload)] = []

    init(outcomes: [SendDispatchOutcome] = [], mutation: FileMutation? = nil) {
        configuredOutcomes = outcomes
        self.mutation = mutation
    }

    func send(target: SendTarget, payload: SendPayload) async -> SendDispatchOutcome {
        recorded.append((target, payload))
        if !didMutate, let mutation {
            didMutate = true
            switch mutation {
            case .rewrite(let url):
                // Same length, but different contents and metadata.
                try? Data("changed!".utf8).write(to: url)
            case .replace(let url):
                let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement")
                try? Data("replacement".utf8).write(to: replacement)
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.moveItem(at: replacement, to: url)
            case .delete(let url):
                try? FileManager.default.removeItem(at: url)
            }
        }
        return configuredOutcomes.isEmpty ? .accepted : configuredOutcomes.removeFirst()
    }

    func dispatches() -> [(SendTarget, SendPayload)] { recorded }
}

/// Simulates an accepted public script command followed by the source row it
/// caused. It writes the same SQLite fixture that the operation observes.
private final class StatusRecordingSender: MessagesSending, @unchecked Sendable {
    enum Mode: Equatable {
        case failed(Int)
        case sent(delivered: Bool)
        case duplicate
        case delayedDuplicate
        case delayedSent
        case conflictingDelivery
        case groupOnlySent
        case absent
    }
    private let database: URL
    private let mode: Mode
    private var sequence = 0
    private var recorded: [(SendTarget, SendPayload)] = []

    init(database: URL, mode: Mode) { self.database = database; self.mode = mode }

    func send(target: SendTarget, payload: SendPayload) async -> SendDispatchOutcome {
        recorded.append((target, payload))
        let observedService: String
        switch target {
        case .chat: observedService = "iMessage"
        case .individual(_, "SMS"): observedService = "RCS"
        case let .individual(_, service): observedService = service
        }
        if case let .file(path) = payload {
            guard case let .sent(delivered) = mode else { return .accepted }
            Self.insertFile(database: database, path: path, delivered: delivered, guid: nextGUID("file"), service: observedService)
            return .accepted
        }
        guard case let .text(text) = payload else { return .accepted }
        switch mode {
        case .absent: return .accepted
        case .failed(let error): Self.insert(database: database, text: text, sent: 0, delivered: 0, error: error, guid: nextGUID("failed"), service: observedService)
        case .sent(let delivered): Self.insert(database: database, text: text, sent: 1, delivered: delivered ? 1 : 0, error: 0, guid: nextGUID("sent"), service: observedService)
        case .duplicate:
            Self.insert(database: database, text: text, sent: 0, delivered: 0, error: 22, guid: nextGUID("one"), service: observedService)
            Self.insert(database: database, text: text, sent: 1, delivered: 1, error: 0, guid: nextGUID("two"), service: observedService)
        case .delayedDuplicate:
            let firstGUID = nextGUID("first")
            let secondGUID = nextGUID("second")
            Self.insert(database: database, text: text, sent: 1, delivered: 1, error: 0, guid: firstGUID, service: observedService)
            let database = database
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                Self.insert(database: database, text: text, sent: 0, delivered: 0, error: 22, guid: secondGUID, service: observedService)
            }
        case .delayedSent:
            let guid = nextGUID("delayed")
            Self.insert(database: database, text: text, sent: 0, delivered: 0, error: 0, guid: guid, service: observedService)
            let database = database
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                var handle: OpaquePointer?
                guard sqlite3_open(database.path, &handle) == SQLITE_OK else { XCTFail("Fixture open failed"); return }
                defer { sqlite3_close(handle) }
                XCTAssertEqual(sqlite3_exec(handle, "UPDATE message SET is_sent=1 WHERE guid='\(guid)'", nil, nil, nil), SQLITE_OK)
            }
        case .conflictingDelivery:
            Self.insert(database: database, text: text, sent: 0, delivered: 1, error: 22, guid: nextGUID("conflict"), service: observedService)
        case .groupOnlySent:
            Self.insert(database: database, text: text, sent: 1, delivered: 1, error: 0, guid: nextGUID("group-only"), chatID: 2, service: observedService)
        }
        return .accepted
    }

    func dispatches() -> [(SendTarget, SendPayload)] { recorded }

    private func nextGUID(_ kind: String) -> String {
        sequence += 1
        return "status-\(kind)-\(sequence)"
    }

    private static func insert(database url: URL, text: String, sent: Int, delivered: Int, error: Int, guid: String, chatID: Int = 1, service: String) {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            XCTFail("Could not open status fixture database")
            return
        }
        defer { sqlite3_close(database) }
        let escaped = text.replacingOccurrences(of: "'", with: "''")
        let statement = """
        INSERT INTO message (guid,date,text,is_from_me,is_sent,is_delivered,error,service) VALUES ('\(guid)',999,'\(escaped)',1,\(sent),\(delivered),\(error),'\(service)');
        INSERT INTO chat_message_join VALUES (\(chatID),last_insert_rowid());
        """
        let status = sqlite3_exec(database, statement, nil, nil, nil)
        guard status == SQLITE_OK else {
            XCTFail("Could not insert status fixture row: \(String(cString: sqlite3_errmsg(database)))")
            return
        }
    }

    private static func insertFile(database url: URL, path: String, delivered: Bool, guid: String, service: String) {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            XCTFail("Could not open status fixture database")
            return
        }
        defer { sqlite3_close(database) }
        let escapedPath = path.replacingOccurrences(of: "'", with: "''")
        let statement = """
        INSERT INTO message (guid,date,text,is_from_me,is_sent,is_delivered,error,service) VALUES ('\(guid)',999,NULL,1,1,\(delivered ? 1 : 0),0,'\(service)');
        INSERT INTO chat_message_join VALUES (1,last_insert_rowid());
        INSERT INTO attachment (guid,filename,mime_type) VALUES ('\(guid)-attachment','\(escapedPath)','application/octet-stream');
        INSERT INTO message_attachment_join VALUES ((SELECT ROWID FROM message WHERE guid = '\(guid)'),last_insert_rowid());
        """
        let status = sqlite3_exec(database, statement, nil, nil, nil)
        guard status == SQLITE_OK else {
            XCTFail("Could not insert file status fixture row: \(String(cString: sqlite3_errmsg(database)))")
            return
        }
    }
}

private actor SuspendedSender: MessagesSending {
    private var recorded: [(SendTarget, SendPayload)] = []
    private var entered = false
    private var shouldSuspend = true
    private var enterWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func send(target: SendTarget, payload: SendPayload) async -> SendDispatchOutcome {
        recorded.append((target, payload))
        guard shouldSuspend else { return .accepted }
        shouldSuspend = false
        entered = true
        enterWaiter?.resume()
        enterWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return .accepted
    }

    func waitForFirstDispatch() async {
        guard !entered else { return }
        await withCheckedContinuation { enterWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func dispatches() -> [(SendTarget, SendPayload)] { recorded }
}

final class SendOperationsTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".scratch/send-operations-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func person(_ id: String, _ name: String, _ handles: [String]) -> ContactPerson {
        ContactPerson(identity: ContactIdentity(containerID: "fixture", id: id), displayName: name, handles: handles)
    }

    private func sql(_ statements: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("chat.db").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let status = sqlite3_exec(database, statements, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw NSError(domain: "SendFixtureSQLite", code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
    }

    private func fixture(_ people: [ContactPerson], sender: any MessagesSending) throws -> MessagesOperations {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("chat.db"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("state"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("outgoing"))
        let date = Int64((now.timeIntervalSince1970 - 978_307_200) * 1_000_000_000)
        try sql("""
        CREATE TABLE chat (guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (guid TEXT, date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, handle_id INTEGER, service TEXT DEFAULT 'iMessage', associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, balloon_bundle_id TEXT, date_edited INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0, is_sent INTEGER, is_delivered INTEGER, error INTEGER);
        CREATE TABLE attachment (guid TEXT, filename TEXT, mime_type TEXT);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        INSERT INTO handle VALUES ('+15550000001'), ('alice@example.test'), ('bob@example.test');
        INSERT INTO chat VALUES ('chat-direct-guid', '+15550000001', NULL, 'iMessage'), ('chat-group-guid', 'group-thread', 'Project Team', 'SMS');
        INSERT INTO chat_handle_join VALUES (1,1),(2,1),(2,3);
        INSERT INTO message (guid,date,text,handle_id) VALUES ('direct-message',\(date),'hello',1), ('group-message',\(date + 1),'group',3);
        INSERT INTO chat_message_join VALUES (1,1),(2,2);
        """)
        let state = try LocalState(directory: root.appendingPathComponent("state"))
        try state.bindContainer("fixture")
        return MessagesOperations(
            store: MessageStore(path: root.appendingPathComponent("chat.db").path),
            directory: SendDirectory(people),
            binding: ContactsContainerBinding(containerID: "fixture"),
            state: state,
            sender: sender,
            outgoingStagingDirectory: root.appendingPathComponent("outgoing")
        )
    }

    private func localFile(_ name: String, contents: String = "fixture") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        // macOS updates fresh fixture metadata asynchronously. Finish fixture
        // setup before taking the production identity snapshot; mutation tests
        // still change files after dispatch and exercise the unchanged guard.
        _ = try Data(contentsOf: url)
        Thread.sleep(forTimeInterval: 0.5)
        return url
    }

    private func stagedPaths(in dispatches: [(SendTarget, SendPayload)]) throws -> [URL] {
        try dispatches.map { _, payload in
            guard case let .file(path) = payload else {
                throw NSError(domain: "SendOperationsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected a staged file payload"])
            }
            return URL(fileURLWithPath: path)
        }
    }

    private func outgoingContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("outgoing").path)
    }

    private func stagedData() throws -> [Data] {
        let outgoing = root.appendingPathComponent("outgoing")
        return try FileManager.default.subpathsOfDirectory(atPath: outgoing.path).compactMap { relativePath in
            let file = outgoing.appendingPathComponent(relativePath)
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return try Data(contentsOf: file)
        }
    }

    func testExistingDirectAndGroupChatsRouteOnlyByExactGUID() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"]), person("bob", "Bob", ["bob@example.test"])], sender: sender)

        let direct = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "direct"), now: now)
        let group = try await ops.sendMessage(.init(chatID: "chat-group-guid", text: "group"), now: now)

        XCTAssertEqual(direct.status, .unknown)
        XCTAssertEqual(direct.destination?.service, "iMessage")
        XCTAssertEqual(group.status, .unknown)
        XCTAssertEqual(group.destination?.service, "SMS")
        let dispatches = await sender.dispatches()
        XCTAssertEqual(dispatches.map(\.0), [.individual(handle: "+15550000001", service: "iMessage"), .chat("chat-group-guid")])
    }

    func testAliasIsOnlyDiscoveryAndExactFoundGUIDIsTheDispatchTarget() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        _ = try await ops.setChatAlias(.init(chatID: "chat-direct-guid", alias: "Family line"))
        let found = try await ops.findChats(.init(query: "Family line"), now: now)
        XCTAssertEqual(found.chats.map(\.chatID), ["chat-direct-guid"])

        _ = try await ops.sendMessage(.init(chatID: found.chats[0].chatID, service: "iMessage", text: "exact"), now: now)
        await XCTAssertThrowsErrorAsync {
            _ = try await ops.sendMessage(.init(chatID: "Family line", text: "not a GUID"), now: self.now)
        }
        let dispatches = await sender.dispatches()
        XCTAssertEqual(dispatches.map(\.0), [.individual(handle: "+15550000001", service: "iMessage")])
    }

    func testNamedRecipientsPreserveAmbiguityAndMultipleHandlesRequireChoice() async throws {
        let duplicateSender = RecordingSender()
        let duplicateOps = try fixture([person("one", "Alex", ["+15550000001"]), person("two", "Alex", ["bob@example.test"])], sender: duplicateSender)
        let duplicates = try await duplicateOps.sendMessage(.init(recipients: [.init(query: "Alex")], service: "iMessage", text: "hello"), now: now)
        XCTAssertEqual(duplicates.status, .needsChoice)
        XCTAssertEqual(Set(duplicates.contactCandidates.map(\.identity.id)), ["one", "two"])
        let duplicateDispatches = await duplicateSender.dispatches()
        XCTAssertTrue(duplicateDispatches.isEmpty)

        let handlesSender = RecordingSender()
        let handlesOps = try fixture([person("alice", "Alice", ["+15550000001", "alice@example.test"])], sender: handlesSender)
        let handles = try await handlesOps.sendMessage(.init(recipients: [.init(query: "Alice")], service: "iMessage", text: "hello"), now: now)
        XCTAssertEqual(handles.status, .needsChoice)
        XCTAssertEqual(Set(handles.handleCandidates), ["+15550000001", "alice@example.test"])
        let handleDispatches = await handlesSender.dispatches()
        XCTAssertTrue(handleDispatches.isEmpty)
    }

    func testExplicitHandleDoesNotExpandAndForeignContactIdentityCannotSend() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001", "alice@example.test"])], sender: sender)
        let result = try await ops.sendMessage(.init(recipients: [.init(query: "ALICE@example.test")], service: "RCS", text: "hello"), now: now)
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.destination?.recipients.map(\.handle), ["alice@example.test"])
        let dispatches = await sender.dispatches()
        XCTAssertEqual(dispatches.map(\.0), [.individual(handle: "alice@example.test", service: "RCS")])

        await XCTAssertThrowsErrorAsync {
            _ = try await ops.sendMessage(.init(recipients: [.init(sourceIdentity: .init(containerID: "foreign", id: "alice"))], service: "iMessage", text: "no"), now: self.now)
        }
    }

    func testFormattedPhoneUsesOnlyItsNormalizedHandleWithAndWithoutContacts() async throws {
        let contactSender = RecordingSender()
        let contactOps = try fixture([person("alice", "Alice", ["+15550000001", "alice@example.test"])], sender: contactSender)
        let contactResult = try await contactOps.sendMessage(.init(recipients: [.init(query: "+1 (555) 000-0001")], service: "SMS", text: "phone"), now: now)
        XCTAssertEqual(contactResult.status, .unknown)
        XCTAssertEqual(contactResult.destination?.recipients.map(\.handle), ["+15550000001"])
        let contactDispatches = await contactSender.dispatches()
        XCTAssertEqual(contactDispatches.map(\.0), [.individual(handle: "+15550000001", service: "SMS")])

        let absentSender = RecordingSender()
        let absentOps = try fixture([], sender: absentSender)
        let absentResult = try await absentOps.sendMessage(.init(recipients: [.init(query: "+1 (555) 000-0001")], service: "SMS", text: "phone"), now: now)
        XCTAssertEqual(absentResult.status, .unknown)
        let absentDispatches = await absentSender.dispatches()
        XCTAssertEqual(absentDispatches.map(\.0), [.individual(handle: "+15550000001", service: "SMS")])
    }

    func testUniqueObservedSourceFailureMakesTheSendFail() async throws {
        let sender = StatusRecordingSender(database: root.appendingPathComponent("chat.db"), mode: .failed(22))
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)

        let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "provider failed"), now: now)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.parts.map(\.outcome), [.failed])
        XCTAssertEqual(result.parts[0].errorCode, "messages_send_failed")
        XCTAssertEqual(result.parts[0].isSent, false)
        XCTAssertEqual(result.parts[0].deliveryErrorCode, 22)
        XCTAssertNotNil(result.parts[0].messageID)
    }

    func testSentDoesNotRequireARecipientDeliveryReceipt() async throws {
        let sender = StatusRecordingSender(database: root.appendingPathComponent("chat.db"), mode: .sent(delivered: false))
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)

        let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "sent no receipt"), now: now)

        XCTAssertEqual(result.status, .sent)
        XCTAssertEqual(result.parts.map(\.outcome), [.sent])
        XCTAssertEqual(result.parts[0].isSent, true)
        XCTAssertEqual(result.parts[0].isDelivered, false)
        XCTAssertEqual(result.parts[0].deliveryErrorCode, 0)
        XCTAssertEqual(result.delivery, "unconfirmed")
    }

    func testObservedSentTextAndFilesContinueInOrderAndConfirmDeliveryOnlyWhenEveryPartIsDelivered() async throws {
        let sender = StatusRecordingSender(database: root.appendingPathComponent("chat.db"), mode: .sent(delivered: true))
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let first = try localFile("confirmed-first.txt")
        let second = try localFile("confirmed-second.txt")

        let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "confirmed text", files: [first.path, second.path]), now: now)

        XCTAssertEqual(result.status, .sent)
        XCTAssertEqual(result.delivery, "provider_reported")
        XCTAssertEqual(result.parts.map(\.outcome), [.sent, .sent, .sent])
        XCTAssertEqual(result.parts.map(\.messageID), ["status-sent-1", "status-file-2", "status-file-3"])
        XCTAssertEqual(result.parts.map(\.isDelivered), [true, true, true])
        let dispatches = sender.dispatches()
        XCTAssertEqual(dispatches.count, 3)
        XCTAssertEqual(dispatches[0].1, .text("confirmed text"))
        XCTAssertEqual(dispatches.dropFirst().map(\.1).compactMap { payload -> String? in
            guard case let .file(path) = payload else { return nil }
            return URL(fileURLWithPath: path).lastPathComponent
        }, ["confirmed-first.txt", "confirmed-second.txt"])
    }

    func testMissingOrAmbiguousPostDispatchSourceRowsRemainUnknownWithoutRetry() async throws {
        for mode in [StatusRecordingSender.Mode.absent, .duplicate] {
            let sender = StatusRecordingSender(database: root.appendingPathComponent("chat.db"), mode: mode)
            let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)

            let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "same payload"), now: now)

            XCTAssertEqual(result.status, .unknown)
            XCTAssertEqual(result.parts.map(\.outcome), [.unknown])
            XCTAssertEqual(result.parts[0].errorCode, mode == .absent ? "messages_status_unavailable" : "messages_status_ambiguous")
        }
    }

    func testDirectSendDoesNotTreatAnOutgoingGroupRowContainingTheHandleAsItsStatus() async throws {
        let sender = StatusRecordingSender(database: root.appendingPathComponent("chat.db"), mode: .groupOnlySent)
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)

        let result = try await ops.sendMessage(.init(recipients: [.init(query: "+15550000001")], service: "iMessage", text: "direct only"), now: now)

        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.parts.map(\.outcome), [.unknown])
        XCTAssertEqual(result.parts[0].errorCode, "messages_status_unavailable")
        XCTAssertNil(result.parts[0].messageID)
    }

    func testSecondIdenticalOutgoingRowWithinObservationWindowMakesStatusUnknown() async throws {
        let sender = StatusRecordingSender(database: root.appendingPathComponent("chat.db"), mode: .delayedDuplicate)
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)

        let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "delayed duplicate"), now: now)

        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.parts.map(\.outcome), [.unknown])
        XCTAssertEqual(result.parts[0].errorCode, "messages_status_ambiguous")
        XCTAssertNil(result.parts[0].messageID)
    }

    func testAggregateNeverReportsSentWhenAnyPartWasNotAttempted() async throws {
        let ops = try fixture([], sender: RecordingSender())
        func part(_ index: Int, _ outcome: SendPartOutcome) -> SendPartResult {
            .init(index: index, kind: "text", fileIndex: nil, outcome: outcome, errorCode: nil,
                  messageID: nil, isSent: nil, isDelivered: nil, deliveryErrorCode: nil,
                  observedService: nil, correlation: nil)
        }

        let cancelledAfterSent = await ops.aggregateSendStatus([part(0, .sent), part(1, .notAttempted)])
        let cancelledBeforeDispatch = await ops.aggregateSendStatus([part(0, .notAttempted), part(1, .notAttempted)])

        XCTAssertEqual(cancelledAfterSent, .unknown)
        XCTAssertEqual(cancelledBeforeDispatch, .unknown)
    }

    func testAttachmentStatusExpandsOnlyALeadingTilde() throws {
        let database = root.appendingPathComponent("chat.db")
        _ = try fixture([person("alice", "Alice", ["+15550000001"])], sender: RecordingSender())
        let store = MessageStore(path: database.path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let relative = "Library/Messages/Attachments/messages-swift/status-fixture.bin"
        let expectedPath = home + "/" + relative

        try sql("""
        INSERT INTO message (guid,date,text,is_from_me,is_sent,is_delivered,error) VALUES ('interior-tilde',1000,NULL,1,1,1,0);
        INSERT INTO chat_message_join VALUES (1,last_insert_rowid());
        INSERT INTO attachment (guid,filename,mime_type) VALUES ('interior-tilde-attachment','prefix~/\(relative)','application/octet-stream');
        INSERT INTO message_attachment_join VALUES ((SELECT ROWID FROM message WHERE guid = 'interior-tilde'),last_insert_rowid());
        """)
        let interior = try store.outgoingMessageStatus(afterRowID: 2, target: .chat("chat-direct-guid"), expectedService: "iMessage", payload: .file("prefix" + expectedPath))
        XCTAssertEqual(interior, .none)

        try sql("""
        INSERT INTO message (guid,date,text,is_from_me,is_sent,is_delivered,error) VALUES ('leading-tilde',1001,NULL,1,1,1,0);
        INSERT INTO chat_message_join VALUES (1,last_insert_rowid());
        INSERT INTO attachment (guid,filename,mime_type) VALUES ('leading-tilde-attachment','~/\(relative)','application/octet-stream');
        INSERT INTO message_attachment_join VALUES ((SELECT ROWID FROM message WHERE guid = 'leading-tilde'),last_insert_rowid());
        """)
        let leading = try store.outgoingMessageStatus(afterRowID: 3, target: .chat("chat-direct-guid"), expectedService: "iMessage", payload: .file(expectedPath))
        XCTAssertEqual(leading, .unique(.init(messageID: "leading-tilde", isSent: true, isDelivered: true, deliveryErrorCode: 0, service: "iMessage")))
    }

    func testInvalidDestinationsAndContentNeverDispatch() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let invalid = [
            SendMessageInput(chatID: "chat-direct-guid", recipients: [.init(query: "Alice")], text: "x"),
            SendMessageInput(recipients: [.init(query: "Alice"), .init(query: "Alice")], service: "iMessage", text: "x"),
            SendMessageInput(recipients: [.init(query: "Alice")], service: "iMessage"),
            SendMessageInput(recipients: [.init(query: "Alice")], service: "iMessage", text: "\0")
        ]
        for input in invalid {
            await XCTAssertThrowsErrorAsync { _ = try await ops.sendMessage(input, now: self.now) }
        }
        let dispatches = await sender.dispatches()
        XCTAssertTrue(dispatches.isEmpty)
    }

    func testAllFilesAreValidatedBeforeFirstDispatch() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let good = try localFile("good.txt")
        let directory = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let symlink = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: good)
        let unreadable = try localFile("unreadable.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        for bad in [directory.path, symlink.path, unreadable.path, root.appendingPathComponent("missing.txt").path, "relative.txt", good.path + "\0"] {
            do {
                _ = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "text", files: [good.path, bad]), now: now)
                XCTFail("Invalid file must prevent every dispatch")
            } catch let error as SendValidationError { XCTAssertEqual(error, .invalidFile) }
        }
        let dispatches = await sender.dispatches()
        XCTAssertTrue(dispatches.isEmpty)
    }

    func testUnconfirmedTextStopsFiles() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let first = try localFile("first.txt")
        let second = try localFile("second.txt")
        let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "first text", files: [first.path, second.path]), now: now)
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.delivery, "unconfirmed")
        XCTAssertEqual(result.parts.map(\.outcome), [.unknown, .notAttempted, .notAttempted])
        let dispatches = await sender.dispatches()
        XCTAssertEqual(dispatches.count, 1)
        XCTAssertEqual(dispatches.map(\.1).first, .text("first text"))
        let staged = try stagedPaths(in: Array(dispatches.dropFirst()))
        XCTAssertTrue(staged.isEmpty, "Unknown post-dispatch status stops before file sends")
    }

    func testOneAndMultipleFilesWithoutText() async throws {
        let sender = RecordingSender()
        let ops = try fixture([], sender: sender)
        let first = try localFile("file-only-one.txt")
        let second = try localFile("file-only-two.txt")
        let single = try await ops.sendMessage(.init(chatID: "chat-group-guid", files: [first.path]), now: now)
        XCTAssertEqual(single.status, .unknown)
        XCTAssertEqual(single.parts.map(\.kind), ["file"])
        XCTAssertEqual(single.parts.map(\.fileIndex), [0])
        let multiple = try await ops.sendMessage(.init(chatID: "chat-group-guid", files: [first.path, second.path]), now: now)
        XCTAssertEqual(multiple.status, .unknown)
        XCTAssertEqual(multiple.parts.map(\.fileIndex), [0, 1])
        let calls = await sender.dispatches()
        let staged = try stagedPaths(in: calls)
        XCTAssertEqual(staged.map { $0.lastPathComponent }, ["file-only-one.txt", "file-only-one.txt"])
        XCTAssertEqual(try staged.map { try Data(contentsOf: $0) }, [Data("fixture".utf8), Data("fixture".utf8)])
        XCTAssertEqual(Set(staged.map(\.path)).count, staged.count)
    }

    func testRejectedAndUnknownStopTheBatchWithoutRetry() async throws {
        for (outcome, expectedStatus, expectedPart) in [(SendDispatchOutcome.rejected, SendStatus.failed, SendPartOutcome.failed), (.unknown, .unknown, .unknown), (.unavailable, .failed, .failed)] {
            let sender = RecordingSender(outcomes: [outcome, .accepted])
            let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
            let first = try localFile("first-\(outcome.rawValue).txt")
            let second = try localFile("second-\(outcome.rawValue).txt")
            let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "text", files: [first.path, second.path]), now: now)
            XCTAssertEqual(result.status, expectedStatus)
            if outcome == .unavailable { XCTAssertEqual(result.parts[0].errorCode, "messages_route_unavailable") }
            XCTAssertEqual(result.parts.map(\.outcome), [expectedPart, .notAttempted, .notAttempted])
            let dispatches = await sender.dispatches()
            XCTAssertEqual(dispatches.count, 1)
        }
    }

    func testFileChangesDuringAwaitedTextDispatchStopBeforeAnyFileDispatch() async throws {
        let mutations: [(URL) -> FileMutation] = [FileMutation.rewrite, FileMutation.replace, FileMutation.delete]
        for mutation in mutations {
            let file = try localFile("mutated-\(UUID().uuidString).txt", contents: "original")
            let sender = RecordingSender(mutation: mutation(file))
            let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
            let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "text", files: [file.path]), now: now)
            XCTAssertEqual(result.status, .unknown)
            XCTAssertEqual(result.parts.map(\.outcome), [.unknown, .notAttempted])
            let dispatches = await sender.dispatches()
            XCTAssertEqual(dispatches.map(\.1), [.text("text")])
        }
    }

    func testConcurrentBatchIsRejectedWithoutDispatchWhileFirstBatchIsPaused() async throws {
        let sender = SuspendedSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        async let first = ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "first"), now: now)
        await sender.waitForFirstDispatch()

        let second = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "second"), now: now)
        XCTAssertEqual(second.status, .failed)
        XCTAssertEqual(second.errorCode, "send_in_progress")
        XCTAssertEqual(second.parts.map(\.outcome), [.notAttempted])
        let pausedDispatches = await sender.dispatches()
        XCTAssertEqual(pausedDispatches.map(\.1), [.text("first")])

        await sender.release()
        let firstResult = try await first
        XCTAssertEqual(firstResult.status, .unknown)
        XCTAssertEqual(firstResult.parts.map(\.outcome), [.unknown])
    }

    func testCancellationAfterAcceptedTextStopsFilesAndReleasesBatchGuard() async throws {
        let sender = SuspendedSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let file = try localFile("cancelled.txt")
        let first = Task { try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "text", files: [file.path]), now: self.now) }
        await sender.waitForFirstDispatch()

        first.cancel()
        await sender.release()
        let cancelled = try await first.value
        XCTAssertEqual(cancelled.status, .unknown)
        XCTAssertEqual(cancelled.errorCode, "send_cancelled")
        XCTAssertEqual(cancelled.parts.map(\.outcome), [.unknown, .notAttempted])
        let cancelledDispatches = await sender.dispatches()
        XCTAssertEqual(cancelledDispatches.map(\.1), [.text("text")])
        XCTAssertTrue(try outgoingContents().isEmpty)

        let next = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "next"), now: now)
        XCTAssertEqual(next.status, .unknown)
        let finalDispatches = await sender.dispatches()
        XCTAssertEqual(finalDispatches.map(\.1), [.text("text"), .text("next")])
    }

    func testWholeFileBatchIsStagedBeforePausedTextDispatch() async throws {
        let sender = SuspendedSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let firstFile = try localFile("first-staged-before-text.txt", contents: "first bytes")
        let secondFile = try localFile("second-staged-before-text.txt", contents: "second bytes")
        let task = Task {
            try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "text", files: [firstFile.path, secondFile.path]), now: self.now)
        }
        await sender.waitForFirstDispatch()

        let staged = try stagedData()
        XCTAssertEqual(staged.count, 2)
        XCTAssertTrue(staged.contains(Data("first bytes".utf8)))
        XCTAssertTrue(staged.contains(Data("second bytes".utf8)))

        await sender.release()
        let result = try await task.value
        XCTAssertEqual(result.status, .unknown)
    }

    func testCancellationRetainsOnlyTheAcceptedFileStage() async throws {
        let sender = SuspendedSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let firstFile = try localFile("accepted-before-cancel.txt", contents: "first")
        let secondFile = try localFile("not-attempted-after-cancel.txt", contents: "second")
        let task = Task {
            try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", files: [firstFile.path, secondFile.path]), now: self.now)
        }
        await sender.waitForFirstDispatch()

        task.cancel()
        await sender.release()
        let result = try await task.value

        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.parts.map(\.outcome), [.unknown, .notAttempted])
        let dispatched = try stagedPaths(in: await sender.dispatches())
        XCTAssertEqual(dispatched.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dispatched[0].path))
        XCTAssertEqual(try outgoingContents().count, 1)
    }

    func testReadAndFindNeverDispatch() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        _ = try await ops.findChats(.init(query: "Alice"), now: now)
        _ = try await ops.readMessages(.init(chatID: "chat-direct-guid"), now: now)
        let dispatches = await sender.dispatches()
        XCTAssertTrue(dispatches.isEmpty)
    }

    func testTextOnlySendNeverCreatesStaging() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)

        let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "only text"), now: now)

        XCTAssertEqual(result.status, .unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outgoing").path))
    }

    func testStagingFailurePreventsTextAndFileDispatch() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let file = try localFile("file.txt")
        let outgoing = root.appendingPathComponent("outgoing")
        try FileManager.default.createDirectory(at: outgoing, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outgoing.path)

        do {
            _ = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", text: "text", files: [file.path]), now: now)
            XCTFail("A non-private staging root must fail before the text dispatch")
        } catch let error as SendValidationError {
            XCTAssertEqual(error, .fileStagingFailed)
        }
        let dispatches = await sender.dispatches()
        XCTAssertTrue(dispatches.isEmpty)
    }

    func testFileRetentionTracksAcceptedAndUnknownOutcomesPerPart() async throws {
        for (outcomes, expectedStatus, retainedCount) in [
            ([SendDispatchOutcome.accepted, .unknown], SendStatus.unknown, 1),
            ([.rejected], SendStatus.failed, 0),
            ([.unavailable], SendStatus.failed, 0),
        ] {
            let sender = RecordingSender(outcomes: outcomes)
            let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
            let first = try localFile("retained-first-\(UUID().uuidString).txt")
            let second = try localFile("retained-second-\(UUID().uuidString).txt")

            let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", files: [first.path, second.path]), now: now)

            XCTAssertEqual(result.status, expectedStatus)
            let dispatches = await sender.dispatches()
            XCTAssertEqual(dispatches.count, 1)
            let files = try stagedPaths(in: dispatches)
            XCTAssertEqual(files.filter { FileManager.default.fileExists(atPath: $0.path) }.count, retainedCount)
            XCTAssertEqual((try? outgoingContents())?.count ?? 0, retainedCount == 0 ? 0 : 1)
        }
    }

    func testOnlyAcceptedFileStageSurvivesLaterRejectedOrUnavailableFile() async throws {
        for outcome in [SendDispatchOutcome.rejected, .unavailable] {
            let sender = RecordingSender(outcomes: [.accepted, outcome, .accepted])
            let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
            let first = try localFile("accepted-\(outcome.rawValue)-\(UUID().uuidString).txt", contents: "first")
            let second = try localFile("failed-\(outcome.rawValue)-\(UUID().uuidString).txt", contents: "second")
            let third = try localFile("unattempted-\(outcome.rawValue)-\(UUID().uuidString).txt", contents: "third")

            let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: "iMessage", files: [first.path, second.path, third.path]), now: now)

            XCTAssertEqual(result.status, .unknown)
            XCTAssertEqual(result.parts.map(\.outcome), [.unknown, .notAttempted, .notAttempted])
            let staged = try stagedPaths(in: await sender.dispatches())
            XCTAssertEqual(staged.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged[0].path))
            let batch = staged[0].deletingLastPathComponent().deletingLastPathComponent()
            XCTAssertFalse(FileManager.default.fileExists(atPath: batch.appendingPathComponent("2").path))
            XCTAssertEqual(try outgoingContents().count, 1)
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

private actor RouteAvailabilitySender: MessagesSending, MessagesRouteDiscovering {
    let services: [String]
    private var targets: [SendTarget] = []
    init(_ services: [String] = ["iMessage", "SMS"]) { self.services = services }
    func availableServices() async throws -> [String] { services }
    func send(target: SendTarget, payload: SendPayload) async -> SendDispatchOutcome {
        targets.append(target)
        return .rejected
    }
    func dispatchedTargets() -> [SendTarget] { targets }
}

extension SendOperationsTests {
    func testRouteNewNumberAndNamedIdentityAreReadOnly() async throws {
        let alice = person("alice", "Alice", ["+15550000001"])
        let sender = RouteAvailabilitySender()
        let ops = try fixture([alice], sender: sender)
        let fresh = try await ops.resolveSendRoute(.init(recipients: [.init(query: "+15550009999")]), now: now)
        XCTAssertEqual(fresh.kind, "direct")
        XCTAssertNil(fresh.suggestedService)
        XCTAssertEqual(fresh.suggestionBasis, "no_history")
        XCTAssertEqual(fresh.serviceOptions, ["iMessage", "SMS"])
        let named = try await ops.resolveSendRoute(.init(recipients: [.init(query: "Alice")]), now: now)
        let identity = try await ops.resolveSendRoute(.init(recipients: [.init(sourceIdentity: alice.identity)]), now: now)
        XCTAssertEqual(named.destination, identity.destination)
        XCTAssertEqual(named.destination?.recipients.first?.handle, "+15550000001")
        let calls = await sender.dispatchedTargets()
        XCTAssertTrue(calls.isEmpty)
    }

    func testRouteAmbiguousNamesReturnCandidatesWithoutDispatch() async throws {
        let sender = RouteAvailabilitySender()
        let ops = try fixture([person("a", "Alex", ["+15550000001"]), person("b", "Alex", ["+15550000002"])], sender: sender)
        let result = try await ops.resolveSendRoute(.init(recipients: [.init(query: "Alex")]), now: now)
        XCTAssertNil(result.destination)
        XCTAssertEqual(result.suggestionBasis, "needs_choice")
        XCTAssertEqual(result.contactCandidates.count, 2)
        let calls = await sender.dispatchedTargets()
        XCTAssertTrue(calls.isEmpty)
    }

    func testRouteRCSHistoryUsesSMSAndFrozenServiceSurvivesHistoryChange() async throws {
        let sender = RouteAvailabilitySender()
        let ops = try fixture([], sender: sender)
        try sql("UPDATE message SET is_from_me=1,is_sent=1,error=0,service='RCS' WHERE ROWID=1")
        let route = try await ops.resolveSendRoute(.init(chatID: "chat-direct-guid"), now: now)
        XCTAssertEqual(route.suggestedService, "SMS")
        XCTAssertEqual(route.suggestionBasis, "latest_successful")
        try sql("UPDATE message SET service='iMessage' WHERE ROWID=1")
        _ = try await ops.sendMessage(.init(chatID: "chat-direct-guid", service: route.suggestedService, text: "approved synthetic text"), now: now)
        let calls = await sender.dispatchedTargets()
        XCTAssertEqual(calls, [.individual(handle: "+15550000001", service: "SMS")])
        _ = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "automatic service"), now: now)
        let finalCalls = await sender.dispatchedTargets()
        XCTAssertEqual(finalCalls.last, .individual(handle: "+15550000001", service: "iMessage"))
        XCTAssertEqual(finalCalls.count, 2)
    }

    func testRouteNewerFailedPendingAndConflictedAttemptsSuppressOldSuccess() async throws {
        let ops = try fixture([], sender: RouteAvailabilitySender())
        try sql("""
        UPDATE message SET is_from_me=1,is_sent=1,error=0,service='RCS' WHERE ROWID=1;
        INSERT INTO message (ROWID,guid,date,text,is_from_me,is_sent,error,service)
        SELECT 3,'new-attempt',date+100,'new attempt',1,0,22,'iMessage' FROM message WHERE ROWID=1;
        INSERT INTO chat_message_join VALUES (1,3);
        """)
        for (sent, error, basis) in [(0,22,"last_attempt_unconfirmed"),(0,0,"last_attempt_unconfirmed"),(1,22,"history_conflicted")] {
            try sql("UPDATE message SET is_sent=\(sent),error=\(error) WHERE ROWID=3")
            let route = try await ops.resolveSendRoute(.init(chatID: "chat-direct-guid"), now: now)
            XCTAssertNil(route.suggestedService)
            XCTAssertEqual(route.suggestionBasis, basis)
        }
    }

    func testRouteIgnoresBackdatedAppendAndUnavailableRelay() async throws {
        let ops = try fixture([], sender: RouteAvailabilitySender(["iMessage"]))
        try sql("""
        UPDATE message SET is_from_me=1,is_sent=1,error=0,service='RCS' WHERE ROWID=1;
        INSERT INTO message (ROWID,guid,date,text,is_from_me,is_sent,error,service)
        SELECT 3,'old-import',date-100,'old import',1,1,0,'iMessage' FROM message WHERE ROWID=1;
        INSERT INTO chat_message_join VALUES (1,3);
        """)
        let route = try await ops.resolveSendRoute(.init(chatID: "chat-direct-guid"), now: now)
        XCTAssertNil(route.suggestedService)
        XCTAssertEqual(route.suggestionBasis, "service_unavailable", "The backdated iMessage row must not override newer RCS history")
        XCTAssertEqual(route.serviceOptions, ["iMessage"])
    }

    func testRouteAndStatusSupportDuplicateHandleRowsAcrossServices() async throws {
        let ops = try fixture([], sender: RouteAvailabilitySender())
        try sql("""
        UPDATE message SET is_from_me=1,is_sent=1,error=0 WHERE ROWID=1;
        INSERT INTO handle (ROWID,id) VALUES (4,'+15550000001');
        INSERT INTO chat (ROWID,guid,chat_identifier,service_name) VALUES (3,'relay-direct','+15550000001','SMS');
        INSERT INTO chat_handle_join VALUES (3,4);
        INSERT INTO message (ROWID,guid,date,text,is_from_me,is_sent,error,service,handle_id)
        SELECT 3,'relay-outgoing',date+100,'latest relay',1,1,0,'RCS',4 FROM message WHERE ROWID=1;
        INSERT INTO chat_message_join VALUES (3,3),(1,3);
        """)
        let route = try await ops.resolveSendRoute(.init(recipients: [.init(query: "+15550000001")]), now: now)
        XCTAssertEqual(route.suggestedService, "SMS")
        let store = MessageStore(path: root.appendingPathComponent("chat.db").path)
        let observation = try store.outgoingMessageStatus(afterRowID: 2, target: .individual(handle: "+15550000001", service: "SMS"), expectedService: "SMS", payload: .text("latest relay"))
        guard case let .unique(row) = observation else { return XCTFail("Duplicate handle IDs must not exclude the selected relay row") }
        XCTAssertEqual(row.messageID, "relay-outgoing")
        XCTAssertEqual(row.service, "RCS")
    }

    func testRoutePreservesOneMemberGroupAndRejectsGroupServiceOverride() async throws {
        let sender = RouteAvailabilitySender()
        let ops = try fixture([], sender: sender)
        try sql("DELETE FROM chat_handle_join WHERE chat_id=2 AND handle_id=3")
        let route = try await ops.resolveSendRoute(.init(chatID: "chat-group-guid"), now: now)
        XCTAssertEqual(route.kind, "group")
        XCTAssertNil(route.suggestedService)
        _ = try await ops.sendMessage(.init(chatID: "chat-group-guid", text: "synthetic group fixture"), now: now)
        let calls = await sender.dispatchedTargets()
        XCTAssertEqual(calls, [.chat("chat-group-guid")])
        do {
            _ = try await ops.sendMessage(.init(chatID: "chat-group-guid", service: "SMS", text: "invalid override"), now: now)
            XCTFail("Group identity must not become an individual send")
        } catch let error as SendValidationError { XCTAssertEqual(error, .invalidDestination) }
    }
}

/// Executes the production routing handler in AppleScript, replacing only the
/// Messages boundary with inert handlers. SQLite owns post-dispatch observation.
private actor AutomaticFixtureSender: MessagesSending, MessagesRouteDiscovering {
    let services: [String]
    let source: StatusRecordingSender
    let unavailableCalls: Set<Int>
    var calls: [(SendTarget, SendPayload)] = []
    init(database: URL, services: [String] = ["iMessage", "SMS"], mode: StatusRecordingSender.Mode = .sent(delivered: false), unavailableCalls: Set<Int> = []) {
        self.services = services
        source = StatusRecordingSender(database: database, mode: mode)
        self.unavailableCalls = unavailableCalls
    }
    func availableServices() async throws -> [String] { services }
    func send(target: SendTarget, payload: SendPayload) async -> SendDispatchOutcome {
        calls.append((target, payload))
        let unavailable = unavailableCalls.contains(calls.count)
        let handlers = """
        on enabledAccounts(serviceName)
            return {"inert-account"}
        end enabledAccounts
        on directTarget(handleValue, targetAccount)
            \(unavailable ? "error number -1728" : "return handleValue")
        end directTarget
        on dispatchPayload(payloadKind, payloadValue, targetReference)
            return "inert"
        end dispatchPayload
        """
        let outcome = AppleScriptExecutor(source: MessagesScriptingScript.routingBody + "\n" + handlers).execute(arguments: MessagesScriptingScript.arguments(target: target, payload: payload))
        guard outcome == .accepted else { return outcome }
        return await source.send(target: target, payload: payload)
    }
    func dispatches() -> [(SendTarget, SendPayload)] { calls }
}

extension SendOperationsTests {
    func testAutomaticHistorySelectsRelayAndExplicitOverrideDisablesAlternative() async throws {
        let sender = RouteAvailabilitySender()
        let ops = try fixture([], sender: sender)
        try sql("UPDATE message SET is_from_me=1,is_sent=1,error=0,service='RCS' WHERE ROWID=1")
        let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "synthetic"), now: now)
        XCTAssertEqual(result.attempts.map(\.service), ["SMS"])
        let calls = await sender.dispatchedTargets()
        XCTAssertEqual(calls, [.individual(handle: "+15550000001", service: "SMS")])
    }

    func testAutomaticNewPhoneUsesInertPredispatchFailureThenOneRelayAttempt() async throws {
        let sender = AutomaticFixtureSender(database: root.appendingPathComponent("chat.db"), unavailableCalls: [1, 2])
        let ops = try fixture([], sender: sender)
        let result = try await ops.sendMessage(.init(recipients: [.init(query: "+15550009999")], text: "synthetic exact body"), now: now)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.attempts.map(\.service), ["SMS", "iMessage"])
        XCTAssertEqual(result.attempts.map { $0.part.errorCode }, ["messages_route_unavailable", "messages_route_unavailable"])
        let calls = await sender.dispatches()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].1, calls[1].1)
        XCTAssertEqual(calls[0].0, .individual(handle: "+15550009999", service: "SMS"))
        XCTAssertEqual(calls[1].0, .individual(handle: "+15550009999", service: "iMessage"))
    }

    func testAutomaticPredispatchAlternativeObservesNegotiatedRCSSuccess() async throws {
        let sender = AutomaticFixtureSender(database: root.appendingPathComponent("chat.db"), unavailableCalls: [1])
        let ops = try fixture([], sender: sender)
        try sql("UPDATE message SET is_from_me=1,is_sent=1,error=0,service='iMessage' WHERE ROWID=1")
        let result = try await ops.sendMessage(.init(recipients: [.init(query: "+15550000001")], text: "synthetic"), now: now)
        XCTAssertEqual(result.status, .sent)
        XCTAssertEqual(result.attempts.map(\.service), ["iMessage", "SMS"])
        XCTAssertEqual(result.parts.first?.observedService, "RCS")
    }

    func testAutomaticHistoricalRelayUsesIMessagingAlternativeOnlyBeforeDispatch() async throws {
        let sender = AutomaticFixtureSender(database: root.appendingPathComponent("chat.db"), unavailableCalls: [1])
        let ops = try fixture([], sender: sender)
        try sql("UPDATE message SET is_from_me=1,is_sent=1,error=0,service='RCS' WHERE ROWID=1")
        let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "synthetic"), now: now)
        XCTAssertEqual(result.status, .sent)
        XCTAssertEqual(result.attempts.map(\.service), ["SMS", "iMessage"])
        XCTAssertEqual(result.parts.first?.observedService, "iMessage")
    }

    func testAutomaticServiceAvailabilityKeepsEmailIMessagingOnly() async throws {
        let iMessageOnly = RouteAvailabilitySender(["iMessage"])
        let iMessageOps = try fixture([], sender: iMessageOnly)
        for handle in ["+15550009999", "new@example.test"] {
            let result = try await iMessageOps.sendMessage(.init(recipients: [.init(query: handle)], text: "synthetic"), now: now)
            XCTAssertEqual(result.attempts.map(\.service), ["iMessage"])
        }
        let iMessageTargets = await iMessageOnly.dispatchedTargets()
        XCTAssertEqual(iMessageTargets, [
            .individual(handle: "+15550009999", service: "iMessage"),
            .individual(handle: "new@example.test", service: "iMessage"),
        ])

        let sender = RouteAvailabilitySender(["SMS"])
        let ops = try fixture([], sender: sender)
        let result = try await ops.sendMessage(.init(recipients: [.init(query: "+15550009999")], text: "synthetic"), now: now)
        XCTAssertEqual(result.attempts.map(\.service), ["SMS"])
        do {
            _ = try await ops.sendMessage(.init(recipients: [.init(query: "new@example.test")], text: "synthetic"), now: now)
            XCTFail("Email cannot use SMS")
        } catch let error as SendRouteError { XCTAssertEqual(error, .noAvailableService) }
        let empty = try fixture([], sender: RouteAvailabilitySender([]))
        do {
            _ = try await empty.sendMessage(.init(recipients: [.init(query: "+15550009999")], text: "synthetic"), now: now)
            XCTFail("No account must fail without a probe")
        } catch let error as SendRouteError { XCTAssertEqual(error, .noAvailableService) }
    }

    func testAutomaticSourceFailurePendingMissingAndCompetingRowsNeverFallback() async throws {
        for (mode, expected) in [(StatusRecordingSender.Mode.failed(22), SendStatus.failed), (.failed(0), .pending), (.absent, .unknown), (.duplicate, .unknown), (.delayedDuplicate, .unknown), (.delayedSent, .sent), (.conflictingDelivery, .unknown), (.sent(delivered: false), .sent)] {
            let sender = AutomaticFixtureSender(database: root.appendingPathComponent("chat.db"), mode: mode)
            let ops = try fixture([], sender: sender)
            let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "synthetic"), now: now)
            XCTAssertEqual(result.status, expected)
            XCTAssertEqual(result.attempts.count, 1)
            let calls = await sender.dispatches()
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testAutomaticMultipartAlternativeNeverReplaysSuccessfulText() async throws {
        let sender = AutomaticFixtureSender(database: root.appendingPathComponent("chat.db"), unavailableCalls: [2, 3])
        let ops = try fixture([], sender: sender)
        let file = try localFile("synthetic.txt")
        let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "synthetic", files: [file.path, file.path]), now: now)
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.parts.map(\.outcome), [.sent, .failed, .notAttempted])
        XCTAssertEqual(result.attempts.map { $0.part.index }, [0, 1, 1])
        let calls = await sender.dispatches()
        XCTAssertEqual(calls.count, 3)
        guard calls.count == 3 else { return }
        XCTAssertEqual(calls[1].1, calls[2].1)
    }

    func testExplicitServiceAndEmailDisablePredispatchAlternative() async throws {
        for input in [SendMessageInput(chatID: "chat-direct-guid", service: "iMessage", text: "synthetic"), .init(recipients: [.init(query: "new@example.test")], text: "synthetic")] {
            let sender = AutomaticFixtureSender(database: root.appendingPathComponent("chat.db"), unavailableCalls: [1])
            let ops = try fixture([], sender: sender)
            let result = try await ops.sendMessage(input, now: now)
            XCTAssertEqual(result.attempts.count, 1)
            XCTAssertEqual(result.status, .failed)
        }
    }
}
