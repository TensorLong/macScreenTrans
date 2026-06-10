import CoreGraphics
import Foundation

// MARK: - Inputs

/// One OCR'd word with its tight box. `range` is a UTF-16 range inside the
/// OWNING line's `text`. `box` is normalized image coordinates with a
/// TOP-LEFT origin (y grows down) — the convention the Vision layer converts
/// into before handing observations here, so "reading order" is simply
/// "smaller y first".
public struct RecognizedWord: Sendable, Equatable {
    public let text: String
    public let range: Range<Int>
    public let box: CGRect

    public init(text: String, range: Range<Int>, box: CGRect) {
        self.text = text
        self.range = range
        self.box = box
    }
}

/// One OCR'd line (Vision observation) with its bounding box and the words it
/// contains. `box` is normalized image coordinates, top-left origin.
public struct RecognizedLine: Sendable, Equatable {
    public let text: String
    public let box: CGRect
    public let words: [RecognizedWord]

    public init(text: String, box: CGRect, words: [RecognizedWord]) {
        self.text = text
        self.box = box
        self.words = words
    }
}

// MARK: - Outputs

/// A line as it appears in the assembled text: its UTF-16 range within
/// `AssembledText.text`, its box, and its words with ranges remapped to
/// global (assembled-text) offsets.
public struct AssembledLine: Sendable, Equatable {
    public let range: Range<Int>
    public let box: CGRect
    public let words: [RecognizedWord]

    public init(range: Range<Int>, box: CGRect, words: [RecognizedWord]) {
        self.range = range
        self.box = box
        self.words = words
    }
}

/// One visual span of a phrase: a UTF-16 sub-range of the assembled text and
/// the normalized image box that covers it. The reader converts `box` into an
/// AppKit screen rect to build the green per-line highlight.
public struct PhraseBox: Sendable, Equatable {
    public let range: Range<Int>
    public let box: CGRect

    public init(range: Range<Int>, box: CGRect) {
        self.range = range
        self.box = box
    }
}

/// The result of assembling OCR observations into one reading-ordered text
/// block plus the located tapped word.
public struct AssembledText: Sendable, Equatable {
    public let text: String
    public let lines: [AssembledLine]
    /// UTF-16 range of the tapped word inside `text`, or nil when the tap did
    /// not land on (or near) any recognized word.
    public let tappedWordRange: Range<Int>?
    /// Normalized image box (top-left origin) of the tapped word.
    public let tappedWordBox: CGRect?

    public init(
        text: String,
        lines: [AssembledLine],
        tappedWordRange: Range<Int>?,
        tappedWordBox: CGRect?
    ) {
        self.text = text
        self.lines = lines
        self.tappedWordRange = tappedWordRange
        self.tappedWordBox = tappedWordBox
    }
}

/// Pure assembly of OCR observations: reading-order sort, soft-wrap merge with
/// de-hyphenation, tapped-word hit-testing, and phrase → per-line segment
/// mapping. No Vision / AppKit dependency, so the whole thing is unit-testable
/// with hand-authored boxes.
public enum OCRSentenceAssembler {
    /// Largest vertical gap (as a multiple of the median line height) still
    /// joined with a space rather than a paragraph break.
    private static let paragraphGapFactor: CGFloat = 1.6

    /// Assemble `lines` into one text block and locate the word under
    /// `tapPoint`. `tapPoint` is in the same normalized image space as the
    /// boxes (top-left origin, y down).
    public static func assemble(lines rawLines: [RecognizedLine], tapPoint: CGPoint) -> AssembledText {
        let lines = rawLines.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else {
            return AssembledText(text: "", lines: [], tappedWordRange: nil, tappedWordBox: nil)
        }

        let ordered = readingOrder(lines)
        let median = medianHeight(ordered)

        var text = ""
        var assembled: [AssembledLine] = []
        var pendingSeparator = ""

        for idx in ordered.indices {
            let line = ordered[idx]
            let normalizedWords = normalizeWordBoxes(line.words)

            // Look ahead: a trailing hyphen continued by a lowercase next line
            // is a soft-wrapped word — drop the hyphen and join with nothing.
            var effective = line.text
            var joinNextWithEmpty = false
            if idx + 1 < ordered.count,
               effective.hasSuffix("-"),
               startsLowercaseLetter(ordered[idx + 1].text) {
                effective = String(effective.dropLast())
                joinNextWithEmpty = true
            }

            if idx > 0 { text += pendingSeparator }

            let start = text.utf16.count
            text += effective
            let lineRange = start..<text.utf16.count
            let effectiveLen = effective.utf16.count

            // Remap each word's range to global offsets, clipping any word
            // that ran into the dropped hyphen.
            let remapped: [RecognizedWord] = normalizedWords.compactMap { word in
                let lo = min(word.range.lowerBound, effectiveLen)
                let hi = min(word.range.upperBound, effectiveLen)
                guard lo < hi else { return nil }
                return RecognizedWord(text: word.text, range: (start + lo)..<(start + hi), box: word.box)
            }

            assembled.append(AssembledLine(range: lineRange, box: line.box, words: remapped))

            // Separator before the NEXT line.
            if joinNextWithEmpty {
                pendingSeparator = ""
            } else if idx + 1 < ordered.count {
                let gap = ordered[idx + 1].box.minY - line.box.maxY
                pendingSeparator = (median > 0 && gap > paragraphGapFactor * median) ? "\n" : " "
            }
        }

        let (tappedRange, tappedBox) = locateTappedWord(
            in: assembled,
            text: text,
            tapPoint: tapPoint,
            medianHeight: median
        )
        return AssembledText(text: text, lines: assembled, tappedWordRange: tappedRange, tappedWordBox: tappedBox)
    }

