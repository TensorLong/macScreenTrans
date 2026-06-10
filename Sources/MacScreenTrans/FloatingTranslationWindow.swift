import AppKit
import MacScreenTransCore

@MainActor
final class FloatingTranslationWindowController {
    // Speech-bubble tail dimensions (points). Tuned to match the visual
    // weight of macOS's native Look Up arrow.
    private static let tailHeight: CGFloat = 8
    private static let tailHalfBase: CGFloat = 9
    private static let cornerRadius: CGFloat = 14
    private static let contentInset: CGFloat = 14
    private static let popupWidth: CGFloat = 390
    private static let popupHeight: CGFloat = 230
    private static let panelHeight = popupHeight + tailHeight
    // Mirrors the highlight overlays' insetBy(dy: -2). Keep in sync if changed.
    private static let highlightVerticalOverhang: CGFloat = 2
    // The yellow/green bubbles also redraw their text 1.05× scaled + lifted
    // 2pt, which makes their visible top edge ~3.5pt above the segment for
    // short glyphs. Apple's Look Up leaves ~8pt of breathing room between
    // tail tip and the underlined word — match that, not the bubble's raw
    // overhang.
    private static let tipClearanceFromHighlight: CGFloat = 8

    private let panel: NSPanel
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let sourceStack = NSStackView()
    private let wordLabel = NSTextField(labelWithString: "")
    private let posLabel = NSTextField(labelWithString: "")
    private let briefLabel = NSTextField(labelWithString: "")
    private let targetTextView = NSTextView()
    private let bubbleBackground: BubbleBackgroundView
    private var dismissArmedAt = Date.distantPast
    private var onCloseHandler: (() -> Void)?
    nonisolated(unsafe) private var localDismissMonitor: Any?
    nonisolated(unsafe) private var globalKeyMonitor: Any?
    nonisolated(unsafe) private var globalMouseMonitor: Any?

    /// Frozen at `show(anchoredTo:)`. The edge of the panel adjacent to the
    /// word is pinned at `pinnedScreenY` in screen coordinates; subsequent
    /// `update(_:)` calls reflow the panel keeping that edge fixed, so the
    /// body can only grow in the direction AWAY from the word, up to
    /// `maxHeight`. Nil when the popup is shown via the cursor fallback
    /// `show(at:)`.
    private struct AnchorState {
        /// True when the bubble sits above the word (tail points DOWN).
        let isAbove: Bool
        /// Screen-Y of the edge that's pinned next to the word:
        ///   - isAbove=true  → panel.minY  (bubble bottom)
        ///   - isAbove=false → panel.maxY  (bubble top)
        let pinnedScreenY: CGFloat
        /// Panel origin.x — locked once at show; never changes.
        let originX: CGFloat
        /// Hard cap on panel height: distance from the pinned edge to the
        /// screen's far edge, minus padding. The body never exceeds this.
        let maxHeight: CGFloat
        /// Tail geometry, also frozen at show.
        let tailConfig: BubbleBackgroundView.TailConfig
    }

    private var anchorState: AnchorState?

