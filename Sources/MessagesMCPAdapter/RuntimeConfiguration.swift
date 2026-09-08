import Foundation

/// Device-local setup. The selected container is confirmed by the user, never guessed from its name.
public struct RuntimeConfiguration: Codable, Sendable {
    public let containerID: String
    public let databasePath: String
    public let stateDirectory: String

    public init(containerID: String, databasePath: String, stateDirectory: String) {
        self.containerID = containerID
        self.databasePath = databasePath
        self.stateDirectory = stateDirectory
    }

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

    public func save(to path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

public enum ConfigurationError: Error {
    case invalidConfiguration
}
