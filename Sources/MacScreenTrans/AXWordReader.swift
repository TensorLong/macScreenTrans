import AppKit
import ApplicationServices
import MacScreenTransCore

enum AXWordReader {
    static func selection(at appKitPoint: CGPoint, radius: Int = 200) -> WordSelection? {
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

        guard let range = rangeForPosition(element: element, point: axPoint) else {
            return nil
        }

        if let text = stringAttribute(element: element, attribute: kAXValueAttribute as String),
           let selection = WordContextExtractor.selection(
            in: text,
            utf16Offset: range.location,
            radius: radius
           ) {
            return selection
        }

        let lower = max(0, range.location - radius)
        let length = radius * 2 + max(range.length, 1)
        guard let context = stringForRange(element: element, location: lower, length: length) else {
            return nil
        }

        return WordContextExtractor.selection(
            in: context,
            utf16Offset: max(0, range.location - lower),
            radius: radius
        )
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

        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            return CGPoint(
                x: displayBounds.minX + (appKitPoint.x - screen.frame.minX),
                y: displayBounds.maxY - (appKitPoint.y - screen.frame.minY)
            )
        }

        return CGPoint(
            x: appKitPoint.x,
            y: screen.frame.maxY - appKitPoint.y + screen.frame.minY
        )
    }
}
