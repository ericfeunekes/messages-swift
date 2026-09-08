// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MessagesSwift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MessagesCore", targets: ["MessagesCore"]),
        .executable(name: "messages-mcp", targets: ["MessagesMCP"]),
        .executable(name: "Messages Swift", targets: ["MessagesMenuApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "MessagesCore", dependencies: ["CSQLite"]),
        .target(name: "MessagesMCPAdapter", dependencies: ["MessagesCore", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "MessagesMCP", dependencies: ["MessagesCore", "MessagesMCPAdapter"]),
        .executableTarget(name: "MessagesMenuApp", dependencies: ["MessagesCore", "MessagesMCPAdapter"]),
        .executableTarget(name: "MCPTestServer", dependencies: ["MessagesCore", "MessagesMCPAdapter"], path: "Tests/Fixtures/MCPServer"),
        .executableTarget(name: "MCPBridgeTestClient", dependencies: ["MessagesMCPAdapter"], path: "Tests/Fixtures/BridgeClient"),
        .testTarget(name: "MessagesCoreTests", dependencies: ["MessagesCore", "CSQLite"]),
        .testTarget(name: "MessagesRuntimeTests", dependencies: ["MessagesCore", "MessagesMCPAdapter", "CSQLite"]),
    ]
)
