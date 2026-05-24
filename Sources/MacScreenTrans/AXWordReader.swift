import AppKit
import ApplicationServices
import MacScreenTransCore

enum AXWordReader {
    struct Result {
        let selection: WordSelection
        /// The word's on-screen rect in AppKit coordinates, or nil when the
        /// underlying element doesn't implement `kAXBoundsForRangeParameterizedAttribute`
        /// (image PDFs, custom-drawn UIs, some web views).
        let wordRect: NSRect?
    }

    static func selection(at appKitPoint: CGPoint, radius: Int = 200) -> WordSelection? {
        resolve(at: appKitPoint, radius: radius)?.selection
    }

    static func resolve(at appKitPoint: CGPoint, radius: Int = 200) -> Result? {
        let axPoint = accessibilityPoint(from: appKitPoint)
        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let elementError = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &hitElement
        )
        guard elementError == .success, let initial = hitElement else {
            return nil
        }

        // The leaf element under the cursor sometimes returns a useless
        // {0, 0} from kAXRangeForPositionParameterizedAttribute (some
        // AXStaticText wrappers, browser/Electron text containers). Try
        // the hit element first; if its location is unreliable, walk up
        // the parent chain and validate against kAXBoundsForRange. As a
        // last resort, scan the element's bounds to find which character
        // actually sits under the cursor.
        guard let (element, pointedRange) = resolveTextElementAndRange(
            from: initial,
            point: axPoint
        ) else {
            return nil
        }

        let selection: WordSelection
        var wordUTF16Range = CFRange(location: pointedRange.location, length: max(pointedRange.length, 1))

        if let text = stringAttribute(element: element, attribute: kAXValueAttribute as String),
           let resolved = WordContextExtractor.selection(
            in: text,
            utf16Offset: pointedRange.location,
            radius: radius
           ) {
            selection = resolved
            // Recover the absolute UTF-16 range of the matched word inside the full element string
            // so we can ask for its on-screen bounds.
            let wordStart = absoluteWordStartUTF16Offset(
                in: text,
                pointedOffset: pointedRange.location,
                word: resolved.word
            ) ?? pointedRange.location
            wordUTF16Range = CFRange(location: wordStart, length: resolved.word.utf16.count)
        } else {
            let lower = max(0, pointedRange.location - radius)
            let length = radius * 2 + max(pointedRange.length, 1)
            guard let context = stringForRange(element: element, location: lower, length: length),
                  let resolved = WordContextExtractor.selection(
                    in: context,
                    utf16Offset: max(0, pointedRange.location - lower),
                    radius: radius
                  ) else {
                return nil
            }
            selection = resolved
            wordUTF16Range = CFRange(
                location: lower + resolved.wordRangeInContext.lowerBound,
                length: resolved.word.utf16.count
            )
        }

        let wordRect = boundsForRange(element: element, range: wordUTF16Range)
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

    /// Find an element + CFRange pair where the range actually corresponds
    /// to the character under `point`. Many real-world apps either:
    ///   1. Return `{0, 0}` from kAXRangeForPositionParameterizedAttribute
    ///      no matter where the cursor is (broken AX wiring), or
    ///   2. Don't implement the attribute on the hit element, but DO on a
    ///      parent (or vice versa).
    /// We try the hit element, then walk up to 4 parents, validating each
    /// candidate by querying kAXBoundsForRange and checking whether that
    /// rect actually sits under `point`. If no parent works, we fall back
    /// to a brute-force bounds scan over the element's text.
    private static func resolveTextElementAndRange(
        from start: AXUIElement,
        point: CGPoint
    ) -> (AXUIElement, CFRange)? {
        var candidates: [AXUIElement] = [start]
        var cursor: AXUIElement = start
        // Walk up the parent chain so we can fall back when the leaf element
        // has a broken parameterized-attribute implementation.
        for _ in 0..<4 {
            guard let parent = parentElement(of: cursor) else { break }
            candidates.append(parent)
            cursor = parent
        }

        // First pass: take the most-specific candidate whose reported range
        // is consistent with `point` (i.e. its character's bounds contain
        // the cursor). This is the happy path for well-behaved apps.
        for element in candidates {
            guard let range = rangeForPosition(element: element, point: point) else {
                continue
            }
            if rangeIsConsistent(with: point, element: element, range: range) {
                return (element, range)
            }
        }

        // Second pass: the parameterized attribute is unreliable on every
        // candidate (returns 0 or a bogus offset). Scan kAXBoundsForRange
        // character-by-character to find which character actually sits
        // under the cursor. Restrict to elements that expose any text.
        for element in candidates {
            guard let textLength = textLength(of: element), textLength > 0 else {
                continue
            }
            if let scanned = bruteForceRange(
                element: element,
                point: point,
                textLength: textLength
            ) {
                return (element, scanned)
            }
        }

        return nil
    }

    /// True when the rect that `element` reports for the single character at
    /// `range.location` actually contains `point` (with a small tolerance
    /// for sub-pixel rounding and inter-glyph gaps). We compare in Quartz
    /// space because `point` is already in Quartz space and the AX bounds
    /// are too — flipping isn't needed here.
    private static func rangeIsConsistent(
        with point: CGPoint,
        element: AXUIElement,
        range: CFRange
    ) -> Bool {
        let probeLength = max(range.length, 1)
        let probe = CFRange(location: range.location, length: probeLength)
        guard let rect = quartzBoundsForRange(element: element, range: probe),
              rect.width > 0, rect.height > 0 else {
            // No bounds info means we can't validate — accept the offset as
            // a best effort rather than rejecting outright. For broken apps
            // that ALSO fail bounds queries, the brute-force pass below
            // wouldn't help either.
            return true
        }
        return rect.insetBy(dx: -2, dy: -2).contains(point)
    }

    /// Last-resort scan: walk each character and pick the one whose
    /// kAXBoundsForRange rect contains the cursor. Capped to avoid
    /// thrashing AX on huge text blobs — for very large fields a click
    /// that the parameterized attribute can't handle is rare in practice,
    /// and the cap also bounds how long a misbehaving app can stall us.
    /// We can't use a coarse stride here because some apps return the
    /// UNION rect for multi-character ranges, which crosses line wraps
    /// and produces false positives.
    private static func bruteForceRange(
        element: AXUIElement,
        point: CGPoint,
        textLength: Int
    ) -> CFRange? {
        // Bail early when the element doesn't implement bounds-for-range at
        // all; otherwise we'd burn thousands of nil-returning AX round trips.
        guard quartzBoundsForRange(element: element, range: CFRange(location: 0, length: 1)) != nil else {
            return nil
        }
        let limit = min(textLength, 4_000)
        for character in 0..<limit {
            let probe = CFRange(location: character, length: 1)
            if let rect = quartzBoundsForRange(element: element, range: probe),
               rect.width > 0, rect.height > 0,
               rect.insetBy(dx: -2, dy: -2).contains(point) {
                return probe
            }
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

        // AX returns Quartz coordinates (origin top-left of primary screen).
        // Flip against the AppKit frame of the screen anchored at (0, 0).
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
