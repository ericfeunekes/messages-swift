import Foundation

/// Native canonical/caseless matching constrained to whole Swift Characters.
/// Construct UTF-16 boundaries only after a native match; continuation advances
/// monotonically from the rejected match's start, preserving later valid matches.
enum NativeMatcher {
  static func matches(_ candidate: String, query: String, mode: MessageSearchMode) -> Bool {
    if mode == .exact {
      return candidate.caseInsensitiveCompare(query) == .orderedSame
    }
    let native = candidate as NSString
    var searchRange = NSRange(location: 0, length: native.length)
    var boundaries: [Int]?
    var boundarySet = Set<Int>()
    var nextBoundary = 0
    while searchRange.length > 0 {
      let found = native.range(of: query, options: [.caseInsensitive], range: searchRange)
      guard found.location != NSNotFound else { return false }
      if boundaries == nil {
        var offsets = [0]
        var offset = 0
        for character in candidate {
          offset += String(character).utf16.count
          offsets.append(offset)
        }
        boundaries = offsets
        boundarySet = Set(offsets)
      }
      let edges = boundaries!
      if boundarySet.contains(found.location) && boundarySet.contains(NSMaxRange(found)) { return true }
      while nextBoundary < edges.count && edges[nextBoundary] <= found.location { nextBoundary += 1 }
      guard nextBoundary < edges.count else { return false }
      let next = edges[nextBoundary]
      searchRange = NSRange(location: next, length: native.length - next)
    }
    return false
  }
}
