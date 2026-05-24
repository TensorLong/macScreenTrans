import AppKit
import ApplicationServices

/// Autonomous AX self-test harness. Invoked by passing `--self-test` to the
/// app binary. Spawns a deterministic NSTextView with known text, then calls
/// `AXWordReader.resolve(at:)` at several screen positions inside the text
/// and prints a per-probe report to stdout. Exits before the normal app
/// delegate runs.
///
/// Why this exists: the v0.1.9 regression ("rejects every cursor position")
/// is in a code path that only fires against a real AX hierarchy — unit
/// tests can't catch it. Running this from a signed .app bundle reuses the
/// bundle's Accessibility TCC grant, so we get full AX access without any
/// external automation tool (Peekaboo / Hammerspoon / cliclick) and the
/// permission dance they bring.
enum SelfTest {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = SelfTestDelegate()
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

private final class SelfTestDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?
    private static let probeText = "The quick brown fox jumps over the lazy dog right now"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSTextView (not NSTextField label) — only NSTextView reliably
        // implements kAXRangeForPositionParameterizedAttribute /
        // kAXBoundsForRangeParameterizedAttribute, which is exactly the
        // code path AXWordReader exercises in production.
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 60))
        textView.string = Self.probeText
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.font = NSFont.systemFont(ofSize: 28)
        textView.drawsBackground = true
        textView.backgroundColor = .windowBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        self.textView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 400, width: 760, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "MacScreenTrans Self-Test"
        textView.frame = NSRect(x: 20, y: 40, width: 720, height: 60)
        window.contentView?.addSubview(textView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        // Give WindowServer + the AX tree enough time to register before
        // probing. Empirically ~500ms is enough; 1s keeps margin in CI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.runProbes()
            exit(0)
        }
    }

    private func runProbes() {
        guard let window = window, let textView = textView else {
            print("[SelfTest] FAIL: window/textView missing")
            return
        }

        let textInWindow = textView.convert(textView.bounds, to: nil)
        let textOnScreen = window.convertToScreen(textInWindow)

        print("[SelfTest] window=\(window.frame)")
        print("[SelfTest] textView onScreen=\(textOnScreen)")
        print("[SelfTest] text=\"\(Self.probeText)\" len=\(Self.probeText.count)")
        print()

        let positions: [(name: String, point: NSPoint)] = [
            ("left",     NSPoint(x: textOnScreen.minX + 80,                          y: textOnScreen.midY)),
            ("quarter",  NSPoint(x: textOnScreen.minX + textOnScreen.width * 0.30,   y: textOnScreen.midY)),
            ("middle",   NSPoint(x: textOnScreen.midX,                               y: textOnScreen.midY)),
            ("three-q",  NSPoint(x: textOnScreen.minX + textOnScreen.width * 0.70,   y: textOnScreen.midY)),
            ("right",    NSPoint(x: textOnScreen.maxX - 80,                          y: textOnScreen.midY)),
        ]

        var passed = 0
        var failed = 0
        var distinctWords = Set<String>()

        for (name, pt) in positions {
            print("--- probe[\(name)] AppKit=(\(Int(pt.x)),\(Int(pt.y))) ---")
            if let result = AXWordReader.resolve(at: pt) {
                print("✓ word=\"\(result.selection.word)\"")
                if let rect = result.wordRect {
                    print("  wordRect=(\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))×\(Int(rect.height))")
                } else {
                    print("  wordRect=nil")
                }
                passed += 1
                distinctWords.insert(result.selection.word)
            } else {
                print("✗ resolve returned nil")
                failed += 1
            }
            for line in AXWordReader.lastDiagnostic.split(separator: "\n") {
                print("  | \(line)")
            }
            print()
        }

        print("=== Self-test summary ===")
        print("passed: \(passed)  failed: \(failed)")
        print("distinct words: \(distinctWords.count) — \(distinctWords.sorted().joined(separator: ", "))")
        if failed == 0 && distinctWords.count >= 3 {
            print("VERDICT: PASS — multiple distinct words resolved across positions")
        } else if failed == 0 && distinctWords.count == 1 {
            print("VERDICT: REGRESSION-v0.1.8 — every position returns the same word")
        } else if failed == positions.count {
            print("VERDICT: REGRESSION-v0.1.9 — every position rejected")
        } else {
            print("VERDICT: PARTIAL — see diagnostics above")
        }
    }
}
