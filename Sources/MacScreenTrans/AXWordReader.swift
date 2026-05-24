import AppKit
import ApplicationServices
import MacScreenTransCore
import os.log

private let logger = Logger(subsystem: "com.longmac.MacScreenTrans", category: "AXWordReader")

enum AXWordReader {
    struct Result {
        let selection: WordSelection
        /// The word's on-screen rect in AppKit coordinates, or nil when the
        /// underlying element doesn't implement `kAXBoundsForRangeParameterizedAttribute`
        /// (image PDFs, custom-drawn UIs, some web views).
        let wordRect: NSRect?
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
            diag.append("word=\"\(resolved.selection.word)\" via kAXStringForRange (offset \(resolved.offset))")
        }

        let wordRect = boundsForRange(element: element, range: wordUTF16Range)
        diag.append("wordRect=\(wordRect.map { "(\(Int($0.minX)),\(Int($0.minY))) \(Int($0.width))×\(Int($0.height))" } ?? "nil")")
        logger.debug("resolve OK: word=\"\(selection.word)\"")
        return Result(selection: selection, wordRect: wordRect)
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
