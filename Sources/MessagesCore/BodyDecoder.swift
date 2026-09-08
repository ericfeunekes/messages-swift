import Foundation

enum BodyDecoder {
  static func decode(plainText: String?, attributedBody: Data?) -> DecodedBody {
    if let plainText, !plainText.isEmpty {
      return DecodedBody(status: .text, text: plainText)
    }
    if let attributedBody, !attributedBody.isEmpty {
      guard let text = TypedStreamParser.parseAttributedBody(attributedBody) else {
        return DecodedBody(status: .failed)
      }
      return DecodedBody(status: .text, text: text)
    }
    if let plainText { return DecodedBody(status: .text, text: plainText) }
    return DecodedBody(status: .absent)
  }
}
