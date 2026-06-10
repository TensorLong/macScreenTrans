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

/// Pre-computed geometry for one capture. Resolved on the main thread (it
/// reads NSScreen), then consumed by the pixel capture on any thread — the
/// split is what lets the OCR pipeline run off the main actor.
struct CaptureStripPlan: Sendable {
    /// AppKit screen coordinates (origin bottom-left) of the strip.
    let stripAppKit: NSRect
    /// The same rect in Quartz global coordinates (top-left origin anchored
    /// at the primary screen) — what `CGWindowListCreateImage` expects.
    let quartz: CGRect
}

/// Captures a horizontal strip of the screen around a point. Behind a protocol
/// so the capture backend can be swapped (e.g. `SCScreenshotManager`) without
/// touching the OCR pipeline. `Sendable` so the backend can live in a static
/// constant under Swift 6 strict concurrency.
protocol ScreenRegionCapturing: Sendable {
    /// Main-thread half: resolve the screen under `appKitPoint` and compute
    /// the strip geometry (`stripHeight` points tall, centred on the point).
    @MainActor func plan(around appKitPoint: CGPoint, stripHeight: CGFloat) -> CaptureStripPlan?
    /// Heavy half: grab the pixels. Thread-safe; call off the main actor.
    func capture(_ plan: CaptureStripPlan) -> CapturedRegion?
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
    /// Half-width of the strip around the tap, in points. Deliberately
    /// narrower than the full screen: a bounded strip keeps unrelated
    /// columns, sidebars and gutters out of the assembled OCR context and
    /// shrinks the Vision workload per tap.
    static let stripHalfWidth: CGFloat = 480

    @MainActor
    func plan(around appKitPoint: CGPoint, stripHeight: CGFloat) -> CaptureStripPlan? {
        guard let screen = Self.screen(containing: appKitPoint),
              let primary = Self.primaryScreen() else {
            return nil
        }

        // Build the strip in AppKit space: bounded width centred on the tap,
        // bounded height centred on the tap, clamped to visibleFrame so the
        // menu bar and Dock never leak text into the OCR context.
        let visible = screen.visibleFrame
        let halfHeight = stripHeight / 2
        let minX = max(visible.minX, appKitPoint.x - Self.stripHalfWidth)
        let maxX = min(visible.maxX, appKitPoint.x + Self.stripHalfWidth)
        let rawStrip = NSRect(
            x: minX,
            y: appKitPoint.y - halfHeight,
            width: maxX - minX,
            height: stripHeight
        )
        let stripAppKit = rawStrip.intersection(visible)
        guard !stripAppKit.isNull, stripAppKit.height > 1, stripAppKit.width > 1 else { return nil }

        // Convert AppKit (bottom-left, global) -> Quartz (top-left, global)
        // for the capture call; the primary screen anchors the Y flip.
        let quartz = CGRect(
            x: stripAppKit.minX,
            y: primary.frame.maxY - stripAppKit.maxY,
            width: stripAppKit.width,
            height: stripAppKit.height
        )
        return CaptureStripPlan(stripAppKit: stripAppKit, quartz: quartz)
    }

    func capture(_ plan: CaptureStripPlan) -> CapturedRegion? {
        guard let image = CGWindowListCreateImage(
            plan.quartz,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else { return nil }

        return CapturedRegion(image: image, screenFrame: plan.stripAppKit)
    }

    /// `NSMouseInRect(_:_:false)` handles the mouse coordinate convention at
    /// frame edges — `NSEvent.mouseLocation` reports y == frame.maxY with the
    /// cursor pinned at the top of a display, which `CGRect.contains` would
    /// miss. Fall back to the nearest screen, never `NSScreen.main`: the key
    /// window's display is unrelated to where the pointer is.
    @MainActor
    private static func screen(containing point: CGPoint) -> NSScreen? {
        if let hit = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            return hit
        }
        return NSScreen.screens.min { lhs, rhs in
            distanceSquared(from: point, to: lhs.frame) < distanceSquared(from: point, to: rhs.frame)
        }
    }

    @MainActor
    private static func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }

    private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