    /// Vision's `boundingBox(for:)` resolves the queried character range to
    /// ITS OWN token containing it — for slash-joined paths
    /// ("/Users/brownjack/…") or script-mixed runs, several `.byWords` tokens
    /// map to one Vision token and every one of them comes back with the same
    /// token-wide box. Hit-testing then can't tell those words apart and the
    /// word highlight covers the whole token. Detect runs of consecutive words
    /// sharing one box and slice that box horizontally in proportion to each
    /// word's UTF-16 span within the run.
    static func normalizeWordBoxes(_ words: [RecognizedWord]) -> [RecognizedWord] {
        guard words.count > 1 else { return words }
        var result: [RecognizedWord] = []
        result.reserveCapacity(words.count)
        var i = words.startIndex
        while i < words.endIndex {
            var j = i + 1
            while j < words.endIndex, approximatelyEqual(words[j].box, words[i].box) { j += 1 }
            let group = words[i..<j]
            let span = group.first!.range.lowerBound..<group.last!.range.upperBound
            let spanLength = span.upperBound - span.lowerBound
            let box = group.first!.box
            if group.count > 1, spanLength > 0, box.width > 0 {
                for word in group {
                    let relStart = CGFloat(word.range.lowerBound - span.lowerBound) / CGFloat(spanLength)
                    let relEnd = CGFloat(word.range.upperBound - span.lowerBound) / CGFloat(spanLength)
                    result.append(RecognizedWord(
                        text: word.text,
                        range: word.range,
                        box: CGRect(
                            x: box.minX + box.width * relStart,
                            y: box.minY,
                            width: box.width * (relEnd - relStart),
                            height: box.height
                        )
                    ))
                }
            } else {
                result.append(contentsOf: group)
            }
            i = j
        }
        return result
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        let eps: CGFloat = 1e-4
        return abs(a.minX - b.minX) < eps && abs(a.minY - b.minY) < eps
            && abs(a.width - b.width) < eps && abs(a.height - b.height) < eps
    }

    /// Map a UTF-16 range of the assembled text to one box per visual line it
    /// spans. Each box is the union of the word boxes overlapping the range on
    /// that line, falling back to a proportional slice of the line box when no
    /// word boxes cover the span.
    public static func segments(forRange target: Range<Int>, in assembled: AssembledText) -> [PhraseBox] {
        guard target.lowerBound < target.upperBound else { return [] }
        var result: [PhraseBox] = []
        for line in assembled.lines {
            let lo = max(line.range.lowerBound, target.lowerBound)
            let hi = min(line.range.upperBound, target.upperBound)
            guard lo < hi else { continue }
            let inter = lo..<hi

            let coveringBoxes = line.words
                .filter { $0.range.lowerBound < inter.upperBound && inter.lowerBound < $0.range.upperBound }
                .map { $0.box }

            let box: CGRect
            if let first = coveringBoxes.first {
                box = coveringBoxes.dropFirst().reduce(first) { $0.union($1) }
            } else {
                box = proportionalSlice(of: line.box, lineRange: line.range, sub: inter)
            }
            result.append(PhraseBox(range: inter, box: box))
        }
        return result
    }

    // MARK: - Reading order

