import AppKit
import ApplicationServices
import MacScreenTransCore
import os.log

private let logger = Logger(subsystem: "com.longmac.MacScreenTrans", category: "AXWordReader")

enum AXWordReader {
    struct PhraseSegment {
        /// The rect for this segment of the phrase in AppKit screen coords —
        /// same convention as `Result.wordRect`.
        let rect: NSRect
        /// The substring of the phrase that occupies this rect. For a
        /// single-line phrase this is the full phrase; for a multi-line
        /// phrase each line's slice is returned in a separate segment.
        let text: String
    }

    /// Opaque handle that captures everything we need to resolve phrase rects
    /// AFTER the original `resolve(at:)` call returned. We hold on to the
    /// concrete AXUIElement plus the element's full text and the offset where
    /// the resolved `selection.context` lives inside that text — that triple
    /// is what `phraseSegments(for:)` needs to map a phrase string back into
    /// a CFRange the AX layer can answer geometry queries about.
    fileprivate struct PhraseLookup {
        /// The AX element that we resolved the word against. Same element
        /// AXWordReader.resolve() finally settled on — could be the hit
        /// element or one of its ancestors.
        let element: AXUIElement
        /// The element's full text content. May come from `kAXValue` or from
        /// stitching `kAXStringForRange` calls — we store the same string
        /// whose UTF-16 offsets are valid inputs to `kAXBoundsForRange`.
        let elementText: String
        /// The absolute UTF-16 offset where the resolved `WordSelection.context`
        /// begins within `elementText`. 0 when context came from `kAXValue`
        /// (context == elementText). Non-zero when we obtained context via
        /// `kAXStringForRange` over a sub-window.
        let contextOffsetInElement: Int
    }

    struct Result {
        let selection: WordSelection
        /// The word's on-screen rect in AppKit coordinates, or nil when the
        /// underlying element doesn't implement `kAXBoundsForRangeParameterizedAttribute`
        /// (image PDFs, custom-drawn UIs, some web views).
        let wordRect: NSRect?
        /// Internal — opaque handle for follow-up phrase lookups. Callers
        /// should call `phraseSegments(for:)` rather than touching this.
        fileprivate let phraseLookup: PhraseLookup?

        /// Returns one segment per visual line that `phrase` occupies inside
        /// the AX element this Result was resolved from. Returns `[]` when
        /// the phrase can't be located, or when AX context is no longer
        /// available (pass-3 fallback path / image-only views).
        ///
        /// Strategy:
        ///   1. Try to locate `phrase` as an exact substring (first inside
        ///      `selection.context`, then inside the full element text).
        ///   2. If exact fails, retry with a normalized (lower / collapsed
        ///      whitespace / stripped punctuation) match, mapping the result
        ///      back to the original UTF-16 range.
        ///   3. Per-character scan the matched UTF-16 range and Y-cluster
        ///      the rects into visual lines. We avoid `kAXLineForIndex` /
        ///      `kAXRangeForLine` because WebKit doesn't implement them —
        ///      that path silently returned the enclosing rect for multi-
        ///      line ranges in v0.2 and made the green band engulf entire
        ///      paragraphs (Issue 1).
        ///   4. If the per-character scan returns nothing, fall back to a
        ///      single `boundsForRange` rect, sanity-checked against a
        ///      single-char probe to refuse paragraph-tall rects.
        func phraseSegments(for phrase: String) -> [PhraseSegment] {
            AXWordReader.phraseSegments(for: phrase, lookup: phraseLookup, selection: selection)
        }
    }

    /// Human-readable trace of the most recent `resolve(at:)` call. When
    /// `resolve` returns nil, AppDelegate appends this string to the popup
    /// so the user can see WHERE the resolve pipeline gave up — without
    /// needing to read system logs. Set under `MainActor` from the popup
    /// flow only; treat as advisory not authoritative.
    nonisolated(unsafe) private(set) static var lastDiagnostic: String = ""

    static func selection(at appKitPoint: CGPoint, radius: Int = 200) -> WordSelection? {
        resolve(at: appKitPoint, radius: radius)?.selection
    }

    static func resolve(at appKitPoint: CGPoint, radius: Int = 200) -> Result? {
        var diag: [String] = []
        defer { lastDiagnostic = diag.joined(separator: "\n") }

        diag.append("appKit=(\(Int(appKitPoint.x)), \(Int(appKitPoint.y)))")
        let axPoint = accessibilityPoint(from: appKitPoint)
        diag.append("axPoint=(\(Int(axPoint.x)), \(Int(axPoint.y)))")
        logger.debug("resolve: appKit=(\(Int(appKitPoint.x)),\(Int(appKitPoint.y))) ax=(\(Int(axPoint.x)),\(Int(axPoint.y)))")

        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let elementError = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &hitElement
        )
        guard elementError == .success, let initial = hitElement else {
            diag.append("FAIL: AXUIElementCopyElementAtPosition err=\(elementError.rawValue)")
            logger.warning("resolve FAIL: copyElementAtPosition err=\(elementError.rawValue)")
            return nil
        }
        diag.append("hit=\(elementRole(initial) ?? "?")")

