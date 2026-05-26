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
    private var button: NSButton?
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

        // NSButton — v0.2.3 AXTextRoleProbe section uses it to validate
        // the hard-exclude path. The probe was widened to accept
        // `kAXValueAttribute` as String; without the AXButton hard-
        // exclude, the button's title would falsely pass acceptance
        // (Issue 5 false positive).
        let button = NSButton(frame: NSRect(x: 20, y: 6, width: 100, height: 28))
        button.title = "Save"
        button.bezelStyle = .rounded
        self.button = button

        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 400, width: 760, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "MacScreenTrans Self-Test"
        textView.frame = NSRect(x: 20, y: 40, width: 720, height: 60)
        window.contentView?.addSubview(textView)
        window.contentView?.addSubview(button)
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
        // Capture the "middle" probe's result so the phrase test can reuse
        // its AX element without doing a second resolve at a different
        // position — that keeps phrase lookup independent of further
        // cursor motion.
        var middleResult: AXWordReader.Result?

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
                if name == "middle" {
                    middleResult = result
                }
            } else {
                print("✗ resolve returned nil")
                failed += 1
            }
            for line in AXWordReader.lastDiagnostic.split(separator: "\n") {
                print("  | \(line)")
            }
            print()
        }

        // v0.2 phrase-rect probe: ask for a 3-word substring of the probe
        // text and confirm we get back at least one segment whose `text`
        // contains the leading word. The leading word check guards against
        // a fuzzy match that landed on a non-overlapping span.
        let phrase = "quick brown fox"
        let leadingWord = "quick"
        var phraseSegments: [AXWordReader.PhraseSegment] = []
        var phraseOK = false
        print("--- phrase[\"\(phrase)\"] using middle probe ---")
        if let result = middleResult {
            phraseSegments = result.phraseSegments(for: phrase)
            if phraseSegments.isEmpty {
                print("✗ no segments returned")
            } else {
                for (idx, seg) in phraseSegments.enumerated() {
                    print("  seg[\(idx)] rect=(\(Int(seg.rect.minX)),\(Int(seg.rect.minY))) \(Int(seg.rect.width))×\(Int(seg.rect.height)) text=\"\(seg.text)\"")
                }
                let containsLeading = phraseSegments.contains { seg in
                    seg.text.lowercased().contains(leadingWord)
                }
                if containsLeading {
                    print("✓ at least one segment contains \"\(leadingWord)\"")
                    phraseOK = true
                } else {
                    print("✗ no segment contained \"\(leadingWord)\"")
                }
            }
        } else {
            print("✗ middle probe didn't produce a Result")
        }
        for line in AXWordReader.lastDiagnostic.split(separator: "\n") {
            print("  | \(line)")
        }
        print()

        // v0.2.3 AXTextRoleProbe coverage. Closes the saved feedback gap
        // ("--self-test only covers AX text-resolve, NOT role-gate").
        // PASS criteria: probe(textView@middle) == .text (kAXTextArea),
        // probe(button@middle) == .nonText (hard-exclude AXButton).
        let textPoint = NSPoint(x: textOnScreen.midX, y: textOnScreen.midY)
        let buttonInWindow = button?.convert(button?.bounds ?? .zero, to: nil) ?? .zero
        let buttonOnScreen = window.convertToScreen(buttonInWindow)
        let buttonPoint = NSPoint(x: buttonOnScreen.midX, y: buttonOnScreen.midY)

        var roleProbeOK = true
        print("--- probe[textView@middle] AppKit=(\(Int(textPoint.x)),\(Int(textPoint.y))) ---")
        let textOutcome = AXTextRoleProbe.probe(at: textPoint)
        switch textOutcome {
        case .text:
            print("✓ .text")
        case .nonText(let role):
            print("✗ expected .text, got .nonText(\(role))")
            roleProbeOK = false
        case .failed(let reason):
            print("✗ expected .text, got .failed(\(reason))")
            roleProbeOK = false
        }
        for line in AXTextRoleProbe.lastTrace.split(separator: "\n") {
            print("  | \(line)")
        }
        print()

        print("--- probe[button@middle] AppKit=(\(Int(buttonPoint.x)),\(Int(buttonPoint.y))) ---")
        let btnOutcome = AXTextRoleProbe.probe(at: buttonPoint)
        switch btnOutcome {
        case .text:
            print("✗ expected .nonText (button hard-exclude), got .text — FALSE POSITIVE")
            roleProbeOK = false
        case .nonText(let role):
            print("✓ .nonText(\(role))")
        case .failed(let reason):
            // .failed is acceptable — means we didn't hit the button
            // exactly (e.g., window not active). Note it but don't fail.
            print("⚠ .failed(\(reason)) — accepted (window may not be frontmost)")
        }
        for line in AXTextRoleProbe.lastTrace.split(separator: "\n") {
            print("  | \(line)")
        }
        print()

        print("=== Self-test summary ===")
        print("passed: \(passed)  failed: \(failed)")
        print("distinct words: \(distinctWords.count) — \(distinctWords.sorted().joined(separator: ", "))")
        print("phrase segments: \(phraseSegments.count) phrase OK: \(phraseOK)")
        print("role probe OK: \(roleProbeOK)")
        let wordProbesPass = (failed == 0 && distinctWords.count >= 3)
        if wordProbesPass && phraseOK && roleProbeOK {
            print("VERDICT: PASS — word + phrase + role-probe all succeeded")
        } else if wordProbesPass && phraseOK && !roleProbeOK {
            print("VERDICT: REGRESSION-v0.2.3-role-probe — text-resolve pass but role-probe failed")
        } else if wordProbesPass && !phraseOK {
            print("VERDICT: REGRESSION-v0.2-phrase — word probes pass but phrase test failed")
        } else if failed == 0 && distinctWords.count == 1 {
            print("VERDICT: REGRESSION-v0.1.8 — every position returns the same word")
        } else if failed == positions.count {
            print("VERDICT: REGRESSION-v0.1.9 — every position rejected")
        } else {
            print("VERDICT: PARTIAL — see diagnostics above")
        }
    }
}
