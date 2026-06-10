import AppKit
import MacScreenTransCore

/// Autonomous OCR self-test harness. Invoked by passing `--self-test` to the
/// app binary. Renders deterministic NSTextViews with known text, then runs
/// `OCRWordReader.resolve(at:)` at the screen position of known words and
/// prints a per-probe report to stdout. Exits before the normal app delegate
/// runs.
///
/// Every probe is checked against GROUND TRUTH: the layout manager knows
/// exactly which token sits under the probe point and the screen rect of its
/// glyphs, so the OCR-mapped rects must agree within tolerance. This is what
/// catches geometry distortion (wrong size/position of the yellow/green
/// highlights) that a text-only check sails past.
///
/// Two scenarios run back to back:
///   - "clean": 28pt system font, black on white — the easy case.
///   - "terminal": 13pt monospace, light on dark, with an ls(1)-style column
///     line, a slash path (Vision returns ONE token box for all its words)
///     and an unspaced Chinese line — the field conditions that broke v0.3.
///
/// Running this from a signed .app bundle reuses the bundle's Screen Recording
/// TCC grant, so the full capture → Vision → assemble → resolve pipeline is
/// exercised against a real on-screen window without any external automation.
enum SelfTest {
    @MainActor
    static func run() -> Never {
        // Line-buffer stdout so a mid-run crash doesn't swallow every probe
        // report already printed (piped stdout is block-buffered by default).
        setvbuf(stdout, nil, _IOLBF, 0)
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

// MARK: - Scenario definitions

private struct ProbeSpec {
    /// Substring of the scenario text to aim at; the probe taps its center.
    let target: String
    /// `true` → the OCR word must merely be CONTAINED in the layout token
    /// under the tap and the OCR rect must sit INSIDE the token rect (used
    /// for unspaced CJK runs and slash paths, where the whitespace token is
    /// much bigger than the linguistic word). `false` → exact comparison.
    let containment: Bool

    init(_ target: String, containment: Bool = false) {
        self.target = target
        self.containment = containment
    }
}

private struct Scenario {
    let name: String
    let text: String
    let font: NSFont
    let textColor: NSColor
    let backgroundColor: NSColor
    let probes: [ProbeSpec]
    /// Phrase passed to `phraseSegments(for:)` on the first successful probe
    /// result; the union of segment rects must agree with the layout rect.
    let phrase: String
    let viewSize: NSSize
}

@MainActor
private final class SelfTestDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?

    private static let scenarios: [Scenario] = [
        Scenario(
            name: "clean",
            text: "The quick brown fox jumps over the lazy dog near R&D now",
            font: .systemFont(ofSize: 28),
            textColor: .black,
            backgroundColor: .white,
            probes: [
                ProbeSpec("quick"),
                ProbeSpec("brown"),
                ProbeSpec("over"),
                ProbeSpec("dog"),
                // Symbol-joined compound: a tap anywhere in "R&D" must
                // resolve the whole compound, not the letter under the tap.
                ProbeSpec("R&D"),
            ],
            phrase: "quick brown fox",
            viewSize: NSSize(width: 900, height: 60)
        ),
        Scenario(
            name: "terminal",
            text: """
            drwxr-xr-x   5 brownjack  staff   160 Jun 10 17:02 release
            swift build --package-path /Users/brownjack/project/macScreenTrans-clipboard
            已打包release版本，全部88个测试通过，等待真机验证
            """,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            textColor: NSColor(calibratedWhite: 0.92, alpha: 1),
            backgroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
            probes: [
                ProbeSpec("brownjack"),
                ProbeSpec("staff"),
                ProbeSpec("160"),
                ProbeSpec("macScreenTrans-clipboard", containment: true),
                ProbeSpec("测试", containment: true),
            ],
            phrase: "全部88个测试通过",
            viewSize: NSSize(width: 860, height: 90)
        ),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Route the per-tap evidence dump somewhere inspectable.
        OCRDebugDump.overrideDirectory = URL(
            fileURLWithPath: "/tmp/mst-selftest-dump",
            isDirectory: true
        )

        Task { @MainActor [weak self] in
            guard let self else { exit(1) }
            var geometryFailures = 0
            var wordFailures = 0
            var resolveFailures = 0
            var phraseFailures = 0

            print("[SelfTest] screenRecordingGranted=\(PermissionHelper.screenRecordingGranted)")
            print("[SelfTest] evidence dump: /tmp/mst-selftest-dump")
            print()

            for scenario in Self.scenarios {
                let outcome = await self.run(scenario)
                geometryFailures += outcome.geometryFailures
                wordFailures += outcome.wordFailures
                resolveFailures += outcome.resolveFailures
                phraseFailures += outcome.phraseFailures
            }

            // The field tap path shows the "取词中..." popup BEFORE the strip
            // is captured. Verify live that our own windows really are
            // excluded from our own capture — if they aren't, the popup's
            // text pollutes every subsequent OCR context.
            let pollutionFailures = await self.runPopupPollutionCheck()
            wordFailures += pollutionFailures

            // Field report: with the pointer parked on the tapped word (the
            // pointing-hand hover state over links), recognition garbles into
            // frankenwords. Reproduce: warp the hardware cursor onto a probe
            // word, force the pointing-hand shape, and resolve.
            let cursorFailures = await self.runCursorOcclusionCheck()
            wordFailures += cursorFailures

            // Field requirement: scrolling moves the content the highlights
            // are glued to — they must vanish — but the popup must survive
            // so the user can scroll elsewhere to cross-reference.
            let scrollFailures = await self.runScrollAwayCheck()
            wordFailures += scrollFailures

            if ProcessInfo.processInfo.environment["MST_CHROME_DUMP"] != nil {
                await self.dumpPopupChrome()
            }

            print("=== Self-test summary ===")
            print("resolve failures: \(resolveFailures)")
            print("word failures: \(wordFailures)")
            print("geometry failures: \(geometryFailures)")
            print("phrase failures: \(phraseFailures)")
            if resolveFailures == 0 && wordFailures == 0 && geometryFailures == 0 && phraseFailures == 0 {
                print("VERDICT: PASS — OCR word, phrase and geometry probes succeeded in all scenarios")
            } else if !PermissionHelper.screenRecordingGranted {
                print("VERDICT: BLOCKED — Screen Recording not granted; capture returned no text")
            } else if resolveFailures == 0 && wordFailures == 0 {
                print("VERDICT: PARTIAL-geometry — words resolved but rects disagree with the layout ground truth")
            } else {
                print("VERDICT: FAIL — see per-probe output above")
            }
            exit(0)
        }
    }

    private struct ScenarioOutcome {
        var resolveFailures = 0
        var wordFailures = 0
        var geometryFailures = 0
        var phraseFailures = 0
    }

    private func run(_ scenario: Scenario) async -> ScenarioOutcome {
        var outcome = ScenarioOutcome()
        print("=== scenario[\(scenario.name)] ===")

        presentWindow(for: scenario)
        // Give WindowServer time to composite the window before screenshotting.
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        guard textView != nil, window != nil else {
            print("✗ window/textView missing")
            outcome.resolveFailures += scenario.probes.count
            return outcome
        }
        print("text=\(scenario.text.split(separator: "\n").map { "\"\($0)\"" }.joined(separator: " / "))")

        var firstResult: OCRWordReader.Result?
        for probe in scenario.probes {
            guard let aim = screenRect(forSubstring: probe.target) else {
                print("--- probe[\(probe.target)] — target not found in layout, skipped")
                continue
            }
            let pt = NSPoint(x: aim.midX, y: aim.midY)
            print("--- probe[\(probe.target)] AppKit=(\(Int(pt.x)),\(Int(pt.y))) ---")

            guard let truth = groundTruth(at: pt) else {
                print("  (no layout ground truth — skipped)")
                continue
            }
            print("  expect token=\"\(truth.word)\" rect=\(Self.describe(truth.rect))")

            guard let result = await OCRWordReader.resolve(at: pt) else {
                print("✗ resolve returned nil")
                for line in OCRWordReader.lastDiagnostic.split(separator: "\n") {
                    print("  | \(line)")
                }
                outcome.resolveFailures += 1
                continue
            }

            let got = result.selection.word
            let wordOK: Bool
            if probe.containment {
                wordOK = truth.word.lowercased().contains(got.lowercased())
            } else {
                wordOK = got.lowercased() == truth.word.lowercased()
            }
            print("\(wordOK ? "✓" : "✗") word=\"\(got)\"")
            if !wordOK { outcome.wordFailures += 1 }

            if let rect = result.wordRect {
                print("  wordRect=\(Self.describe(rect))")
                let check = probe.containment
                    ? Self.containmentCheck(ocr: rect, container: truth.rect)
                    : Self.compareRects(ocr: rect, expected: truth.rect)
                print("  geometry \(check.pass ? "✓" : "✗") \(check.detail)")
                if !check.pass { outcome.geometryFailures += 1 }
            } else {
                print("  wordRect=nil")
                outcome.geometryFailures += 1
            }
            if firstResult == nil { firstResult = result }
        }

        // Phrase probe: locate the scenario phrase from the first result and
        // compare the union of segment rects against the layout rect.
        print("--- phrase[\"\(scenario.phrase)\"] ---")
        if let result = firstResult {
            let segments = result.phraseSegments(for: scenario.phrase)
            if segments.isEmpty {
                print("✗ no segments returned")
                outcome.phraseFailures += 1
            } else {
                for (idx, seg) in segments.enumerated() {
                    print("  seg[\(idx)] rect=\(Self.describe(seg.rect)) text=\"\(seg.text)\"")
                }
                if let expected = screenRect(forSubstring: scenario.phrase) {
                    var union = segments[0].rect
                    for seg in segments.dropFirst() { union = union.union(seg.rect) }
                    print("  expect rect=\(Self.describe(expected))")
                    let check = Self.compareRects(ocr: union, expected: expected)
                    print("  geometry \(check.pass ? "✓" : "✗") \(check.detail)")
                    if !check.pass { outcome.phraseFailures += 1 }
                } else {
                    print("  (phrase not found in layout — union check skipped)")
                }
            }
        } else {
            print("✗ no probe produced a Result to anchor the phrase")
            outcome.phraseFailures += 1
        }
        print()
        return outcome
    }

