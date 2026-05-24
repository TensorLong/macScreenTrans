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
        var rawElement: AXUIElement?
        let elementError = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &rawElement
        )
        guard elementError == .success, let element = rawElement else {
            return nil
        }

        guard let pointedRange = rangeForPosition(element: element, point: axPoint) else {
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

    private static func boundsForRange(element: AXUIElement, range: CFRange) -> NSRect? {
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
        let screen = NSScreen.screens.first { NSMouseInRect(appKitPoint, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return appKitPoint }

        return CGPoint(
            x: appKitPoint.x,
            y: screen.frame.maxY - appKitPoint.y + screen.frame.minY
        )
    }
}
