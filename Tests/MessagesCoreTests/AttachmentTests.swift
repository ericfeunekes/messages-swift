import CSQLite
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import MessagesCore

final class AttachmentTests: XCTestCase {
  func testReadAttachmentReturnsOnlyTheAssociatedOriginalFileAndMIME() throws {
    let fixture = try AttachmentFixture()
    let document = fixture.root.appendingPathComponent("report.pdf")
    let bytes = Data("synthetic PDF bytes".utf8)
    try bytes.write(to: document)
    try fixture.add(messageID: 1, guid: "message-one", attachmentID: 1, attachmentGUID: "attachment-one", path: document.path, mime: nil, uti: "com.adobe.pdf", name: "report.pdf")
    try fixture.add(messageID: 2, guid: "message-two", attachmentID: 2, attachmentGUID: "attachment-two", path: document.path, mime: "application/pdf", uti: nil, name: "other.pdf")

    let content = try fixture.store.readAttachment(.init(messageID: "message-one", attachmentID: "attachment-one"))
    XCTAssertEqual(content.data, bytes)
    XCTAssertEqual(content.mimeType, "application/pdf")
    XCTAssertEqual(content.info.name, "report.pdf")
    XCTAssertEqual(content.info.originalByteCount, Int64(bytes.count))
    XCTAssertEqual(content.info.returnedByteCount, Int64(bytes.count))
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "message-one", attachmentID: "attachment-two"))) { error in
      XCTAssertEqual(error as? AttachmentReadError, .attachment_not_found)
    }
  }

  func testReadAttachmentRejectsMissingUnsafeAndOversizeFiles() throws {
    let fixture = try AttachmentFixture()
    let missing = fixture.root.appendingPathComponent("missing.txt")
    try fixture.add(messageID: 1, guid: "missing-message", attachmentID: 1, attachmentGUID: "missing-attachment", path: missing.path)
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "missing-message", attachmentID: "missing-attachment"))) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_unavailable)
    }

    let regular = fixture.root.appendingPathComponent("regular.txt")
    try Data("safe".utf8).write(to: regular)
    let link = fixture.root.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
    try fixture.add(messageID: 2, guid: "link-message", attachmentID: 2, attachmentGUID: "link-attachment", path: link.path)
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "link-message", attachmentID: "link-attachment"))) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_unsafe_file)
    }

    let fifo = fixture.root.appendingPathComponent("pipe")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    try fixture.add(messageID: 4, guid: "fifo-message", attachmentID: 4, attachmentGUID: "fifo-attachment", path: fifo.path)
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "fifo-message", attachmentID: "fifo-attachment"))) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_unsafe_file)
    }

    let oversized = fixture.root.appendingPathComponent("oversized.bin")
    XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
    let descriptor = open(oversized.path, O_WRONLY)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    XCTAssertEqual(ftruncate(descriptor, 8 * 1024 * 1024 + 1), 0)
    close(descriptor)
    try fixture.add(messageID: 3, guid: "large-message", attachmentID: 3, attachmentGUID: "large-attachment", path: oversized.path)
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "large-message", attachmentID: "large-attachment"))) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_too_large)
    }
  }

  func testReadImageDecodesAndBoundsPNGOutput() throws {
    let fixture = try AttachmentFixture()
    let image = fixture.root.appendingPathComponent("large.png")
    try makePNG(width: 3000, height: 1000).write(to: image)
    try fixture.add(messageID: 1, guid: "image-message", attachmentID: 1, attachmentGUID: "image-attachment", path: image.path, mime: "image/png", name: "large.png")

    let content = try fixture.store.readAttachment(.init(messageID: "image-message", attachmentID: "image-attachment"), image: true)
    XCTAssertEqual(content.mimeType, "image/png")
    XCTAssertEqual(content.info.sourceWidth, 3000)
    XCTAssertEqual(content.info.sourceHeight, 1000)
    XCTAssertEqual(content.info.frameCount, 1)
    XCTAssertEqual(content.info.frameIndex, 0)
    XCTAssertEqual(content.info.width, 2048)
    XCTAssertEqual(content.info.height, 683)
    XCTAssertLessThanOrEqual(content.data.count, 8 * 1024 * 1024)
    XCTAssertNotNil(CGImageSourceCreateWithData(content.data as CFData, nil))
  }

  func testReadImageDistinguishesUnsupportedAndInvalidImages() throws {
    let fixture = try AttachmentFixture()
    let pdf = fixture.root.appendingPathComponent("report.pdf")
    try Data("not an image".utf8).write(to: pdf)
    try fixture.add(messageID: 1, guid: "pdf-message", attachmentID: 1, attachmentGUID: "pdf-attachment", path: pdf.path, mime: "application/pdf")
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "pdf-message", attachmentID: "pdf-attachment"), image: true)) {
      XCTAssertEqual($0 as? AttachmentReadError, .unsupported_image)
    }

    let corrupt = fixture.root.appendingPathComponent("corrupt.png")
    try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: corrupt)
    try fixture.add(messageID: 2, guid: "bad-message", attachmentID: 2, attachmentGUID: "bad-attachment", path: corrupt.path, mime: "image/png")
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "bad-message", attachmentID: "bad-attachment"), image: true)) {
      XCTAssertEqual($0 as? AttachmentReadError, .invalid_image)
    }

    let svg = fixture.root.appendingPathComponent("image.svg")
    try Data("<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'/>".utf8).write(to: svg)
    try fixture.add(messageID: 3, guid: "svg-message", attachmentID: 3, attachmentGUID: "svg-attachment", path: svg.path, mime: "image/svg+xml")
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "svg-message", attachmentID: "svg-attachment"), image: true)) {
      XCTAssertEqual($0 as? AttachmentReadError, .unsupported_image)
    }
  }

  func testConnectionScopedFallbackIDsWorkOnlyForTheirIssuingStore() throws {
    let fixture = try AttachmentFixture()
    let file = fixture.root.appendingPathComponent("fallback.txt")
    try Data("fallback".utf8).write(to: file)
    try fixture.add(messageID: 1, guid: "message", attachmentID: 1, attachmentGUID: "attachment", path: file.path)
    try fixture.exec("ALTER TABLE message DROP COLUMN guid; ALTER TABLE attachment DROP COLUMN guid")
    let page = try fixture.store.readMessages(ReadMessagesRequest(filter: MessageFilter()))
    let message = try XCTUnwrap(page.messages.first)
    let attachment = try XCTUnwrap(message.attachments.first)
    XCTAssertEqual(try fixture.store.readAttachment(.init(messageID: message.id.rawValue, attachmentID: attachment.id)).data, Data("fallback".utf8))
    let freshStore = MessageStore(path: fixture.databaseURL.path)
    XCTAssertThrowsError(try freshStore.readAttachment(.init(messageID: message.id.rawValue, attachmentID: attachment.id))) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_not_found)
    }
  }

  func testReaderRejectsIntermediateSymlinkAndImageSourceLimit() throws {
    let fixture = try AttachmentFixture()
    let directory = fixture.root.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("note.txt")
    try Data("safe".utf8).write(to: file)
    let link = fixture.root.appendingPathComponent("linked-files")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    try fixture.add(messageID: 1, guid: "intermediate-message", attachmentID: 1, attachmentGUID: "intermediate-attachment", path: link.appendingPathComponent("note.txt").path)
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "intermediate-message", attachmentID: "intermediate-attachment"))) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_unsafe_file)
    }

    let large = fixture.root.appendingPathComponent("source.png")
    XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: Data()))
    let descriptor = open(large.path, O_WRONLY)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    XCTAssertEqual(ftruncate(descriptor, 32 * 1024 * 1024 + 1), 0)
    close(descriptor)
    try fixture.add(messageID: 2, guid: "source-message", attachmentID: 2, attachmentGUID: "source-attachment", path: large.path, mime: "image/png")
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "source-message", attachmentID: "source-attachment"), image: true)) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_too_large)
    }
  }

  func testDatabaseReplacementCannotRebindConnectionScopedAttachmentIDs() throws {
    let fixture = try AttachmentFixture()
    let file = fixture.root.appendingPathComponent("original.txt")
    try Data("original".utf8).write(to: file)
    try fixture.add(messageID: 1, guid: "", attachmentID: 1, attachmentGUID: "", path: file.path)
    let history = try fixture.store.readMessages(ReadMessagesRequest(filter: MessageFilter()))
    let row = try XCTUnwrap(history.messages.first)
    let attachment = try XCTUnwrap(row.attachments.first)
    let input = ReadAttachmentInput(messageID: row.id.rawValue, attachmentID: attachment.id)
    XCTAssertEqual(try fixture.store.readAttachment(input).data, Data("original".utf8))
    let copy = fixture.root.appendingPathComponent("replacement.db")
    try FileManager.default.copyItem(at: fixture.databaseURL, to: copy)
    try FileManager.default.moveItem(at: fixture.databaseURL, to: fixture.root.appendingPathComponent("old.db"))
    try FileManager.default.moveItem(at: copy, to: fixture.databaseURL)
    XCTAssertThrowsError(try fixture.store.readAttachment(input)) { error in
      guard let storeError = error as? MessageStoreError else { return XCTFail("Expected database identity failure") }
      switch storeError {
      case .databaseReplaced, .databaseIdentityUnavailable: break
      default: XCTFail("Unexpected database error: \(storeError)")
      }
    }
    let reopened = MessageStore(path: fixture.databaseURL.path)
    XCTAssertThrowsError(try reopened.readAttachment(input)) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_not_found)
    }
  }

  func testCheckedDescriptorKeepsOriginalFileAfterPathReplacement() throws {
    let fixture = try AttachmentFixture()
    let file = fixture.root.appendingPathComponent("replace.txt")
    try Data("original".utf8).write(to: file)
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { close(descriptor) }
    try FileManager.default.removeItem(at: file)
    try Data("replacement".utf8).write(to: file)
    XCTAssertEqual(try AttachmentFile.read(descriptor: descriptor, limit: 100), Data("original".utf8))
    XCTAssertEqual(try AttachmentFile.read(path: file.path, limit: 100), Data("replacement".utf8))
  }

  func testMIMEAndNameUseSourceMetadataBeforeStorageNames() throws {
    let fixture = try AttachmentFixture()
    let file = fixture.root.appendingPathComponent("opaque.bin")
    try Data("synthetic document".utf8).write(to: file)
    try fixture.add(messageID: 1, guid: "named", attachmentID: 1, attachmentGUID: "named-file", path: file.path, name: "Original.pdf")
    let named = try fixture.store.readAttachment(.init(messageID: "named", attachmentID: "named-file"))
    XCTAssertEqual(named.info.name, "Original.pdf")
    XCTAssertEqual(named.mimeType, "application/pdf")
    try fixture.add(messageID: 2, guid: "source-mime", attachmentID: 2, attachmentGUID: "source-file", path: file.path, mime: "application/x-original", uti: "com.adobe.pdf", name: "Original.pdf")
    XCTAssertEqual(try fixture.store.readAttachment(.init(messageID: "source-mime", attachmentID: "source-file")).mimeType, "application/x-original")
    let pdf = fixture.root.appendingPathComponent("extension.pdf")
    try Data("extension only".utf8).write(to: pdf)
    try fixture.add(messageID: 3, guid: "empty-name", attachmentID: 3, attachmentGUID: "extension-file", path: pdf.path)
    XCTAssertEqual(try fixture.store.readAttachment(.init(messageID: "empty-name", attachmentID: "extension-file")).mimeType, "application/pdf")
  }

  func testMissingPathPermissionDirectoryAndTildeSemantics() throws {
    let fixture = try AttachmentFixture()
    let file = fixture.root.appendingPathComponent("private.txt")
    try Data("private synthetic file".utf8).write(to: file)
    try fixture.add(messageID: 1, guid: "permission", attachmentID: 1, attachmentGUID: "private", path: file.path)
    XCTAssertEqual(chmod(file.path, 0), 0)
    defer { chmod(file.path, 0o600) }
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "permission", attachmentID: "private"))) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_unavailable)
    }
    try fixture.add(messageID: 2, guid: "directory", attachmentID: 2, attachmentGUID: "folder", path: fixture.root.path)
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "directory", attachmentID: "folder"))) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_unsafe_file)
    }
    try fixture.add(messageID: 3, guid: "no-path", attachmentID: 3, attachmentGUID: "undownloaded", path: "")
    try fixture.exec("UPDATE attachment SET filename = NULL WHERE ROWID = 3")
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "no-path", attachmentID: "undownloaded"))) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_unavailable)
    }
    XCTAssertEqual(chmod(file.path, 0o600), 0)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    XCTAssertTrue(file.path.hasPrefix(home + "/"))
    let tildePath = "~" + file.path.dropFirst(home.count)
    try fixture.add(messageID: 4, guid: "tilde", attachmentID: 4, attachmentGUID: "tilde-file", path: tildePath)
    XCTAssertEqual(try fixture.store.readAttachment(.init(messageID: "tilde", attachmentID: "tilde-file")).data, Data("private synthetic file".utf8))
  }

  func testNativeHEICWhenEncoderIsAvailable() throws {
    guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains("public.heic") == true else {
      throw XCTSkip("This OS does not expose a HEIC encoder for the synthetic fixture")
    }
    let fixture = try AttachmentFixture()
    let original = try makePNG(width: 64, height: 32)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let bytes = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.heic" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw XCTSkip("Native HEIC encoder unavailable on this Mac") }
    let file = fixture.root.appendingPathComponent("native.heic")
    try (bytes as Data).write(to: file)
    try fixture.add(messageID: 1, guid: "heic", attachmentID: 1, attachmentGUID: "heic-file", path: file.path, mime: "image/heic")
    let result = try fixture.store.readAttachment(.init(messageID: "heic", attachmentID: "heic-file"), image: true)
    XCTAssertEqual(result.info.sourceMimeType, "image/heic")
    XCTAssertEqual(result.info.width, 64)
    XCTAssertEqual(result.info.height, 32)
    let output = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
    XCTAssertEqual(CGImageSourceGetType(output) as String?, "public.png")
    XCTAssertNotNil(CGImageSourceCreateImageAtIndex(output, 0, nil))
  }

  func testImagePixelAndEncodedOutputLimits() throws {
    let fixture = try AttachmentFixture()
    // A real native grayscale PNG just over the pixel cap proves metadata
    // rejection before rendering; the synthetic encoder needs about 100 MB.
    let largeProvider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 0, count: 10001 * 10000) as CFData))
    let largeImage = try XCTUnwrap(CGImage(width: 10001, height: 10000, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 10001,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: largeProvider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let largeBytes = NSMutableData()
    let largeDestination = try XCTUnwrap(CGImageDestinationCreateWithData(largeBytes, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(largeDestination, largeImage, nil)
    XCTAssertTrue(CGImageDestinationFinalize(largeDestination))
    let large = fixture.root.appendingPathComponent("dimensions.png")
    try (largeBytes as Data).write(to: large)
    try fixture.add(messageID: 1, guid: "pixels", attachmentID: 1, attachmentGUID: "pixels-file", path: large.path, mime: "image/png")
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "pixels", attachmentID: "pixels-file"), image: true)) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_too_large)
    }

    var pixels = [UInt8](repeating: 255, count: 2048 * 2048 * 4)
    var random: UInt32 = 0x12345678
    for index in pixels.indices where index % 4 != 3 {
      random ^= random << 13; random ^= random >> 17; random ^= random << 5
      pixels[index] = UInt8(truncatingIfNeeded: random)
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    let image = try XCTUnwrap(CGImage(width: 2048, height: 2048, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8192,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let encoded = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    XCTAssertGreaterThan(encoded.length, 8 * 1024 * 1024)
    XCTAssertLessThan(encoded.length, 32 * 1024 * 1024)
    let noisy = fixture.root.appendingPathComponent("noise.png")
    try (encoded as Data).write(to: noisy)
    try fixture.add(messageID: 2, guid: "encoded", attachmentID: 2, attachmentGUID: "encoded-file", path: noisy.path, mime: "image/png")
    XCTAssertThrowsError(try fixture.store.readAttachment(.init(messageID: "encoded", attachmentID: "encoded-file"), image: true)) {
      XCTAssertEqual($0 as? AttachmentReadError, .attachment_too_large)
    }
  }

}

private final class AttachmentFixture {
  let root: URL
  let databaseURL: URL
  private var database: OpaquePointer?
  let store: MessageStore

  init() throws {
    root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scratch/attachment-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    databaseURL = root.appendingPathComponent("chat.db")
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, database != nil else { throw MessageStoreError.sqlite("fixture open") }
    store = MessageStore(path: databaseURL.path)
    try exec("""
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT);
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER, is_from_me INTEGER, text TEXT, handle_id INTEGER);
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT, total_bytes INTEGER, is_sticker INTEGER);
      CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
      """)
    try exec("INSERT INTO chat VALUES (1, 'chat')")
  }

  deinit { sqlite3_close_v2(database); try? FileManager.default.removeItem(at: root) }

  func add(messageID: Int, guid: String, attachmentID: Int, attachmentGUID: String, path: String, mime: String? = nil, uti: String? = nil, name: String? = nil) throws {
    try exec("INSERT INTO message VALUES (\(messageID), '\(guid)', 1, 0, '', NULL); INSERT INTO chat_message_join VALUES (1, \(messageID));")
    let quotedPath = path.replacingOccurrences(of: "'", with: "''")
    let quotedName = name?.replacingOccurrences(of: "'", with: "''") ?? ""
    let mimeSQL = mime.map { "'\($0)'" } ?? "NULL"
    let utiSQL = uti.map { "'\($0)'" } ?? "NULL"
    try exec("INSERT INTO attachment VALUES (\(attachmentID), '\(attachmentGUID)', '\(quotedPath)', '\(quotedName)', \(utiSQL), \(mimeSQL), NULL, NULL); INSERT INTO message_attachment_join VALUES (\(messageID), \(attachmentID));")
  }

  func exec(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
      defer { sqlite3_free(error) }
      throw MessageStoreError.sqlite(error.map { String(cString: $0) } ?? "fixture SQL")
    }
  }
}

private func makePNG(width: Int, height: Int) throws -> Data {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let image = context.makeImage() else { throw AttachmentReadError.invalid_image }
  let data = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw AttachmentReadError.invalid_image }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw AttachmentReadError.invalid_image }
  return data as Data
}
