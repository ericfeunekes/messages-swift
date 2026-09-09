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
        CREATE TABLE message (guid TEXT, date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, handle_id INTEGER, service TEXT DEFAULT 'iMessage', associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, balloon_bundle_id TEXT, date_edited INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0);
        CREATE TABLE attachment (guid TEXT, filename TEXT, mime_type TEXT);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        INSERT INTO handle VALUES ('+15550000001'), ('alice@example.test'), ('bob@example.test');
        INSERT INTO chat VALUES ('chat-direct-guid', 'direct-thread', NULL, 'iMessage'), ('chat-group-guid', 'group-thread', 'Project Team', 'SMS');
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

        let direct = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "direct"), now: now)
        let group = try await ops.sendMessage(.init(chatID: "chat-group-guid", text: "group"), now: now)

        XCTAssertEqual(direct.status, .accepted)
        XCTAssertEqual(direct.destination?.service, "iMessage")
        XCTAssertEqual(group.status, .accepted)
        XCTAssertEqual(group.destination?.service, "SMS")
        let dispatches = await sender.dispatches()
        XCTAssertEqual(dispatches.map(\.0), [.chat("chat-direct-guid"), .chat("chat-group-guid")])
    }

    func testAliasIsOnlyDiscoveryAndExactFoundGUIDIsTheDispatchTarget() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        _ = try await ops.setChatAlias(.init(chatID: "chat-direct-guid", alias: "Family line"))
        let found = try await ops.findChats(.init(query: "Family line"), now: now)
        XCTAssertEqual(found.chats.map(\.chatID), ["chat-direct-guid"])

        _ = try await ops.sendMessage(.init(chatID: found.chats[0].chatID, text: "exact"), now: now)
        await XCTAssertThrowsErrorAsync {
            _ = try await ops.sendMessage(.init(chatID: "Family line", text: "not a GUID"), now: self.now)
        }
        let dispatches = await sender.dispatches()
        XCTAssertEqual(dispatches.map(\.0), [.chat("chat-direct-guid")])
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
        XCTAssertEqual(result.status, .accepted)
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
        XCTAssertEqual(contactResult.status, .accepted)
        XCTAssertEqual(contactResult.destination?.recipients.map(\.handle), ["+15550000001"])
        let contactDispatches = await contactSender.dispatches()
        XCTAssertEqual(contactDispatches.map(\.0), [.individual(handle: "+15550000001", service: "SMS")])

        let absentSender = RecordingSender()
        let absentOps = try fixture([], sender: absentSender)
        let absentResult = try await absentOps.sendMessage(.init(recipients: [.init(query: "+1 (555) 000-0001")], service: "SMS", text: "phone"), now: now)
        XCTAssertEqual(absentResult.status, .accepted)
        let absentDispatches = await absentSender.dispatches()
        XCTAssertEqual(absentDispatches.map(\.0), [.individual(handle: "+15550000001", service: "SMS")])
    }

    func testInvalidDestinationsAndContentNeverDispatch() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let invalid = [
            SendMessageInput(chatID: "chat-direct-guid", recipients: [.init(query: "Alice")], text: "x"),
            SendMessageInput(recipients: [.init(query: "Alice"), .init(query: "Alice")], service: "iMessage", text: "x"),
            SendMessageInput(recipients: [.init(query: "Alice")], text: "x"),
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
                _ = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "text", files: [good.path, bad]), now: now)
                XCTFail("Invalid file must prevent every dispatch")
            } catch let error as SendValidationError { XCTAssertEqual(error, .invalidFile) }
        }
        let dispatches = await sender.dispatches()
        XCTAssertTrue(dispatches.isEmpty)
    }

    func testTextAndFilesPreserveOrderAndAcceptedOnlyMeansMessagesAccepted() async throws {
        let sender = RecordingSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let first = try localFile("first.txt")
        let second = try localFile("second.txt")
        let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "first text", files: [first.path, second.path]), now: now)
        XCTAssertEqual(result.status, .accepted)
        XCTAssertEqual(result.delivery, "unconfirmed")
        XCTAssertEqual(result.parts.map(\.outcome), [.accepted, .accepted, .accepted])
        let dispatches = await sender.dispatches()
        XCTAssertEqual(dispatches.map(\.1).first, .text("first text"))
        let staged = try stagedPaths(in: Array(dispatches.dropFirst()))
        XCTAssertEqual(staged.map { $0.lastPathComponent }, ["first.txt", "second.txt"])
        XCTAssertNotEqual(staged[0].path, first.path)
        XCTAssertNotEqual(staged[1].path, second.path)
        XCTAssertEqual(try staged.map { try Data(contentsOf: $0) }, [Data("fixture".utf8), Data("fixture".utf8)])
    }

    func testOneAndMultipleFilesWithoutText() async throws {
        let sender = RecordingSender()
        let ops = try fixture([], sender: sender)
        let first = try localFile("file-only-one.txt")
        let second = try localFile("file-only-two.txt")
        let single = try await ops.sendMessage(.init(chatID: "chat-group-guid", files: [first.path]), now: now)
        XCTAssertEqual(single.status, .accepted)
        XCTAssertEqual(single.parts.map(\.kind), ["file"])
        XCTAssertEqual(single.parts.map(\.fileIndex), [0])
        let multiple = try await ops.sendMessage(.init(chatID: "chat-group-guid", files: [first.path, second.path]), now: now)
        XCTAssertEqual(multiple.status, .accepted)
        XCTAssertEqual(multiple.parts.map(\.fileIndex), [0, 1])
        let calls = await sender.dispatches()
        let staged = try stagedPaths(in: calls)
        XCTAssertEqual(staged.map { $0.lastPathComponent }, ["file-only-one.txt", "file-only-one.txt", "file-only-two.txt"])
        XCTAssertEqual(try staged.map { try Data(contentsOf: $0) }, [Data("fixture".utf8), Data("fixture".utf8), Data("fixture".utf8)])
        XCTAssertEqual(Set(staged.map(\.path)).count, staged.count)
    }

    func testRejectedAndUnknownStopTheBatchWithoutRetry() async throws {
        for (outcome, expectedStatus, expectedPart) in [(SendDispatchOutcome.rejected, SendStatus.rejected, SendPartOutcome.rejected), (.unknown, .unknown, .unknown), (.unavailable, .rejected, .rejected)] {
            let sender = RecordingSender(outcomes: [outcome, .accepted])
            let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
            let first = try localFile("first-\(outcome.rawValue).txt")
            let second = try localFile("second-\(outcome.rawValue).txt")
            let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "text", files: [first.path, second.path]), now: now)
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
            let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "text", files: [file.path]), now: now)
            XCTAssertEqual(result.status, .partial)
            XCTAssertEqual(result.parts.map(\.outcome), [.accepted, .rejected])
            XCTAssertEqual(result.parts[1].errorCode, "send_file_changed")
            let dispatches = await sender.dispatches()
            XCTAssertEqual(dispatches.map(\.1), [.text("text")])
        }
    }

    func testConcurrentBatchIsRejectedWithoutDispatchWhileFirstBatchIsPaused() async throws {
        let sender = SuspendedSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        async let first = ops.sendMessage(.init(chatID: "chat-direct-guid", text: "first"), now: now)
        await sender.waitForFirstDispatch()

        let second = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "second"), now: now)
        XCTAssertEqual(second.status, .rejected)
        XCTAssertEqual(second.errorCode, "send_in_progress")
        XCTAssertEqual(second.parts.map(\.outcome), [.notAttempted])
        let pausedDispatches = await sender.dispatches()
        XCTAssertEqual(pausedDispatches.map(\.1), [.text("first")])

        await sender.release()
        let firstResult = try await first
        XCTAssertEqual(firstResult.status, .accepted)
        XCTAssertEqual(firstResult.parts.map(\.outcome), [.accepted])
    }

    func testCancellationAfterAcceptedTextStopsFilesAndReleasesBatchGuard() async throws {
        let sender = SuspendedSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let file = try localFile("cancelled.txt")
        let first = Task { try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "text", files: [file.path]), now: self.now) }
        await sender.waitForFirstDispatch()

        first.cancel()
        await sender.release()
        let cancelled = try await first.value
        XCTAssertEqual(cancelled.status, .partial)
        XCTAssertEqual(cancelled.errorCode, "send_cancelled")
        XCTAssertEqual(cancelled.parts.map(\.outcome), [.accepted, .notAttempted])
        let cancelledDispatches = await sender.dispatches()
        XCTAssertEqual(cancelledDispatches.map(\.1), [.text("text")])
        XCTAssertTrue(try outgoingContents().isEmpty)

        let next = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "next"), now: now)
        XCTAssertEqual(next.status, .accepted)
        let finalDispatches = await sender.dispatches()
        XCTAssertEqual(finalDispatches.map(\.1), [.text("text"), .text("next")])
    }

    func testWholeFileBatchIsStagedBeforePausedTextDispatch() async throws {
        let sender = SuspendedSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let firstFile = try localFile("first-staged-before-text.txt", contents: "first bytes")
        let secondFile = try localFile("second-staged-before-text.txt", contents: "second bytes")
        let task = Task {
            try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "text", files: [firstFile.path, secondFile.path]), now: self.now)
        }
        await sender.waitForFirstDispatch()

        let staged = try stagedData()
        XCTAssertEqual(staged.count, 2)
        XCTAssertTrue(staged.contains(Data("first bytes".utf8)))
        XCTAssertTrue(staged.contains(Data("second bytes".utf8)))

        await sender.release()
        let result = try await task.value
        XCTAssertEqual(result.status, .accepted)
    }

    func testCancellationRetainsOnlyTheAcceptedFileStage() async throws {
        let sender = SuspendedSender()
        let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
        let firstFile = try localFile("accepted-before-cancel.txt", contents: "first")
        let secondFile = try localFile("not-attempted-after-cancel.txt", contents: "second")
        let task = Task {
            try await ops.sendMessage(.init(chatID: "chat-direct-guid", files: [firstFile.path, secondFile.path]), now: self.now)
        }
        await sender.waitForFirstDispatch()

        task.cancel()
        await sender.release()
        let result = try await task.value

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.parts.map(\.outcome), [.accepted, .notAttempted])
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

        let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "only text"), now: now)

        XCTAssertEqual(result.status, .accepted)
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
            _ = try await ops.sendMessage(.init(chatID: "chat-direct-guid", text: "text", files: [file.path]), now: now)
            XCTFail("A non-private staging root must fail before the text dispatch")
        } catch let error as SendValidationError {
            XCTAssertEqual(error, .fileStagingFailed)
        }
        let dispatches = await sender.dispatches()
        XCTAssertTrue(dispatches.isEmpty)
    }

    func testFileRetentionTracksAcceptedAndUnknownOutcomesPerPart() async throws {
        for (outcomes, expectedStatus, retainedCount) in [
            ([SendDispatchOutcome.accepted, .unknown], SendStatus.unknown, 2),
            ([.rejected], SendStatus.rejected, 0),
            ([.unavailable], SendStatus.rejected, 0),
        ] {
            let sender = RecordingSender(outcomes: outcomes)
            let ops = try fixture([person("alice", "Alice", ["+15550000001"])], sender: sender)
            let first = try localFile("retained-first-\(UUID().uuidString).txt")
            let second = try localFile("retained-second-\(UUID().uuidString).txt")

            let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", files: [first.path, second.path]), now: now)

            XCTAssertEqual(result.status, expectedStatus)
            let dispatches = await sender.dispatches()
            XCTAssertEqual(dispatches.count, retainedCount == 0 ? 1 : 2)
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

            let result = try await ops.sendMessage(.init(chatID: "chat-direct-guid", files: [first.path, second.path, third.path]), now: now)

            XCTAssertEqual(result.status, .partial)
            XCTAssertEqual(result.parts.map(\.outcome), [.accepted, .rejected, .notAttempted])
            let staged = try stagedPaths(in: await sender.dispatches())
            XCTAssertEqual(staged.count, 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged[0].path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged[1].path))
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
