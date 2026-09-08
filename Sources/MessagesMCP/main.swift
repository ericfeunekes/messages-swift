import Foundation
import MessagesCore
import MessagesMCPAdapter

@main
struct MessagesMCPMain {
    static func main() async {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--config" else {
            fail("Usage: messages-mcp --config /absolute/path/to/private-config.json\n")
        }
        do {
            let config = try RuntimeConfiguration.load(from: CommandLine.arguments[2])
            let operations = MessagesOperations(
                store: MessageStore(path: config.databasePath),
                directory: MacContactsDirectory(),
                binding: ContactsContainerBinding(containerID: config.containerID),
                state: try LocalState(directory: URL(fileURLWithPath: config.stateDirectory))
            )
            try await operations.refreshDueContacts()
            let refresh = Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(60))
                        try await operations.refreshDueContacts()
                    } catch is CancellationError { return }
                    catch {
                        FileHandle.standardError.write(Data("Contact refresh failed; cached records were not marked fresh.\n".utf8))
                    }
                }
            }
            defer { refresh.cancel() }
            try await MCPServerRunner.run(operations: operations)
        } catch {
            fail("messages-mcp could not start. Check private configuration, Messages database access and existing selected-container Contacts permission.\n")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }
}