    init() {
        let initialFrame = NSRect(
            x: 0,
            y: 0,
            width: Self.popupWidth,
            height: Self.panelHeight
        )
        panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // .popUpMenu (same as yellow word highlight) so the green phrase
        // overlay at .floating can never z-order on top of us and cover
        // the tail tip.
        panel.level = .popUpMenu
        // NOTE: we deliberately leave sharingType at its default (.readOnly).
        // The OCR pipeline keeps this popup out of its own strip by excluding
        // our process's window IDs at capture time (see ScreenRegionCapture),
        // so the popup stays visible to EXTERNAL screenshot tools for
        // debugging while never polluting our own capture.
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // NSWindow draws a system shadow around the opaque region of its
        // content; with a bubble mask the shadow follows the tail correctly.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        // Lock the panel size. Without this, NSWindow auto-resizes its frame
        // when the contentView's AutoLayout fitting size grows (e.g. the
        // NSTextView inside the scroll view inflates as streaming tokens
        // arrive). The default anchoring is top-left, so panel.maxY stays
        // put while panel.minY drifts down — and panel.minY is exactly the
        // edge we pinned to the word. min==max forbids any AppKit-driven
        // resize, so the frame can only change when we call setFrame.
        let lockedPanelSize = NSSize(width: Self.popupWidth, height: Self.panelHeight)
        panel.minSize = lockedPanelSize
        panel.maxSize = lockedPanelSize

        bubbleBackground = BubbleBackgroundView(frame: initialFrame)
        panel.contentView = bubbleBackground

        let opaqueFill = OpaqueBubbleFillView()
        opaqueFill.translatesAutoresizingMaskIntoConstraints = false
        bubbleBackground.addSubview(opaqueFill)
        bubbleBackground.fillView = opaqueFill

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.spacing = 10
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        bubbleBackground.addSubview(contentStack)
        bubbleBackground.contentStack = contentStack

        let header = makeHeader()
        contentStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        contentStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        configureSourceStack()
        contentStack.addArrangedSubview(sourceStack)
        sourceStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 10

        targetTextView.isEditable = false
        targetTextView.isSelectable = true
        targetTextView.drawsBackground = false
        targetTextView.textColor = .labelColor
        targetTextView.font = .systemFont(ofSize: 15)
        targetTextView.textContainerInset = NSSize(width: 12, height: 10)
        targetTextView.textContainer?.lineFragmentPadding = 0
        targetTextView.minSize = .zero
        targetTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        targetTextView.isVerticallyResizable = true
        targetTextView.isHorizontallyResizable = false
        targetTextView.autoresizingMask = [.width]
        targetTextView.textContainer?.widthTracksTextView = true
        targetTextView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        targetTextView.string = ""
        scrollView.documentView = targetTextView

        contentStack.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let minimumScrollHeight = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minimumScrollHeight.isActive = true

        let preferredScrollHeight = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 96)
        preferredScrollHeight.priority = .defaultLow
        preferredScrollHeight.isActive = true

        bubbleBackground.applyContentConstraints(
            fillView: opaqueFill,
            contentStack: contentStack,
            inset: Self.contentInset,
            tailHeight: Self.tailHeight
        )