        guard let (element, pointedRange) = resolveTextElementAndRange(
            from: initial,
            point: axPoint,
            diag: &diag
        ) else {
            diag.append("FAIL: no text element / range")
            logger.warning("resolve FAIL: no text element resolved")
            return nil
        }
        diag.append("range=loc=\(pointedRange.location) len=\(pointedRange.length) on=\(elementRole(element) ?? "?")")

        let selection: WordSelection
        var wordUTF16Range = CFRange(location: pointedRange.location, length: max(pointedRange.length, 1))
        // The element's full string + the absolute offset where the resolved
        // context lives inside it. Populated by whichever branch produced
        // the selection. Stays nil when no text path applied.
        var lookupElementText: String?
        var lookupContextOffset: Int = 0

        if let text = stringAttribute(element: element, attribute: kAXValueAttribute as String),
           let resolved = wordSelectionAround(
            text: text,
            utf16Offset: pointedRange.location,
            radius: radius
           ) {
            selection = resolved.selection
            let wordStart = absoluteWordStartUTF16Offset(
                in: text,
                pointedOffset: resolved.offset,
                word: resolved.selection.word
            ) ?? resolved.offset
            wordUTF16Range = CFRange(location: wordStart, length: resolved.selection.word.utf16.count)
            // selection.context is a substring of `text`; recover the
            // context's absolute start by subtracting the word's relative
            // offset within context from its absolute offset within text.
            lookupElementText = text
            lookupContextOffset = max(
                0,
                wordStart - resolved.selection.wordRangeInContext.lowerBound
            )
            diag.append("word=\"\(resolved.selection.word)\" via kAXValue (offset \(resolved.offset))")
        } else {
            let lower = max(0, pointedRange.location - radius)
            let length = radius * 2 + max(pointedRange.length, 1)
            guard let context = stringForRange(element: element, location: lower, length: length),
                  let resolved = wordSelectionAround(
                    text: context,
                    utf16Offset: max(0, pointedRange.location - lower),
                    radius: radius
                  ) else {
                diag.append("FAIL: kAXValue+kAXStringForRange both empty after walking near offset")
                logger.warning("resolve FAIL: no text content")
                return nil
            }
            selection = resolved.selection
            wordUTF16Range = CFRange(
                location: lower + resolved.selection.wordRangeInContext.lowerBound,
                length: resolved.selection.word.utf16.count
            )
            // The element doesn't expose its full text via kAXValue — we
            // only have a window obtained from `kAXStringForRange`. Treat
            // the window itself as our "element text" for phrase searches.
            // The word lives at offset `wordRangeInContext.lowerBound`
            // within `selection.context`, which is a substring of `context`
            // (the window). Phrase queries outside the window will miss,
            // but the window already covers ±radius around the word —
            // wider than typical sense groups.
            lookupElementText = context
            // Find the actual offset of the WordSelection.context substring
            // within the window. Falls back to 0 when the substring isn't
            // located exactly (shouldn't happen — extractor guarantees it).
            if let range = context.range(of: resolved.selection.context) {
                let offset = context.utf16.distance(
                    from: context.utf16.startIndex,
                    to: range.lowerBound.samePosition(in: context.utf16) ?? context.utf16.startIndex
                )
                lookupContextOffset = max(0, offset)
            } else {
                lookupContextOffset = 0
            }
            diag.append("word=\"\(resolved.selection.word)\" via kAXStringForRange (offset \(resolved.offset))")
        }

        let wordRect = resolveWordRect(
            element: element,
            range: wordUTF16Range,
            elementText: lookupElementText,
            cursorAxPoint: axPoint,
            diag: &diag
        )
        diag.append("wordRect=\(wordRect.map { "(\(Int($0.minX)),\(Int($0.minY))) \(Int($0.width))×\(Int($0.height))" } ?? "nil")")
        logger.debug("resolve OK: word=\"\(selection.word)\"")