    /// Re-run one probe of the LAST presented scenario with the real
    /// translation popup showing next to the tap — exactly what the field tap
    /// handler does. The resolved context must not contain any popup string.
    private func runPopupPollutionCheck() async -> Int {
        guard textView != nil, window != nil else { return 0 }
        print("=== popup pollution check ===")
        // Aim at a real word of the last scenario so resolve() actually lands
        // on text; an off-text tap would falsely look like a "leak".
        guard let aim = screenRect(forSubstring: "测试") else { return 0 }
        let pt = NSPoint(x: aim.midX, y: aim.midY)

        let popup = FloatingTranslationWindowController()
        popup.show(at: pt, text: "取词中...")
        // Let WindowServer composite the popup before capturing.
        try? await Task.sleep(nanoseconds: 600_000_000)

        var failures = 0
        if let result = await OCRWordReader.resolve(at: pt) {
            let context = result.selection.context
            // Only strings the popup actually displays. "MacScreenTrans" is
            // deliberately NOT a marker: the terminal scenario's own path text
            // contains "macScreenTrans-clipboard", which OCR can capitalize.
            let markers = ["取词中", "翻译完成", "已复制"]
            let leaked = markers.filter { context.contains($0) }
            if leaked.isEmpty {
                print("✓ popup text did not leak into the OCR context")
            } else {
                failures += 1
                print("✗ POPUP LEAKED INTO CAPTURE: found \(leaked.joined(separator: ", "))")
                print("  context=\"\(context.prefix(160))\"")
            }
        } else {
            print("  (resolve returned nil with popup showing — counted as leak)")
            failures += 1
        }
        popup.close()
        print()
        return failures
    }

