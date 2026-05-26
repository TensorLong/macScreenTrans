import CoreGraphics
import Foundation
import Testing
@testable import MacScreenTransCore

// MARK: - Phrase range-matcher contract
//
// AXWordReader's pickBestRange (range-anchor variant) and locatePositionRange
// live in the executable target and aren't importable from this test target.
// To pin the algorithmic contract — and catch silent drift in the AX-side
// implementation during review — this file ports the same pure-logic
// algorithm verbatim and exercises it across the three required cases:
//
//   1. cover-success           — a source_chunk match that overlaps the
//                                position anchor wins outright.
//   2. cover-failure-nearest   — when no match overlaps, the match closest
//                                in UTF-16 range-distance wins.
//   3. multi-position-disamb.  — when `position` appears multiple times in
//                                elementText, the one containing the AX
//                                single-word range wins; if none contain
//                                it, the function returns nil and the
//                                caller falls back to the legacy single-
//                                word anchor path.
//
// The mirror is intentionally a direct copy. Any future change to the
// AXWordReader algorithm must reflect here too; reviewers comparing the
// two files will see the drift.

private enum RangeMatcherMirror {
    /// Mirror of `AXWordReader.allExactMatchStarts`.
    static func allExactMatchStarts(of needle: String, in haystack: String) -> [Int] {
        let needleU = Array(needle.utf16)
        let hayU = Array(haystack.utf16)
        guard !needleU.isEmpty, hayU.count >= needleU.count else { return [] }
        var out: [Int] = []
        let limit = hayU.count - needleU.count
        var i = 0
        while i <= limit {
            var matched = true
            for j in 0..<needleU.count {
                if hayU[i + j] != needleU[j] { matched = false; break }
            }
            if matched { out.append(i) }
            i += 1
        }
        return out
    }

    /// Mirror of `AXWordReader.locatePositionRange`.
    static func locatePositionRange(
        _ position: String,
        in elementText: String,
        fallbackWordRange: Range<Int>?
    ) -> Range<Int>? {
        let positionU = position.utf16.count
        guard positionU > 0, positionU <= elementText.utf16.count else { return nil }
        let starts = allExactMatchStarts(of: position, in: elementText)
        guard !starts.isEmpty else { return nil }
        if starts.count == 1 {
            let s = starts[0]
            return s..<(s + positionU)
        }
        guard let fallback = fallbackWordRange,
              fallback.lowerBound < fallback.upperBound else {
            return nil
        }
        for s in starts {
            let end = s + positionU
            if s <= fallback.lowerBound && end >= fallback.upperBound {
                return s..<end
            }
        }
        return nil
    }

    /// Mirror of `AXWordReader.pickBestRange(matches:positionAnchor:)`. Uses
    /// `Range<Int>` (start, length) tuples instead of CFRange for portability
    /// to the core test target.
    static func pickBestRange(matches: [Range<Int>], positionAnchor anchor: Range<Int>) -> Range<Int>? {
        guard !matches.isEmpty else { return nil }
        for m in matches {
            if m.lowerBound < anchor.upperBound && anchor.lowerBound < m.upperBound {
                return m
            }
        }
        var best = matches[0]
        var bestDistance = rangeDistance(match: best, anchor: anchor)
        for m in matches.dropFirst() {
            let d = rangeDistance(match: m, anchor: anchor)
            if d < bestDistance {
                best = m
                bestDistance = d
            }
        }
        return best
    }

    private static func rangeDistance(match: Range<Int>, anchor: Range<Int>) -> Int {
        if match.upperBound <= anchor.lowerBound { return anchor.lowerBound - match.upperBound }
        if match.lowerBound >= anchor.upperBound { return match.lowerBound - anchor.upperBound }
        return 0
    }
}

// MARK: - cover-success

@Test func pickBestRangeCoverSucceedsWhenSourceChunkOverlapsPosition() {
    // The position window is "keep plan status" in the middle of the
    // bullet. Three candidate source_chunks: an early "plan is" (before
    // the position), the overlapping "plan status updates" (overlaps
    // position chars), and the tail "the plan" (after the position).
    // Only the middle candidate overlaps the position anchor, so cover
    // picks it outright.
    let elementText = "Make sure plan is good, keep plan status updates in a file, update the plan"
    let positionStart = elementText.utf16Offset(of: "keep plan status")
    let positionRange = positionStart..<(positionStart + "keep plan status".utf16.count)

    let matches: [Range<Int>] = [
        rangeOf("plan is", in: elementText),
        rangeOf("plan status updates", in: elementText),
        rangeOf("the plan", in: elementText)
    ]

    let pick = RangeMatcherMirror.pickBestRange(matches: matches, positionAnchor: positionRange)
    let chosen = elementText.utf16Slice(pick!)
    #expect(chosen == "plan status updates")
}

