import Foundation
import XCTest
@testable import MessagesCore

final class LocalStateTests: XCTestCase {
    func testInitialEmptyBaselineIsPersistedAsSeeded() throws {
        let directory = try temporaryDirectory()
        let first = try LocalState(directory: directory)

        try first.seedInitialCache([], now: date(0))

        let reloaded = try LocalState(directory: directory)
        XCTAssertTrue(reloaded.isSeeded)
        XCTAssertEqual(reloaded.cacheEntries, [])
        try reloaded.seedInitialCache([person("ignored")], now: date(1))
        XCTAssertEqual(reloaded.cacheEntries, [])
    }

    func testUseRefreshesWithoutChangingFIFOAndEvictsOldestAdmission() throws {
        let state = try LocalState(directory: try temporaryDirectory(), capacity: 2)
        let a = person("a")
        let b = person("b")
        let refreshedA = ContactPerson(identity: a.identity, displayName: "A refreshed", handles: a.handles)
        let c = person("c")

        try state.use(a, now: date(0))
        try state.use(b, now: date(1))
        try state.use(refreshedA, now: date(2))
        try state.use(c, now: date(3))

        XCTAssertEqual(state.cacheEntries.map(\.person.identity.id), ["b", "c"])
        XCTAssertEqual(state.cacheEntries.map(\.admittedAt), [date(1), date(3)])
    }

    func testCacheAndAliasesPersistInSeparateFilesAcrossRestart() throws {
        let directory = try temporaryDirectory()
        let state = try LocalState(directory: directory)
        let person = person("a")

        try state.use(person, now: date(0))
        try state.setAlias("Family", for: "chat-1")
        try state.use(ContactPerson(identity: person.identity, displayName: "Updated", handles: ["updated@example.test"]), now: date(1))

        let reloaded = try LocalState(directory: directory)
        XCTAssertEqual(reloaded.cacheEntries.count, 1)
        XCTAssertEqual(reloaded.cacheEntries[0].person.displayName, "Updated")
        XCTAssertEqual(reloaded.cacheEntries[0].admittedAt, date(0))
        XCTAssertEqual(reloaded.alias(for: "chat-1"), "Family")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("contacts.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("aliases.json").path))
    }

    func testNewStateDirectoryAndFilesArePrivate() throws {
        let parent = try temporaryDirectory()
        let directory = parent.appendingPathComponent("new-state", isDirectory: true)
        let state = try LocalState(directory: directory)
        try state.use(person("a"), now: date(0))
        try state.setAlias("Family", for: "chat-a")

        XCTAssertEqual(try permissions(of: directory), 0o700)
        XCTAssertEqual(try permissions(of: directory.appendingPathComponent("contacts.json")), 0o600)
        XCTAssertEqual(try permissions(of: directory.appendingPathComponent("aliases.json")), 0o600)
    }

    func testDiscardingCacheAndRemovingContactPreservesAliases() throws {
        let state = try LocalState(directory: try temporaryDirectory())
        try state.seedInitialCache([person("a"), person("b")], now: date(0))
        try state.setAlias("Family", for: "chat-a")

        try state.removeCachedContact(ContactIdentity(containerID: "selected-google-container", id: "a"))
        XCTAssertEqual(state.cacheEntries.map(\.person.identity.id), ["b"])
        try state.discardCachedContacts()

        XCTAssertFalse(state.isSeeded)
        XCTAssertEqual(state.cacheEntries, [])
        XCTAssertEqual(state.alias(for: "chat-a"), "Family")
    }

    func testFailedCacheWriteLeavesInMemoryCacheUnchanged() throws {
        let directory = try temporaryDirectory()
        let state = try LocalState(directory: directory)
        let original = person("a")
        try state.use(original, now: date(0))
        let destination = directory.appendingPathComponent("contacts.json")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        XCTAssertThrowsError(try state.use(person("b"), now: date(1)))
        XCTAssertEqual(state.cacheEntries.map(\.person), [original])
        XCTAssertEqual(state.cacheEntries.map(\.refreshedAt), [date(0)])
    }

    func testFailedAliasWriteLeavesInMemoryAliasesUnchanged() throws {
        let directory = try temporaryDirectory()
        let state = try LocalState(directory: directory)
        try state.setAlias("Family", for: "chat-a")
        let destination = directory.appendingPathComponent("aliases.json")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        XCTAssertThrowsError(try state.setAlias("Friends", for: "chat-b"))
        XCTAssertEqual(state.aliases(), ["chat-a": "Family"])
    }

    func testFutureStateVersionIsRejected() throws {
        let directory = try temporaryDirectory()
        try Data("{\"version\":2,\"isSeeded\":false,\"entries\":[]}".utf8)
            .write(to: directory.appendingPathComponent("contacts.json"))

        XCTAssertThrowsError(try LocalState(directory: directory)) { error in
            XCTAssertEqual(error as? LocalStateError, .unsupportedStateVersion(2))
        }
    }

    func testDuplicateCachedIdentityIsRejectedOnLoad() throws {
        let directory = try temporaryDirectory()
        let entry = "{\"person\":{\"identity\":{\"containerID\":\"selected-google-container\",\"id\":\"a\"},\"displayName\":\"a\",\"handles\":[]},\"admittedAt\":0,\"refreshedAt\":0}"
        try Data("{\"version\":1,\"isSeeded\":false,\"entries\":[\(entry),\(entry)]}".utf8)
            .write(to: directory.appendingPathComponent("contacts.json"))

        XCTAssertThrowsError(try LocalState(directory: directory)) { error in
            XCTAssertEqual(
                error as? LocalStateError,
                .duplicateCachedContactIdentity(ContactIdentity(containerID: "selected-google-container", id: "a"))
            )
        }
    }

    func testDailyRefreshSelectionUsesCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let state = try LocalState(directory: try temporaryDirectory())
        try state.use(person("same"), now: date(0))
        try state.use(person("next"), now: date(86_400))

        XCTAssertEqual(state.entriesDueForRefresh(now: date(86_400), calendar: calendar).map(\.person.identity.id), ["same"])
    }

    func testAliasCollisionReturnsConflictingChatAndOwnReplacementIsAllowed() throws {
        let state = try LocalState(directory: try temporaryDirectory())
        try state.setAlias("Family", for: "chat-a")
        try state.setAlias("Family group", for: "chat-a")

        XCTAssertEqual(state.alias(for: "chat-a"), "Family group")
        XCTAssertThrowsError(try state.setAlias("FAMILY GROUP", for: "chat-b")) { error in
            XCTAssertEqual(error as? LocalStateError, .aliasAlreadyUsed(alias: "FAMILY GROUP", chatIDs: ["chat-a"]))
        }
        XCTAssertNil(state.alias(for: "chat-b"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/local-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func person(_ id: String) -> ContactPerson {
        ContactPerson(
            identity: ContactIdentity(containerID: "selected-google-container", id: id),
            displayName: id,
            handles: ["\(id)@example.test"]
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
    }
}
