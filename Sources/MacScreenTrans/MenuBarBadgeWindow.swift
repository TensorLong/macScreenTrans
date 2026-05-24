import AppKit

@MainActor
final class MenuBarBadgeWindowController {
    private let panel: NSPanel
    private let badgeView: MenuBarBadgeView
    nonisolated(unsafe) private var screenChangeObserver: NSObjectProtocol?

    init(menu: NSMenu) {
        badgeView = MenuBarBadgeView(menu: menu)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 32, height: 26),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.contentView = badgeView

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        // macOS can hide third-party NSStatusItems when the menu bar is crowded or
        // managed by another utility. Keep this visual affordance in the same area.
        let reservedRightWidth: CGFloat = 126
        let x = screen.frame.maxX - reservedRightWidth - panel.frame.width
        let y = screen.frame.maxY - menuBarHeight + max(0, (menuBarHeight - panel.frame.height) / 2)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }
}

private final class MenuBarBadgeView: NSView {
    private let badgeMenu: NSMenu
    private let image = StatusBarIcon.makeBadge()

    init(menu: NSMenu) {
        badgeMenu = menu
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 26))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        image.draw(in: NSRect(x: 4, y: 1, width: 24, height: 24))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu()
    }

    func showMenu() {
        badgeMenu.update()
        let yOffset = -max(32, badgeMenu.size.height + 4)
        badgeMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: yOffset), in: self)
    }
}
