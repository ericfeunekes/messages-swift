import Foundation

extension MessageStore {
  func messageSelect(schema: MessageSchema) -> String {
    func column(_ name: String, _ fallback: String = "NULL") -> String { schema.has(name) ? "m.\(name)" : fallback }
    return [
      "m.ROWID", "cmj.chat_id", "c.guid", column("guid"), "m.date", column("text"),
      column("attributedbody"), "m.is_from_me", column("service"), "h.id",
      column("associated_message_guid"), column("associated_message_type"), column("item_type"),
      column("balloon_bundle_id"), column("date_edited"), column("date_retracted")
    ].enumerated().map { index, expression in "\(expression) AS c\(index)" }.joined(separator: ", ")
  }

  func message(from statement: SQLiteStatement, database: OpaquePointer, schema: MessageSchema, generation: Int64, resolvedBody: DecodedBody? = nil) throws -> MessageRecord {
    let rowID = statement.integer(at: 0)
    let body = resolvedBody ?? BodyDecoder.decode(plainText: statement.text(at: 5), attributedBody: statement.data(at: 6))
    let attachments = try attachments(messageRowID: rowID, database: database, schema: schema, generation: generation)
    let associatedType = statement.isNull(at: 11) ? nil : Int(statement.integer(at: 11))
    let itemType = statement.isNull(at: 12) ? nil : Int(statement.integer(at: 12))
    let edited = !statement.isNull(at: 14) && statement.integer(at: 14) != 0
    let retracted = !statement.isNull(at: 15) && statement.integer(at: 15) != 0
    let kind = classify(
      schema: schema, body: body, attachments: attachments, associatedType: associatedType,
      itemType: itemType, balloonBundleID: statement.text(at: 13)
    )
    let guid = statement.text(at: 3)
    return MessageRecord(
      id: MessageID(rawValue: guid?.isEmpty == false ? guid! : "\(generation):\(rowID)"),
      sourceRowID: rowID,
      sourceDateNanos: statement.integer(at: 4),
      chatID: ChatID(rawValue: statement.text(at: 2) ?? ""),
      guid: guid,
      date: Date(timeIntervalSince1970: (Double(statement.integer(at: 4)) / 1_000_000_000) + 978_307_200),
      sender: statement.text(at: 9),
      isFromMe: statement.integer(at: 7) != 0,
      service: statement.text(at: 8),
      body: body,
      kind: kind,
      associatedMessageGUID: statement.text(at: 10),
      associatedMessageType: associatedType,
      sourceItemType: itemType,
      balloonBundleID: statement.text(at: 13),
      isEdited: edited,
      isRetracted: retracted,
      attachments: attachments
    )
  }

  private func classify(
    schema: MessageSchema, body: DecodedBody, attachments: [AttachmentMetadata],
    associatedType: Int?, itemType: Int?, balloonBundleID: String?
  ) -> MessageRowKind {
    // Without item_type, source semantics are ambiguous: retain the row as
    // unknown rather than presenting it as an ordinary user message.
    guard schema.has("item_type"), schema.has("associated_message_type"), schema.has("balloon_bundle_id"), let itemType else { return .unknown }
    if let associatedType, (2000...2006).contains(associatedType) || (3000...3006).contains(associatedType) {
      return .reaction
    }
    if balloonBundleID?.contains("URLBalloonProvider") == true { return .preview }
    guard itemType == 0 else { return .unknown }
    if (body.status == .absent || (body.status == .text && body.text?.isEmpty == true)) && !attachments.isEmpty { return .attachmentOnly }
    return .ordinary
  }

  private func attachments(messageRowID: Int64, database: OpaquePointer, schema: MessageSchema, generation: Int64) throws -> [AttachmentMetadata] {
    guard schema.hasAttachmentTables else { return [] }
    func column(_ name: String) -> String { schema.attachmentHas(name) ? "a.\(name)" : "NULL" }
    let statement = try SQLiteStatement(database, """
      SELECT a.ROWID, \(column("guid")), \(column("filename")), \(column("transfer_name")), \(column("uti")), \(column("mime_type")),
             \(column("total_bytes")), \(column("is_sticker"))
      FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id = ? ORDER BY a.ROWID ASC
      """)
    defer { statement.finalize() }
    try statement.bind([.integer(messageRowID)])
    var result: [AttachmentMetadata] = []
    while try statement.step() {
      let rowID = statement.integer(at: 0)
      let guid = statement.text(at: 1)
      let filename = statement.text(at: 2)
      let availability: AttachmentAvailability
      if let filename { availability = FileManager.default.fileExists(atPath: (filename as NSString).expandingTildeInPath) ? .available : .unavailable }
      else { availability = .unknown }
      result.append(AttachmentMetadata(
        id: guid?.isEmpty == false ? guid! : "\(generation):\(rowID)",
        filename: filename, transferName: statement.text(at: 3), uniformTypeIdentifier: statement.text(at: 4),
        mimeType: statement.text(at: 5), byteCount: statement.isNull(at: 6) ? nil : statement.integer(at: 6),
        isSticker: statement.isNull(at: 7) ? nil : statement.integer(at: 7) != 0, availability: availability
      ))
    }
    return result
  }
}
