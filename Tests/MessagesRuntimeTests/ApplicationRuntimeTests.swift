import Foundation
import Testing
import CSQLite
import os
import MessagesCore
import MessagesMCPAdapter

private let fixtureNow = Date(timeIntervalSince1970: 1_800_000_000)
private let fixturePerson = ContactPerson(identity: .init(containerID: "selected", id: "person"), displayName: "Current name", handles: ["person@example.test"])
private struct Directory: ContactsDirectorySource, Sendable {
    var fail = false
    var failScoped = false
    func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String>) throws -> ContactLookup {
        guard !failScoped else { throw ContactsDirectoryError.selectedContainerMissing("PRIVATE ACCOUNT DETAIL") }
        return ContactLookup(people: try allContacts(in: binding).filter { identities.contains($0.identity) })
    }
    func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] {
        guard !fail else { throw ContactsDirectoryError.selectedContainerMissing("PRIVATE ACCOUNT DETAIL") }
        guard binding.containerID == "selected" else { throw ContactsDirectoryError.permissionNotGranted }
        return [fixturePerson]
    }
}

private struct Fixture: Sendable {
    let root: URL
    let config: RuntimeConfiguration
    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("config.json")
        let json = ["containerID": "selected", "databasePath": root.appendingPathComponent("chat.db").path, "stateDirectory": root.appendingPathComponent("state").path]
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        config = try RuntimeConfiguration.load(from: path.path)
        var db: OpaquePointer?
        guard sqlite3_open(config.databasePath, &db) == SQLITE_OK else { throw Failure.fixture }
        defer { sqlite3_close(db) }
        let date = Int64((fixtureNow.timeIntervalSince1970 - 978_307_200) * 1_000_000_000)
        let sql = """
        CREATE TABLE chat (guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (guid TEXT, date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, handle_id INTEGER, service TEXT, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, balloon_bundle_id TEXT, date_edited INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0);
        CREATE TABLE attachment (guid TEXT, filename TEXT, mime_type TEXT);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        INSERT INTO chat VALUES ('fixture-chat', 'identifier', NULL, 'iMessage');
        INSERT INTO handle VALUES ('person@example.test');
        INSERT INTO chat_handle_join VALUES (1,1);
        INSERT INTO message (guid,date,text,handle_id) VALUES ('fixture-message',\(date),'fixture text',1);
        INSERT INTO chat_message_join VALUES (1,1);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.fixture }
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
    func state() throws -> LocalState { try LocalState(directory: URL(fileURLWithPath: config.stateDirectory)) }
}
private enum Failure: Error, Equatable { case fixture, runner }

/// A manual calendar clock. The second wait proves the first scheduled refresh
/// has completed, without racing a wall-clock sleep against the assertion.
private actor ManualClock {
    var date = fixtureNow
    var waits = 0
    var stopped = false
    var waiter: CheckedContinuation<Void, Never>?
    func now() -> Date { date }
    func next() async throws {
        waits += 1
        if waits == 1 { date = fixtureNow.addingTimeInterval(2 * 86_400); return }
        waiter?.resume(); waiter = nil
        do { try await Task.sleep(for: .seconds(600)) }
        catch { stopped = true; throw error }
    }
    func refreshed() async {
        if waits >= 2 { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

struct ApplicationRuntimeTests {
    @Test func configurationDefaultsAndRejectedValues() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("config.json")
        try Data(#"{"containerID":"selected"}"#.utf8).write(to: path)
        let config = try RuntimeConfiguration.load(from: path.path)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(config.containerID == "selected")
        #expect(config.databasePath == home.appendingPathComponent("Library/Messages/chat.db").path)
        #expect(config.stateDirectory == home.appendingPathComponent("Library/Application Support/messages-swift").path)
        for value in [#"{}"#, #"{"containerID":" "}"#, #"{"containerID":3}"#, #"{"containerID":"x","unknown":true}"#, #"{"containerID":"x","databasePath":"relative"}"#, #"{"containerID":"x","stateDirectory":4}"#] {
            try Data(value.utf8).write(to: path)
            do { _ = try RuntimeConfiguration.load(from: path.path); Issue.record("Invalid configuration accepted: \(value)") }
            catch ConfigurationError.invalidConfiguration { }
        }
    }

    @Test func executableRejectsPrivateConfigurationWithoutLeakingDetails() throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let bad = fixture.root.appendingPathComponent("PRIVATE-CONFIG-NAME.json")
        try Data(#"{"containerID":"PRIVATE ACCOUNT DETAIL","stateDirectory":42}"#.utf8).write(to: bad)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/messages-mcp")
        process.arguments = ["--config", bad.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output == ApplicationRuntime.startupFailureMessage)
        #expect(!output.contains("PRIVATE"))
    }

    @Test func coldStartupUsesConfiguredSQLiteAndPersistsBaselineAndAlias() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        try await ApplicationRuntime.run(configuration: fixture.config, directory: Directory(), now: { fixtureNow }, runner: { operations in
            let result = try await operations.readMessages(.init(chatID: "fixture-chat"), now: fixtureNow)
            #expect(result.messages.first?.text == "fixture text")
            #expect(result.chat.participants.first?.displayName == "Current name")
            _ = try await operations.setChatAlias(.init(chatID: "fixture-chat", alias: "Local alias"))
        })
        let state = try fixture.state()
        #expect(state.isSeeded)
        #expect(state.cacheEntries.map(\.person) == [fixturePerson])
        #expect(state.alias(for: "fixture-chat") == "Local alias")
    }

    @Test func overdueStartupAndScheduledRefreshAndRunnerExit() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let state = try fixture.state()
        try state.bindContainer("selected")
        let old = ContactPerson(identity: fixturePerson.identity, displayName: "Old name", handles: fixturePerson.handles)
        try state.seedInitialCache([old], now: fixtureNow.addingTimeInterval(-3 * 86_400))
        let clock = ManualClock()
        try await ApplicationRuntime.run(configuration: fixture.config, directory: Directory(), now: { await clock.now() }, waitForNextRefresh: { try await clock.next() }, runner: { _ in
            await clock.refreshed()
        })
        #expect(await clock.stopped)
        let refreshed = try fixture.state().cacheEntries
        #expect(refreshed.first?.person == fixturePerson)
        #expect(refreshed.first?.refreshedAt == fixtureNow.addingTimeInterval(2 * 86_400))
        #expect(refreshed.first?.admittedAt == fixtureNow.addingTimeInterval(-3 * 86_400))
    }

    @Test func overdueRefreshCompletesBeforeRunnerStarts() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let state = try fixture.state()
        try state.bindContainer("selected")
        let old = ContactPerson(identity: fixturePerson.identity, displayName: "Old name", handles: fixturePerson.handles)
        try state.seedInitialCache([old], now: fixtureNow.addingTimeInterval(-3 * 86_400))
        try await ApplicationRuntime.run(configuration: fixture.config, directory: Directory(), now: { fixtureNow }, runner: { _ in
            let entries = try fixture.state().cacheEntries
            #expect(entries.first?.person == fixturePerson)
            #expect(entries.first?.refreshedAt == fixtureNow)
        })
    }

    @Test func callerCancellationJoinsSchedulerAndRunner() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let clock = ManualClock()
        let task = Task {
            try await ApplicationRuntime.run(configuration: fixture.config, directory: Directory(), now: { await clock.now() }, waitForNextRefresh: { try await clock.next() }, runner: { _ in
                try await Task.sleep(for: .seconds(600))
            })
        }
        await clock.refreshed()
        task.cancel()
        do { try await task.value }
        catch is CancellationError { }
        #expect(await clock.stopped)
    }

    @Test func startupFailureDoesNotRunTransport() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        do {
            try await ApplicationRuntime.run(configuration: fixture.config, directory: Directory(fail: true), runner: { _ in Issue.record("Runner invoked after startup failure") })
            Issue.record("Expected startup failure")
        } catch ContactsDirectoryError.selectedContainerMissing(let id) { #expect(id == "PRIVATE ACCOUNT DETAIL") }
        #expect(!ApplicationRuntime.startupFailureMessage.contains("PRIVATE ACCOUNT DETAIL"))
        #expect(!ApplicationRuntime.refreshFailureMessage.contains("PRIVATE ACCOUNT DETAIL"))
    }

    @Test func scheduledFailureIsSanitizedAndDoesNotMarkCacheFresh() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let state = try fixture.state()
        try state.bindContainer("selected")
        try state.seedInitialCache([fixturePerson], now: fixtureNow)
        let clock = ManualClock()
        let reports = OSAllocatedUnfairLock(initialState: [String]())
        try await ApplicationRuntime.run(configuration: fixture.config, directory: Directory(failScoped: true), now: { await clock.now() }, waitForNextRefresh: { try await clock.next() }, report: { message in
            reports.withLock { $0.append(message) }
        }, runner: { _ in await clock.refreshed() })
        #expect(reports.withLock { $0 } == [ApplicationRuntime.refreshFailureMessage])
        #expect(try fixture.state().cacheEntries.first?.refreshedAt == fixtureNow)
        #expect(await clock.stopped)
    }

    @Test func runnerFailureCancelsAndJoinsRefreshTask() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let clock = ManualClock()
        do {
            try await ApplicationRuntime.run(configuration: fixture.config, directory: Directory(), now: { await clock.now() }, waitForNextRefresh: { try await clock.next() }, runner: { _ in
                await clock.refreshed()
                throw Failure.runner
            })
            Issue.record("Expected runner failure")
        } catch Failure.runner { }
        #expect(await clock.stopped)
    }
}
