import Foundation
import Testing
import CSQLite
import os
import Darwin
import MessagesCore
@testable import MessagesMCPAdapter

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

private func connectedSocket(_ url: URL) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure.runner }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    _ = url.path.withCString { source in withUnsafeMutablePointer(to: &address.sun_path) { target in target.withMemoryRebound(to: CChar.self, capacity: capacity) { strncpy($0, source, capacity) } } }
    let connected = withUnsafePointer(to: &address) {
        connect(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size))
    }
    guard connected == 0 else { let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL); close(fd); throw error }
    return fd
}

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
    @Test func databaseReadinessFailureDoesNotRunTransport() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let missing = RuntimeConfiguration(containerID: "selected", databasePath: fixture.root.appendingPathComponent("missing.db").path, stateDirectory: fixture.config.stateDirectory)
        let started = OSAllocatedUnfairLock(initialState: false)
        do {
            try await ApplicationRuntime.run(configuration: missing, directory: Directory(), runner: { _ in started.withLock { $0 = true } })
            Issue.record("Missing database started runtime")
        } catch { }
        #expect(!started.withLock { $0 })
    }
    @Test func socketListenerRejectsSecondOwnerAndAcceptsPartialMalformedFrame() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let socketDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/s\(Int.random(in: 0...999_999))")
        let path = socketDirectory.appendingPathComponent("run/mcp.sock")
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let server = UnixSocketServer(url: path)
        let operations = MessagesOperations(store: MessageStore(path: fixture.config.databasePath), directory: Directory(), binding: .init(containerID: "selected"), state: try fixture.state())
        try server.start(operations: operations)
        defer { server.stop() }
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(throws: SocketError.activeServer) { try UnixSocketServer(url: path).start(operations: operations) }
        try await Task.sleep(for: .milliseconds(20))
        let client = try connectedSocket(path)
        defer { close(client) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = "{\"jsonrpc\":\"2.0\",\"id\":1,".withCString { write(client, $0, strlen($0)) }
        _ = "}\n".withCString { write(client, $0, strlen($0)) }
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = recv(client, &bytes, bytes.count, 0)
        #expect(count > 0)
        #expect(String(decoding: bytes.prefix(max(0, Int(count))), as: UTF8.self).contains("error"))
        shutdown(client, SHUT_WR)
        #expect(recv(client, &bytes, bytes.count, 0) == 0)
        server.stop()
        try await server.waitUntilStopped()
    }
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
        #expect(output == "Usage: messages-mcp\n")
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

