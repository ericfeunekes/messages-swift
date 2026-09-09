import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ReadAttachmentInput: Codable, Sendable {
  public let messageID: String
  public let attachmentID: String

  public init(messageID: String, attachmentID: String) {
    self.messageID = messageID
    self.attachmentID = attachmentID
  }
}

public enum AttachmentReadError: String, Error, Sendable {
  case attachment_not_found
  case attachment_unavailable
  case attachment_unsafe_file
  case attachment_too_large
  case unsupported_image
  case invalid_image
}

public struct AttachmentContentInfo: Codable, Sendable {
  public let messageID: String
  public let attachmentID: String
  public let name: String?
  public let originalByteCount: Int64
  public let returnedByteCount: Int64
  public let sourceByteLimit: Int
  public let returnedByteLimit: Int
  public let maxPixelDimension: Int?
  public let maxSourcePixelCount: Int?
  public let mimeType: String
  public let sourceMimeType: String?
  public let sourceWidth: Int?
  public let sourceHeight: Int?
  public let frameCount: Int?
  public let frameIndex: Int?
  public let width: Int?
  public let height: Int?
  public let metadata: AttachmentMetadata
}

public struct AttachmentContent: Sendable {
  public let data: Data
  public let mimeType: String
  public let info: AttachmentContentInfo
}

extension MessageStore {
  public func readAttachment(_ input: ReadAttachmentInput, image: Bool = false) throws -> AttachmentContent {
    guard !input.messageID.isEmpty, !input.attachmentID.isEmpty else { throw AttachmentReadError.attachment_not_found }
    return try withSnapshot { database, schema, generation in
      guard let metadata = try attachmentMetadata(input, database: database, schema: schema, generation: generation) else {
        throw AttachmentReadError.attachment_not_found
      }
      guard let filename = metadata.filename, !filename.isEmpty else { throw AttachmentReadError.attachment_unavailable }
      let sourceLimit = image ? 32 * 1024 * 1024 : 8 * 1024 * 1024
      let source = try AttachmentFile.read(path: expandedAttachmentPath(filename), limit: sourceLimit)
      let sourceMime = selectedMIME(metadata)
      let name = attachmentName(metadata)
      if image {
        return try renderedImage(source, input: input, metadata: metadata, name: name)
      }
      return AttachmentContent(
        data: source, mimeType: sourceMime,
        info: AttachmentContentInfo(
          messageID: input.messageID, attachmentID: input.attachmentID, name: name,
          originalByteCount: Int64(source.count), returnedByteCount: Int64(source.count),
          sourceByteLimit: 8 * 1024 * 1024, returnedByteLimit: 8 * 1024 * 1024,
          maxPixelDimension: nil, maxSourcePixelCount: nil,
          mimeType: sourceMime,
          sourceMimeType: metadata.mimeType, sourceWidth: nil, sourceHeight: nil, frameCount: nil,
          frameIndex: nil, width: nil, height: nil, metadata: responseMetadata(metadata)
        )
      )
    }
  }

  private func attachmentMetadata(_ input: ReadAttachmentInput, database: OpaquePointer, schema: MessageSchema, generation: String) throws -> AttachmentMetadata? {
    guard schema.hasAttachmentTables, let messageRowID = try attachmentMessageRowID(input.messageID, database: database, schema: schema, generation: generation) else { return nil }
    return try attachments(messageRowID: messageRowID, database: database, schema: schema, generation: generation)
      .first { $0.id == input.attachmentID }
  }

  private func attachmentMessageRowID(_ requestedID: String, database: OpaquePointer, schema: MessageSchema, generation: String) throws -> Int64? {
    guard schema.has("guid") else { return try fallbackMessageRowID(requestedID, database: database, schema: schema, generation: generation) }
    let statement = try SQLiteStatement(database, "SELECT ROWID, guid FROM message WHERE guid = ?")
    defer { statement.finalize() }
    try statement.bind([.text(requestedID)])
    while try statement.step() {
      let rowID = statement.integer(at: 0)
      let guid = statement.text(at: 1)
      if MessageID(rawValue: guid?.isEmpty == false ? guid! : "\(generation):\(rowID)").rawValue == requestedID { return rowID }
    }
    return try fallbackMessageRowID(requestedID, database: database, schema: schema, generation: generation)
  }

  private func fallbackMessageRowID(_ requestedID: String, database: OpaquePointer, schema: MessageSchema, generation: String) throws -> Int64? {
    let prefix = "\(generation):"
    guard requestedID.hasPrefix(prefix), let rowID = Int64(requestedID.dropFirst(prefix.count)), requestedID == "\(prefix)\(rowID)" else { return nil }
    let fallback = try SQLiteStatement(database, schema.has("guid") ? "SELECT guid FROM message WHERE ROWID = ?" : "SELECT ROWID FROM message WHERE ROWID = ?")
    defer { fallback.finalize() }
    try fallback.bind([.integer(rowID)])
    guard try fallback.step(), !schema.has("guid") || fallback.text(at: 0)?.isEmpty != false else { return nil }
    return rowID
  }
}

private func attachmentName(_ metadata: AttachmentMetadata) -> String? {
  if let name = metadata.transferName, !name.isEmpty { return name }
  return metadata.filename.map { URL(fileURLWithPath: $0).lastPathComponent }
}

private func responseMetadata(_ metadata: AttachmentMetadata) -> AttachmentMetadata {
  AttachmentMetadata(
    id: metadata.id, filename: attachmentName(metadata), transferName: metadata.transferName,
    uniformTypeIdentifier: metadata.uniformTypeIdentifier, mimeType: metadata.mimeType,
    byteCount: metadata.byteCount, isSticker: metadata.isSticker, availability: metadata.availability
  )
}

