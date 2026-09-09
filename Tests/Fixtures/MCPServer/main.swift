import CSQLite
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

// Inert test-only boundary: records synthetic dispatches, never contacts Messages.
private actor FixtureSender: MessagesSending, MessagesRouteDiscovering {
  struct Invocation: Codable { let target: String; let service: String?; let kind: String; let value: String }
  let log: URL
  let database: URL
  init(log: URL, database: URL) { self.log = log; self.database = database }
  func send(target: SendTarget, payload: SendPayload) async -> SendDispatchOutcome {
    let targetID: String
    let service: String?
    switch target {
    case .chat(let id): targetID = id; service = nil
    case .individual(let handle, let selectedService): targetID = handle; service = selectedService
    }
    let kind: String
    let value: String
    switch payload {
    case .text(let text): kind = "text"; value = text
    case .file(let path): kind = "file"; value = path
    }
    do {
      let line = try JSONEncoder().encode(Invocation(target: targetID, service: service, kind: kind, value: value)) + Data([10])
      if !FileManager.default.fileExists(atPath: log.path) { try Data().write(to: log) }
      let handle = try FileHandle(forWritingTo: log)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } catch { return .unknown }
    if value.contains("fixture-unknown") { return .unknown }
    if value.contains("fixture-rejected") { return .rejected }
    recordObservedRow(target: target, payload: payload, text: value, failed: value.contains("fixture-source-failed"))
    return .accepted
  }
  func availableServices() async throws -> [String] { ["iMessage", "SMS", "RCS"] }

  private func recordObservedRow(target: SendTarget, payload: SendPayload, text: String, failed: Bool) {
    let chatID: String
    switch target {
    case let .chat(id) where id == "chat-direct" || id == "chat-group": chatID = id
    case let .individual(handle, _) where handle == "alice@example.test": chatID = "chat-direct"
    default: return
    }
    var handle: OpaquePointer?
    guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { return }
    defer { sqlite3_close(handle) }
    let escapedText = text.replacingOccurrences(of: "'", with: "''")
    let row = "fixture-observed-\(UUID().uuidString)"
    let chatRow = chatID == "chat-direct" ? 1 : 2
    let status = failed ? "0, 0, 22" : "1, 0, 0"
    let attachmentSQL: String
    if case let .file(path) = payload {
      let escapedPath = path.replacingOccurrences(of: "'", with: "''")
      attachmentSQL = "INSERT INTO attachment (filename) VALUES ('\(escapedPath)'); INSERT INTO message_attachment_join VALUES ((SELECT MAX(ROWID) FROM message), last_insert_rowid());"
    } else { attachmentSQL = "" }
    let sql = """
      INSERT INTO message (guid,date,text,is_from_me,is_sent,is_delivered,error,service) VALUES ('\(row)',999,'\(escapedText)',1,\(status),'iMessage');
      INSERT INTO chat_message_join VALUES (\(chatRow),last_insert_rowid());
      \(attachmentSQL)
      """
    _ = sqlite3_exec(handle, sql, nil, nil, nil)
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
  state: try LocalState(directory: fixture.stateDirectory),
  sender: FixtureSender(log: fixture.stateDirectory.appendingPathComponent("send-invocations.jsonl"), database: URL(fileURLWithPath: fixture.database)),
  outgoingStagingDirectory: fixture.stateDirectory.appendingPathComponent("outgoing")
)
if let index = CommandLine.arguments.firstIndex(of: "--socket"), index + 1 < CommandLine.arguments.count {
  let server = UnixSocketServer(url: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
  try server.start(operations: operations)
  FileHandle.standardOutput.write(Data("ready\n".utf8))
  Task.detached {
    _ = FileHandle.standardInput.readDataToEndOfFile()
    server.stop()
  }
  try await server.waitUntilStopped()
} else {
  try await MCPServerRunner.run(operations: operations)
}
