import Foundation

/// Device-local setup. The selected container is confirmed by the user, never guessed from its name.
public struct RuntimeConfiguration: Codable, Sendable {
    public let containerID: String
    public let databasePath: String
    public let stateDirectory: String

    public static func load(from path: String) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["containerID", "databasePath", "stateDirectory"]),
              let containerID = object["containerID"] as? String,
              !containerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidConfiguration
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let databasePath = object["databasePath"] ?? home.appendingPathComponent("Library/Messages/chat.db").path
        let stateDirectory = object["stateDirectory"] ?? home.appendingPathComponent("Library/Application Support/messages-swift").path
        guard let databasePath = databasePath as? String, databasePath.hasPrefix("/"),
              let stateDirectory = stateDirectory as? String, stateDirectory.hasPrefix("/") else {
            throw ConfigurationError.invalidConfiguration
        }
        return Self(containerID: containerID, databasePath: databasePath, stateDirectory: stateDirectory)
    }
}

public enum ConfigurationError: Error {
    case invalidConfiguration
}
