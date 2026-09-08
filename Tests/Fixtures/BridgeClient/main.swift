import Darwin
import MessagesMCPAdapter

@main struct BridgeClient {
    static func main() {
        do {
            let fd = try StdioSocketBridge.connect(path: CommandLine.arguments[1])
            defer { close(fd) }
            try StdioSocketBridge.relay(socket: fd)
        } catch { exit(1) }
    }
}
