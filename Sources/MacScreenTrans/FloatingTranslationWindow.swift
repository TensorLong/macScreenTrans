import AppKit

@MainActor
final class FloatingTranslationWindowController {
    private let panel: NSPanel
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let sourceStack = NSStackView()
    private let sourceText = NSTextField(labelWithString: "")
    private let targetTextView = NSTextView()
    nonisolated(unsafe) private var localDismissMonitor: Any?
    nonisolated(unsafe) private var globalKeyMonitor: Any?
    nonisolated(unsafe) private var globalMouseMonitor: Any?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 230),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.addSubview(visualEffect)
        panel.contentView = root

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.spacing = 10
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)

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
        targetTextView.string = ""
        scrollView.documentView = targetTextView

        contentStack.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        NSLayoutConstraint.activate([
            visualEffect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            visualEffect.topAnchor.constraint(equalTo: root.topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])

        installDismissMonitors()
    }

    func show(at point: CGPoint, text: String) {
        update(text)
        panel.setFrameOrigin(origin(near: point, size: panel.frame.size))
        panel.orderFrontRegardless()
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
        panel.orderOut(nil)
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
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        return header
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
        if text.hasPrefix("意群:"),
           let targetRange = text.range(of: "\n释义:") {
            status = "Translation"
            source = text[text.index(text.startIndex, offsetBy: 3)..<targetRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            target = text[targetRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        if text.hasPrefix("正在解释：") {
            status = "Streaming"
            source = String(text.dropFirst("正在解释：".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            target = "等待模型输出..."
            return
        }

        if text.isEmpty {
            status = "Ready"
            source = ""
            target = ""
            return
        }

        status = "Status"
        source = ""
        target = text
    }
}
