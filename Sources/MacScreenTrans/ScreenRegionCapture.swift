import AppKit
import CoreGraphics

/// A captured screen strip: the pixels plus the AppKit screen rect they cover.
/// The screen frame is all the geometry the OCR layer needs to map normalized
/// image coordinates back onto the screen — it is scale-independent, so Retina
/// backing factors never enter the math explicitly.
struct CapturedRegion {
    let image: CGImage
    /// AppKit screen coordinates (origin bottom-left) of the captured rect.
    let screenFrame: NSRect
}

/// Captures a horizontal strip of the screen around a point. Behind a protocol
/// so the capture backend can be swapped (e.g. `SCScreenshotManager`) without
/// touching the OCR pipeline. `Sendable` so the backend can live in a static
/// constant under Swift 6 strict concurrency.
protocol ScreenRegionCapturing: Sendable {
    /// Capture a strip `stripHeight` points tall, centred vertically on
    /// `appKitPoint`, spanning the full width of the screen that contains it.
    /// Returns nil only on hard failure (no screen / capture API returned nil).
    func capture(around appKitPoint: CGPoint, stripHeight: CGFloat) -> CapturedRegion?
}

/// Synchronous capture via `CGWindowListCreateImage`.
///
/// Deprecated in macOS 14+ (still functional at runtime). Chosen for v1
/// because it is synchronous — lowest tap-to-result latency, no
/// `SCShareableContent` enumeration — and supports the macOS 13 floor. Kept
/// behind `ScreenRegionCapturing` so a `SCScreenshotManager` implementation
/// can replace it in one file when we move off the deprecated API.
///
/// Note: without Screen Recording permission this returns an image of the
/// desktop only (not nil), so permission is gated separately via
/// `PermissionHelper.screenRecordingGranted` before we ever call it.
struct LegacyWindowListCapture: ScreenRegionCapturing {
    func capture(around appKitPoint: CGPoint, stripHeight: CGFloat) -> CapturedRegion? {
        guard let screen = Self.screen(containing: appKitPoint),
              let primary = Self.primaryScreen() else {
            return nil
        }

        // Build the strip in AppKit space: full screen width, bounded height
        // centred on the tap, clamped to the screen.
        let halfHeight = stripHeight / 2
        let rawStrip = NSRect(
            x: screen.frame.minX,
            y: appKitPoint.y - halfHeight,
            width: screen.frame.width,
            height: stripHeight
        )
        let stripAppKit = rawStrip.intersection(screen.frame)
        guard !stripAppKit.isNull, stripAppKit.height > 1, stripAppKit.width > 1 else { return nil }

        // Convert AppKit (bottom-left, global) -> Quartz (top-left, global)
        // for the capture call; the primary screen anchors the Y flip.
        let quartz = CGRect(
            x: stripAppKit.minX,
            y: primary.frame.maxY - stripAppKit.maxY,
            width: stripAppKit.width,
            height: stripAppKit.height
        )

        guard let image = CGWindowListCreateImage(
            quartz,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else { return nil }

        return CapturedRegion(image: image, screenFrame: stripAppKit)
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private static func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }
}
