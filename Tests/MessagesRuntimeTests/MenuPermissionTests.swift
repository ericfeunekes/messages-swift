import AppKit
import Contacts
import CSQLite
import Darwin
import Foundation
import MessagesCore
import Testing
import MessagesMCPAdapter
@testable import MessagesMenuApp

@Suite(.serialized) @MainActor struct MenuPermissionTests {
    enum Failure: Error { case request, sources }

    @MainActor final class Fixture {
        let root: URL
        var authorization: CNAuthorizationStatus = .notDetermined
        var readAccess: MessagesReadAccess = .denied
        var automationAccess: AutomationSetupAccess = .unavailable
        var accessibilityAccess: AccessibilitySetupAccess = .denied
        var requests = 0
        var automationRequests = 0
        var accessibilityRequests = 0
        var urls: [URL] = []
        var revealed: [URL] = []
        var presentations = 0
        var sources: [MessagesMenuApp.ContactsSource] = []
        var failSources = false
        var sourceReads = 0
        var checkedPaths: [String] = []
        var continuation: CheckedContinuation<Bool, any Error>?
        var automationContinuation: CheckedContinuation<AutomationSetupAccess, Never>?
        var automationStatusContinuation: CheckedContinuation<AutomationSetupAccess, Never>?
        var suspendAutomationStatus = false
        init() throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".scratch/menu-permissions-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var path: String { root.appendingPathComponent("config.json").path }
        func writeReadableRuntimeConfiguration() throws {
            let databasePath = root.appendingPathComponent("chat.db").path
            try RuntimeConfiguration(containerID: "selected", databasePath: databasePath, stateDirectory: root.appendingPathComponent("state").path).save(to: path)
            var database: OpaquePointer?
            guard sqlite3_open(databasePath, &database) == SQLITE_OK else { throw Failure.sources }
            defer { sqlite3_close(database) }
            let sql = """
            CREATE TABLE chat (guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE handle (id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message (guid TEXT, date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, handle_id INTEGER, service TEXT, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, balloon_bundle_id TEXT, date_edited INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0);
            CREATE TABLE attachment (guid TEXT, filename TEXT, mime_type TEXT);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            INSERT INTO chat VALUES ('fixture-chat', 'fixture', NULL, 'iMessage');
            INSERT INTO handle VALUES ('fixture@example.test');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message (guid, date, text, handle_id, service) VALUES ('fixture-message', 1, 'synthetic read boundary', 1, 'iMessage');
            INSERT INTO chat_message_join VALUES (1, 1);
            """
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sources }
        }
        func app() -> MessagesMenuApp {
            var services = MessagesMenuApp.Services()
            services.authorization = { self.authorization }
            services.requestContacts = {
                self.requests += 1
                return try await withCheckedThrowingContinuation { self.continuation = $0 }
            }
            services.sources = {
                self.sourceReads += 1
                if self.failSources { throw Failure.sources }
                return self.sources
            }
            services.readAccess = { path in self.checkedPaths.append(path); return self.readAccess }
            services.automationAccess = {
                if self.suspendAutomationStatus {
                    return await withCheckedContinuation { self.automationStatusContinuation = $0 }
                }
                return self.automationAccess
            }
            services.requestAutomation = {
                self.automationRequests += 1
                return await withCheckedContinuation { self.automationContinuation = $0 }
            }
            services.accessibilityAccess = { self.accessibilityAccess }
            services.requestAccessibility = {
                self.accessibilityRequests += 1
                return self.accessibilityAccess
            }
            services.openURL = { self.urls.append($0) }
            services.revealApp = { self.revealed.append($0) }
            services.presentWindow = { _ in self.presentations += 1 }
            return MessagesMenuApp(services: services, configurationPath: path)
        }
        func clean(_ app: MessagesMenuApp) {
            app.settingsWindow?.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test(arguments: [0, 1, 2]) func asynchronousPermissionCompletionStaysOnMainActor(outcome: Int) async throws {
        let fixture = try Fixture()
        let app = fixture.app()
        defer { fixture.clean(app) }
        app.setUpPermissions()
        app.setUpPermissions()
        for _ in 0..<10_000 {
            if fixture.continuation != nil { break }
            await Task.yield()
        }
        #expect(fixture.requests == 1)
        #expect(app.requestingContacts)
        fixture.authorization = outcome == 0 ? .authorized : (outcome == 1 ? .denied : .notDetermined)
        if outcome == 0 {
            fixture.readAccess = .readable
            fixture.sources = [.init(identifier: "selected", name: "Fixture source", type: .cardDAV)]
        }
        let continuation = try #require(fixture.continuation)
        await Task.detached {
            if outcome == 2 { continuation.resume(throwing: Failure.request) }
            else { continuation.resume(returning: outcome == 0) }
        }.value
        for _ in 0..<10_000 {
            if !app.requestingContacts { break }
            await Task.yield()
        }
        #expect(!app.requestingContacts)
        #expect(app.settingsWindow != nil)
        if outcome == 0 {
            #expect(app.status == .sourceRequired)
            #expect(app.sourcePicker?.isEnabled == true)
            #expect(app.sourcePicker?.numberOfItems == 2)
            #expect(fixture.sourceReads > 0)
            #expect(fixture.urls.isEmpty)
            #expect(fixture.revealed.isEmpty)
        } else {
            #expect(app.status == .contactsRequired)
            #expect(app.sourcePicker?.isEnabled == false)
            #expect(fixture.sourceReads == 0)
            #expect(fixture.urls.count == 1)
            #expect(fixture.urls.first?.absoluteString.contains("Privacy_AllFiles") == true)
            #expect(fixture.revealed == [Bundle.main.bundleURL])
        }
        if outcome == 2 {
            #expect(app.settingsMessage?.stringValue.contains("could not be requested") == true)
            fixture.continuation = nil
            app.setUpPermissions()
            for _ in 0..<10_000 {
                if fixture.continuation != nil { break }
                await Task.yield()
            }
            let retry = try #require(fixture.continuation)
            #expect(fixture.requests == 2)
            fixture.authorization = .denied
            await Task.detached { retry.resume(returning: false) }.value
            for _ in 0..<10_000 {
                if !app.requestingContacts { break }
                await Task.yield()
            }
            #expect(!app.requestingContacts)
        }
        let openings = fixture.urls.count
        app.checkAgain()
        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(fixture.requests == (outcome == 2 ? 2 : 1))
        #expect(fixture.urls.count == openings)
    }

    @Test func missingPermissionsLaunchShowsBothRowsWithoutRequesting() throws {
        let fixture = try Fixture()
        let app = fixture.app()
        defer { fixture.clean(app) }
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(app.settingsWindow)
        let fields = window.contentView!.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        let buttons = window.contentView!.subviews.compactMap { $0 as? NSButton }.map(\.title)
        #expect(fields.contains("Contacts: not requested"))
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
        #expect(!fixture.checkedPaths.isEmpty)
        #expect(fixture.checkedPaths.allSatisfy { $0 == defaultPath })
        #expect(fields.contains(where: { $0.contains("Messages: Access denied") }))
        #expect(fields.contains(where: { $0.contains("Automation: could not be checked") }))
        #expect(fields.contains("Accessibility: not granted — enable Accessibility for Messages Swift"))
        #expect(buttons.contains("Set Up Permissions"))
        #expect(buttons.contains("Full Disk Access…"))
        #expect(fixture.requests == 0)
        #expect(fixture.accessibilityRequests == 0)
        #expect(fixture.urls.isEmpty)
        fixture.authorization = .denied
        fixture.readAccess = .missing
        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(app.settingsWindow === window)
        #expect(app.messagesAccess == .missing)
        let refreshedFields = window.contentView!.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(refreshedFields.contains("Contacts: denied"))
        #expect(refreshedFields.contains(where: { $0.contains("Messages: Database file not found") }))
        #expect(fixture.presentations == 1)
        #expect(fixture.requests == 0)
        #expect(fixture.urls.isEmpty)
    }

    @Test func accessibilityRowFitsThePermissionWindow() throws {
        let fixture = try Fixture()
        let app = fixture.app()
        defer { fixture.clean(app) }
        app.showSettings()
        let views = try #require(app.settingsWindow?.contentView?.subviews)
        for (index, view) in views.enumerated() {
            for other in views.dropFirst(index + 1) {
                #expect(!view.frame.intersects(other.frame))
            }
        }
    }

    @Test func automationPermissionIsRequestedOnceAndCompletesFromAnInertInjectedBoundary() async throws {
        let fixture = try Fixture()
        fixture.authorization = .authorized
        fixture.readAccess = .readable
        fixture.automationAccess = .notRequested
        let app = fixture.app()
        defer { fixture.clean(app) }
        app.showSettings()
        await waitForAutomationCheck(app)
        app.setUpPermissions()
        for _ in 0..<10_000 {
            if fixture.automationContinuation != nil { break }
            await Task.yield()
        }
        #expect(fixture.automationRequests == 1)
        #expect(app.requestingAutomation)
        app.setUpPermissions()
        #expect(fixture.automationRequests == 1)
        let continuation = try #require(fixture.automationContinuation)
        await Task.detached { continuation.resume(returning: .granted) }.value
        for _ in 0..<10_000 {
            if !app.requestingAutomation { break }
            await Task.yield()
        }
        #expect(!app.requestingAutomation)
        #expect(app.automationAccess == .granted)
        #expect(app.settingsMessage?.stringValue.contains("Automation") == false)
        #expect(fixture.urls.isEmpty)
    }

    @Test(arguments: [AutomationSetupAccess.denied, .unavailable]) func automationFailureRoutesWithoutPrompting(result: AutomationSetupAccess) async throws {
        let fixture = try Fixture()
        fixture.authorization = .authorized
        fixture.readAccess = .readable
        fixture.automationAccess = result
        let app = fixture.app()
        defer { fixture.clean(app) }
        app.showSettings()
        await waitForAutomationCheck(app)
        app.setUpPermissions()
        #expect(fixture.automationRequests == 0)
        if result == .denied {
            #expect(fixture.urls.count == 1)
            #expect(fixture.urls[0].absoluteString.contains("Privacy_Automation"))
            #expect(app.settingsMessage?.stringValue.contains("Automation") == true)
        } else {
            #expect(fixture.urls.isEmpty)
            #expect(app.settingsMessage?.stringValue.contains("could not be checked") == true)
        }
    }

    @Test func automationStatusRefreshesWithoutPromptingOnLaunchCheckAndActivation() async throws {
        let fixture = try Fixture()
        fixture.automationAccess = .notRequested
        let app = fixture.app()
        defer { fixture.clean(app) }
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        app.checkAgain()
        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        await waitForAutomationCheck(app)
        #expect(fixture.automationRequests == 0)
        #expect(fixture.accessibilityRequests == 0)
        #expect(app.automationAccess == .notRequested)
        #expect(fixture.urls.isEmpty)
        let fields = app.settingsWindow!.contentView!.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(fields.contains("Automation: not requested"))
        #expect(fields.contains("Accessibility: not granted — enable Accessibility for Messages Swift"))
    }

    @Test func accessibilityPermissionRequestsOnceThenRefreshesGrantedTrust() async throws {
        let fixture = try Fixture()
        fixture.authorization = .authorized
        fixture.readAccess = .readable
        fixture.automationAccess = .granted
        let app = fixture.app()
        defer { fixture.clean(app) }
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        await waitForAutomationCheck(app)
        app.setUpPermissions()
        #expect(fixture.accessibilityRequests == 1)
        #expect(app.accessibilityAccess == .denied)
        app.setUpPermissions()
        #expect(fixture.accessibilityRequests == 1)
        #expect(fixture.urls.last?.absoluteString.contains("Privacy_Accessibility") == true)
        fixture.accessibilityAccess = .granted
        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(app.accessibilityAccess == .granted)
        #expect(app.settingsMessage?.stringValue.contains("Accessibility") == false)
    }

    @Test func staleAutomationStatusCannotOverwriteAnExplicitGrantedRequest() async throws {
        let fixture = try Fixture()
        fixture.authorization = .authorized
        fixture.readAccess = .readable
        fixture.automationAccess = .notRequested
        let app = fixture.app()
        defer { fixture.clean(app) }
        app.showSettings()
        await waitForAutomationCheck(app)
        fixture.suspendAutomationStatus = true
        app.checkAgain()
        for _ in 0..<10_000 {
            if fixture.automationStatusContinuation != nil { break }
            await Task.yield()
        }
        app.setUpPermissions()
        for _ in 0..<10_000 {
            if fixture.automationContinuation != nil { break }
            await Task.yield()
        }
        let request = try #require(fixture.automationContinuation)
        await Task.detached { request.resume(returning: .granted) }.value
        for _ in 0..<10_000 {
            if !app.requestingAutomation { break }
            await Task.yield()
        }
        let staleStatus = try #require(fixture.automationStatusContinuation)
        await Task.detached { staleStatus.resume(returning: .notRequested) }.value
        await Task.yield()
        #expect(app.automationAccess == .granted)
    }

    @Test(arguments: [AutomationSetupAccess.denied, .notRequested]) func readRuntimeStartsWithAutomationUnavailableToSending(access: AutomationSetupAccess) async throws {
        let fixture = try Fixture()
        fixture.authorization = .authorized
        fixture.readAccess = .readable
        fixture.automationAccess = access
        fixture.sources = [.init(identifier: "selected", name: "Fixture source", type: .cardDAV)]
        try fixture.writeReadableRuntimeConfiguration()
        var services = MessagesMenuApp.Services()
        services.authorization = { fixture.authorization }
        services.sources = { fixture.sources }
        services.readAccess = { _ in fixture.readAccess }
        services.automationAccess = { fixture.automationAccess }
        services.accessibilityAccess = { fixture.accessibilityAccess }
        services.makeDirectory = { MenuRuntimeDirectory() }
        services.presentWindow = { _ in fixture.presentations += 1 }
        let socketRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/a\(Int.random(in: 0...999_999))")
        let socketPath = socketRoot.appendingPathComponent("runtime/mcp.sock")
        let socket = UnixSocketServer(url: socketPath)
        let app = MessagesMenuApp(services: services, configurationPath: fixture.path, socket: socket)
        defer { app.stopRuntime(); try? FileManager.default.removeItem(at: socketRoot); fixture.clean(app) }
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        for _ in 0..<10_000 {
            if app.status == .ready { break }
            await Task.yield()
        }
        #expect(app.status == .ready)
        #expect(FileManager.default.fileExists(atPath: socketPath.path))
        let response = try await Task.detached {
            let socket = try menuConnectedSocket(socketPath)
            defer { close(socket) }
            _ = try menuSocketRequest(socket, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"synthetic","version":"1"}}}"#)
            let notification = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
            _ = notification.withCString { write(socket, $0, strlen($0)) }
            let result = try menuSocketRequest(socket, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_messages","arguments":{"chatID":"fixture-chat","limit":1}}}"#)
            return try JSONSerialization.data(withJSONObject: result)
        }.value
        #expect(String(decoding: response, as: UTF8.self).contains("synthetic read boundary"))
        #expect(fixture.automationRequests == 0)
        #expect(fixture.accessibilityRequests == 0)
    }

