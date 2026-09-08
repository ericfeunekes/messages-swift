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
    enum RuntimeStatus: Equatable {
        case contactsRequired, messagesRequired, sourceRequired, starting, ready, restartRequired, failed

        var menuTitle: String {
            switch self {
            case .contactsRequired: "Contacts access is required"
            case .messagesRequired: "Messages access needs attention"
            case .sourceRequired: "Choose a Contacts source"
            case .starting: "Starting…"
            case .ready: "Ready"
            case .restartRequired: "Quit and reopen to apply changes"
            case .failed: "Could not start"
            }
        }
    }

    struct ContactsSource: Hashable {
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
    @MainActor struct Services {
        var authorization: () -> CNAuthorizationStatus = { CNContactStore.authorizationStatus(for: .contacts) }
        var requestContacts: @MainActor () async throws -> Bool = { try await CNContactStore().requestAccess(for: .contacts) }
        var sources: () throws -> [ContactsSource] = {
            try CNContactStore().containers(matching: nil).map { ContactsSource(identifier: $0.identifier, name: $0.name, type: $0.type) }
        }
        var readAccess: (String) -> MessagesReadAccess = { MessagesReadAccess.check(path: $0) }
        var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
        var revealApp: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        var presentWindow: @MainActor (NSWindow) -> Void = {
            $0.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private let services: Services
    private let configurationPath: String

    override convenience init() {
        self.init(services: Services(), configurationPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/messages-swift/config.json").path)
    }

    init(services: Services, configurationPath: String) {
        self.services = services
        self.configurationPath = configurationPath
        super.init()
    }
    private var statusItem: NSStatusItem!
    private var runtime: Task<Void, Never>?
    private var statusWatcher: Task<Void, Never>?
    private(set) var status: RuntimeStatus = .contactsRequired
    private var sources: [ContactsSource] = []
    private(set) var settingsWindow: NSWindow?
    private(set) var sourcePicker: NSPopUpButton?
    private(set) var settingsMessage: NSTextField?
    private var contactsStatusLabel: NSTextField?
    private var messagesStatusLabel: NSTextField?
    private(set) var messagesAccess: MessagesReadAccess = .unavailable
    private var setupMessage = ""
    private var sourceMessage = ""
    private(set) var requestingContacts = false

    private var contactsAccess: ContactsSetupAccess {
        switch services.authorization() {
        case .notDetermined: .notRequested
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .granted
        @unknown default: .unavailable
        }
    }

    private var messagesDescription: String {
        switch messagesAccess {
        case .readable: "Database file is readable"
        case .denied: "Access denied — enable Full Disk Access"
        case .missing: "Database file not found. Check the configured path."
        case .unavailable: "Database file could not be read. Check the path and file."
        }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = MessagesMenuApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "ellipsis.bubble", accessibilityDescription: "Messages Swift")!
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))!
            let ratio = min(18 / image.size.width, 18 / image.size.height)
            image.size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.isTemplate = true
            button.title = ""
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Messages Swift"
            button.setAccessibilityLabel("Messages Swift")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshSetupState()
        if status != .starting && status != .ready { showSettings() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard statusItem != nil else { return }
        refreshSetupState()
        populateSettings()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Status: \(status.menuTitle)", action: nil, keyEquivalent: ""))
        let authorization = services.authorization()
        menu.addItem(NSMenuItem(title: "Contacts: \(contactsDescription(authorization))", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Messages: \(messagesDescription)", action: nil, keyEquivalent: ""))
        menu.addItem(item(title: "Set Up Permissions…", action: #selector(setUpPermissions)))
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

    @objc func setUpPermissions() {
        showSettings()
        guard !requestingContacts else { return }
        switch contactsAccess.action {
        case .request:
            requestingContacts = true
            setupMessage = "Respond to the macOS Contacts request."
            populateSettings()
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.services.requestContacts()
                    self.setupMessage = ""
                } catch {
                    self.setupMessage = "Contacts access could not be requested. Check Contacts in System Settings."
                }
                self.requestingContacts = false
                self.refreshSetupState()
                self.guideMessagesAccess()
            }
        case .settings:
            setupMessage = "Enable Messages Swift in Privacy & Security → Contacts, then click Check Again."
            openContactsSettings()
            guideMessagesAccess(openSettings: false)
        case .explain:
            setupMessage = "Contacts access is restricted or unavailable. Check this Mac’s privacy restrictions."
            guideMessagesAccess(openSettings: false)
        case .none:
            refreshSetupState()
            guideMessagesAccess()
        }
    }

    private func guideMessagesAccess(openSettings: Bool = true) {
        if messagesAccess == .denied {
            setupMessage += " Enable Messages Swift in Full Disk Access. If absent, add the app revealed in Finder. Then click Check Again."
            if openSettings { openFullDiskAccessSettings() }
            else { setupMessage += " Use the Full Disk Access button below." }
        }
        populateSettings()
    }

    @objc func checkAgain() {
        setupMessage = ""
        refreshSetupState()
        populateSettings()
    }

    @objc private func openContactsSettings() {
        services.openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
    }

    @objc func showSettings() {
        refreshSetupState()
        if let settingsWindow {
            populateSettings()
            services.presentWindow(settingsWindow)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Messages Swift Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        let contactsLabel = label("")
        contactsLabel.frame = NSRect(x: 20, y: 377, width: 370, height: 24)
        contactsStatusLabel = contactsLabel
        content.addSubview(contactsLabel)
        let contactsButton = NSButton(title: "Contacts Settings…", target: self, action: #selector(openContactsSettings))
        contactsButton.frame = NSRect(x: 390, y: 375, width: 170, height: 28)
        content.addSubview(contactsButton)
        let messagesLabel = label("")
        messagesLabel.frame = NSRect(x: 20, y: 317, width: 365, height: 48)
        messagesLabel.maximumNumberOfLines = 2
        messagesStatusLabel = messagesLabel
        content.addSubview(messagesLabel)
        let messagesButton = NSButton(title: "Full Disk Access…", target: self, action: #selector(openFullDiskAccessSettings))
        messagesButton.frame = NSRect(x: 390, y: 325, width: 170, height: 28)
        content.addSubview(messagesButton)
        let setup = NSButton(title: "Set Up Permissions", target: self, action: #selector(setUpPermissions))
        setup.frame = NSRect(x: 20, y: 275, width: 170, height: 28)
        content.addSubview(setup)
        let check = NSButton(title: "Check Again", target: self, action: #selector(checkAgain))
        check.frame = NSRect(x: 200, y: 275, width: 120, height: 28)
        content.addSubview(check)
        let explanation = label("Choose the account whose contacts you want to use. Its contacts must already be synchronized with this Mac.")
        explanation.frame = NSRect(x: 20, y: 210, width: 540, height: 44)
        explanation.lineBreakMode = .byWordWrapping
        explanation.maximumNumberOfLines = 3
        content.addSubview(explanation)
        let picker = NSPopUpButton(frame: NSRect(x: 20, y: 170, width: 540, height: 28), pullsDown: false)
        picker.target = self
        picker.action = #selector(sourceSelectionChanged)
        sourcePicker = picker
        content.addSubview(picker)
        let message = label("")
        message.frame = NSRect(x: 20, y: 48, width: 540, height: 112)
        message.maximumNumberOfLines = 6
        message.lineBreakMode = .byWordWrapping
        message.textColor = .secondaryLabelColor
        settingsMessage = message
        content.addSubview(message)
        let save = NSButton(title: "Save Source", target: self, action: #selector(saveSelectedSource))
        save.frame = NSRect(x: 460, y: 12, width: 100, height: 28)
        content.addSubview(save)
        window.contentView = content
        settingsWindow = window
        populateSettings()
        window.center()
        services.presentWindow(window)
    }

    @objc private func sourceSelectionChanged() { sourceMessage = "Save to use this source. Changes take effect after restart."; updateSettingsStatus() }

    @objc func saveSelectedSource() {
        defer { updateSettingsStatus() }
        guard services.authorization() == .authorized else {
            status = .contactsRequired
            sourceMessage = "Grant Contacts access before selecting a source."
            refreshMenu()
            return
        }
        guard let sourcePicker, sourcePicker.indexOfSelectedItem > 0,
              sources.indices.contains(sourcePicker.indexOfSelectedItem - 1) else {
            sourceMessage = "Choose a source before saving."
            return
        }
        let source = sources[sourcePicker.indexOfSelectedItem - 1]
        do {
            let existing = FileManager.default.fileExists(atPath: configurationPath)
                ? try RuntimeConfiguration.load(from: configurationPath) : nil
            let home = FileManager.default.homeDirectoryForCurrentUser
            let databasePath = existing?.databasePath ?? home.appendingPathComponent("Library/Messages/chat.db").path
            let stateDirectory = existing?.stateDirectory ?? home.appendingPathComponent("Library/Application Support/messages-swift").path
            try RuntimeConfiguration(containerID: source.identifier, databasePath: databasePath, stateDirectory: stateDirectory).save(to: configurationPath)
            if runtime == nil {
                refreshSetupState()
                sourceMessage = "Saved."
            } else {
                status = .restartRequired
                sourceMessage = "Saved. Quit and reopen Messages Swift to use the new source."
                refreshMenu()
            }
        } catch {
            status = .failed
            sourceMessage = "Could not save the selected source."
            refreshMenu()
        }
    }

    private func refreshSetupState() {
        let path = (try? RuntimeConfiguration.load(from: configurationPath).databasePath)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
        messagesAccess = services.readAccess(path)
        defer { updateSettingsStatus() }
        guard services.authorization() == .authorized else { status = .contactsRequired; refreshMenu(); return }
        refreshSources()
        guard let configuration = try? RuntimeConfiguration.load(from: configurationPath),
              sources.contains(where: { $0.identifier == configuration.containerID }) else {
            status = .sourceRequired
            refreshMenu()
            return
        }
        guard messagesAccess == .readable else { status = .messagesRequired; refreshMenu(); return }
        if runtime != nil && status != .ready && status != .starting { status = .restartRequired }
        startRuntimeIfConfigured()
        refreshMenu()
    }

    private func refreshSources() {
        guard services.authorization() == .authorized else { sources = []; return }
        do {
            sources = try services.sources().sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
        sourcePicker.isEnabled = contactsAccess.action == .none && !sources.isEmpty
        updateSettingsStatus()
    }

    private func updateSettingsStatus() {
        contactsStatusLabel?.stringValue = "Contacts: \(contactsDescription(services.authorization()))"
        messagesStatusLabel?.stringValue = "Messages: \(messagesDescription)"
        var messages = [setupMessage, sourceMessage]
        if contactsAccess.action != .none { messages.append("Contacts access is required to list sources.") }
        else if sources.isEmpty { messages.append("No Contacts sources are available.") }
        if status == .restartRequired || status == .failed { messages.append("Quit and reopen Messages Swift after correcting setup. The existing runtime cannot be restarted here.") }
        else { messages.append(status.menuTitle) }
        settingsMessage?.stringValue = messages.filter { !$0.isEmpty }.joined(separator: "\n")
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

    private func runtimeDidBecomeReady() { guard status == .starting else { return }; status = .ready; refreshMenu(); updateSettingsStatus() }
    private func runtimeDidFail() {
        guard status != .restartRequired else { return }
        status = .failed
        setupMessage = "Messages Swift could not start. Check the source, database and saved configuration."
        updateSettingsStatus()
        showSettings()
        refreshMenu()
    }
    private func refreshMenu() { statusItem?.menu.map(rebuildMenu) }

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
        services.revealApp(Bundle.main.bundleURL)
        services.openURL(url)
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
