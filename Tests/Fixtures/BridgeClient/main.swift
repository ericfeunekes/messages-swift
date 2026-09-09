import Darwin
import MessagesMCPAdapter

@main struct BridgeClient {
    static func main() {
        do {
            try RecoveringStdioBridge.relay(path: CommandLine.arguments[1])
        } catch { exit(1) }
    }
}
