import AppKit
import Carbon.HIToolbox

/// Registers a global hotkey (Cmd+Option+T) and invokes the registered
/// callback whenever it fires — the escape hatch for triggering translation
/// when the three-finger trackpad gesture isn't available.
///
/// Implemented with Carbon's `RegisterEventHotKey`, which needs NO TCC
/// permission and fires regardless of which app is focused. The previous
/// `NSEvent.addGlobalMonitorForEvents` implementation silently required
/// Accessibility permission — which this app stopped requesting when the
/// word-capture backend moved from AX to Screen Recording — so the hotkey
/// never fired unless MacScreenTrans itself was frontmost.
@MainActor
final class GlobalShortcutMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    private static let signature: OSType = 0x4D53_5454 // 'MSTT'

    func start(onTrigger: @escaping () -> Void) {
        stop()
        self.onTrigger = onTrigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // The handler fires on the main thread (application event target).
        // The context pointer carries `self` unretained; `stop()` removes
        // the handler before the monitor could ever go away.
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context -> OSStatus in
                guard let event, let context else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard hotKeyID.signature == GlobalShortcutMonitor.signature else { return noErr }
                let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(context).takeUnretainedValue()
                // Carbon dispatches application-target handlers on the main
                // thread; assumeIsolated converts that runtime guarantee for
                // the compiler.
                MainActor.assumeIsolated {
                    monitor.fire()
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
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
}
