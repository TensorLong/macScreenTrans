import AppKit

/// Green counterpart to `WordHighlightOverlayController`. Tints each visual
/// line of the LLM-returned sense group with a translucent green highlight,
/// inside a single click-through `NSPanel`.
///
/// Like the yellow overlay, v0.4 draws NO text — only a translucent fill over
/// the host app's own glyphs. The earlier design redrew each segment's text
/// at a guessed font size, which produced giant text spilling out of a small
/// box whenever a segment rect came back narrow (the "绿框只框单个字母 +
/// 字大框小" report). A translucent tint can't mis-size text: the real glyphs
/// show through.
///
/// Z-order versus the yellow overlay:
///   - Yellow word overlay uses `.popUpMenu`
///   - This phrase overlay uses `.floating`
/// `.popUpMenu` > `.floating`, so the yellow word tint stays layered on top
/// of the green band where they overlap.
@MainActor
final class PhraseHighlightOverlayController {
    private let panel: NSPanel
    private let view: PhraseHighlightView
    /// Same staleness guard as WordHighlightOverlayController: a hide's
    /// fade-out completion must not order out a panel that a newer show()
    /// already re-displayed.
    private var generation = 0

    init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 10, height: 10)
        panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // .floating sits below .popUpMenu, so the yellow word overlay stays
        // on top of the green phrase band automatically when both panels
        // overlap on screen.
        panel.level = .floating
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

        view = PhraseHighlightView(frame: initialFrame)
        panel.contentView = view
    }

    /// Show the green phrase highlight covering the screen region of each
    /// segment. `segments` is what `OCRWordReader.Result.phraseSegments(for:)`
    /// returned — one entry per visual line, each rect in AppKit screen
    /// coordinates.
    func show(segments: [PhraseSegment]) {
        let valid = segments.filter { $0.rect.width > 0 && $0.rect.height > 0 }
        guard !valid.isEmpty else {
            hide()
            return
        }
        generation += 1

        // Union the segment rects, then pad a touch so the rounded tint
        // hugs the glyphs.
        let padding: CGFloat = 2
        var union = valid[0].rect
        for segment in valid.dropFirst() {
            union = union.union(segment.rect)
        }
        let frame = union.insetBy(dx: -padding, dy: -padding)

        // Translate each segment's screen rect into panel-local coords —
        // the view draws in its own bounds, not screen space.
        let localSegments: [NSRect] = valid.map { seg in
            NSRect(
                x: seg.rect.minX - frame.minX,
                y: seg.rect.minY - frame.minY,
                width: seg.rect.width,
                height: seg.rect.height
            )
        }

        view.frame = NSRect(origin: .zero, size: frame.size)
        view.segments = localSegments
        view.needsDisplay = true
        panel.setFrame(frame, display: false)
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
            // Completion fires on the main thread; Swift 6 isolation
            // analysis still flags NSPanel access as cross-actor, so hop
            // back onto MainActor before touching it.
            Task { @MainActor [weak self] in
                guard self?.generation == expected else { return }
                panel.orderOut(nil)
            }
        })
    }
}

private final class PhraseHighlightView: NSView {
    var segments: [NSRect] = []

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !segments.isEmpty else { return }

        for segment in segments {
            let rect = segment.insetBy(dx: 0.5, dy: 0.5)
            guard rect.width > 0, rect.height > 0 else { continue }
            let radius = min(5, rect.height * 0.3)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.systemGreen.withAlphaComponent(0.28).setFill()
            path.fill()
            NSColor.systemGreen.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
