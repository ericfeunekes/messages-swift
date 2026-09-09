import Darwin
import Foundation
import MessagesMCPAdapter

@main
struct MessagesMCPMain {
    static func main() {
        guard CommandLine.arguments.count == 1 else { fail("Usage: messages-mcp\n") }
        do {
            try RecoveringStdioBridge.relay(path: UnixSocketServer.defaultURL.path)
        } catch {
            fail("Messages Swift connection ended or is unavailable. Open the app, check its status, and retry the connection.\n")
        }
    }
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }
}
