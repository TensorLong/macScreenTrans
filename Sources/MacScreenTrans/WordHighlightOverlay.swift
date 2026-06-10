import AppKit

/// A click-through borderless panel that tints the recognized word with a
/// translucent yellow highlight — like a highlighter pen drawn over the text
/// already on screen.
///
/// v0.4 deliberately does NOT redraw the word's glyphs. The previous design
/// painted an opaque bubble and re-rendered the text inside it at a font size
/// *guessed* from the box height; whenever the box was small or the guess was
/// off, the redrawn text overflowed — the "字大框小" distortion users hit. A
/// translucent fill over the real glyphs needs no font, so it can never
/// mis-size the text: whatever is under the highlight is the host app's own,
/// correctly-rendered text showing through.
///
/// Z-order: this panel is `.popUpMenu`, one level above the green phrase
/// overlay (`.floating`), so the yellow word tint layers over the green band.
@MainActor
final class WordHighlightOverlayController {
    private let panel: NSPanel
    private let highlightView: HighlightView
    /// Bumped on every show()/hide(). A hide's fade-out completion only
    /// orders the panel out when no newer show()/hide() superseded it —
    /// otherwise a stale completion (queued while the main thread was busy)
    /// would remove a highlight that was just re-shown.
    private var generation = 0

    /// Padding around the word rect so the rounded tint hugs the glyphs with
    /// a little breathing room without swallowing neighbours.
    private static let padding: CGFloat = 2

    init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 10, height: 10)
        panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // .popUpMenu draws above ordinary floating windows so the highlight
        // never hides behind the host app's own subviews during the brief
        // moment before the translation popup appears.
        panel.level = .popUpMenu
        // Kept out of our own OCR captures via window-ID exclusion (see
        // ScreenRegionCapture), NOT sharingType — so external screenshot
        // tools can still record the highlight for debugging.
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        highlightView = HighlightView(frame: initialFrame)
        panel.contentView = highlightView
    }

    /// Show the translucent highlight over `wordRect` (AppKit screen coords).
    func show(at wordRect: NSRect) {
        guard wordRect.width > 0, wordRect.height > 0 else { return }
        generation += 1
        let frame = wordRect.insetBy(dx: -Self.padding, dy: -Self.padding)
        panel.setFrame(frame, display: false)
        highlightView.frame = NSRect(origin: .zero, size: frame.size)
        highlightView.needsDisplay = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        generation += 1
        let expected = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            // NSAnimationContext fires the completion on the main thread,
            // but Swift 6 sees the closure as nonisolated. Hop back onto
            // MainActor before touching NSPanel.
            Task { @MainActor [weak self] in
                guard self?.generation == expected else { return }
                panel.orderOut(nil)
            }
        })
    }
}

private final class HighlightView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 0, rect.height > 0 else { return }

        // Translucent fill over the host app's own glyphs (which show through
        // unchanged) plus a slightly stronger rim, the highlighter look.
        let radius = min(5, rect.height * 0.3)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.systemYellow.withAlphaComponent(0.32).setFill()
        path.fill()
        NSColor.systemYellow.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
