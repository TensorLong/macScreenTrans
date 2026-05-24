import AppKit

/// A click-through borderless panel that draws Apple's "Look Up" yellow
/// highlight: a rounded yellow bubble behind the recognized word, with the
/// word redrawn slightly enlarged and lifted upward so it pops off the
/// surrounding text.
@MainActor
final class WordHighlightOverlayController {
    private let panel: NSPanel
    private let highlightView: HighlightView

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

    /// Show the highlight over `wordRect` (AppKit screen coordinates).
    /// `font` is the best available font for the word — passed in by the
    /// caller because we usually can't introspect the host app's text run.
    func show(word: String, font: NSFont?, at wordRect: NSRect) {
        // Pad the panel so the slight scale-up + upward lift don't clip.
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 8
        let frame = NSRect(
            x: wordRect.origin.x - horizontalPadding,
            y: wordRect.origin.y - verticalPadding,
            width: wordRect.width + horizontalPadding * 2,
            height: wordRect.height + verticalPadding * 2
        )
        highlightView.configure(
            word: word,
            font: font,
            wordRectInPanel: NSRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: wordRect.width,
                height: wordRect.height
            )
        )
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
            // NSAnimationContext fires the completion on the main thread,
            // but Swift 6 sees the closure as nonisolated. Hop back onto
            // MainActor before touching NSPanel.
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })
    }
}

private final class HighlightView: NSView {
    private var word: String = ""
    private var font: NSFont = .systemFont(ofSize: 14)
    private var wordRectInPanel: NSRect = .zero

    override var isFlipped: Bool { false }

    func configure(word: String, font: NSFont?, wordRectInPanel: NSRect) {
        self.word = word
        // If the caller didn't give us a font, infer one whose ascender/
        // descender roughly matches the bounded rect's height so the redraw
        // doesn't look comically off-size.
        if let font {
            self.font = font
        } else {
            let approxPointSize = max(11, wordRectInPanel.height * 0.78)
            self.font = .systemFont(ofSize: approxPointSize)
        }
        self.wordRectInPanel = wordRectInPanel
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard wordRectInPanel.width > 0, wordRectInPanel.height > 0 else { return }

        // Yellow bubble — slightly inset so it hugs the word.
        let bubbleRect = wordRectInPanel.insetBy(dx: -3, dy: -2)
        let bubblePath = NSBezierPath(roundedRect: bubbleRect, xRadius: 5, yRadius: 5)
        NSColor.systemYellow.withAlphaComponent(0.55).setFill()
        bubblePath.fill()

        // Hairline border to match Apple's Look Up shape edge.
        NSColor.systemYellow.withAlphaComponent(0.85).setStroke()
        bubblePath.lineWidth = 0.5
        bubblePath.stroke()

        // Redraw the word ~1.05× scaled, lifted 2pt upward, so it "pops"
        // off the surrounding text. We draw with the strongest contrast
        // color the system theme gives us.
        let scaledFont = NSFont(
            descriptor: font.fontDescriptor,
            size: font.pointSize * 1.05
        ) ?? font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: scaledFont,
            .foregroundColor: NSColor.labelColor
        ]
        let attributed = NSAttributedString(string: word, attributes: attributes)
        let textSize = attributed.size()
        let liftedRect = NSRect(
            x: wordRectInPanel.midX - textSize.width / 2,
            y: wordRectInPanel.midY - textSize.height / 2 + 2,
            width: textSize.width,
            height: textSize.height
        )
        attributed.draw(in: liftedRect)
    }
}