    private func waitForAutomationCheck(_ app: MessagesMenuApp) async {
        await Task.yield()
        for _ in 0..<10_000 {
            if !app.checkingAutomation { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for the injected Automation status check.")
    }

    private struct MenuRuntimeDirectory: ContactsDirectorySource, Sendable {
        func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] { [] }
        func contacts(in binding: ContactsContainerBinding, identities: Set<ContactIdentity>, matchingHandles: Set<String>) throws -> ContactLookup { .init(people: []) }
    }

    @Test func deniedAndRestrictedDoNotRequestAgain() throws {
        let fixture = try Fixture()
        let app = fixture.app()
        defer { fixture.clean(app) }
        fixture.authorization = .denied
        app.setUpPermissions()
        #expect(fixture.requests == 0)
        #expect(fixture.urls.count == 1)
        #expect(fixture.urls[0].absoluteString.contains("Privacy_Contacts"))
        fixture.authorization = .restricted
        app.setUpPermissions()
        #expect(fixture.requests == 0)
        #expect(fixture.urls.count == 1)
        #expect(app.settingsMessage?.stringValue.contains("restricted") == true)
    }

    @Test func firstLaunchAndRefreshPreserveSavedSourceAndDoNotPrompt() throws {
        let fixture = try Fixture()
        fixture.authorization = .authorized
        fixture.sources = [.init(identifier: "selected", name: "Fixture source", type: .cardDAV)]
        let configuration = RuntimeConfiguration(containerID: "selected", databasePath: fixture.root.appendingPathComponent("custom.db").path, stateDirectory: fixture.root.appendingPathComponent("custom-state").path)
        try configuration.save(to: fixture.path)
        let original = try Data(contentsOf: URL(fileURLWithPath: fixture.path))
        let app = fixture.app()
        defer { fixture.clean(app) }
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(app.settingsWindow != nil)
        #expect(fixture.presentations == 1)
        #expect(app.status == .messagesRequired)
        #expect(app.sourcePicker?.indexOfSelectedItem == 1)
        #expect(!fixture.checkedPaths.isEmpty)
        #expect(fixture.checkedPaths.allSatisfy { $0 == configuration.databasePath })
        fixture.checkedPaths = []
        app.checkAgain()
        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(fixture.requests == 0)
        #expect(fixture.urls.isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.path)) == original)
        #expect(fixture.checkedPaths == [configuration.databasePath, configuration.databasePath])
        #expect(app.sourcePicker?.indexOfSelectedItem == 1)
        app.saveSelectedSource()
        app.checkAgain()
        #expect(app.settingsMessage?.stringValue.contains("Saved.") == true)
        let saved = try RuntimeConfiguration.load(from: fixture.path)
        #expect(saved.containerID == configuration.containerID)
        #expect(saved.databasePath == configuration.databasePath)
        #expect(saved.stateDirectory == configuration.stateDirectory)
        fixture.failSources = true
        app.checkAgain()
        #expect(app.sourcePicker?.isEnabled == false)
        app.saveSelectedSource()
        #expect(try RuntimeConfiguration.load(from: fixture.path).containerID == "selected")
    }

    @Test func readableFileWithoutSourceDoesNotMeanReady() throws {
        let fixture = try Fixture()
        fixture.authorization = .authorized
        fixture.readAccess = .readable
        let app = fixture.app()
        defer { fixture.clean(app) }
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(app.status == .sourceRequired)
        #expect(app.settingsWindow != nil)
        #expect(app.sourcePicker?.isEnabled == false)
        #expect(fixture.requests == 0)
        #expect(fixture.urls.isEmpty)
    }
}

private func menuConnectedSocket(_ path: URL) throws -> Int32 {
    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socket >= 0 else { throw MenuPermissionTests.Failure.sources }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    _ = path.path.withCString { source in withUnsafeMutablePointer(to: &address.sun_path) { target in target.withMemoryRebound(to: CChar.self, capacity: capacity) { strncpy($0, source, capacity) } } }
    let connected = withUnsafePointer(to: &address) { connect(socket, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size)) }
    guard connected == 0 else { close(socket); throw MenuPermissionTests.Failure.sources }
    return socket
}

private func menuSocketRequest(_ socket: Int32, _ request: String) throws -> [String: Any] {
    let frame = request + "\n"
    guard frame.withCString({ write(socket, $0, strlen($0)) }) == frame.utf8.count else { throw MenuPermissionTests.Failure.sources }
    var result = Data(); var byte: UInt8 = 0
    while result.count <= 2_000_000 {
        guard recv(socket, &byte, 1, 0) == 1 else { throw MenuPermissionTests.Failure.sources }
        if byte == 10 { return try JSONSerialization.jsonObject(with: result) as! [String: Any] }
        result.append(byte)
    }
    throw MenuPermissionTests.Failure.sources
}