extension ApplicationRuntimeTests {
    @Test func transportFragmentedFrameAndDisconnectJoinsReader() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let transport = UnixSocketTransport(fileDescriptor: pair[0])
        defer { close(pair[1]) }
        try await transport.connect()
        let expected = Data(repeating: 97, count: 50_000)
        for fragment in stride(from: 0, to: expected.count, by: 1000) {
            let part = expected[fragment..<min(fragment + 1000, expected.count)]
            #expect(part.withUnsafeBytes { write(pair[1], $0.baseAddress, $0.count) } == part.count)
        }
        _ = "\n".withCString { write(pair[1], $0, 1) }
        var iterator = await transport.receive().makeAsyncIterator()
        #expect(try await iterator.next() == expected)
        await transport.disconnect()
        #expect(try await iterator.next() == nil)
        // Observe the peer boundary; the closed descriptor number may already be reused.
        var byte: UInt8 = 0
        #expect(recv(pair[1], &byte, 1, MSG_DONTWAIT) == 0)
        do { try await transport.send(Data("late".utf8)); Issue.record("send after close succeeded") }
        catch SocketError.disconnected { }
    }

    @Test func blockedWriterDoesNotBlockDisconnect() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let transport = UnixSocketTransport(fileDescriptor: pair[0])
        defer { close(pair[1]) }
        try await transport.connect()
        let writer = Task { try await transport.send(Data(repeating: 97, count: 4_000_000)) }
        try await Task.sleep(for: .milliseconds(30))
        await transport.disconnect()
        do { try await writer.value; Issue.record("blocked write unexpectedly completed") }
        catch SocketError.disconnected { }
    }

    @Test func transportRejectsOversizedUnterminatedFrame() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let transport = UnixSocketTransport(fileDescriptor: pair[0])
        try await transport.connect()
        let peer = pair[1]
        let writer = Task.detached {
            defer { close(peer) }
            var one: Int32 = 1
            _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let bytes = [UInt8](repeating: 97, count: 4096)
            for _ in 0..<257 { _ = bytes.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) } }
        }
        var iterator = await transport.receive().makeAsyncIterator()
        do { _ = try await iterator.next(); Issue.record("oversized frame accepted") }
        catch SocketError.messageTooLarge { }
        await transport.disconnect()
        await writer.value
    }

    @Test func listenerRejectsUnsafePathsAndRecoversStaleSocket() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let operations = MessagesOperations(store: MessageStore(path: fixture.config.databasePath), directory: Directory(), binding: .init(containerID: "selected"), state: try fixture.state())
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/p\(Int.random(in: 0...999_999))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("mcp.sock")
        try Data("keep".utf8).write(to: path)
        #expect(throws: SocketError.invalidPath) { try UnixSocketServer(url: path).start(operations: operations) }
        #expect(try String(contentsOf: path, encoding: .utf8) == "keep")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent("missing"))
        #expect(throws: SocketError.invalidPath) { try UnixSocketServer(url: path).start(operations: operations) }
        try FileManager.default.removeItem(at: path)
        chmod(root.path, 0o755)
        #expect(throws: SocketError.invalidPath) { try UnixSocketServer(url: path).start(operations: operations) }
        chmod(root.path, 0o700)
        let link = root.appendingPathExtension("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: SocketError.invalidPath) { try UnixSocketServer(url: link.appendingPathComponent("run/mcp.sock")).start(operations: operations) }
        try FileManager.default.removeItem(at: link)
        let lockPath = directory.appendingPathComponent("mcp.lock")
        chmod(lockPath.path, 0o644)
        #expect(throws: SocketError.invalidPath) { try UnixSocketServer(url: path).start(operations: operations) }
        chmod(lockPath.path, 0o600)
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        _ = path.path.withCString { source in withUnsafeMutablePointer(to: &address.sun_path) { target in target.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, source, 104) } } }
        #expect(withUnsafePointer(to: &address) { bind(stale, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size)) } == 0)
        chmod(path.path, 0o600)
        close(stale)
        let server = UnixSocketServer(url: path)
        try server.start(operations: operations)
        let client = try connectedSocket(path)
        close(client)
        server.stop()
        try await server.waitUntilStopped()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}

extension ApplicationRuntimeTests {
    @Test func twoMCPSessionsShareAliasesWithIndependentRequestIDs() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let operations = MessagesOperations(store: MessageStore(path: fixture.config.databasePath), directory: Directory(), binding: .init(containerID: "selected"), state: try fixture.state())
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/m\(Int.random(in: 0...999_999))")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = UnixSocketServer(url: root.appendingPathComponent("run/mcp.sock"))
        try server.start(operations: operations)
        defer { server.stop() }
        let first = try connectedSocket(root.appendingPathComponent("run/mcp.sock"))
        let second = try connectedSocket(root.appendingPathComponent("run/mcp.sock"))
        defer { close(first); close(second) }
        for fd in [first, second] {
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let initialized = try socketRequest(fd, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"synthetic","version":"1"}}}"#)
            #expect(initialized["id"] as? Int == 1)
            #expect(initialized["result"] != nil)
            let notification = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
            _ = notification.withCString { write(fd, $0, strlen($0)) }
        }
        let alias = try socketRequest(first, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_chat_alias","arguments":{"chatID":"fixture-chat","alias":"Shared synthetic alias"}}}"#)
        #expect(alias["id"] as? Int == 2)
        #expect(alias["error"] == nil)
        let found = try socketRequest(second, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"find_chats","arguments":{}}}"#)
        #expect(found["id"] as? Int == 2)
        #expect(String(decoding: try JSONSerialization.data(withJSONObject: found), as: UTF8.self).contains("Shared synthetic alias"))
        server.stop()
        try await server.waitUntilStopped()
        var byte: UInt8 = 0
        #expect(recv(first, &byte, 1, 0) == 0)
        #expect(recv(second, &byte, 1, 0) == 0)
    }
}