        // Build the phrase-lookup handle when we have any text to search.
        // For the `kAXStringForRange` path we stored the window text; offsets
        // inside `elementText` aren't element-absolute, so phrase queries on
        // that path operate within the window only. Good enough for typical
        // sense-group phrases (the window already covers ±radius around the
        // word, which is almost always wider than the LLM's sense group).
        let lookup: PhraseLookup?
        if let lookupElementText {
            lookup = PhraseLookup(
                element: element,
                elementText: lookupElementText,
                contextOffsetInElement: lookupContextOffset
            )
        } else {
            lookup = nil
        }
        return Result(selection: selection, wordRect: wordRect, phraseLookup: lookup)
    }

    // MARK: - Phrase segments

    fileprivate static func phraseSegments(
        for phrase: String,
        lookup: PhraseLookup?,
        selection: WordSelection
    ) -> [PhraseSegment] {
        var diag: [String] = []
        defer {
            if !diag.isEmpty {
                let joined = "phrase=\"\(phrase)\" " + diag.joined(separator: " ")
                if lastDiagnostic.isEmpty {
                    lastDiagnostic = joined
                } else {
                    lastDiagnostic += "\n" + joined
                }
            }
        }

        guard !phrase.isEmpty else {
            diag.append("hit=empty-input")
            return []
        }
        guard let lookup else {
            diag.append("hit=no-lookup")
            return []
        }

        // Step 1: locate `phrase` as a UTF-16 range inside `lookup.elementText`.
        // Two-stage: exact substring (preferring the context window), then
        // normalized fuzzy match.
        let phraseRange: CFRange
        let hitKind: String
        if let exact = locateExactRange(
            phrase: phrase,
            elementText: lookup.elementText,
            preferStart: lookup.contextOffsetInElement,
            preferLength: selection.context.utf16.count
        ) {
            phraseRange = exact
            hitKind = "exact"
        } else if let fuzzy = locateFuzzyRange(
            phrase: phrase,
            elementText: lookup.elementText
        ) {
            phraseRange = fuzzy
            hitKind = "fuzzy"
        } else {
            diag.append("hit=miss")
            return []
        }
        diag.append("hit=\(hitKind)")
        diag.append("range=loc=\(phraseRange.location) len=\(phraseRange.length)")

        // Step 2: split per visual line by Y-clustering per-character bounds.
        // This works on WebKit too, where the older kAXLineForIndex /
        // kAXRangeForLine path silently returned the enclosing rect for
        // multi-line ranges (Issue 1).
        if let segments = perLineSegments(
            element: lookup.element,
            elementText: lookup.elementText,
            phraseRange: phraseRange
        ), !segments.isEmpty {
            // Sanity-check: if the segment heights are wildly inconsistent
            // with each other, AX returned garbage. Compare the union height
            // to the median per-segment height; a ratio > 2.5 means at least
            // one segment is enclosing the whole multi-line range. Refuse
            // green in that case rather than draw a paragraph-sized bubble.
            let sortedHeights = segments.map(\.rect.height).sorted()
            let medianHeight = sortedHeights[sortedHeights.count / 2]
            var unionRect = segments[0].rect
            for s in segments.dropFirst() { unionRect = unionRect.union(s.rect) }
            if medianHeight > 0, unionRect.height > 2.5 * medianHeight,
               segments.count == 1 {
                diag.append("lines=reject(single tall seg \(Int(unionRect.height))pt > 2.5× median \(Int(medianHeight))pt)")
                return []
            }
            diag.append("lines=\(segments.count) segs=\(segments.count)")
            return segments
        }

        // Fallback: a single bubble covering the whole phrase rect. Looks
        // identical to per-line for single-line phrases; lumps multi-line
        // phrases into one tall box. Before accepting it, probe a single
        // character at the phrase start to estimate the line height — if
        // the whole-phrase rect is more than 2.5× that, AX is giving us a
        // multi-line enclosing rect and we'd draw a paragraph-sized bubble.
        // Refuse in that case (Issue 1 belt-and-suspenders).
        if let rect = boundsForRange(element: lookup.element, range: phraseRange) {
            let probe = boundsForRange(
                element: lookup.element,
                range: CFRange(location: phraseRange.location, length: 1)
            )
            if let probe, probe.height > 0, rect.height > 2.5 * probe.height {
                diag.append("lines=reject-fallback(whole \(Int(rect.height))pt > 2.5× probe \(Int(probe.height))pt)")
                return []
            }
            let text = substring(of: lookup.elementText, utf16Range: phraseRange) ?? phrase
            diag.append("lines=fallback segs=1")
            return [PhraseSegment(rect: rect, text: text)]
        }

        diag.append("lines=none segs=0")
        return []
    }

    /// Try exact substring search. We prefer hits that fall inside the original
    /// context window (so we anchor against the sense group the user actually
    /// pointed at, not a different occurrence elsewhere in a long doc).
    private static func locateExactRange(
        phrase: String,
        elementText: String,
        preferStart: Int,
        preferLength: Int
    ) -> CFRange? {
        let elementUTF16Count = elementText.utf16.count
        guard elementUTF16Count > 0 else { return nil }

        let phraseUTF16Count = phrase.utf16.count
        guard phraseUTF16Count > 0, phraseUTF16Count <= elementUTF16Count else { return nil }

        // Search within the context window first — clamp inputs so an
        // overlong/negative preferStart doesn't blow up the substring math.
        let windowStart = max(0, min(preferStart, elementUTF16Count))
        let windowEnd = max(windowStart, min(elementUTF16Count, preferStart + max(preferLength, 0)))
        if windowEnd > windowStart,
           let window = substring(of: elementText, utf16Range: CFRange(location: windowStart, length: windowEnd - windowStart)),
           let relative = window.range(of: phrase) {
            let relativeOffset = window.utf16.distance(from: window.utf16.startIndex, to: relative.lowerBound.samePosition(in: window.utf16) ?? window.utf16.startIndex)
            return CFRange(location: windowStart + relativeOffset, length: phraseUTF16Count)
        }

        // Fall back to whole-element search.
        if let match = elementText.range(of: phrase) {
            let offset = elementText.utf16.distance(from: elementText.utf16.startIndex, to: match.lowerBound.samePosition(in: elementText.utf16) ?? elementText.utf16.startIndex)
            return CFRange(location: offset, length: phraseUTF16Count)
        }
        return nil
    }

    /// Normalize both haystack and needle (lowercase, collapse whitespace
    /// runs to a single space, strip ASCII punctuation) and search again.
    /// When a normalized match exists, walk the original-index map we built
    /// during normalization to recover a CFRange in the ORIGINAL UTF-16
    /// coordinate system.
    private static func locateFuzzyRange(
        phrase: String,
        elementText: String
    ) -> CFRange? {
        let normalizedPhrase = normalize(phrase)
        guard !normalizedPhrase.text.isEmpty else { return nil }

        let normalizedElement = normalize(elementText)
        guard !normalizedElement.text.isEmpty,
              normalizedPhrase.text.count <= normalizedElement.text.count else {
            return nil
        }

        guard let hit = normalizedElement.text.range(of: normalizedPhrase.text) else {
            return nil
        }
        let normStart = normalizedElement.text.utf16.distance(
            from: normalizedElement.text.utf16.startIndex,
            to: hit.lowerBound.samePosition(in: normalizedElement.text.utf16) ?? normalizedElement.text.utf16.startIndex
        )
        let normEnd = normalizedElement.text.utf16.distance(
            from: normalizedElement.text.utf16.startIndex,
            to: hit.upperBound.samePosition(in: normalizedElement.text.utf16) ?? normalizedElement.text.utf16.startIndex
        )
        guard normStart < normalizedElement.indexMap.count,
              normEnd > 0,
              normEnd <= normalizedElement.indexMap.count else {
            return nil
        }

        // Map normalized offsets back to original UTF-16 offsets. The
        // index map has one entry per normalized UTF-16 unit, pointing to
        // its origin in the source text. End index uses the last consumed
        // unit + 1 (or clamps to elementText length).
        let originalStart = normalizedElement.indexMap[normStart]
        let originalEnd: Int
        if normEnd - 1 < normalizedElement.indexMap.count {
            originalEnd = normalizedElement.indexMap[normEnd - 1] + 1
        } else {
            originalEnd = elementText.utf16.count
        }
        let length = max(0, originalEnd - originalStart)
        guard length > 0 else { return nil }
        return CFRange(location: originalStart, length: length)
    }

    /// Normalization output: the cleaned string plus a parallel array mapping
    /// each normalized UTF-16 unit back to its source UTF-16 offset in the
    /// original `elementText`.
    private struct NormalizedString {
        let text: String
        let indexMap: [Int]
    }

    private static func normalize(_ source: String) -> NormalizedString {
        var out = ""
        out.reserveCapacity(source.utf16.count)
        var map: [Int] = []
        map.reserveCapacity(source.utf16.count)

        var sourceIndex = 0
        var lastWasSpace = false
        for unit in source.unicodeScalars {
            let unitLength = unit.utf16.count
            defer { sourceIndex += unitLength }
            // Treat any Unicode whitespace OR ASCII punctuation as a
            // collapsible separator. ASCII-only punctuation is on purpose:
            // we don't want to strip CJK punctuation in case it's actually
            // load-bearing in the sense-group phrase.
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

            // Lowercase via the scalar's own lowercase mapping. Append
            // each resulting UTF-16 unit and pin its origin back to this
            // input scalar's start offset.
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

        // Trim trailing collapsed space.
        if out.hasSuffix(" ") {
            out.removeLast()
            if !map.isEmpty {
                map.removeLast()
            }
        }
        return NormalizedString(text: out, indexMap: map)
    }

    private static func isASCIIPunctuation(_ byte: UInt8) -> Bool {
        // ASCII range 33...47, 58...64, 91...96, 123...126 covers the visible
        // ASCII punctuation we want to collapse.
        switch byte {
        case 33...47, 58...64, 91...96, 123...126:
            return true
        default:
            return false
        }
    }

    /// Slice an Element-text UTF-16 range out as a Swift String.
    private static func substring(of source: String, utf16Range: CFRange) -> String? {
        let total = source.utf16.count
        guard utf16Range.location >= 0,
              utf16Range.length >= 0,
              utf16Range.location + utf16Range.length <= total else {
            return nil
        }
        let start = source.utf16.index(source.utf16.startIndex, offsetBy: utf16Range.location)
        let end = source.utf16.index(start, offsetBy: utf16Range.length)
        return String(source.utf16[start..<end])
    }

    /// Resolve the on-screen rect for `range` with three escalating
    /// fallbacks. The plain `boundsForRange` call alone returns nil on
    /// soft-wrap edges, zero-width spaces, and certain web glyphs — that
    /// nil was the root cause of the yellow box randomly disappearing in
    /// v0.2 (Issue 3) while the green band still rendered.
    ///
    /// Path 1: fast `boundsForRange(range)`, sanity-checked against the
    ///         height of a single-char probe at the range start. Rejects
    ///         the WebKit "multi-line enclosing rect" case where a word
    ///         straddles a wrap and AX hands back a tall paragraph rect.
    /// Path 2: scan per-character rects across the range, Y-cluster, return
    ///         the union of the cluster nearest the cursor. Handles the
    ///         normal soft-wrap case and zero-width-space glyphs.
    /// Path 3: probe ±20 UTF-16 units around the word range looking for
    ///         the first char that has any bounds at all, return its rect.
    ///         Implements "find nearest word" so yellow lands on the
    ///         visually-adjacent glyph rather than disappearing.
    private static func resolveWordRect(
        element: AXUIElement,
        range: CFRange,
        elementText: String?,
        cursorAxPoint: CGPoint,
        diag: inout [String]
    ) -> NSRect? {
        guard range.length > 0 else { return nil }

        // Compare cursor against AppKit-flipped rects coming out of
        // `boundsForRange`. The class-level `accessibilityPoint(from:)`
        // does AppKit→Quartz; the inverse uses the same primary-screen
        // anchor.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let cursorAppKit: CGPoint
        if let primary {
            cursorAppKit = CGPoint(x: cursorAxPoint.x, y: primary.frame.maxY - cursorAxPoint.y)
        } else {
            cursorAppKit = cursorAxPoint
        }

        // Path 1 — fast path with sanity check on tall multi-line rect.
        if let direct = boundsForRange(element: element, range: range) {
            let probe = boundsForRange(
                element: element,
                range: CFRange(location: range.location, length: 1)
            )
            if let probe, probe.height > 0, direct.height > 1.6 * probe.height {
                diag.append("wordRect: path1 reject(tall \(Int(direct.height))pt > 1.6× probe \(Int(probe.height))pt)")
            } else {
                diag.append("wordRect: path1 ok")
                return direct
            }
        }

        // Path 2 — per-character scan + Y-cluster, pick cluster nearest cursor.
        let chars = scanCharacterRects(element: element, range: range, elementText: elementText)
        if !chars.isEmpty {
            let clusters = clusterByVisualLine(chars)
            if !clusters.isEmpty {
                let best = clusters.min { a, b in
                    let da = abs(a.rect.midY - cursorAppKit.y)
                    let db = abs(b.rect.midY - cursorAppKit.y)
                    return da < db
                }
                if let best {
                    diag.append("wordRect: path2 ok (\(clusters.count) clusters)")
                    return best.rect
                }
            }
        }

        // Path 3 — probe nearby chars for any rect at all. Walk outward from
        // the range, alternating forward and backward, until we hit a rect.
        let center = range.location + range.length / 2
        let maxProbes = 40
        var probed = 0
        var forward = range.location + range.length
        var backward = range.location - 1
        while probed < maxProbes {
            if forward - center <= 20 {
                if let rect = boundsForRange(
                    element: element,
                    range: CFRange(location: forward, length: 1)
                ) {
                    diag.append("wordRect: path3 ok (forward off=\(forward))")
                    return rect
                }
                forward += 1
                probed += 1
            }
            if probed >= maxProbes { break }
            if backward >= 0, center - backward <= 20 {
                if let rect = boundsForRange(
                    element: element,
                    range: CFRange(location: backward, length: 1)
                ) {
                    diag.append("wordRect: path3 ok (backward off=\(backward))")
                    return rect
                }
                backward -= 1
                probed += 1
            }
            // Bail out when both directions are out of probe budget.
            if (forward - center > 20) && (backward < 0 || center - backward > 20) {
                break
            }
        }

        diag.append("wordRect: all paths failed")
        return nil
    }

    /// Split a phrase range into one segment per visual line by Y-clustering
    /// per-character bounds. We deliberately avoid `kAXLineForIndex` /
    /// `kAXRangeForLine` here because WebKit (Twitter/X, Gmail, most web
    /// surfaces) doesn't implement them — falling back to a single
    /// `boundsForRange(phraseRange)` on WebKit returns the *enclosing rect*
    /// for a multi-line range, which is what made the v0.2 green overlay
    /// "engulf" entire paragraphs and pick up a ~70pt font from the tall
    /// rect height.
    private static func perLineSegments(
        element: AXUIElement,
        elementText: String,
        phraseRange: CFRange
    ) -> [PhraseSegment]? {
        guard phraseRange.length > 0 else { return nil }

        let chars = scanCharacterRects(
            element: element,
            range: phraseRange,
            elementText: elementText
        )
        guard !chars.isEmpty else { return nil }

        let clusters = clusterByVisualLine(chars)
        guard !clusters.isEmpty else { return nil }

        return clusters.map { PhraseSegment(rect: $0.rect, text: $0.text) }
    }

    private static func rangeForPosition(element: AXUIElement, point: CGPoint) -> CFRange? {
        var mutablePoint = point
        guard let pointValue = AXValueCreate(.cgPoint, &mutablePoint) else {
            return nil
        }

        var rawRange: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXRangeForPositionParameterizedAttribute as CFString,
            pointValue,
            &rawRange
        )
        guard error == .success, let rawRange else {
            return nil
        }
        guard CFGetTypeID(rawRange) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = rawRange as! AXValue

        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0 else {
            return nil
        }
        return range
    }

    /// Run WordContextExtractor at the given offset, walking up to ±3 UTF-16
    /// units when the cursor lands on whitespace / punctuation that the
    /// extractor rejects as a non-token. Returns the matched selection plus
    /// the offset it actually matched at, so callers can recompute the word's
    /// absolute UTF-16 start. The walk biases slightly left first, which
    /// matches Apple's Look Up behavior of choosing the previous word when
    /// the cursor lands in inter-word whitespace.
    private static func wordSelectionAround(
        text: String,
        utf16Offset: Int,
        radius: Int
    ) -> (selection: WordSelection, offset: Int)? {
        let deltas = [0, -1, 1, -2, 2, -3, 3]
        let maxOffset = text.utf16.count
        for delta in deltas {
            let off = utf16Offset + delta
            guard off >= 0, off <= maxOffset else { continue }
            if let result = WordContextExtractor.selection(in: text, utf16Offset: off, radius: radius) {
                return (result, off)
            }
        }
        return nil
    }

    /// Find an (element, CFRange) where the range identifies the character
    /// under `point`. Strategy in three passes:
    ///   1. Walk the hit element + up to 4 parents. Trust the FIRST candidate
    ///      that returns `location > 0` — a non-zero offset means AX actually
    ///      walked the layout. The previous v0.1.9 logic insisted the rect
    ///      strictly contain the cursor, which fails on line spacing / inter-
    ///      glyph gaps everywhere and made the app return nil for 100% of
    ///      positions in real apps.
    ///   2. All candidates returned 0-or-nothing. Brute-force scan each
    ///      candidate's per-character bounds and pick the character whose
    ///      rect is *closest* to the cursor (distance, not contains). This
    ///      handles cursors that land between glyph boxes.
    ///   3. As a last resort, return whatever range any candidate gave —
    ///      even `{0, 0}` — so the user gets *some* translation rather than
    ///      a hard "no". The v0.1.8 "first word everywhere" bug only matters
    ///      when pass 1 + 2 both fail, which is the genuinely broken-AX case.
    private static func resolveTextElementAndRange(
        from start: AXUIElement,
        point: CGPoint,
        diag: inout [String]
    ) -> (AXUIElement, CFRange)? {
        var candidates: [AXUIElement] = [start]
        var cursor: AXUIElement = start
        for _ in 0..<4 {
            guard let parent = parentElement(of: cursor) else { break }
            candidates.append(parent)
            cursor = parent
        }
        diag.append("candidates=\(candidates.count)")

        // Pass 1 — trust any non-zero range result.
        for (idx, element) in candidates.enumerated() {
            guard let range = rangeForPosition(element: element, point: point) else {
                continue
            }
            if range.location > 0 {
                diag.append("pass1: trust loc=\(range.location) on cand[\(idx)]=\(elementRole(element) ?? "?")")
                return (element, range)
            }
        }

        // Pass 2 — brute-force closest character.
        for (idx, element) in candidates.enumerated() {
            guard let textLength = textLength(of: element), textLength > 0 else {
                continue
            }
            if let scanned = bruteForceClosestRange(
                element: element,
                point: point,
                textLength: textLength
            ) {
                diag.append("pass2: closest loc=\(scanned.location) on cand[\(idx)] len=\(textLength)")
                return (element, scanned)
            }
        }

        // Pass 3 — accept any range, even {0, *}. Better than nothing.
        for (idx, element) in candidates.enumerated() {
            if let range = rangeForPosition(element: element, point: point) {
                diag.append("pass3: fallback loc=\(range.location) on cand[\(idx)]")
                return (element, range)
            }
        }

        diag.append("all candidates exhausted")
        return nil
    }

    /// Group a list of per-character rects into visual lines. Walks the
    /// rects in offset order; when a char's vertical position jumps more
    /// than `0.5 × medianHeight` from the current cluster's first char, we
    /// close the cluster and start a new one. Returns one entry per cluster:
    /// the union of horizontal extent (height taken from the cluster's
    /// own union) and the concatenation of the cluster's glyphs.
    static func clusterByVisualLine(
        _ chars: [(offset: Int, rect: NSRect, glyph: String)]
    ) -> [(rect: NSRect, text: String)] {
        guard !chars.isEmpty else { return [] }
        let sorted = chars.sorted { $0.offset < $1.offset }

        // Median of heights as the line-break threshold reference. We use
        // height (not pointSize) because that's what AX actually gives us.
        let heights = sorted.map(\.rect.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let threshold = max(1.0, 0.5 * medianHeight)

        var clusters: [[(offset: Int, rect: NSRect, glyph: String)]] = []
        var current: [(offset: Int, rect: NSRect, glyph: String)] = []
        var anchorY: CGFloat = sorted[0].rect.minY

        for c in sorted {
            if current.isEmpty {
                current.append(c)
                anchorY = c.rect.minY
                continue
            }
            if abs(c.rect.minY - anchorY) < threshold {
                current.append(c)
            } else {
                clusters.append(current)
                current = [c]
                anchorY = c.rect.minY
            }
        }
        if !current.isEmpty {
            clusters.append(current)
        }

        var out: [(rect: NSRect, text: String)] = []
        out.reserveCapacity(clusters.count)
        for cluster in clusters {
            guard let first = cluster.first else { continue }
            var union = first.rect
            for entry in cluster.dropFirst() {
                union = union.union(entry.rect)
            }
            let text = cluster.map(\.glyph).joined()
            out.append((union, text))
        }
        return out
    }

    /// Per-character rect scan over a UTF-16 range. Probes each offset with
    /// a length-1 `kAXBoundsForRange` query, keeps only the ones that return
    /// a non-degenerate AppKit rect, and pairs each kept rect with the
    /// corresponding glyph from `elementText` when available. Capped at 600
    /// iterations so a phrase that accidentally spans a huge AX element
    /// doesn't stall the AppKit thread. Used by both the per-line phrase
    /// segmenter (which needs glyphs to slice text per visual line) and the
    /// word-rect fallback (which only needs rects).
    static func scanCharacterRects(
        element: AXUIElement,
        range: CFRange,
        elementText: String?
    ) -> [(offset: Int, rect: NSRect, glyph: String)] {
        guard range.length > 0 else { return [] }
        let safeLimit = min(range.length, 600)
        let start = range.location
        let end = start + safeLimit

        // Precompute element-text UTF-16 view for fast slicing. Building the
        // index map for every char would re-walk the string, so we cache it.
        let utf16View: [UInt16]?
        if let elementText {
            utf16View = Array(elementText.utf16)
        } else {
            utf16View = nil
        }

        var out: [(offset: Int, rect: NSRect, glyph: String)] = []
        out.reserveCapacity(safeLimit)
        for offset in start..<end {
            guard let rect = boundsForRange(
                element: element,
                range: CFRange(location: offset, length: 1)
            ) else {
                continue
            }
            let glyph: String
            if let utf16View, offset >= 0, offset < utf16View.count {
                if let scalar = Unicode.Scalar(utf16View[offset]) {
                    glyph = String(scalar)
                } else {
                    glyph = ""
                }
            } else {
                glyph = ""
            }
            out.append((offset, rect, glyph))
        }
        return out
    }

    /// Scan each character's bounds and return the one whose rect is closest
    /// (Euclidean) to `point`. Capped to 4000 chars so a misbehaving AX
    /// implementation can't stall us. Returns nil when the element doesn't
    /// implement bounds-for-range at all, or when no character is within
    /// 40pt of the cursor (handles line spacing / clicks just past EOL).
    private static func bruteForceClosestRange(
        element: AXUIElement,
        point: CGPoint,
        textLength: Int
    ) -> CFRange? {
        guard quartzBoundsForRange(element: element, range: CFRange(location: 0, length: 1)) != nil else {
            return nil
        }
        let limit = min(textLength, 4_000)
        var best: (range: CFRange, distance: CGFloat)? = nil
        for character in 0..<limit {
            let probe = CFRange(location: character, length: 1)
            guard let rect = quartzBoundsForRange(element: element, range: probe),
                  rect.width > 0, rect.height > 0 else {
                continue
            }
            let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
            let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
            let distance = sqrt(dx * dx + dy * dy)
            if distance == 0 {
                return probe
            }
            if best == nil || distance < best!.distance {
                best = (probe, distance)
            }
        }
        if let best, best.distance < 40 {
            return best.range
        }
        return nil
    }

    private static func parentElement(of element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &raw)
        guard error == .success, let raw else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func textLength(of element: AXUIElement) -> Int? {
        if let text = stringAttribute(element: element, attribute: kAXValueAttribute as String) {
            return text.utf16.count
        }
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &raw
        )
        guard error == .success else { return nil }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func boundsForRange(element: AXUIElement, range: CFRange) -> NSRect? {
        guard let quartzRect = quartzBoundsForRange(element: element, range: range) else {
            return nil
        }
        guard quartzRect.width > 0, quartzRect.height > 0 else { return nil }

        // AX bounds are documented as Quartz screen coords (top-left origin).
        // Flip against the AppKit frame of the primary screen — using the
        // local screen the cursor happens to be on breaks when a secondary
        // display sits above/beside the primary.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        guard let primary else { return nil }

        let appKitRect = ScreenCoordinateConverter.appKitRect(
            fromQuartzRect: quartzRect,
            primaryScreenFrame: primary.frame
        )
        return NSRect(
            x: appKitRect.origin.x,
            y: appKitRect.origin.y,
            width: appKitRect.size.width,
            height: appKitRect.size.height
        )
    }

    /// Raw Quartz-space rect for a CFRange. Returns nil if the element does
    /// not implement `kAXBoundsForRangeParameterizedAttribute` or the rect
    /// is empty. Used during point-resolution to compare against the cursor
    /// in the same coordinate space the cursor is already in.
    private static func quartzBoundsForRange(element: AXUIElement, range: CFRange) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var rawBounds: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rawBounds
        )
        guard error == .success, let rawBounds else { return nil }
        guard CFGetTypeID(rawBounds) == AXValueGetTypeID() else { return nil }
        let boundsValue = rawBounds as! AXValue

        var quartzRect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &quartzRect) else { return nil }
        return quartzRect
    }

    private static func elementRole(_ element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw)
        guard err == .success else { return nil }
        return raw as? String
    }

    private static func absoluteWordStartUTF16Offset(
        in fullText: String,
        pointedOffset: Int,
        word: String
    ) -> Int? {
        // The extractor returns the matched word's content but not its
        // absolute UTF-16 start inside `fullText`. We walk backwards from
        // `pointedOffset` to find where the word starts so kAXBoundsForRange
        // gets the right CFRange.
        let utf16 = Array(fullText.utf16)
        guard pointedOffset >= 0, pointedOffset <= utf16.count else { return nil }
        let wordUTF16 = Array(word.utf16)
        guard !wordUTF16.isEmpty else { return nil }

        let searchStart = max(0, pointedOffset - wordUTF16.count)
        let searchEnd = min(utf16.count - wordUTF16.count, pointedOffset)
        guard searchStart <= searchEnd else { return nil }

        for candidate in stride(from: searchEnd, through: searchStart, by: -1) {
            if Array(utf16[candidate..<(candidate + wordUTF16.count)]) == wordUTF16 {
                return candidate
            }
        }
        return nil
    }

    private static func stringAttribute(element: AXUIElement, attribute: String) -> String? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success else { return nil }
        return rawValue as? String
    }

    private static func stringForRange(element: AXUIElement, location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            return nil
        }

        var rawString: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rawString
        )
        guard error == .success else { return nil }
        return rawString as? String
    }

    private static func accessibilityPoint(from appKitPoint: CGPoint) -> CGPoint {
        // AppKit screen coords: origin bottom-left of the PRIMARY screen, y up.
        // Quartz / AX coords: origin top-left of the PRIMARY screen, y down.
        // The flip therefore has to be anchored on the primary screen frame —
        // using the local screen the cursor happens to be on breaks once the
        // user has a secondary display arranged above or beside the primary.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        guard let primary else { return appKitPoint }
        return CGPoint(
            x: appKitPoint.x,
            y: primary.frame.maxY - appKitPoint.y
        )
    }
}