    private static func readingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        let sortedByY = lines.sorted { $0.box.midY < $1.box.midY }
        var rows: [[RecognizedLine]] = []
        for line in sortedByY {
            if let ref = rows.last?.first {
                let tolerance = 0.6 * min(line.box.height, ref.box.height)
                if abs(line.box.midY - ref.box.midY) <= tolerance {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    private static func medianHeight(_ lines: [RecognizedLine]) -> CGFloat {
        let heights = lines.map(\.box.height).sorted()
        guard !heights.isEmpty else { return 0 }
        return heights[heights.count / 2]
    }

    // MARK: - Tap hit-testing

    private static func locateTappedWord(
        in lines: [AssembledLine],
        text: String,
        tapPoint: CGPoint,
        medianHeight: CGFloat
    ) -> (Range<Int>?, CGRect?) {
        // Vertical tolerance so a tap just above/below the glyph body still
        // lands on the line. Falls back to a fraction of the line height when
        // no median is available.
        let verticalPad = max(medianHeight * 0.75, 0.01)

        var bestLine: AssembledLine?
        var bestVerticalDistance = CGFloat.greatestFiniteMagnitude
        for line in lines {
            let withinPadded = tapPoint.y >= line.box.minY - verticalPad
                && tapPoint.y <= line.box.maxY + verticalPad
            guard withinPadded else { continue }
            let distance = abs(tapPoint.y - line.box.midY)
            if distance < bestVerticalDistance {
                bestVerticalDistance = distance
                bestLine = line
            }
        }
        guard let line = bestLine else { return (nil, nil) }

        // No per-word geometry at all (Vision's boundingBox(for:) threw for
        // every token on this line): synthesize the word from the line text
        // by slicing the line box proportionally at the tap's x offset.
        guard !line.words.isEmpty else {
            return synthesizeWord(in: line, text: text, tapPoint: tapPoint)
        }

        // Of the words whose box contains the tap x, prefer the NARROWEST —
        // a degenerate token-wide box must not shadow a properly-boxed word.
        // Otherwise fall back to the nearest word within a horizontal
        // tolerance so a tap in inter-word whitespace still resolves.
        let horizontalPad = max(line.box.height, 0.01)
        var containing: RecognizedWord?
        var nearest: RecognizedWord?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for word in line.words {
            if tapPoint.x >= word.box.minX && tapPoint.x <= word.box.maxX {
                if containing == nil || word.box.width < containing!.box.width {
                    containing = word
                }
            } else {
                let distance = tapPoint.x < word.box.minX
                    ? word.box.minX - tapPoint.x
                    : tapPoint.x - word.box.maxX
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearest = word
                }
            }
        }
        if let word = containing { return (word.range, word.box) }
        if let word = nearest, nearestDistance <= horizontalPad { return (word.range, word.box) }
        return (nil, nil)
    }

    /// Last-resort hit-testing for a line whose words carry no geometry:
    /// map the tap's x to a UTF-16 offset by proportion, then expand to the
    /// whitespace-delimited token around that offset. The downstream
    /// `WordContextExtractor` re-derives the precise linguistic word from the
    /// offset, so an approximate token boundary is enough here.
    private static func synthesizeWord(
        in line: AssembledLine,
        text: String,
        tapPoint: CGPoint
    ) -> (Range<Int>?, CGRect?) {
        let span = line.range.upperBound - line.range.lowerBound
        guard span > 0, line.box.width > 0 else { return (nil, nil) }

        let rel = min(max((tapPoint.x - line.box.minX) / line.box.width, 0), 0.999)
        var probe = line.range.lowerBound + Int(rel * CGFloat(span))

        let utf16 = Array(text.utf16)
        guard probe >= 0, probe < utf16.count else { return (nil, nil) }

        func isSpace(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }

        if isSpace(utf16[probe]) {
            let left = probe - 1
            let right = probe + 1
            if left >= line.range.lowerBound, left >= 0, !isSpace(utf16[left]) {
                probe = left
            } else if right < line.range.upperBound, right < utf16.count, !isSpace(utf16[right]) {
                probe = right
            } else {
                return (nil, nil)
            }
        }

        var lo = probe
        var hi = probe + 1
        while lo > line.range.lowerBound, lo - 1 >= 0, !isSpace(utf16[lo - 1]) { lo -= 1 }
        while hi < line.range.upperBound, hi < utf16.count, !isSpace(utf16[hi]) { hi += 1 }
        let range = lo..<hi
        return (range, proportionalSlice(of: line.box, lineRange: line.range, sub: range))
    }

    // MARK: - Geometry helpers

    private static func proportionalSlice(of box: CGRect, lineRange: Range<Int>, sub: Range<Int>) -> CGRect {
        let span = lineRange.upperBound - lineRange.lowerBound
        guard span > 0 else { return box }
        let relStart = CGFloat(sub.lowerBound - lineRange.lowerBound) / CGFloat(span)
        let relEnd = CGFloat(sub.upperBound - lineRange.lowerBound) / CGFloat(span)
        return CGRect(
            x: box.minX + box.width * relStart,
            y: box.minY,
            width: box.width * (relEnd - relStart),
            height: box.height
        )
    }

    private static func startsLowercaseLetter(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first.isLetter && first.isLowercase
    }
}
