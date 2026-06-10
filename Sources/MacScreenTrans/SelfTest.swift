import AppKit
import MacScreenTransCore

/// Autonomous OCR self-test harness. Invoked by passing `--self-test` to the
/// app binary. Renders a deterministic NSTextView with known text, then runs
/// `OCRWordReader.resolve(at:)` at several screen positions inside the text and
/// prints a per-probe report to stdout. Exits before the normal app delegate
/// runs.
///
/// Running this from a signed .app bundle reuses the bundle's Screen Recording
/// TCC grant, so the full capture → Vision → assemble → resolve pipeline is
/// exercised against a real on-screen window without any external automation.
enum SelfTest {
    @MainActor
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // `run()` never returns, so this local retains the delegate (NSApp's
        // delegate property is weak) for the app's lifetime.
        let delegate = SelfTestDelegate()
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

@MainActor
private final class SelfTestDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?
    private static let probeText = "The quick brown fox jumps over the lazy dog right now"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 60))
        textView.string = Self.probeText
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.font = NSFont.systemFont(ofSize: 28)
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textColor = .black
        textView.textContainerInset = NSSize(width: 8, height: 8)
        self.textView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 400, width: 760, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "MacScreenTrans Self-Test"
        textView.frame = NSRect(x: 20, y: 30, width: 720, height: 60)
        window.contentView?.addSubview(textView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        // Give WindowServer time to composite the window before screenshotting.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await self?.runProbes()
            exit(0)
        }
    }

    private func runProbes() async {
        guard let window, let textView else {
            print("[SelfTest] FAIL: window/textView missing")
            return
        }

        let textInWindow = textView.convert(textView.bounds, to: nil)
        let textOnScreen = window.convertToScreen(textInWindow)

        print("[SelfTest] screenRecordingGranted=\(PermissionHelper.screenRecordingGranted)")
        print("[SelfTest] textView onScreen=\(textOnScreen)")
        print("[SelfTest] text=\"\(Self.probeText)\" len=\(Self.probeText.count)")
        print()

        let positions: [(name: String, point: NSPoint)] = [
            ("left",    NSPoint(x: textOnScreen.minX + 80,                        y: textOnScreen.midY)),
            ("quarter", NSPoint(x: textOnScreen.minX + textOnScreen.width * 0.30, y: textOnScreen.midY)),
            ("middle",  NSPoint(x: textOnScreen.midX,                             y: textOnScreen.midY)),
            ("three-q", NSPoint(x: textOnScreen.minX + textOnScreen.width * 0.70, y: textOnScreen.midY)),
            ("right",   NSPoint(x: textOnScreen.maxX - 80,                        y: textOnScreen.midY)),
        ]

        var passed = 0
        var failed = 0
        var distinctWords = Set<String>()
        var middleResult: OCRWordReader.Result?

        for (name, pt) in positions {
            print("--- probe[\(name)] AppKit=(\(Int(pt.x)),\(Int(pt.y))) ---")
            if let result = await OCRWordReader.resolve(at: pt) {
                print("✓ word=\"\(result.selection.word)\"")
                if let rect = result.wordRect {
                    print("  wordRect=(\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))×\(Int(rect.height))")
                } else {
                    print("  wordRect=nil")
                }
                passed += 1
                distinctWords.insert(result.selection.word)
                if name == "middle" { middleResult = result }
            } else {
                print("✗ resolve returned nil")
                failed += 1
            }
            for line in OCRWordReader.lastDiagnostic.split(separator: "\n") {
                print("  | \(line)")
            }
            print()
        }

        // Phrase-rect probe: ask for a 3-word substring of the probe text and
        // confirm at least one segment's text contains the leading word.
        let phrase = "quick brown fox"
        let leadingWord = "quick"
        var phraseSegments: [PhraseSegment] = []
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
                phraseOK = phraseSegments.contains { $0.text.lowercased().contains(leadingWord) }
                print(phraseOK ? "✓ a segment contains \"\(leadingWord)\"" : "✗ no segment contained \"\(leadingWord)\"")
            }
        } else {
            print("✗ middle probe didn't produce a Result")
        }
        print()

        print("=== Self-test summary ===")
        print("passed: \(passed)  failed: \(failed)")
        print("distinct words: \(distinctWords.count) — \(distinctWords.sorted().joined(separator: ", "))")
        print("phrase segments: \(phraseSegments.count) phrase OK: \(phraseOK)")
        let wordProbesPass = (failed == 0 && distinctWords.count >= 3)
        if wordProbesPass && phraseOK {
            print("VERDICT: PASS — OCR word + phrase probes succeeded")
        } else if !PermissionHelper.screenRecordingGranted {
            print("VERDICT: BLOCKED — Screen Recording not granted; capture returned no text")
        } else if wordProbesPass && !phraseOK {
            print("VERDICT: PARTIAL-phrase — words resolved but phrase segments failed")
        } else if failed == positions.count {
            print("VERDICT: FAIL — every position rejected (OCR found no word under tap)")
        } else {
            print("VERDICT: PARTIAL — see diagnostics above")
        }
    }
}
