import Foundation

/// Pure phrase-localisation shared by the word-capture backends. Given the
/// full captured text, the phrase the LLM returned as the sense group, and
/// the cursor anchor, it finds the UTF-16 range of the occurrence the user
/// actually pointed at — not merely the first textual match.
///
/// This is the duplicate-word disambiguation that shipped in 0.3.0, lifted
/// out of the (now retired) AX reader so the OCR backend reuses it verbatim.
/// Everything here is platform-free and unit-testable: offsets are UTF-16
/// units into the haystack, matching `String.utf16` indexing.
///
/// Ranking policy (carried over unchanged):
///   - When a `positionAnchor` (the 3-word verbatim LLM `position` field,
///     already localised in the haystack) is supplied, cover = ANY
///     character-level overlap with that range; ties break by range-to-range
///     distance.
///   - Otherwise cover = the match fully contains the single-word anchor;
///     ties break by match-start vs. word-start distance.
public enum PhraseLocator {
    /// Two-stage locate: exact substring first, normalized fuzzy fallback.
    /// Returns the best-aligned occurrence as a UTF-16 range, or nil when the
    /// phrase doesn't appear at all.
    public static func locate(
        phrase: String,
        in haystack: String,
        wordAnchor: Range<Int>,
        positionAnchor: Range<Int>? = nil
    ) -> Range<Int>? {
        if let exact = locateExact(
            phrase: phrase,
            haystack: haystack,
            wordAnchor: wordAnchor,
            positionAnchor: positionAnchor
        ) {
            return exact
        }
        return locateFuzzy(
            phrase: phrase,
            haystack: haystack,
            wordAnchor: wordAnchor,
            positionAnchor: positionAnchor
        )
    }

    /// Locate the verbatim `position` substring inside `haystack`.
    ///   - Appears once → that range.
    ///   - Appears multiple times → the match fully containing
    ///     `fallbackWordRange` (the single-word anchor). When none contain it,
    ///     nil so the caller falls back to the single-word anchor path.
    public static func locatePosition(
        _ position: String,
        in haystack: String,
        fallbackWordRange: Range<Int>?
    ) -> Range<Int>? {
        let haystackCount = haystack.utf16.count
        guard haystackCount > 0 else { return nil }
        let positionCount = position.utf16.count
        guard positionCount > 0, positionCount <= haystackCount else { return nil }

        let starts = allExactMatchStarts(of: position, in: haystack)
        guard !starts.isEmpty else { return nil }

        if starts.count == 1 {
            let s = starts[0]
            return s..<(s + positionCount)
        }

        guard let fallback = fallbackWordRange,
              fallback.lowerBound < fallback.upperBound else {
            return nil
        }
        for s in starts {
            let end = s + positionCount
            if s <= fallback.lowerBound && end >= fallback.upperBound {
                return s..<end
            }
        }
        return nil
    }

    // MARK: - Exact / fuzzy stages

    private static func locateExact(
        phrase: String,
        haystack: String,
        wordAnchor: Range<Int>,
        positionAnchor: Range<Int>?
    ) -> Range<Int>? {
        let haystackCount = haystack.utf16.count
        guard haystackCount > 0 else { return nil }
        let phraseCount = phrase.utf16.count
        guard phraseCount > 0, phraseCount <= haystackCount else { return nil }

        let starts = allExactMatchStarts(of: phrase, in: haystack)
        guard !starts.isEmpty else { return nil }

        let ranges = starts.map { $0..<($0 + phraseCount) }
        if let positionAnchor {
            return pickBestRange(matches: ranges, positionAnchor: positionAnchor)
        }
        return pickBestRange(matches: ranges, wordAnchor: wordAnchor)
    }

    /// Normalize both strings (lowercase, collapse whitespace runs to a single
    /// space, strip ASCII punctuation), search again, then map every
    /// normalized match back to its original UTF-16 range via the index map
    /// and rank with the same rules as the exact stage.
    private static func locateFuzzy(
        phrase: String,
        haystack: String,
        wordAnchor: Range<Int>,
        positionAnchor: Range<Int>?
    ) -> Range<Int>? {
        let normalizedPhrase = normalize(phrase)
        guard !normalizedPhrase.text.isEmpty else { return nil }

        let normalizedHaystack = normalize(haystack)
        guard !normalizedHaystack.text.isEmpty,
              normalizedPhrase.text.utf16.count <= normalizedHaystack.text.utf16.count else {
            return nil
        }

        let needleCount = normalizedPhrase.text.utf16.count
        let normalizedStarts = allExactMatchStarts(
            of: normalizedPhrase.text,
            in: normalizedHaystack.text
        )
        guard !normalizedStarts.isEmpty else { return nil }

        let haystackCount = haystack.utf16.count
        var originalRanges: [Range<Int>] = []
        originalRanges.reserveCapacity(normalizedStarts.count)
        for normStart in normalizedStarts {
            let normEnd = normStart + needleCount
            guard normStart >= 0, normStart < normalizedHaystack.indexMap.count,
                  normEnd > 0, normEnd <= normalizedHaystack.indexMap.count else {
                continue
            }
            let originalStart = normalizedHaystack.indexMap[normStart]
            let originalEnd: Int
            if normEnd - 1 < normalizedHaystack.indexMap.count {
                originalEnd = normalizedHaystack.indexMap[normEnd - 1] + 1
            } else {
                originalEnd = haystackCount
            }
            guard originalEnd > originalStart else { continue }
            originalRanges.append(originalStart..<originalEnd)
        }
        if let positionAnchor {
            return pickBestRange(matches: originalRanges, positionAnchor: positionAnchor)
        }
        return pickBestRange(matches: originalRanges, wordAnchor: wordAnchor)
    }

