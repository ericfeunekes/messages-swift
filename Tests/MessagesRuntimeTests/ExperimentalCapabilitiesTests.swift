import Foundation
import MCP
import Testing

@Test func nestedExperimentalClientCapabilitiesRoundTrip() throws {
    let data = Data(#"{"experimental":{"legacy":"enabled","feature":{"enabled":true,"options":[1,"text",null,{"nested":false}]}}}"#.utf8)
    let capabilities = try JSONDecoder().decode(Client.Capabilities.self, from: data)
    let encoded = try JSONEncoder().encode(capabilities)
    #expect(try JSONDecoder().decode(Value.self, from: encoded) == JSONDecoder().decode(Value.self, from: data))
}