    /// Park the hardware cursor exactly on a probe word — the field-reported
    /// "pointing hand over a link" state — and resolve at that point. If the
    /// capture path ever composites the cursor into the strip, the cursor
    /// pixels garble the word under it and this probe fails.
    private func runCursorOcclusionCheck() async -> Int {
        guard window != nil else { return 0 }
        print("=== cursor occlusion check ===")
        guard let aim = screenRect(forSubstring: "brownjack") else { return 0 }
        let pt = NSPoint(x: aim.midX, y: aim.midY)

        let restore = NSEvent.mouseLocation
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            let quartz = CGPoint(x: pt.x, y: primary.frame.maxY - pt.y)
            CGWarpMouseCursorPosition(quartz)
        }
        NSCursor.pointingHand.set()
        try? await Task.sleep(nanoseconds: 600_000_000)

        var failures = 0
        if let result = await OCRWordReader.resolve(at: pt) {
            let ok = result.selection.word.lowercased() == "brownjack"
            print("\(ok ? "✓" : "✗") word=\"\(result.selection.word)\" with cursor parked on the word")
            if !ok { failures += 1 }
        } else {
            print("✗ resolve returned nil with cursor parked on the word")
            failures += 1
        }

        NSCursor.arrow.set()
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            CGWarpMouseCursorPosition(CGPoint(x: restore.x, y: primary.frame.maxY - restore.y))
        }
        print()
        return failures
    }

    /// Scroll-away contract: a scroll OUTSIDE the panel fires the handler
    /// (AppDelegate hides the highlight overlays), a scroll INSIDE the panel
    /// (the user reading the translation) does not, and the popup stays
    /// visible either way. Posting a real scroll event needs the
    /// Accessibility grant the app doesn't have, so this drives the shared
    /// handler the NSEvent monitors call.
    private func runScrollAwayCheck() async -> Int {
        print("=== scroll-away check ===")
        let popup = FloatingTranslationWindowController()
        var notified = 0
        popup.setOnScrollAway { notified += 1 }
        popup.show(at: NSPoint(x: 400, y: 400), text: "取词中...")
        try? await Task.sleep(nanoseconds: 300_000_000)

        var failures = 0
        let frame = popup.panelFrame
        popup.simulateScroll(at: NSPoint(x: frame.minX - 40, y: frame.minY - 40))
        if notified == 1 {
            print("✓ outside-panel scroll fired scroll-away")
        } else {
            print("✗ outside-panel scroll: expected 1 notification, got \(notified)")
            failures += 1
        }

        popup.simulateScroll(at: NSPoint(x: frame.midX, y: frame.midY))
        if notified == 1 {
            print("✓ inside-panel scroll ignored")
        } else {
            print("✗ inside-panel scroll fired scroll-away (notified=\(notified))")
            failures += 1
        }

        if popup.isPanelVisible {
            print("✓ popup still visible after scroll-away")
        } else {
            print("✗ popup vanished on scroll")
            failures += 1
        }
        popup.close()
        print()
        return failures
    }

    /// MST_CHROME_DUMP=1: replay the field tap flow (cursor-fallback bubble,
    /// then the anchored tail bubble) over a white backdrop and screenshot
    /// the region with the system tool, for visual inspection of the bubble
    /// chrome. This is how the stale-shadow ghost outline below the bubble
    /// (the field "extra border line" report) was reproduced and verified
    /// fixed — pixel assertions can't see window-server shadows, eyes can.
    private func dumpPopupChrome() async {
        // White backdrop: the field artifact is a faint light hairline,
        // invisible over the terminal scenario's dark background.
        presentWindow(for: Self.scenarios[0])
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let aim = screenRect(forSubstring: "brown"),
              let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else { return }
        let popup = FloatingTranslationWindowController()
        // Mirror the field tap flow: cursor-fallback bubble (no tail, body
        // fills the whole panel) first, then the anchored tail bubble.
        popup.show(at: NSPoint(x: aim.midX, y: aim.midY), text: "取词中...")
        try? await Task.sleep(nanoseconds: 400_000_000)
        popup.show(anchoredTo: aim, text: "单词: brown\n意群: quick brown fox\n译文: 敏捷的棕色狐狸")
        try? await Task.sleep(nanoseconds: 400_000_000)
        // Second-stage repeat-tap content: divider + full-sentence section.
        popup.updateSentenceSection("敏捷的棕色狐狸跳过了懒狗。这是整句翻译段落的渲染检查，长文本应该在固定高度的窗口里出现滚动条。")
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let x = Int(aim.midX - 250)
        let quartzY = Int(primary.frame.maxY - aim.maxY - 260)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R\(x),\(quartzY),500,310", "/tmp/popup-chrome.png"]
        try? task.run()
        task.waitUntilExit()
        print("[SelfTest] popup chrome dump: /tmp/popup-chrome.png")
        popup.close()
    }

    // MARK: - Window plumbing

    private func presentWindow(for scenario: Scenario) {
        window?.orderOut(nil)
        window?.close()

        let textView = NSTextView(
            frame: NSRect(origin: .zero, size: scenario.viewSize)
        )
        textView.string = scenario.text
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.font = scenario.font
        textView.drawsBackground = true
        textView.backgroundColor = scenario.backgroundColor
        textView.textColor = scenario.textColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        self.textView = textView

        // The probe window must fill the screen's visibleFrame: the capture
        // strip is 960×260pt centred on the tap, and anything the strip sees
        // beyond our window is whatever the developer happens to have on
        // screen — which pollutes the OCR context and makes probes fail for
        // reasons unrelated to the pipeline. A full-screen opaque backdrop
        // (strips are clamped to visibleFrame, so the menu bar and Dock are
        // already out of reach) guarantees the strip only ever sees scenario
        // pixels. Borderless: a title bar would put the literal app name
        // inside the captured strip.
        let backdrop = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 800)
        let window = NSWindow(
            contentRect: backdrop,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // We keep a strong reference across scenarios — close() must not
        // also release the window (default NSWindow behavior) or swapping
        // scenarios over-releases and segfaults.
        window.isReleasedWhenClosed = false
        window.backgroundColor = scenario.backgroundColor
        window.isOpaque = true
        window.level = .normal
        textView.frame = NSRect(
            x: ((backdrop.width - scenario.viewSize.width) / 2).rounded(),
            y: ((backdrop.height - scenario.viewSize.height) / 2).rounded(),
            width: scenario.viewSize.width,
            height: scenario.viewSize.height
        )
        window.contentView?.addSubview(textView)
        // Borderless windows can't become key; visibility is all OCR needs.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        // The capture pipeline excludes our own process's windows; the probe
        // text lives in one, so force-include exactly this window. The popup
        // created by the pollution check is NOT in this set, so that check
        // still proves the exclusion works.
        LegacyWindowListCapture.additionalIncludedWindowIDs = [CGWindowID(window.windowNumber)]
    }

    // MARK: - Layout ground truth

    /// The token under `screenPoint` according to the TEXT LAYOUT (not OCR):
    /// hit-test the layout manager for the character index, expand to the
    /// whitespace-delimited token, and return it with its glyph screen rect.
    private func groundTruth(at screenPoint: NSPoint) -> (word: String, rect: NSRect)? {
        guard let window, let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return nil
        }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = textView.convert(windowPoint, from: nil)
        let containerPoint = NSPoint(
            x: viewPoint.x - textView.textContainerOrigin.x,
            y: viewPoint.y - textView.textContainerOrigin.y
        )
        let charIndex = layoutManager.characterIndex(
            for: containerPoint,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        let text = textView.string as NSString
        guard charIndex < text.length else { return nil }

        func isSpace(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        guard !isSpace(charIndex) else { return nil }

        var lo = charIndex
        var hi = charIndex
        while lo > 0, !isSpace(lo - 1) { lo -= 1 }
        while hi + 1 < text.length, !isSpace(hi + 1) { hi += 1 }
        let range = NSRange(location: lo, length: hi - lo + 1)
        guard let rect = screenRect(forCharacterRange: range) else { return nil }
        return (text.substring(with: range), rect)
    }

    private func screenRect(forSubstring substring: String) -> NSRect? {
        guard let textView else { return nil }
        let range = (textView.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return screenRect(forCharacterRange: range)
    }

    private func screenRect(forCharacterRange range: NSRange) -> NSRect? {
        guard let window, let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return nil
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        let inWindow = textView.convert(rect, to: nil)
        return window.convertToScreen(inWindow)
    }

    // MARK: - Comparison

    private struct RectCheck {
        let pass: Bool
        let detail: String
    }

    /// Layout rects span the full line height plus side bearings; OCR boxes
    /// hug the inked glyphs. So: centers must agree tightly, sizes loosely.
    private static func compareRects(ocr: NSRect, expected: NSRect) -> RectCheck {
        let dx = ocr.midX - expected.midX
        let dy = ocr.midY - expected.midY
        let widthRatio = expected.width > 0 ? ocr.width / expected.width : 0
        let heightRatio = expected.height > 0 ? ocr.height / expected.height : 0
        let pass = abs(dx) <= max(6, expected.width * 0.35)
            && abs(dy) <= max(6, expected.height * 0.6)
            && widthRatio >= 0.45 && widthRatio <= 1.6
            && heightRatio >= 0.35 && heightRatio <= 1.4
        let detail = String(
            format: "Δcenter=(%.1f,%.1f) got %.0f×%.0f, expected %.0f×%.0f (ratio %.2f/%.2f)",
            dx, dy, ocr.width, ocr.height, expected.width, expected.height, widthRatio, heightRatio
        )
        return RectCheck(pass: pass, detail: detail)
    }

    /// For probes whose layout token is much bigger than the linguistic word
    /// (slash paths, unspaced CJK): the OCR rect must sit inside the token
    /// rect (small pad) and have a sane height; width is not comparable.
    private static func containmentCheck(ocr: NSRect, container: NSRect) -> RectCheck {
        let padded = container.insetBy(dx: -6, dy: -6)
        let heightRatio = container.height > 0 ? ocr.height / container.height : 0
        let pass = padded.contains(NSPoint(x: ocr.midX, y: ocr.midY))
            && ocr.width <= container.width * 1.3
            && heightRatio >= 0.35 && heightRatio <= 1.4
        let detail = String(
            format: "center=(%.0f,%.0f) inside token=%@ height ratio %.2f",
            ocr.midX, ocr.midY, padded.contains(NSPoint(x: ocr.midX, y: ocr.midY)) ? "yes" : "NO", heightRatio
        )
        return RectCheck(pass: pass, detail: detail)
    }

    private static func describe(_ rect: NSRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))"
    }
}
