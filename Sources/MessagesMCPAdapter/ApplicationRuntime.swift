import Foundation
import MessagesCore

/// Owns the production store, local state, startup refresh, and refresh task for
/// one server lifetime. A state directory must have only one active owner.
public enum ApplicationRuntime {
    public static let startupFailureMessage = "messages-mcp could not start. Check private configuration, Messages database access and existing selected-container Contacts permission.\n"
    public static let refreshFailureMessage = "Contact refresh failed; cached records were not marked fresh.\n"

    public static func run(
        configuration: RuntimeConfiguration,
        directory: sending any ContactsDirectorySource,
        now: @escaping @Sendable () async -> Date = { Date() },
        waitForNextRefresh: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(60)) },
        report: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) },
        runner: @escaping @Sendable (MessagesOperations) async throws -> Void = { try await MCPServerRunner.run(operations: $0) }
    ) async throws {
        let operations = MessagesOperations(
            store: MessageStore(path: configuration.databasePath),
            directory: directory,
            binding: ContactsContainerBinding(containerID: configuration.containerID),
            state: try LocalState(directory: URL(fileURLWithPath: configuration.stateDirectory))
        )
        try await operations.refreshDueContacts(now: now())
        try Task.checkCancellation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    do {
                        try await waitForNextRefresh()
                        try Task.checkCancellation()
                        try await operations.refreshDueContacts(now: now())
                    } catch is CancellationError { return }
                    catch { report(refreshFailureMessage) }
                }
            }
            group.addTask { try await runner(operations) }
            defer { group.cancelAll() }
            // Runner exit (including failure) ends this lifetime. Structured
            // cancellation also waits for the refresh task to stop.
            try await group.next()
        }
    }
}