        installDismissMonitors()
    }

    /// Hook invoked whenever the popup closes for any reason (escape, click
    /// outside, programmatic close). Used by AppDelegate to dismiss the
    /// yellow word highlight in lockstep with the translation popup.
    func setOnClose(_ handler: @escaping () -> Void) {
        onCloseHandler = handler
    }

    func show(at point: CGPoint, text: String) {
        // Non-anchored: no edge to pin. Clear state so update() doesn't try
        // to reflow against stale geometry.
        anchorState = nil
        update(text)
        bubbleBackground.tailConfig = nil
        let size = NSSize(width: Self.popupWidth, height: Self.panelHeight)
        let origin = origin(near: point, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        dismissArmedAt = Date().addingTimeInterval(0.25)
    }

    /// Show the popup as a speech bubble anchored to `wordRect` (AppKit
    /// screen coords). The above/below side is decided ONCE here and
    /// frozen in `anchorState` — subsequent `update(_:)` calls reflow the
    /// panel keeping the edge adjacent to the word pinned in place, so the
    /// body can only grow AWAY from the anchor. Tail points DOWN at the
    /// word when the bubble is above, UP when below.
    func show(anchoredTo wordRect: NSRect, text: String) {
        let screenFrame = (NSScreen.screens.first {
            NSMouseInRect(CGPoint(x: wordRect.midX, y: wordRect.midY), $0.frame, false)
        } ?? NSScreen.main)?.visibleFrame ?? .zero

        let verticalGap: CGFloat = 2
        let edgePadding: CGFloat = 8

        // Inset the anchor so the tail tip lands outside the yellow/green
        // highlight overhang above the word.
        let anchorRect = wordRect.insetBy(
            dx: 0,
            dy: -(Self.highlightVerticalOverhang + Self.tipClearanceFromHighlight)
        )

        // Decide side once. Apple's Look Up prefers above; we fall back
        // below only when above doesn't fit the ideal height. Once chosen,
        // the side never flips mid-stream — VSCode (#109226) learned the
        // hard way that mid-stream flips cause the popup to jump under
        // the cursor.
        let idealHeight = Self.panelHeight
        let aboveSpace = screenFrame.maxY - (anchorRect.maxY + verticalGap) - edgePadding
        let belowSpace = (anchorRect.minY - verticalGap) - screenFrame.minY - edgePadding

        let isAbove: Bool
        if aboveSpace >= idealHeight {
            isAbove = true
        } else if belowSpace >= idealHeight {
            isAbove = false
        } else {
            isAbove = aboveSpace >= belowSpace
        }

        // Pin the edge adjacent to the word. The body may only grow in
        // the direction AWAY from `pinnedScreenY`.
        let pinnedScreenY: CGFloat
        let maxHeight: CGFloat
        if isAbove {
            pinnedScreenY = anchorRect.maxY + verticalGap  // panel.minY
            maxHeight = max(idealHeight, aboveSpace)
        } else {
            pinnedScreenY = anchorRect.minY - verticalGap  // panel.maxY
            maxHeight = max(idealHeight, belowSpace)
        }

        // Lock X centering once. tailX is the tail tip's horizontal offset
        // inside the panel; clamp so the triangle clears the rounded
        // corners.
        let wordCenterX = wordRect.midX
        var originX = wordCenterX - Self.popupWidth / 2
        originX = max(screenFrame.minX + edgePadding, originX)
        originX = min(screenFrame.maxX - Self.popupWidth - edgePadding, originX)

        let minTail = Self.cornerRadius + Self.tailHalfBase + 2
        let maxTail = Self.popupWidth - Self.cornerRadius - Self.tailHalfBase - 2
        let tailX = max(minTail, min(maxTail, wordCenterX - originX))

        let tailConfig = BubbleBackgroundView.TailConfig(
            edge: isAbove ? .bottom : .top,
            tailX: tailX,
            tailHeight: Self.tailHeight,
            tailHalfBase: Self.tailHalfBase,
            cornerRadius: Self.cornerRadius
        )
        bubbleBackground.tailConfig = tailConfig

        anchorState = AnchorState(
            isAbove: isAbove,
            pinnedScreenY: pinnedScreenY,
            originX: originX,
            maxHeight: maxHeight,
            tailConfig: tailConfig
        )

        // update() runs reflowAnchoredFrame() which calls setFrame.
        update(text)
        panel.orderFrontRegardless()
        dismissArmedAt = Date().addingTimeInterval(0.25)
    }

    func update(_ text: String) {
        let parsed = ParsedPopupText(text)
        statusLabel.stringValue = parsed.status
        wordLabel.stringValue = parsed.word
        posLabel.stringValue = parsed.wordPOS
        posLabel.isHidden = parsed.wordPOS.isEmpty
        briefLabel.stringValue = parsed.wordBrief
        briefLabel.isHidden = parsed.wordBrief.isEmpty
        sourceStack.isHidden = parsed.word.isEmpty
        targetTextView.string = parsed.target
        targetTextView.scrollToEndOfDocument(nil)

        if let state = anchorState {
            reflowAnchoredFrame(state: state)
        }
    }

    /// Recompute the anchored panel's frame using the frozen `state`. The
    /// edge adjacent to the word (`state.pinnedScreenY`) NEVER moves —
    /// the far edge does, clamped by `state.maxHeight`. This is the
    /// geometric invariant that guarantees the body can never cross
    /// into the word, no matter how much streaming content arrives.
    private func reflowAnchoredFrame(state: AnchorState) {
        let height = min(state.maxHeight, Self.panelHeight)

        let originY: CGFloat
        if state.isAbove {
            // panel.minY is pinned; panel grows upward away from the word.
            originY = state.pinnedScreenY
        } else {
            // panel.maxY is pinned; panel grows downward away from the word.
            originY = state.pinnedScreenY - height
        }

        let newFrame = NSRect(
            x: state.originX,
            y: originY,
            width: Self.popupWidth,
            height: height
        )
        if !panel.frame.equalTo(newFrame) {
            panel.setFrame(newFrame, display: true)
        }
    }

    func append(_ delta: String) {
        update(targetTextView.string + delta)
    }

    func close() {
        guard panel.isVisible else { return }
        anchorState = nil
        panel.orderOut(nil)
        onCloseHandler?()
    }

    private func makeHeader() -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let badge = NSTextField(labelWithString: "译")
        badge.alignment = .center
        badge.font = .systemFont(ofSize: 14, weight: .semibold)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 8
        badge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 28).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 1

        let title = NSTextField(labelWithString: "MacScreenTrans")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        titleStack.addArrangedSubview(title)
        titleStack.addArrangedSubview(statusLabel)

        header.addArrangedSubview(badge)
        header.addArrangedSubview(titleStack)
        header.addArrangedSubview(NSView())
        let copyButton = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制译文") ?? NSImage(),
            target: self,
            action: #selector(copyCurrentText)
        )
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.isBordered = false
        copyButton.toolTip = "复制译文"
        copyButton.contentTintColor = .secondaryLabelColor
        header.addArrangedSubview(copyButton)
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        return header
    }

    @objc private func copyCurrentText() {
        let text = targetTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = "已复制"
    }

    private func configureSourceStack() {
        // Mini-dictionary entry for the pointed word.
        // Layout:
        //   [Word]                       — 22pt semibold, label color
        //   [POS · Brief]                — POS italic 13pt secondary, brief 14pt label
        //   [Thin separator]             — full-width separator above the phrase translation
        sourceStack.orientation = .vertical
        sourceStack.spacing = 4
        sourceStack.alignment = .leading

        wordLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        wordLabel.textColor = .labelColor
        wordLabel.lineBreakMode = .byTruncatingTail
        wordLabel.maximumNumberOfLines = 1

        let posBriefRow = NSStackView()
        posBriefRow.orientation = .horizontal
        posBriefRow.alignment = .firstBaseline
        posBriefRow.spacing = 6

        let posBaseFont = NSFont.systemFont(ofSize: 13)
        let italicDescriptor = posBaseFont.fontDescriptor.withSymbolicTraits(.italic)
        posLabel.font = NSFont(descriptor: italicDescriptor, size: 13) ?? posBaseFont
        posLabel.textColor = .secondaryLabelColor
        posLabel.lineBreakMode = .byTruncatingTail
        posLabel.maximumNumberOfLines = 1

        briefLabel.font = .systemFont(ofSize: 14)
        briefLabel.textColor = .labelColor
        briefLabel.lineBreakMode = .byTruncatingTail
        briefLabel.maximumNumberOfLines = 2
        briefLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        posBriefRow.addArrangedSubview(posLabel)
        posBriefRow.addArrangedSubview(briefLabel)

        // 10pt vertical gap before the separator that divides the dictionary
        // entry from the phrase translation scroll view below.
        let gap = NSView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let innerSeparator = NSBox()
        innerSeparator.boxType = .separator

        sourceStack.addArrangedSubview(wordLabel)
        sourceStack.addArrangedSubview(posBriefRow)
        sourceStack.addArrangedSubview(gap)
        sourceStack.addArrangedSubview(innerSeparator)

        wordLabel.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
        posBriefRow.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
        innerSeparator.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
    }

    private func origin(near point: CGPoint, size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return CGPoint(x: point.x + 16, y: point.y - size.height - 16) }

        var x = point.x + 16
        var y = point.y - size.height - 16
        if x + size.width > screen.visibleFrame.maxX {
            x = point.x - size.width - 16
        }
        if y < screen.visibleFrame.minY {
            y = point.y + 16
        }
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        y = min(max(y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - size.height - 8)
        return CGPoint(x: x, y: y)
    }

    private func installDismissMonitors() {
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 {
                self?.close()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                self?.closeIfClickIsOutsidePanel()
            }
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.close() }
            }
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closeIfClickIsOutsidePanel() }
        }
    }

    private func closeIfClickIsOutsidePanel() {
        guard Date() >= dismissArmedAt else { return }
        guard panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        close()
    }

    deinit {
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }
}

