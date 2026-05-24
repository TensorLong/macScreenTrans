import AppKit

/// Listens for a global hotkey (Cmd+Option+T) and invokes the registered
/// callback whenever it fires. v0.2.2 adds this as an escape hatch so the
/// user can still trigger translation while the three-finger trackpad
/// gesture is silently rejecting touches (see Issue 5 follow-up). We use
/// `NSEvent.addGlobalMonitorForEvents` (cursor in another app) plus
/// `addLocalMonitorForEvents` (MacScreenTrans focused) because the global
/// monitor doesn't observe key events delivered to the current process.
///
/// Both monitors require the same Accessibility permission we already
/// request — no new TCC prompt. The local monitor returns `nil` so the
/// keystroke doesn't propagate as a text-input "t" inside any text
/// field MacScreenTrans owns.
@MainActor
final class GlobalShortcutMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onTrigger: (() -> Void)?

    func start(onTrigger: @escaping () -> Void) {
        stop()
        self.onTrigger = onTrigger

        let mask: NSEvent.EventTypeMask = .keyDown

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            if Self.matchesShortcut(event) {
                MainActor.assumeIsolated {
                    self.fire()
                }
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if Self.matchesShortcut(event) {
                self.fire()
                return nil
            }
            return event
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        onTrigger = nil
    }

    // No deinit cleanup: the monitor is owned by AppDelegate for the full
    // app lifetime, and `applicationWillTerminate` calls `stop()` before
    // process exit. A nonisolated deinit cannot touch these @MainActor-
    // bound stored properties under Swift 6 strict concurrency.

    private func fire() {
        onTrigger?()
    }

    /// Matches Cmd+Option+T exactly. Other modifier combinations (e.g.
    /// Cmd+Shift+Option+T) are intentionally excluded so we don't steal
    /// shortcuts the user wired up in another tool.
    private static func matchesShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.command, .option] else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "t"
    }
}
