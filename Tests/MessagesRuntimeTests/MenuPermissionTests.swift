import AppKit
import Contacts
import Foundation
import Testing
import MessagesMCPAdapter
@testable import MessagesMenuApp

@Suite(.serialized) @MainActor struct MenuPermissionTests {
    enum Failure: Error { case request, sources }

    @MainActor final class Fixture {
        let root: URL
        var authorization: CNAuthorizationStatus = .notDetermined
        var readAccess: MessagesReadAccess = .denied
        var requests = 0
        var urls: [URL] = []
        var revealed: [URL] = []
        var presentations = 0
        var sources: [MessagesMenuApp.ContactsSource] = []
        var failSources = false
        var sourceReads = 0
        var checkedPaths: [String] = []
        var continuation: CheckedContinuation<Bool, any Error>?
        init() throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".scratch/menu-permissions-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var path: String { root.appendingPathComponent("config.json").path }
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
        #expect(buttons.contains("Set Up Permissions"))
        #expect(buttons.contains("Full Disk Access…"))
        #expect(fixture.requests == 0)
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
