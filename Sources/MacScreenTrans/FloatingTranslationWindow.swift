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

    private let panel: NSPanel
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let sourceStack = NSStackView()
    private let sourceText = NSTextField(labelWithString: "")
    private let targetTextView = NSTextView()
    private let bubbleBackground: BubbleBackgroundView
    private var dismissArmedAt = Date.distantPast
    private var onCloseHandler: (() -> Void)?
    nonisolated(unsafe) private var localDismissMonitor: Any?
    nonisolated(unsafe) private var globalKeyMonitor: Any?
    nonisolated(unsafe) private var globalMouseMonitor: Any?

    init() {
        let initialFrame = NSRect(
            x: 0,
            y: 0,
            width: Self.popupWidth,
            height: Self.popupHeight
        )
        panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // NSWindow draws a system shadow around the opaque region of its
        // content; with a bubble mask the shadow follows the tail correctly.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow

        bubbleBackground = BubbleBackgroundView(frame: initialFrame)
        panel.contentView = bubbleBackground

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        bubbleBackground.addSubview(visualEffect)
        bubbleBackground.visualEffectView = visualEffect

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
        scrollView.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.42)
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
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        bubbleBackground.applyContentConstraints(
            visualEffect: visualEffect,
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
        update(text)
        bubbleBackground.tailConfig = nil
        let size = NSSize(width: Self.popupWidth, height: Self.popupHeight)
        let origin = origin(near: point, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        dismissArmedAt = Date().addingTimeInterval(0.25)
    }

    /// Show the popup as a speech bubble anchored to `wordRect` (AppKit
    /// screen coords). Tail points DOWN at the word when the bubble is
    /// above, UP when below.
    func show(anchoredTo wordRect: NSRect, text: String) {
        update(text)

        let screenFrame = (NSScreen.screens.first {
            NSMouseInRect(CGPoint(x: wordRect.midX, y: wordRect.midY), $0.frame, false)
        } ?? NSScreen.main)?.visibleFrame ?? .zero

        // Include the tail in the panel size so the bubble path has room
        // to draw both the body and the triangle.
        let size = NSSize(
            width: Self.popupWidth,
            height: Self.popupHeight + Self.tailHeight
        )
        let verticalGap: CGFloat = 2
        let placement = ScreenCoordinateConverter.popupPlacement(
            wordRect: wordRect,
            popupSize: size,
            screenVisibleFrame: screenFrame,
            verticalGap: verticalGap
        )

        // Constrain tailX so the tail can still draw a clean triangle near
        // the bubble's rounded corners.
        let minTail = Self.cornerRadius + Self.tailHalfBase + 2
        let maxTail = size.width - Self.cornerRadius - Self.tailHalfBase - 2
        let tailX = max(minTail, min(maxTail, placement.tailX))

        bubbleBackground.tailConfig = BubbleBackgroundView.TailConfig(
            edge: placement.isAboveWord ? .bottom : .top,
            tailX: tailX,
            tailHeight: Self.tailHeight,
            tailHalfBase: Self.tailHalfBase,
            cornerRadius: Self.cornerRadius
        )
        panel.setFrame(NSRect(origin: placement.origin, size: size), display: true)
        panel.orderFrontRegardless()
        dismissArmedAt = Date().addingTimeInterval(0.25)
    }

    func update(_ text: String) {
        let parsed = ParsedPopupText(text)
        statusLabel.stringValue = parsed.status
        sourceStack.isHidden = parsed.source.isEmpty
        sourceText.stringValue = parsed.source
        targetTextView.string = parsed.target
        targetTextView.scrollToEndOfDocument(nil)
    }

    func append(_ delta: String) {
        update(targetTextView.string + delta)
    }

    func close() {
        guard panel.isVisible else { return }
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
        sourceStack.orientation = .vertical
        sourceStack.spacing = 5
        sourceStack.alignment = .leading

        let caption = NSTextField(labelWithString: "意群")
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .secondaryLabelColor

        sourceText.font = .systemFont(ofSize: 16, weight: .semibold)
        sourceText.textColor = .labelColor
        sourceText.lineBreakMode = .byTruncatingTail
        sourceText.maximumNumberOfLines = 2
        sourceText.wantsLayer = true
        sourceText.layer?.cornerRadius = 8
        sourceText.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor

        sourceStack.addArrangedSubview(caption)
        sourceStack.addArrangedSubview(sourceText)
        sourceText.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
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
    let source: String
    let target: String

    init(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourcePrefix = "意群:"
        let targetPrefix = "\n释义:"

        if text.hasPrefix(sourcePrefix) {
            let afterSourcePrefix = text.index(text.startIndex, offsetBy: sourcePrefix.count)

            if let targetRange = text.range(of: targetPrefix) {
                let parsedTarget = text[targetRange.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                status = parsedTarget.isEmpty || parsedTarget.hasPrefix("正在") ? "翻译中" : "翻译完成"
                source = text[afterSourcePrefix..<targetRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                target = parsedTarget.isEmpty ? "正在补译..." : parsedTarget
                return
            }

            // Streaming may emit "意群: X" before the next chunk adds "\n释义: Y".
            // Don't drop into the catch-all path (which hides the source field and
            // dumps the whole line into the translation slot); keep the source
            // visible and show a placeholder until the target arrives.
            status = "翻译中"
            source = text[afterSourcePrefix...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            target = "正在补译..."
            return
        }

        if text.hasPrefix("正在解释：") {
            status = "翻译中"
            source = String(text.dropFirst("正在解释：".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            target = "等待模型输出..."
            return
        }

        if text.isEmpty {
            status = "就绪"
            source = ""
            target = ""
            return
        }

        status = "状态"
        source = ""
        target = text
    }
}

/// Hosts the bubble shape: a rounded rect body plus an optional triangular
/// tail on either top or bottom edge. The shape is applied as a layer mask
/// to the panel's visual-effect view so the system blur, shadow, and
/// content all conform to it.
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
            if tailConfig != oldValue { needsLayout = true }
        }
    }

    weak var visualEffectView: NSVisualEffectView?
    weak var contentStack: NSStackView?

    private var contentTopConstraint: NSLayoutConstraint?
    private var contentBottomConstraint: NSLayoutConstraint?
    private var baseInset: CGFloat = 14
    private var baseTailHeight: CGFloat = 0

    override var isFlipped: Bool { false }

    func applyContentConstraints(
        visualEffect: NSVisualEffectView,
        contentStack: NSStackView,
        inset: CGFloat,
        tailHeight: CGFloat
    ) {
        self.baseInset = inset
        self.baseTailHeight = tailHeight

        // visualEffect fills the whole panel. The bubble path masks it to
        // the speech-bubble shape (body + tail).
        let csTop = contentStack.topAnchor.constraint(equalTo: topAnchor, constant: inset)
        let csBottom = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        contentTopConstraint = csTop
        contentBottomConstraint = csBottom

        NSLayoutConstraint.activate([
            visualEffect.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffect.topAnchor.constraint(equalTo: topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        guard let visualEffectView else { return }
        visualEffectView.wantsLayer = true
        let layer = visualEffectView.layer ?? CALayer()
        visualEffectView.layer = layer

        let path = bubblePath(in: visualEffectView.bounds)
        let maskLayer = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        maskLayer.path = path
        maskLayer.frame = visualEffectView.bounds
        layer.mask = maskLayer
    }

    private func bubblePath(in rect: NSRect) -> CGPath {
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
