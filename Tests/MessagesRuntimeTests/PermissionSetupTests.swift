import Darwin
import Foundation
import Testing
@testable import MessagesMCPAdapter

@Test func messagesReadAccessUsesActualFiles() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".scratch/permissions-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("chat.db")
    #expect(MessagesReadAccess.check(path: file.path) == .missing)
    try Data("synthetic".utf8).write(to: file)
    #expect(MessagesReadAccess.check(path: file.path) == .readable)
    #expect(MessagesReadAccess.check(path: root.path) == .unavailable)
    #expect(MessagesReadAccess.check(path: file.appendingPathComponent("child").path) == .missing)
    #expect(try Data(contentsOf: file) == Data("synthetic".utf8))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    #expect(MessagesReadAccess.check(path: file.path) == .denied)
}

@Test func messagesAccessErrorsDoNotAllMeanFullDiskAccess() {
    #expect(MessagesReadAccess.classify(errno: EACCES) == .denied)
    #expect(MessagesReadAccess.classify(errno: EPERM) == .denied)
    #expect(MessagesReadAccess.classify(errno: ENOENT) == .missing)
    #expect(MessagesReadAccess.classify(errno: ENOTDIR) == .missing)
    #expect(MessagesReadAccess.classify(errno: EIO) == .unavailable)
    #expect(MessagesReadAccess.classify(errno: EMFILE) == .unavailable)
}

@Test func contactsPermissionActionsRespectSystemState() {
    #expect(ContactsSetupAccess.notRequested.action == .request)
    #expect(ContactsSetupAccess.denied.action == .settings)
    #expect(ContactsSetupAccess.restricted.action == .explain)
    #expect(ContactsSetupAccess.unavailable.action == .explain)
    #expect(ContactsSetupAccess.granted.action == .none)
}
