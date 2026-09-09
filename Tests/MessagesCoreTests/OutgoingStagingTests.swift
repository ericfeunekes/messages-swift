import Foundation
import Darwin
import XCTest
@testable import MessagesCore

final class OutgoingStagingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".scratch/outgoing-staging-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func write(_ relativePath: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    func testStagesDistinctPrivateCopiesForDuplicateNamesWithOriginalBytes() throws {
        let first = try write("one/report.txt", "first bytes")
        let second = try write("two/report.txt", "second bytes")
        let stagingRoot = root.appendingPathComponent("outgoing")

        let staged = try StagedOutgoingFiles(
            files: [try OutgoingFile(path: first.path), try OutgoingFile(path: second.path)],
            root: stagingRoot
        )

        XCTAssertEqual(staged.paths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["report.txt", "report.txt"])
        XCTAssertNotEqual(staged.paths[0], staged.paths[1])
        XCTAssertEqual(try staged.paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }, [Data("first bytes".utf8), Data("second bytes".utf8)])
        XCTAssertEqual(try permissions(stagingRoot), 0o700)
        for (index, path) in staged.paths.enumerated() {
            let file = URL(fileURLWithPath: path)
            XCTAssertEqual(try permissions(file), 0o600)
            XCTAssertEqual(try permissions(file.deletingLastPathComponent()), 0o700)
            XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, String(index))
            XCTAssertEqual(try permissions(file.deletingLastPathComponent().deletingLastPathComponent()), 0o700)
        }
    }

    func testFailureAfterFirstCopyRemovesTheIncompleteBatch() throws {
        let first = try write("first.txt", "first")
        let second = try write("second.txt", "second")
        let files = [try OutgoingFile(path: first.path), try OutgoingFile(path: second.path)]
        try FileManager.default.removeItem(at: second)
        let stagingRoot = root.appendingPathComponent("outgoing")

        XCTAssertThrowsError(try StagedOutgoingFiles(files: files, root: stagingRoot)) { error in
            XCTAssertEqual(error as? SendValidationError, .fileChanged)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        XCTAssertTrue(contents.isEmpty)
    }

    func testSourceChangeBeforeCopyIsRejectedAndCompletedCopyKeepsItsSnapshot() throws {
        let source = try write("source.txt", "before")
        let file = try OutgoingFile(path: source.path)
        try Data("after!".utf8).write(to: source)
        XCTAssertThrowsError(try StagedOutgoingFiles(files: [file], root: root.appendingPathComponent("changed-before-copy"))) { error in
            XCTAssertEqual(error as? SendValidationError, .fileChanged)
        }

        let snapshotSource = try write("snapshot.txt", "snapshot")
        let snapshot = try OutgoingFile(path: snapshotSource.path)
        let destination = root.appendingPathComponent("snapshot-copy.txt")
        try snapshot.copy(to: destination)
        try Data("changed!".utf8).write(to: snapshotSource)
        XCTAssertFalse(snapshot.isUnchanged())
        XCTAssertEqual(try Data(contentsOf: destination), Data("snapshot".utf8))
    }

    func testValidatedDescriptorRejectsRewriteAndPathReplacementAfterReads() throws {
        for replacePath in [false, true] {
            let source = try write("source-\(replacePath).txt", "first-remaining")
            let file = try OutgoingFile(path: source.path)

            XCTAssertThrowsError(try file.withValidatedSource { descriptor in
                var first = [UInt8](repeating: 0, count: 5)
                let firstCount = first.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                XCTAssertEqual(firstCount, 5)
                XCTAssertEqual(String(decoding: first, as: UTF8.self), "first")

                if replacePath {
                    let replacement = source.deletingLastPathComponent().appendingPathComponent("replacement-\(UUID().uuidString)")
                    try Data("FIRST-REMAINING".utf8).write(to: replacement)
                    try FileManager.default.removeItem(at: source)
                    try FileManager.default.moveItem(at: replacement, to: source)
                } else {
                    try Data("FIRST-REMAINING".utf8).write(to: source)
                }

                var remaining = [UInt8](repeating: 0, count: 16)
                let remainingCount = remaining.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                XCTAssertGreaterThan(remainingCount, 0)
            }) { error in
                XCTAssertEqual(error as? SendValidationError, .fileChanged)
            }
        }
    }

    func testRejectsSymlinkAndNonPrivateStagingRoots() throws {
        let source = try write("source.txt", "contents")
        let files = [try OutgoingFile(path: source.path)]
        let privateRoot = root.appendingPathComponent("private-root")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateRoot.path)
        let symlink = root.appendingPathComponent("outgoing-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: privateRoot)
        XCTAssertThrowsError(try StagedOutgoingFiles(files: files, root: symlink))

        let publicRoot = root.appendingPathComponent("public-root")
        try FileManager.default.createDirectory(at: publicRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: publicRoot.path)
        XCTAssertThrowsError(try StagedOutgoingFiles(files: files, root: publicRoot))
    }

    func testCleanupKeepsOnlyExplicitlyRetainedFileStages() throws {
        let first = try write("first.txt", "first")
        let second = try write("second.txt", "second")
        let staged = try StagedOutgoingFiles(
            files: [try OutgoingFile(path: first.path), try OutgoingFile(path: second.path)],
            root: root.appendingPathComponent("outgoing")
        )
        let retained = URL(fileURLWithPath: staged.paths[0])
        let discarded = URL(fileURLWithPath: staged.paths[1])

        staged.retain(index: 0)
        staged.cleanupUnhanded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.path))
    }
}