    // MARK: - Matching primitives

    /// All start offsets where `needle` occurs in `haystack`, comparing UTF-16
    /// units directly so combining sequences / pre-composed forms aren't
    /// folded together. Reports overlapping matches.
    public static func allExactMatchStarts(of needle: String, in haystack: String) -> [Int] {
        let hay = Array(haystack.utf16)
        let pat = Array(needle.utf16)
        guard !pat.isEmpty, hay.count >= pat.count else { return [] }

        var out: [Int] = []
        let limit = hay.count - pat.count
        var i = 0
        while i <= limit {
            var matched = true
            for j in 0..<pat.count where hay[i + j] != pat[j] {
                matched = false
                break
            }
            if matched { out.append(i) }
            i += 1
        }
        return out
    }

    /// Cover beats distance: a match whose range fully covers the anchor word
    /// always wins. Among non-covering matches, nearest match-start to
    /// anchor-start wins.
    public static func pickBestRange(matches: [Range<Int>], wordAnchor anchor: Range<Int>) -> Range<Int>? {
        guard !matches.isEmpty else { return nil }

        for m in matches where m.lowerBound <= anchor.lowerBound && m.upperBound >= anchor.upperBound {
            return m
        }

        var best = matches[0]
        var bestDistance = abs(best.lowerBound - anchor.lowerBound)
        for m in matches.dropFirst() {
            let d = abs(m.lowerBound - anchor.lowerBound)
            if d < bestDistance {
                best = m
                bestDistance = d
            }
        }
        return best
    }

    /// Cover = any character-level overlap with the position anchor range.
    /// Among non-overlapping matches, the one whose range is closest (gap
    /// distance) to the anchor wins.
    public static func pickBestRange(matches: [Range<Int>], positionAnchor anchor: Range<Int>) -> Range<Int>? {
        guard !matches.isEmpty else { return nil }

        for m in matches where m.lowerBound < anchor.upperBound && anchor.lowerBound < m.upperBound {
            return m
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

    /// UTF-16 gap between a match range and an anchor range. 0 if they touch
    /// or overlap, positive otherwise.
    private static func rangeDistance(match: Range<Int>, anchor: Range<Int>) -> Int {
        if match.upperBound <= anchor.lowerBound {
            return anchor.lowerBound - match.upperBound
        }
        if match.lowerBound >= anchor.upperBound {
            return match.lowerBound - anchor.upperBound
        }
        return 0
    }

    // MARK: - Normalisation

    struct NormalizedString {
        let text: String
        /// One entry per normalized UTF-16 unit → that unit's source UTF-16
        /// offset, so a normalized match maps back to the original range.
        let indexMap: [Int]
    }

    static func normalize(_ source: String) -> NormalizedString {
        var out = ""
        out.reserveCapacity(source.utf16.count)
        var map: [Int] = []
        map.reserveCapacity(source.utf16.count)

        var sourceIndex = 0
        var lastWasSpace = false
        for unit in source.unicodeScalars {
            let unitLength = unit.utf16.count
            defer { sourceIndex += unitLength }

            // Any Unicode whitespace OR ASCII punctuation is a collapsible
            // separator. ASCII-only punctuation on purpose: CJK punctuation
            // may be load-bearing inside a sense-group phrase.
            let isSeparator: Bool
            if unit.properties.isWhitespace {
                isSeparator = true
            } else if unit.isASCII && isASCIIPunctuation(UInt8(unit.value)) {
                isSeparator = true
            } else {
                isSeparator = false
            }

            if isSeparator {
                if !lastWasSpace, !out.isEmpty {
                    out.append(" ")
                    map.append(sourceIndex)
                    lastWasSpace = true
                }
                continue
            }

            let lowered = String(unit).lowercased()
            for u in lowered.utf16 {
                if let scalar = Unicode.Scalar(u) {
                    out.unicodeScalars.append(scalar)
                } else {
                    out.append(" ")
                }
                map.append(sourceIndex)
            }
            lastWasSpace = false
        }

        if out.hasSuffix(" ") {
            out.removeLast()
            if !map.isEmpty { map.removeLast() }
        }
        return NormalizedString(text: out, indexMap: map)
    }

    private static func isASCIIPunctuation(_ byte: UInt8) -> Bool {
        switch byte {
        case 33...47, 58...64, 91...96, 123...126:
            return true
        default:
            return false
        }
    }
}
