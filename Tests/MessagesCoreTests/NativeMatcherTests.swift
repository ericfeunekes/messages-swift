import Testing
@testable import MessagesCore

@Test func graphemePolicyContractExamples() {
  #expect(!NativeMatcher.matches("İstanbul", query: "ß", mode: .substring))
  #expect(NativeMatcher.matches("İ", query: "i\u{307}" , mode: .substring))
  #expect(NativeMatcher.matches("Straße", query: "SS", mode: .substring))
  #expect(NativeMatcher.matches("CAFÉ", query: "cafe\u{301}", mode: .substring))
  #expect(!NativeMatcher.matches("café", query: "cafe", mode: .substring))
  #expect(!NativeMatcher.matches("👨‍👩‍👧‍👦", query: "👨", mode: .substring))
  #expect(NativeMatcher.matches("👨‍👩‍👧‍👦 then 👨", query: "👨", mode: .substring))
  #expect(!NativeMatcher.matches("cafe\u{301}", query: "\u{301}", mode: .substring))
  #expect(!NativeMatcher.matches("\r\n", query: "\r", mode: .substring))
  #expect(NativeMatcher.matches("\r\n then \r", query: "\r", mode: .substring))
  #expect(!NativeMatcher.matches("🇨🇦", query: "🇨", mode: .substring))
  #expect(NativeMatcher.matches("🇨🇦 then 🇨", query: "🇨", mode: .substring))
  #expect(NativeMatcher.matches("100%_\\done", query: "%_\\", mode: .substring))
  #expect(!NativeMatcher.matches("100xy\\done", query: "%_\\", mode: .substring))
  #expect(NativeMatcher.matches("CAFÉ", query: "cafe\u{301}", mode: .exact))
  #expect(NativeMatcher.matches("Straße", query: "STRASSE", mode: .exact))
  #expect(!NativeMatcher.matches("prefix CAFÉ suffix", query: "café", mode: .exact))
  #expect(!NativeMatcher.matches("İstanbul", query: "ß", mode: .exact))
}