private struct ParsedPopupText {
    let status: String
    let word: String
    let wordPOS: String
    let wordBrief: String
    let source: String
    let target: String

    init(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) New tagged schema: 单词 / 词性 / 释义 / 意群 / 译文.
        let tagged = Self.parseTaggedSchema(text)
        if tagged.matched {
            self.word = tagged.word
            self.wordPOS = tagged.wordPOS
            self.wordBrief = tagged.wordBrief
            self.source = tagged.source
            let resolvedTarget = tagged.target
            if resolvedTarget.isEmpty {
                self.target = tagged.source.isEmpty ? "" : "正在补译..."
                self.status = "翻译中"
            } else {
                self.target = resolvedTarget
                self.status = resolvedTarget.hasPrefix("正在") ? "翻译中" : "翻译完成"
            }
            return
        }

        // 2) Legacy schema from prior streaming partials: "意群: X[\n释义: Y]".
        //    Kept so transitional or fallback-path strings still render.
        let legacySourcePrefix = "意群:"
        let legacyTargetPrefix = "\n释义:"

        if text.hasPrefix(legacySourcePrefix) {
            let afterSourcePrefix = text.index(text.startIndex, offsetBy: legacySourcePrefix.count)

            if let targetRange = text.range(of: legacyTargetPrefix) {
                let parsedTarget = text[targetRange.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parsedSource = text[afterSourcePrefix..<targetRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.status = parsedTarget.isEmpty || parsedTarget.hasPrefix("正在") ? "翻译中" : "翻译完成"
                self.word = parsedSource
                self.wordPOS = ""
                self.wordBrief = ""
                self.source = parsedSource
                self.target = parsedTarget.isEmpty ? "正在补译..." : parsedTarget
                return
            }

            self.status = "翻译中"
            let parsedSource = text[afterSourcePrefix...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.word = parsedSource
            self.wordPOS = ""
            self.wordBrief = ""
            self.source = parsedSource
            self.target = "正在补译..."
            return
        }

        if text.hasPrefix("正在解释：") {
            self.status = "翻译中"
            let parsedSource = String(text.dropFirst("正在解释：".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            self.word = parsedSource
            self.wordPOS = ""
            self.wordBrief = ""
            self.source = parsedSource
            self.target = "等待模型输出..."
            return
        }

        if text.isEmpty {
            self.status = "就绪"
            self.word = ""
            self.wordPOS = ""
            self.wordBrief = ""
            self.source = ""
            self.target = ""
            return
        }

        // Catch-all: status messages or fallback plain text.
        self.status = "状态"
        self.word = ""
        self.wordPOS = ""
        self.wordBrief = ""
        self.source = ""
        self.target = text
    }

    private struct TaggedParse {
        var matched: Bool
        var word: String
        var wordPOS: String
        var wordBrief: String
        var source: String
        var target: String
    }

    /// Parse the tagged popup schema emitted by `SenseGroupResponseRenderer.displayText`.
    /// Schema lines (any subset, in this order):
    ///   单词: <word>
    ///   词性: <pos>
    ///   释义: <brief>
    ///   意群: <source_chunk>
    ///   译文: <target_chunk>
    /// `matched` is true only when a tag exclusive to the new schema is seen
    /// (单词 / 词性 / 译文). 释义 and 意群 alone overlap with the legacy
    /// format so they don't trigger a new-schema match on their own.
    private static func parseTaggedSchema(_ text: String) -> TaggedParse {
        var result = TaggedParse(
            matched: false,
            word: "",
            wordPOS: "",
            wordBrief: "",
            source: "",
            target: ""
        )

        let lines = text.components(separatedBy: "\n")
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if let value = Self.value(after: "单词:", in: line) {
                result.word = value
                result.matched = true
            } else if let value = Self.value(after: "词性:", in: line) {
                result.wordPOS = value
                result.matched = true
            } else if let value = Self.value(after: "译文:", in: line) {
                result.target = value
                result.matched = true
            } else if let value = Self.value(after: "释义:", in: line) {
                // Ambiguous tag: in the new schema it carries the word brief;
                // in the legacy format it carries the phrase translation.
                // Capture it but don't flip `matched` on its strength alone.
                result.wordBrief = value
            } else if let value = Self.value(after: "意群:", in: line) {
                // Same caveat as 释义: present in both schemas.
                result.source = value
            }
        }
        return result
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let valueStart = line.index(line.startIndex, offsetBy: prefix.count)
        return String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Hosts the bubble shape: a rounded rect body plus an optional triangular
/// tail on either top or bottom edge. The bubble path is drawn (solid fill
/// + thin stroke) by the embedded `OpaqueBubbleFillView`, matching native
/// AppKit popover opacity instead of the previous translucent blur.
private final class BubbleBackgroundView: NSView {
    struct TailConfig: Equatable {
        enum Edge { case top, bottom }
        let edge: Edge
        let tailX: CGFloat
        let tailHeight: CGFloat
        let tailHalfBase: CGFloat
        let cornerRadius: CGFloat
    }

    var tailConfig: TailConfig? {
        didSet {
            if tailConfig != oldValue {
                needsLayout = true
                fillView?.tailConfig = tailConfig
            }
        }
    }

    weak var fillView: OpaqueBubbleFillView?
    weak var contentStack: NSStackView?

    private var contentTopConstraint: NSLayoutConstraint?
    private var contentBottomConstraint: NSLayoutConstraint?
    private var baseInset: CGFloat = 14
    private var baseTailHeight: CGFloat = 0

    override var isFlipped: Bool { false }

    func applyContentConstraints(
        fillView: OpaqueBubbleFillView,
        contentStack: NSStackView,
        inset: CGFloat,
        tailHeight: CGFloat
    ) {
        self.baseInset = inset
        self.baseTailHeight = tailHeight

        // fillView fills the whole panel and draws the opaque bubble shape
        // (body + tail). The window's shadow follows the masked layer.
        let csTop = contentStack.topAnchor.constraint(equalTo: topAnchor, constant: inset)
        let csBottom = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        contentTopConstraint = csTop
        contentBottomConstraint = csBottom

        NSLayoutConstraint.activate([
            fillView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fillView.trailingAnchor.constraint(equalTo: trailingAnchor),
            fillView.topAnchor.constraint(equalTo: topAnchor),
            fillView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            csTop,
            csBottom
        ])
    }

    override func layout() {
        super.layout()
        applyTailLayout()
        applyMaskAndShadow()
    }

    private func applyTailLayout() {
        // When the tail sits on a given edge, content must be pushed away
        // from that edge by tailHeight so it doesn't draw inside the
        // triangle.
        let topInset: CGFloat
        let bottomInset: CGFloat
        switch tailConfig?.edge {
        case .top:
            topInset = baseTailHeight
            bottomInset = 0
        case .bottom:
            topInset = 0
            bottomInset = baseTailHeight
        case .none:
            topInset = 0
            bottomInset = 0
        }

        contentTopConstraint?.constant = baseInset + topInset
        contentBottomConstraint?.constant = -(baseInset + bottomInset)
    }

    private func applyMaskAndShadow() {
        // The OpaqueBubbleFillView redraws itself in response to bounds &
        // tailConfig changes; nothing further to mask at this level. The
        // window's drop shadow tracks the fill view's opaque alpha shape
        // via the layer mask installed in OpaqueBubbleFillView.layout().
        fillView?.needsDisplay = true
        fillView?.needsLayout = true
    }

    fileprivate func bubblePath(in rect: NSRect) -> CGPath {
        let path = CGMutablePath()
        let radius = tailConfig?.cornerRadius ?? 14

        guard let tail = tailConfig else {
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
            return path
        }

        // Carve a body rect that leaves room for the tail on one edge.
        let body: NSRect
        switch tail.edge {
        case .bottom:
            body = NSRect(
                x: rect.minX,
                y: rect.minY + tail.tailHeight,
                width: rect.width,
                height: rect.height - tail.tailHeight
            )
        case .top:
            body = NSRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: rect.height - tail.tailHeight
            )
        }

        let halfBase = tail.tailHalfBase
        let height = tail.tailHeight
        // tailX is expressed in the panel's local x — same origin as `rect`.
        let tipX = tail.tailX

        switch tail.edge {
        case .bottom:
            let bodyBottom = body.minY
            let tipY = bodyBottom - height

            let leftBase = tipX - halfBase
            let rightBase = tipX + halfBase

            // Trace clockwise from top-left.
            path.move(to: CGPoint(x: body.minX + radius, y: body.maxY))
            path.addLine(to: CGPoint(x: body.maxX - radius, y: body.maxY))
            path.addArc(
                tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                tangent2End: CGPoint(x: body.maxX, y: body.maxY - radius),
                radius: radius
            )
            path.addLine(to: CGPoint(x: body.maxX, y: bodyBottom + radius))
            path.addArc(
                tangent1End: CGPoint(x: body.maxX, y: bodyBottom),
                tangent2End: CGPoint(x: body.maxX - radius, y: bodyBottom),
                radius: radius
            )
            path.addLine(to: CGPoint(x: rightBase, y: bodyBottom))
            path.addLine(to: CGPoint(x: tipX, y: tipY))
            path.addLine(to: CGPoint(x: leftBase, y: bodyBottom))
            path.addLine(to: CGPoint(x: body.minX + radius, y: bodyBottom))
            path.addArc(
                tangent1End: CGPoint(x: body.minX, y: bodyBottom),
                tangent2End: CGPoint(x: body.minX, y: bodyBottom + radius),
                radius: radius
            )
            path.addLine(to: CGPoint(x: body.minX, y: body.maxY - radius))
            path.addArc(
                tangent1End: CGPoint(x: body.minX, y: body.maxY),
                tangent2End: CGPoint(x: body.minX + radius, y: body.maxY),
                radius: radius
            )
            path.closeSubpath()

        case .top:
            let bodyTop = body.maxY
            let tipY = bodyTop + height

            let leftBase = tipX - halfBase
            let rightBase = tipX + halfBase

            path.move(to: CGPoint(x: body.minX + radius, y: bodyTop))
            path.addLine(to: CGPoint(x: leftBase, y: bodyTop))
            path.addLine(to: CGPoint(x: tipX, y: tipY))
            path.addLine(to: CGPoint(x: rightBase, y: bodyTop))
            path.addLine(to: CGPoint(x: body.maxX - radius, y: bodyTop))
            path.addArc(
                tangent1End: CGPoint(x: body.maxX, y: bodyTop),
                tangent2End: CGPoint(x: body.maxX, y: bodyTop - radius),
                radius: radius
            )
            path.addLine(to: CGPoint(x: body.maxX, y: body.minY + radius))
            path.addArc(
                tangent1End: CGPoint(x: body.maxX, y: body.minY),
                tangent2End: CGPoint(x: body.maxX - radius, y: body.minY),
                radius: radius
            )
            path.addLine(to: CGPoint(x: body.minX + radius, y: body.minY))
            path.addArc(
                tangent1End: CGPoint(x: body.minX, y: body.minY),
                tangent2End: CGPoint(x: body.minX, y: body.minY + radius),
                radius: radius
            )
            path.addLine(to: CGPoint(x: body.minX, y: bodyTop - radius))
            path.addArc(
                tangent1End: CGPoint(x: body.minX, y: bodyTop),
                tangent2End: CGPoint(x: body.minX + radius, y: bodyTop),
                radius: radius
            )
            path.closeSubpath()
        }

        return path
    }
}

/// Solid-fill bubble background. Draws the speech-bubble path with an
/// opaque system "elevated" color plus a hairline border. Replaces the
/// prior NSVisualEffectView so underlying app content cannot bleed
/// through the popup body, matching the look of Apple's native popovers
/// (e.g. Dictionary's Look Up window) at rest.
fileprivate final class OpaqueBubbleFillView: NSView {
    var tailConfig: BubbleBackgroundView.TailConfig? {
        didSet {
            if tailConfig != oldValue {
                needsDisplay = true
                needsLayout = true
            }
        }
    }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // The window's drop shadow follows the layer's alpha; mask the
        // backing layer to the bubble path so the shadow conforms to the
        // tail rather than the bounding rect.
        let layer = self.layer ?? CALayer()
        self.layer = layer
        let path = bubblePath(in: bounds)
        let maskLayer = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        maskLayer.path = path
        maskLayer.frame = bounds
        layer.mask = maskLayer
        // The panel's size is locked (min==max), so swapping bubble shapes
        // (cursor-fallback rounded rect ↔ anchored tail bubble) never
        // triggers AppKit's own shadow recomputation — the old shape's
        // shadow rim lingers as a ghost outline below the new bubble.
        // Recompute explicitly every time the mask changes.
        window?.invalidateShadow()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let path = bubblePath(in: bounds)

        context.saveGState()
        defer { context.restoreGState() }

        context.addPath(path)
        context.setFillColor(fillColor().cgColor)
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(strokeColor().cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    private func fillColor() -> NSColor {
        // Use `windowBackgroundColor` rather than `controlBackgroundColor`
        // — it tracks the system popover/window chrome (slightly tinted
        // off-white in light mode, near-black in dark mode), matching the
        // Look Up popover's body.
        NSColor.windowBackgroundColor
    }

    private func strokeColor() -> NSColor {
        NSColor.separatorColor
    }

    private func bubblePath(in rect: NSRect) -> CGPath {
        if let parent = superview as? BubbleBackgroundView {
            return parent.bubblePath(in: rect)
        }
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: 14, cornerHeight: 14)
        return path
    }
}
