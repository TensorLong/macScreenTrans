import AppKit
import MacScreenTransCore

/// One visual line of a sense-group phrase, with its on-screen rect (AppKit
/// screen coordinates). Drop-in replacement for the old `AXWordReader`-nested
/// segment type — the highlight overlays consume this shape unchanged.
struct PhraseSegment: Sendable, Equatable {
    let rect: NSRect
    let text: String
    let rangeInElementText: Range<Int>
}

/// Pure-OCR word capture. Replaces the Accessibility reader: it captures a
/// screen strip around the tap, OCRs it with Vision, assembles the lines into
/// one reading-ordered text block, locates the tapped word, and feeds the
/// same `WordContextExtractor` seam the AX path used. Geometry comes from the
/// OCR boxes, so the yellow word box and green sense-group highlights work
/// anywhere text is visible — image PDFs, video, Electron, games — needing
/// only Screen Recording permission.
enum OCRWordReader {
    /// Strip height (points) captured around the tap. Tall enough to catch a
    /// few neighbouring lines for sentence context; the width is the full
    /// screen so a tapped line is never clipped horizontally.
    static let stripHeight: CGFloat = 260

    /// BCP-47 recognition languages. zh-Hans MUST lead: with en-US first,
    /// Vision renders mixed zh/en lines as Latin garbage and drops
    /// pure-Chinese lines entirely (verified empirically on terminal
    /// screenshots); with zh-Hans first both scripts come back intact and
    /// English-only lines are unaffected.
    static let recognitionLanguages: [String] = ["zh-Hans", "en-US", "zh-Hant", "ja-JP", "ko-KR"]

    private static let capture: ScreenRegionCapturing = LegacyWindowListCapture()

    /// Diagnostic trace from the most recent `resolve`, surfaced in the
    /// fallback popup. Written and read on the main thread (the tap handler).
    nonisolated(unsafe) private(set) static var lastDiagnostic: String = ""

    struct Result: Sendable {
        let selection: WordSelection
        let wordRect: NSRect?
        /// UTF-16 range of the tapped word inside the assembled lookup text —
        /// the cursor anchor used to disambiguate duplicate-word sense groups.
        let clickedWordRangeInLookupText: Range<Int>?

        fileprivate let assembled: AssembledText
        fileprivate let screenFrame: NSRect

        /// One segment per visual line the phrase spans, each rect in AppKit
        /// screen coordinates. Mirrors the AX reader's contract so the green
        /// overlay is unchanged.
        func phraseSegments(for phrase: String, positionString: String? = nil) -> [PhraseSegment] {
            guard !phrase.isEmpty else { return [] }
            let anchor = clickedWordRangeInLookupText ?? (0..<0)
            let positionRange = positionString.flatMap {
                PhraseLocator.locatePosition($0, in: assembled.text, fallbackWordRange: anchor)
            }
            guard let phraseRange = PhraseLocator.locate(
                phrase: phrase,
                in: assembled.text,
                wordAnchor: anchor,
                positionAnchor: positionRange
            ) else {
                return []
            }
            return OCRSentenceAssembler.segments(forRange: phraseRange, in: assembled).map { box in
                PhraseSegment(
                    rect: OCRGeometry.screenRect(fromNormalizedTopLeft: box.box, in: screenFrame),
                    text: Self.substring(of: assembled.text, utf16Range: box.range) ?? phrase,
                    rangeInElementText: box.range
                )
            }
        }

        private static func substring(of text: String, utf16Range: Range<Int>) -> String? {
            let utf16 = text.utf16
            guard utf16Range.lowerBound >= 0, utf16Range.upperBound <= utf16.count else { return nil }
            guard let start = utf16.index(utf16.startIndex, offsetBy: utf16Range.lowerBound).samePosition(in: text),
                  let end = utf16.index(utf16.startIndex, offsetBy: utf16Range.upperBound).samePosition(in: text) else {
                return nil
            }
            return String(text[start..<end])
        }
    }

    /// Resolve the word under `appKitPoint`. The screen lookup happens on the
    /// main actor; the pixel capture, Vision OCR and assembly run on a
    /// background task so a tap never freezes the UI (Vision at .accurate is
    /// hundreds of milliseconds per strip, seconds on first use).
    @MainActor
    static func resolve(at appKitPoint: CGPoint, radius: Int = 200) async -> Result? {
        guard let plan = capture.plan(around: appKitPoint, stripHeight: stripHeight) else {
            lastDiagnostic = "capture: failed — no screen under the tap point"
            return nil
        }

        let (result, diagnostic) = await Task.detached(priority: .userInitiated) {
            recognizeAndAssemble(plan: plan, appKitPoint: appKitPoint, radius: radius)
        }.value
        lastDiagnostic = diagnostic
        return result
    }