private func socketRequest(_ fd: Int32, _ request: String) throws -> [String: Any] {
    let frame = request + "\n"
    let written = frame.withCString { write(fd, $0, strlen($0)) }
    guard written == frame.utf8.count else { throw Failure.runner }
    var result = Data()
    var byte: UInt8 = 0
    while result.count <= 2_000_000 {
        guard recv(fd, &byte, 1, 0) == 1 else { throw Failure.runner }
        if byte == 10 { return try JSONSerialization.jsonObject(with: result) as! [String: Any] }
        result.append(byte)
    }
    throw Failure.runner
}

extension ApplicationRuntimeTests {
    @Test func completedSessionsReleaseTransportsDuringListenerLifetime() async throws {
        var sessions = SocketSessions()
        for _ in 0..<100 {
            var pair: [Int32] = [0, 0]
            #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            var transport: UnixSocketTransport? = UnixSocketTransport(fileDescriptor: pair[0])
            weak var released = transport
            let completion = SocketSessionCompletion()
            let task = Task<Void, Never> { [transport] in
                try? await transport?.connect()
                await transport?.disconnect()
                completion.finish()
            }
            sessions.append(transport: transport!, task: task, completion: completion)
            await task.value
            transport = nil
            sessions.reap()
            #expect(released == nil)
            close(pair[1])
        }
        await sessions.stop()
    }

    @Test func canceledPartialWriteClosesConnectionBeforeAnotherFrame() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let transport = UnixSocketTransport(fileDescriptor: pair[0])
        defer { close(pair[1]) }
        try await transport.connect()
        let writer = Task { try await transport.send(Data(repeating: 97, count: 4_000_000)) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes = [UInt8](repeating: 0, count: 4096)
        // A received prefix proves the write began before cancellation.
        #expect(recv(pair[1], &bytes, bytes.count, 0) > 0)
        writer.cancel()
        do { try await writer.value; Issue.record("canceled write succeeded") }
        catch is CancellationError { }
        do { try await transport.send(Data("next frame".utf8)); Issue.record("send after partial cancellation succeeded") }
        catch SocketError.disconnected { }
        var count = recv(pair[1], &bytes, bytes.count, 0)
        while count > 0 { count = recv(pair[1], &bytes, bytes.count, 0) }
        #expect(count == 0)
    }
}

extension ApplicationRuntimeTests {
    @Test func disconnectedWatchReleasesItsOperationOwnerPromptly() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let client = pair[1]
        defer { close(client) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let transport = UnixSocketTransport(fileDescriptor: pair[0])
        weak var released: MessagesOperations?
        let runner: Task<Void, Error>
        do {
            let owner = MessagesOperations(store: MessageStore(path: fixture.config.databasePath), directory: Directory(), binding: .init(containerID: "selected"), state: try fixture.state())
            released = owner
            runner = Task { try await MCPServerRunner.run(operations: owner, transport: transport) }
        }
        _ = try socketRequest(client, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"synthetic","version":"1"}}}"#)
        let frames = """
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"watch_messages","arguments":{"chatID":"fixture-chat","waitSeconds":20}}}

        """
        #expect(frames.withCString { write(client, $0, strlen($0)) } == frames.utf8.count)
        try await Task.sleep(for: .milliseconds(150))
        let read = try socketRequest(client, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_messages","arguments":{"chatID":"fixture-chat"}}}"#)
        #expect(read["id"] as? Int == 3)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        shutdown(client, SHUT_RDWR)
        try await runner.value
        while released != nil && clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(released == nil, "The disconnected watch retained operations after its session ended")
        #expect(clock.now < deadline)
    }
}
