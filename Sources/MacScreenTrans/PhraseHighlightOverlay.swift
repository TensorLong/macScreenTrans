import AppKit

/// Green counterpart to `WordHighlightOverlayController`. Draws one rounded
/// green bubble per phrase segment (one bubble per visual line of the LLM-
/// returned sense group), inside a single click-through `NSPanel`. Each
/// bubble's substring is redrawn 1.05× scaled + lifted 2pt upward, same
/// Look-Up popping treatment the yellow word overlay uses.
///
/// Z-order versus the yellow overlay:
///   - Yellow word overlay uses `.popUpMenu`
///   - This phrase overlay uses `.floating`
/// Because `.popUpMenu` > `.floating` in NSWindow.Level ordering, the yellow
/// word remains visible *on top of* the green band when both are shown.
/// We do NOT raise this panel above `.floating` — that's load-bearing for
/// the visual hierarchy described in the v0.2 spec.
@MainActor
final class PhraseHighlightOverlayController {
    private let panel: NSPanel
    private let view: PhraseHighlightView

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
    /// returned — one entry per visual line, with each entry's rect in
    /// AppKit screen coordinates and its `text` being the slice of the
    /// phrase that appears on that line.
    ///
    /// `font` is the best-available font for redrawing the phrase text. Pass
    /// nil to let the view infer a font from segment rect height, same
    /// heuristic the yellow overlay uses.
    func show(segments: [PhraseSegment], font: NSFont?) {
        guard !segments.isEmpty else {
            hide()
            return
        }

        // Union the segment rects, then pad. Same horizontal+vertical
        // padding as WordHighlightOverlay so a single-segment phrase looks
        // visually consistent with the word bubble.
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 8
        var union = segments[0].rect
        for segment in segments.dropFirst() {
            union = union.union(segment.rect)
        }
        let frame = NSRect(
            x: union.origin.x - horizontalPadding,
            y: union.origin.y - verticalPadding,
            width: union.width + horizontalPadding * 2,
            height: union.height + verticalPadding * 2
        )

        // Translate each segment's screen rect into panel-local coords —
        // the view draws in its own bounds, not screen space.
        let localSegments: [PhraseHighlightView.Segment] = segments.map { seg in
            PhraseHighlightView.Segment(
                rect: NSRect(
                    x: seg.rect.minX - frame.minX,
                    y: seg.rect.minY - frame.minY,
                    width: seg.rect.width,
                    height: seg.rect.height
                ),
                text: seg.text
            )
        }

        view.configure(segments: localSegments, font: font)
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
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            // Completion fires on the main thread; Swift 6 isolation
            // analysis still flags NSPanel access as cross-actor, so hop
            // back onto MainActor before touching it.
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })
    }
}

private final class PhraseHighlightView: NSView {
    struct Segment {
        let rect: NSRect
        let text: String
    }

    private var segments: [Segment] = []
    private var font: NSFont = .systemFont(ofSize: 14)

    override var isFlipped: Bool { false }

    func configure(segments: [Segment], font: NSFont?) {
        self.segments = segments
        if let font {
            self.font = font
        } else if let first = segments.first {
            // Same height-derived font sizing heuristic as the yellow
            // overlay — keeps both bubbles' text scale consistent.
            let approxPointSize = max(11, first.rect.height * 0.78)
            self.font = .systemFont(ofSize: approxPointSize)
        } else {
            self.font = .systemFont(ofSize: 14)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !segments.isEmpty else { return }

        let scaledFont = NSFont(
            descriptor: font.fontDescriptor,
            size: font.pointSize * 1.05
        ) ?? font
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: scaledFont,
            .foregroundColor: NSColor.labelColor
        ]

        for segment in segments {
            guard segment.rect.width > 0, segment.rect.height > 0 else { continue }

            // Green bubble — same inset / radius as the yellow overlay so
            // the two bubble shapes match when they sit next to each other.
            let bubbleRect = segment.rect.insetBy(dx: -3, dy: -2)
            let bubblePath = NSBezierPath(roundedRect: bubbleRect, xRadius: 5, yRadius: 5)
            NSColor.systemGreen.setFill()
            bubblePath.fill()

            // Hairline rim, full alpha — matches the yellow bubble's edge
            // treatment for visual consistency.
            NSColor.systemGreen.setStroke()
            bubblePath.lineWidth = 0.5
            bubblePath.stroke()

            // Redraw the segment text 1.05× scaled, lifted 2pt upward —
            // identical pop logic to the yellow word overlay, just per
            // segment instead of a single word.
            let attributed = NSAttributedString(string: segment.text, attributes: textAttributes)
            let textSize = attributed.size()
            let liftedRect = NSRect(
                x: segment.rect.midX - textSize.width / 2,
                y: segment.rect.midY - textSize.height / 2 + 2,
                width: textSize.width,
                height: textSize.height
            )
            attributed.draw(in: liftedRect)
        }
    }
}