    /// The heavy half of `resolve`, safe to run on any thread: everything it
    /// touches is either a value, the Sendable capture backend, or Vision —
    /// no AppKit state.
    private static func recognizeAndAssemble(
        plan: CaptureStripPlan,
        appKitPoint: CGPoint,
        radius: Int
    ) -> (Result?, String) {
        var diag: [String] = []

        guard let region = capture.capture(plan) else {
            diag.append("capture: failed — capture API returned nil")
            return (nil, diag.joined(separator: "\n"))
        }
        diag.append("capture: \(region.image.width)×\(region.image.height)px frame=\(Self.describe(region.screenFrame))")

        let recognizer = VisionTextRecognizer(recognitionLanguages: recognitionLanguages)
        let lines = recognizer.recognize(in: region.image)
        diag.append("ocr: \(lines.count) line(s)")

        let tapNorm = OCRGeometry.normalizedTapPoint(appKitPoint, in: region.screenFrame)
        let assembled = OCRSentenceAssembler.assemble(lines: lines, tapPoint: tapNorm)
        // Evidence dump for field debugging — `diag` is read at scope exit so
        // the report carries the final pipeline verdict, whichever return ran.
        defer {
            OCRDebugDump.dumpIfEnabled(
                image: region.image,
                screenFrame: region.screenFrame,
                assembled: assembled,
                tapNorm: tapNorm,
                appKitTap: appKitPoint,
                report: diag.joined(separator: "\n")
            )
        }
        guard !lines.isEmpty else {
            diag.append("ocr: no text recognized in strip")
            return (nil, diag.joined(separator: "\n"))
        }

        guard let wordRange = assembled.tappedWordRange else {
            diag.append("locate: no word under tap (norm=\(Self.describe(tapNorm)))")
            return (nil, diag.joined(separator: "\n"))
        }

        guard let selection = WordContextExtractor.selection(
            in: assembled.text,
            utf16Offset: wordRange.lowerBound,
            radius: radius
        ) else {
            diag.append("extract: WordContextExtractor nil at offset \(wordRange.lowerBound)")
            return (nil, diag.joined(separator: "\n"))
        }
        // The extractor may widen the OCR token across joiners ("D" → "R&D"):
        // anchor and highlight must follow the LINGUISTIC word, not the
        // Vision token, or the yellow box covers one letter of a compound.
        let linguisticRange = selection.wordRangeInSource ?? wordRange
        diag.append("word=\(selection.word.debugDescription) range=\(linguisticRange.lowerBound)..<\(linguisticRange.upperBound)")

        let wordBoxes = OCRSentenceAssembler.segments(forRange: linguisticRange, in: assembled)
        let wordRect: NSRect?
        if let first = wordBoxes.first {
            let union = wordBoxes.dropFirst().reduce(first.box) { $0.union($1.box) }
            wordRect = OCRGeometry.screenRect(fromNormalizedTopLeft: union, in: region.screenFrame)
        } else {
            wordRect = assembled.tappedWordBox.map {
                OCRGeometry.screenRect(fromNormalizedTopLeft: $0, in: region.screenFrame)
            }
        }
        let result = Result(
            selection: selection,
            wordRect: wordRect,
            clickedWordRangeInLookupText: linguisticRange,
            assembled: assembled,
            screenFrame: region.screenFrame
        )
        return (result, diag.joined(separator: "\n"))
    }

    private static func describe(_ rect: NSRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))"
    }

    private static func describe(_ point: CGPoint) -> String {
        "(\(String(format: "%.3f", point.x)),\(String(format: "%.3f", point.y)))"
    }
}

/// Geometry bridge between normalized image space (top-left origin, y down)
/// and AppKit screen space (bottom-left origin, y up). Kept separate so both
/// `resolve` and `Result.phraseSegments` share one definition of the mapping.
enum OCRGeometry {
    /// Map a normalized top-left box inside the captured strip to an AppKit
    /// screen rect, using the strip's known AppKit screen frame.
    static func screenRect(fromNormalizedTopLeft box: CGRect, in frame: NSRect) -> NSRect {
        let width = box.width * frame.width
        let height = box.height * frame.height
        let x = frame.minX + box.minX * frame.width
        // box.maxY is the bottom edge in top-left space; flip into bottom-left.
        let y = frame.maxY - box.maxY * frame.height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Map an AppKit screen point to normalized top-left coordinates inside the
    /// captured strip.
    static func normalizedTapPoint(_ point: CGPoint, in frame: NSRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let nx = (point.x - frame.minX) / frame.width
        // point.y is bottom-left (y up); normalized top-left has y down.
        let ny = (frame.maxY - point.y) / frame.height
        return CGPoint(x: nx, y: ny)
    }
}