// MARK: - cover-failure-nearest

@Test func pickBestRangeFallsBackToNearestWhenNoMatchOverlapsPosition() {
    // No source_chunk candidate overlaps the position window. The
    // nearest-by-range-distance match must win. Position covers chars
    // 11..<30 ("gamma delta epsilon"). Distances for the three candidates:
    //   "alpha beta" = 0..<10  → 11 - 10 = 1 (closest)
    //   "eta"        = 36..<39 → 36 - 30 = 6
    //   "iota"       = 46..<50 → 46 - 30 = 16
    // The nearest fallback picks "alpha beta".
    let elementText = "alpha beta gamma delta epsilon zeta eta theta iota"
    let position = rangeOf("gamma delta epsilon", in: elementText)
    let matches: [Range<Int>] = [
        rangeOf("alpha beta", in: elementText),
        rangeOf("eta", in: elementText),
        rangeOf("iota", in: elementText)
    ]

    let pick = RangeMatcherMirror.pickBestRange(matches: matches, positionAnchor: position)
    let chosen = elementText.utf16Slice(pick!)
    #expect(chosen == "alpha beta")
}

// MARK: - locatePositionRange disambiguates by AX word range

@Test func locatePositionRangePicksOccurrenceContainingAXWordRange() {
    // The 3-word position string "the plan" only happens to appear once
    // when truly verbatim. Construct a synthetic case with TWO verbatim
    // occurrences of "set the timer" inside elementText. The user's AX
    // single-word anchor is the SECOND "timer" — locatePositionRange must
    // return the second occurrence, not the first.
    let elementText = "set the timer in the morning, then set the timer at night"
    let secondTimerStart = elementText.utf16Offset(of: "timer at night")
    let secondTimerEnd = secondTimerStart + "timer".utf16.count

    let result = RangeMatcherMirror.locatePositionRange(
        "set the timer",
        in: elementText,
        fallbackWordRange: secondTimerStart..<secondTimerEnd
    )
    let chosen = elementText.utf16Slice(result!)
    #expect(chosen == "set the timer")
    // The chosen range must be the second occurrence — verify by start
    // offset. The first occurrence starts at 0.
    #expect(result!.lowerBound > 0)
}

@Test func locatePositionRangeReturnsNilWhenMultipleMatchesAndNoneContainsWord() {
    // Two verbatim "set the timer" occurrences, but the AX word anchor
    // points at a "timer" NOT inside either match (synthetic edge case
    // — e.g. a third "timer" appears outside any "set the timer"
    // window). Function returns nil so the caller falls back to the
    // legacy single-word-anchor path.
    let elementText = "set the timer once. set the timer twice. and a lone timer."
    let loneTimerStart = elementText.utf16Offset(of: "lone timer") + "lone ".utf16.count
    let loneTimerEnd = loneTimerStart + "timer".utf16.count

    let result = RangeMatcherMirror.locatePositionRange(
        "set the timer",
        in: elementText,
        fallbackWordRange: loneTimerStart..<loneTimerEnd
    )
    #expect(result == nil)
}

@Test func locatePositionRangeReturnsExactRangeWhenOnlyOneOccurrence() {
    let elementText = "Make sure the plan is *immutable*, keep plan status updates in a file"
    let position = "keep plan status"
    let result = RangeMatcherMirror.locatePositionRange(
        position,
        in: elementText,
        fallbackWordRange: nil
    )
    let chosen = elementText.utf16Slice(result!)
    #expect(chosen == position)
}

// MARK: - Helpers

private extension String {
    func utf16Offset(of needle: String) -> Int {
        let range = self.range(of: needle)!
        return range.lowerBound.samePosition(in: self.utf16)!.utf16Offset(in: self)
    }

    func utf16Slice(_ range: Range<Int>) -> String {
        let start = self.utf16.index(self.utf16.startIndex, offsetBy: range.lowerBound)
        let end = self.utf16.index(self.utf16.startIndex, offsetBy: range.upperBound)
        return String(self.utf16[start..<end]) ?? ""
    }
}

/// First-occurrence `range(of:)` helper that returns a `Range<Int>` in
/// UTF-16 coordinates. Crashes on miss — only used inside tests where the
/// needle is guaranteed to appear.
private func rangeOf(_ needle: String, in haystack: String) -> Range<Int> {
    guard let r = haystack.range(of: needle) else {
        fatalError("needle '\(needle)' not found in '\(haystack)'")
    }
    let lo = r.lowerBound.samePosition(in: haystack.utf16)!.utf16Offset(in: haystack)
    let hi = r.upperBound.samePosition(in: haystack.utf16)!.utf16Offset(in: haystack)
    return lo..<hi
}
