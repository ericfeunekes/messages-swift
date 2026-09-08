import Foundation
import Testing
@testable import MessagesCore

@Test func bodyDecoderDistinguishesMissingEmptyAndFailure() {
  #expect(BodyDecoder.decode(plainText: nil, attributedBody: nil).status == .absent)
  #expect(BodyDecoder.decode(plainText: nil, attributedBody: Data()).status == .absent)
  let emptyPlain = BodyDecoder.decode(plainText: "", attributedBody: nil)
  #expect(emptyPlain.status == .text)
  #expect(emptyPlain.text == "")
  let emptyArchive = BodyDecoder.decode(plainText: nil, attributedBody: archivedAttributedBody(""))
  #expect(emptyArchive.status == .text)
  #expect(emptyArchive.text == "")
  for data in [Data([0xff]), Data([4, 11]), Data([0xff, 0xfe, 0x61])] {
    let failed = BodyDecoder.decode(plainText: "", attributedBody: data)
    #expect(failed.status == .failed)
    #expect(failed.text == nil)
  }
}

@Test func bodyDecoderUsesPlainThenAttributedContent() {
  let plain = BodyDecoder.decode(plainText: "plain", attributedBody: Data([0xff]))
  #expect(plain.status == .text)
  #expect(plain.text == "plain")
  let attributed = BodyDecoder.decode(plainText: "", attributedBody: archivedAttributedBody("archive 🌤️"))
  #expect(attributed.status == .text)
  #expect(attributed.text == "archive 🌤️")
}

@Test func rawControlTrimmingPreservesScalarRemainder() {
  let data = Data("\r\nhello".utf8)
  #expect(TypedStreamParser.parseAttributedBody(data) == "hello")
  #expect(TypedStreamParser.parseAttributedBody(Data([0xff])) == nil)
}
