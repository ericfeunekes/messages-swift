import AppKit
import Contacts
import Foundation
import MessagesCore
import MessagesMCPAdapter

private actor RuntimeStatusSignal {
    enum Event: Sendable { case ready, failed }
    private var latest: Event?
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            Task { self.add(continuation) }
        }
    }

    func report(_ event: Event) {
        latest = event
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func add(_ continuation: AsyncStream<Event>.Continuation) {
        continuations[UUID()] = continuation
        if let latest { continuation.yield(latest) }
    }
}

@main
@MainActor final class MessagesMenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum RuntimeStatus: Equatable {
        case contactsRequired, sourceRequired, starting, ready, restartRequired, failed

        var menuTitle: String {
            switch self {
            case .contactsRequired: "Contacts access is required"
            case .sourceRequired: "Choose a Contacts source"
            case .starting: "Starting…"
            case .ready: "Ready"
            case .restartRequired: "Restart required after source change"
            case .failed: "Could not start"
            }
        }
    }

    private struct ContactsSource: Hashable {
        let identifier: String
        let name: String
        let type: CNContainerType

        var title: String {
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return displayName.isEmpty ? "Unnamed Contacts source" : displayName
        }

        var detail: String {
            switch type {
            case .local: "On My Mac"
            case .exchange: "Exchange"
            case .cardDAV: "CardDAV"
            case .unassigned: "Unassigned"
            @unknown default: "Other"
            }
        }
    }

    private let socket = UnixSocketServer()
    private let runtimeSignal = RuntimeStatusSignal()
    private let contactsStore = CNContactStore()
    private let configurationPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/messages-swift/config.json").path
    private var statusItem: NSStatusItem!
    private var runtime: Task<Void, Never>?
    private var statusWatcher: Task<Void, Never>?
    private var status: RuntimeStatus = .contactsRequired
    private var sources: [ContactsSource] = []
    private var settingsWindow: NSWindow?
    private var sourcePicker: NSPopUpButton?
    private var settingsMessage: NSTextField?

    static func main() {
        let app = NSApplication.shared
        let delegate = MessagesMenuApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Messages"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshSetupState()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Status: \(status.menuTitle)", action: nil, keyEquivalent: ""))
        let authorization = CNContactStore.authorizationStatus(for: .contacts)
        menu.addItem(NSMenuItem(title: "Contacts: \(contactsDescription(authorization))", action: nil, keyEquivalent: ""))
        if authorization != .authorized { menu.addItem(item(title: "Request Contacts Access", action: #selector(requestContacts))) }
        if status == .failed { menu.addItem(item(title: "Open Full Disk Access Settings", action: #selector(openFullDiskAccessSettings))) }
        menu.addItem(.separator())
        menu.addItem(item(title: "Settings…", action: #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit Messages Swift", action: #selector(quit), keyEquivalent: "q"))
    }

    private func item(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func requestContacts() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let granted = try await CNContactStore().requestAccess(for: .contacts)
                if granted { self.refreshSetupState(); self.showSettings() }
                else { self.status = .contactsRequired; self.refreshMenu() }
            } catch {
                self.status = .contactsRequired
                self.refreshMenu()
            }
        }
    }

    @objc private func showSettings() {
        refreshSources()
        if let settingsWindow {
            populateSettings()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Messages Swift Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        let explanation = label("Choose the account whose contacts you want to use. Its contacts must already be synchronized with this Mac.")
        explanation.frame = NSRect(x: 20, y: 125, width: 420, height: 44)
        explanation.lineBreakMode = .byWordWrapping
        explanation.maximumNumberOfLines = 3
        content.addSubview(explanation)
        let picker = NSPopUpButton(frame: NSRect(x: 20, y: 80, width: 420, height: 28), pullsDown: false)
        picker.target = self
        picker.action = #selector(sourceSelectionChanged)
        sourcePicker = picker
        content.addSubview(picker)
        let message = label("")
        message.frame = NSRect(x: 20, y: 47, width: 420, height: 20)
        message.textColor = .secondaryLabelColor
        settingsMessage = message
        content.addSubview(message)
        let save = NSButton(title: "Save Source", target: self, action: #selector(saveSelectedSource))
        save.frame = NSRect(x: 340, y: 12, width: 100, height: 28)
        content.addSubview(save)
        window.contentView = content
        settingsWindow = window
        populateSettings()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func sourceSelectionChanged() { settingsMessage?.stringValue = "Save to use this source. Changes take effect after restart." }

    @objc private func saveSelectedSource() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            status = .contactsRequired
            settingsMessage?.stringValue = "Grant Contacts access before selecting a source."
            refreshMenu()
            return
        }
        guard let sourcePicker, sourcePicker.indexOfSelectedItem > 0 else {
            settingsMessage?.stringValue = "Choose a source before saving."
            return
        }
        let source = sources[sourcePicker.indexOfSelectedItem - 1]
        do {
            let existing = try? RuntimeConfiguration.load(from: configurationPath)
            let home = FileManager.default.homeDirectoryForCurrentUser
            let databasePath = existing?.databasePath ?? home.appendingPathComponent("Library/Messages/chat.db").path
            let stateDirectory = existing?.stateDirectory ?? home.appendingPathComponent("Library/Application Support/messages-swift").path
            try RuntimeConfiguration(containerID: source.identifier, databasePath: databasePath, stateDirectory: stateDirectory).save(to: configurationPath)
            if runtime == nil {
                refreshSetupState()
                settingsMessage?.stringValue = "Saved. Starting Messages Swift now."
            } else {
                status = .restartRequired
                settingsMessage?.stringValue = "Saved. Quit and reopen Messages Swift to use the new source."
                refreshMenu()
            }
        } catch {
            status = .failed
            settingsMessage?.stringValue = "Could not save the selected source."
            refreshMenu()
        }
    }

    private func refreshSetupState() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { status = .contactsRequired; refreshMenu(); return }
        refreshSources()
        guard let configuration = try? RuntimeConfiguration.load(from: configurationPath),
              sources.contains(where: { $0.identifier == configuration.containerID }) else {
            status = .sourceRequired
            refreshMenu()
            return
        }
        startRuntimeIfConfigured()
        refreshMenu()
    }

    private func refreshSources() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { sources = []; return }
        do {
            sources = try contactsStore.containers(matching: nil).map { ContactsSource(identifier: $0.identifier, name: $0.name, type: $0.type) }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } catch {
            sources = []
            status = .failed
        }
    }

    private func populateSettings() {
        guard let sourcePicker else { return }
        sourcePicker.removeAllItems()
        sourcePicker.addItem(withTitle: "Select a Contacts source…")
        for source in sources { sourcePicker.addItem(withTitle: "\(source.title) (\(source.detail))") }
        let selectedID = try? RuntimeConfiguration.load(from: configurationPath).containerID
        if let selectedID, let index = sources.firstIndex(where: { $0.identifier == selectedID }) { sourcePicker.selectItem(at: index + 1) }
        else { sourcePicker.selectItem(at: 0) }
        if CNContactStore.authorizationStatus(for: .contacts) != .authorized {
            settingsMessage?.stringValue = "Contacts access is required before sources can be listed."
            sourcePicker.isEnabled = false
        } else if sources.isEmpty {
            settingsMessage?.stringValue = "No Contacts sources are available."
            sourcePicker.isEnabled = false
        } else {
            settingsMessage?.stringValue = ""
            sourcePicker.isEnabled = true
        }
    }

    private func startRuntimeIfConfigured() {
        guard runtime == nil, let configuration = try? RuntimeConfiguration.load(from: configurationPath) else { return }
        status = .starting
        let signal = runtimeSignal
        statusWatcher = Task { @MainActor [weak self, signal] in
            for await event in await signal.events() {
                switch event {
                case .ready: self?.runtimeDidBecomeReady()
                case .failed: self?.runtimeDidFail()
                }
            }
        }
        runtime = Task { [socket, signal] in
            do {
                try await ApplicationRuntime.run(configuration: configuration, directory: MacContactsDirectory(), runner: { operations in
                    try socket.start(operations: operations)
                    await signal.report(.ready)
                    try await socket.waitUntilStopped()
                })
            } catch is CancellationError {
                return
            } catch {
                await signal.report(.failed)
            }
        }
    }

    private func runtimeDidBecomeReady() { guard status == .starting else { return }; status = .ready; refreshMenu() }
    private func runtimeDidFail() {
        guard status != .restartRequired else { return }
        status = .failed
        settingsMessage?.stringValue = "Messages Swift could not start. Check the selected Contacts source and Messages access. If macOS blocks Messages access, grant this app Full Disk Access, then restart it."
        refreshMenu()
    }
    private func refreshMenu() { statusItem.menu.map(rebuildMenu) }

    private func contactsDescription(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not requested"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "granted"
        @unknown default: "unavailable"
        }
    }

    @objc private func quit() { statusWatcher?.cancel(); runtime?.cancel(); socket.stop(); NSApp.terminate(nil) }

    @objc private func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension MessagesMenuApp: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { settingsWindow = nil; sourcePicker = nil; settingsMessage = nil }
    }

    private func label(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        return field
    }
}
