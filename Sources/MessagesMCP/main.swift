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
            try await ApplicationRuntime.run(configuration: config, directory: MacContactsDirectory())
        } catch {
            fail(ApplicationRuntime.startupFailureMessage)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }
}
