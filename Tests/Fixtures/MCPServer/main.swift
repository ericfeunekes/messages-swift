import Foundation
import MessagesCore
import MessagesMCPAdapter

private enum FixtureError: Error {
  case invalidArguments
}

private final class FixtureContacts: ContactsDirectorySource {
  private let people = [
    ContactPerson(
      identity: ContactIdentity(containerID: "synthetic-selected-container", id: "alice"),
      displayName: "Alice Example",
      handles: ["alice@example.test"]
    ),
    ContactPerson(
      identity: ContactIdentity(containerID: "synthetic-selected-container", id: "bob"),
      displayName: "Bob Example",
      handles: ["bob@example.test"]
    ),
  ]

  func allContacts(in binding: ContactsContainerBinding) throws -> [ContactPerson] {
    guard binding.containerID == "synthetic-selected-container" else {
      throw ContactsDirectoryError.selectedContainerMissing(binding.containerID)
    }
    return people
  }
}

private func arguments() throws -> (database: String, stateDirectory: URL, resetState: Bool) {
  let values = Array(CommandLine.arguments.dropFirst())
  guard let databaseIndex = values.firstIndex(of: "--database"), databaseIndex + 1 < values.count,
    let stateIndex = values.firstIndex(of: "--state-directory"), stateIndex + 1 < values.count
  else { throw FixtureError.invalidArguments }
  return (
    database: values[databaseIndex + 1],
    stateDirectory: URL(fileURLWithPath: values[stateIndex + 1], isDirectory: true),
    resetState: values.contains("--reset-state")
  )
}

let fixture = try arguments()
if fixture.resetState, FileManager.default.fileExists(atPath: fixture.stateDirectory.path) {
  try FileManager.default.removeItem(at: fixture.stateDirectory)
}
let operations = MessagesOperations(
  store: MessageStore(path: fixture.database),
  directory: FixtureContacts(),
  binding: ContactsContainerBinding(containerID: "synthetic-selected-container"),
  state: try LocalState(directory: fixture.stateDirectory)
)
try await MCPServerRunner.run(operations: operations)