private func selectedMIME(_ metadata: AttachmentMetadata) -> String {
  if let mime = metadata.mimeType, !mime.isEmpty { return mime }
  if let uti = metadata.uniformTypeIdentifier, let mime = UTType(uti)?.preferredMIMEType { return mime }
  if let name = attachmentName(metadata),
     let extensionType = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension),
     let mime = extensionType.preferredMIMEType { return mime }
  return "application/octet-stream"
}

private func expandedAttachmentPath(_ source: String) -> String {
  guard source == "~" || source.hasPrefix("~/") else { return source }
  return FileManager.default.homeDirectoryForCurrentUser.path + String(source.dropFirst())
}

private func renderedImage(_ source: Data, input: ReadAttachmentInput, metadata: AttachmentMetadata, name: String?) throws -> AttachmentContent {
  guard let imageSource = CGImageSourceCreateWithData(source as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
        let sourceType = CGImageSourceGetType(imageSource) else {
    guard let declared = declaredImageType(metadata), declared.conforms(to: .image) else { throw AttachmentReadError.unsupported_image }
    let supported = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).contains(declared.identifier)
    throw supported ? AttachmentReadError.invalid_image : AttachmentReadError.unsupported_image
  }
  guard let imageType = UTType(sourceType as String), imageType.conforms(to: .image) else { throw AttachmentReadError.unsupported_image }
  let detectedSourceMIME = imageType.preferredMIMEType
  guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
        let sourceWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let sourceHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
        sourceWidth.int64Value > 0, sourceHeight.int64Value > 0 else { throw AttachmentReadError.invalid_image }
  let pixels = sourceWidth.int64Value.multipliedReportingOverflow(by: sourceHeight.int64Value)
  guard !pixels.overflow, pixels.partialValue <= 100_000_000 else { throw AttachmentReadError.attachment_too_large }
  let frameCount = CGImageSourceGetCount(imageSource)
  guard frameCount > 0 else { throw AttachmentReadError.invalid_image }
  let options: CFDictionary = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: 2048,
  ] as CFDictionary
  guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options),
        CGImageSourceGetStatusAtIndex(imageSource, 0) == .statusComplete else { throw AttachmentReadError.invalid_image }
  let output = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw AttachmentReadError.invalid_image }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw AttachmentReadError.invalid_image }
  let data = output as Data
  guard data.count <= 8 * 1024 * 1024 else { throw AttachmentReadError.attachment_too_large }
  let mime = "image/png"
  return AttachmentContent(
    data: data, mimeType: mime,
    info: AttachmentContentInfo(
      messageID: input.messageID, attachmentID: input.attachmentID, name: name,
      originalByteCount: Int64(source.count), returnedByteCount: Int64(data.count),
      sourceByteLimit: 32 * 1024 * 1024, returnedByteLimit: 8 * 1024 * 1024,
      maxPixelDimension: 2048, maxSourcePixelCount: 100_000_000,
      mimeType: mime,
      sourceMimeType: detectedSourceMIME, sourceWidth: sourceWidth.intValue, sourceHeight: sourceHeight.intValue,
      frameCount: frameCount, frameIndex: 0, width: image.width, height: image.height, metadata: responseMetadata(metadata)
    )
  )
}

private func declaredImageType(_ metadata: AttachmentMetadata) -> UTType? {
  if let mime = metadata.mimeType, let type = UTType(mimeType: mime) { return type }
  if let uti = metadata.uniformTypeIdentifier { return UTType(uti) }
  if let name = attachmentName(metadata) { return UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) }
  return nil
}

enum AttachmentFile {
  static func read(path: String, limit: Int) throws -> Data {
    guard path.hasPrefix("/"), !path.contains("\0") else { throw AttachmentReadError.attachment_unsafe_file }
    let descriptor = try openNoFollow(path: path)
    defer { close(descriptor) }
    return try read(descriptor: descriptor, limit: limit)
  }

  /// The caller owns the descriptor. Validation and bytes share this opened file,
  /// even if its pathname is replaced while the request is in progress.
  static func read(descriptor: Int32, limit: Int) throws -> Data {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw AttachmentReadError.attachment_unavailable }
    guard (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0 else { throw AttachmentReadError.attachment_unsafe_file }
    guard status.st_size <= off_t(limit) else { throw AttachmentReadError.attachment_too_large }
    var data = Data()
    data.reserveCapacity(Int(status.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let remaining = limit + 1 - data.count
      guard remaining > 0 else { throw AttachmentReadError.attachment_too_large }
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
      }
      if count == 0 { return data }
      if count < 0 {
        if errno == EINTR { continue }
        throw AttachmentReadError.attachment_unavailable
      }
      data.append(contentsOf: buffer.prefix(count))
    }
  }

  private static func openNoFollow(path: String) throws -> Int32 {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { throw AttachmentReadError.attachment_unsafe_file }
    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard current >= 0 else { throw AttachmentReadError.attachment_unavailable }
    for (index, part) in parts.enumerated() {
      let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (index + 1 < parts.count ? O_DIRECTORY : 0)
      let next = part.withCString { Darwin.openat(current, $0, flags) }
      let openError = errno
      close(current)
      guard next >= 0 else {
        if openError == ELOOP || openError == ENOTDIR { throw AttachmentReadError.attachment_unsafe_file }
        throw AttachmentReadError.attachment_unavailable
      }
      current = next
    }
    return current
  }
}
