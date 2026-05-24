import CoreGraphics

/// Converts between Quartz screen coordinates (origin top-left, y grows down —
/// returned by Accessibility APIs and CoreGraphics) and AppKit screen
/// coordinates (origin bottom-left, y grows up — what `NSWindow.setFrame*`
/// expects).
///
/// Kept platform-free so the math can be exercised by unit tests without
/// touching `NSScreen`.
public enum ScreenCoordinateConverter {
    /// Flip a Quartz rect to AppKit space given the AppKit frame of the
    /// primary screen. `primaryScreenFrame` is the rect of the screen whose
    /// origin is `(0, 0)` in AppKit coordinates — by convention the screen
    /// the AX origin is anchored to.
    public static func appKitRect(
        fromQuartzRect quartzRect: CGRect,
        primaryScreenFrame: CGRect
    ) -> CGRect {
        let flippedY = primaryScreenFrame.maxY - quartzRect.maxY
        return CGRect(
            x: quartzRect.origin.x,
            y: flippedY,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    /// Compute the popup window origin so its tail (anchored at `tailX` in
    /// the popup's local coordinates, on the bubble's bottom or top edge)
    /// lands at the horizontal midpoint of `wordRect`, with a vertical gap.
    ///
    /// Returns both the chosen origin and whether the bubble was placed
    /// ABOVE the word (tail on the bubble's bottom edge, pointing down) or
    /// BELOW (tail on top edge, pointing up).
    public static func popupPlacement(
        wordRect: CGRect,
        popupSize: CGSize,
        screenVisibleFrame: CGRect,
        verticalGap: CGFloat
    ) -> Placement {
        // Prefer placing the bubble ABOVE the word (matches Apple's Look Up).
        let aboveOriginY = wordRect.maxY + verticalGap
        let belowOriginY = wordRect.minY - popupSize.height - verticalGap

        let fitsAbove = aboveOriginY + popupSize.height <= screenVisibleFrame.maxY
        let fitsBelow = belowOriginY >= screenVisibleFrame.minY

        let isAbove: Bool
        var originY: CGFloat
        if fitsAbove {
            isAbove = true
            originY = aboveOriginY
        } else if fitsBelow {
            isAbove = false
            originY = belowOriginY
        } else {
            isAbove = true
            originY = aboveOriginY
        }

        let wordCenterX = wordRect.midX
        var originX = wordCenterX - popupSize.width / 2
        originX = max(screenVisibleFrame.minX + 8, originX)
        originX = min(screenVisibleFrame.maxX - popupSize.width - 8, originX)

        // tailX is the horizontal offset of the tail tip in the popup's
        // local coordinates (0 = left edge of bubble).
        let tailX = wordCenterX - originX

        originY = max(screenVisibleFrame.minY + 8, originY)
        originY = min(screenVisibleFrame.maxY - popupSize.height - 8, originY)

        return Placement(
            origin: CGPoint(x: originX, y: originY),
            isAboveWord: isAbove,
            tailX: tailX
        )
    }

    public struct Placement: Equatable, Sendable {
        public let origin: CGPoint
        /// True when the popup bubble sits above the word and its tail
        /// points DOWN at the word. False when it sits below and the tail
        /// points UP.
        public let isAboveWord: Bool
        /// Horizontal position of the tail tip in the popup's local space.
        public let tailX: CGFloat

        public init(origin: CGPoint, isAboveWord: Bool, tailX: CGFloat) {
            self.origin = origin
            self.isAboveWord = isAboveWord
            self.tailX = tailX
        }
    }
}
