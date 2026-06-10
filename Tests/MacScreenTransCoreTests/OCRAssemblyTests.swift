import CoreGraphics
import Foundation
import Testing
@testable import MacScreenTransCore

// MARK: - PhraseLocator (real implementation, lifted from the retired AX reader)

@Test func phraseLocatorReportsAllOverlappingMatches() {
    #expect(PhraseLocator.allExactMatchStarts(of: "ana", in: "banana") == [1, 3])
    #expect(PhraseLocator.allExactMatchStarts(of: "xyz", in: "banana") == [])
}

@Test func phraseLocatorFindsSingleExactOccurrence() {
    let text = "the quick brown fox"
    let range = PhraseLocator.locate(phrase: "brown fox", in: text, wordAnchor: 16..<19)
    #expect(range == 10..<19)
}

@Test func phraseLocatorPicksOccurrenceCoveringTheClickedWord() {
    // "set the" appears twice; the anchor decides which one wins.
    let text = "set the timer and set the alarm"
    let first = PhraseLocator.locate(phrase: "set the", in: text, wordAnchor: 0..<3)
    let second = PhraseLocator.locate(phrase: "set the", in: text, wordAnchor: 18..<21)
    #expect(first == 0..<7)
    #expect(second == 18..<25)
}

@Test func phraseLocatorPositionUsesFallbackForDuplicateOccurrences() {
    let text = "set the timer and set the alarm"
    // Single occurrence → exact range.
    #expect(PhraseLocator.locatePosition("and set", in: text, fallbackWordRange: nil) == 14..<21)
    // Duplicate occurrence → the one containing the fallback word wins.
    let dup = PhraseLocator.locatePosition("set the", in: text, fallbackWordRange: 18..<21)
    #expect(dup == 18..<25)
}

@Test func phraseLocatorFuzzyMatchesAcrossCaseAndPunctuation() {
    let text = "The Quick, Brown Fox!"
    let range = PhraseLocator.locate(phrase: "quick brown", in: text, wordAnchor: 4..<9)
    #expect(range != nil)
    if let range, let lower = text.utf16.index(text.utf16.startIndex, offsetBy: range.lowerBound).samePosition(in: text),
       let upper = text.utf16.index(text.utf16.startIndex, offsetBy: range.upperBound).samePosition(in: text) {
        #expect(String(text[lower..<upper]) == "Quick, Brown")
    } else {
        Issue.record("fuzzy range did not map back into the source string")
    }
}

// MARK: - OCRSentenceAssembler

private func word(_ text: String, _ range: Range<Int>, _ box: CGRect) -> RecognizedWord {
    RecognizedWord(text: text, range: range, box: box)
}

@Test func assemblerLocatesTappedWordOnASingleLine() {
    let line = RecognizedLine(
        text: "quick brown fox",
        box: CGRect(x: 0.0, y: 0.10, width: 0.6, height: 0.08),
        words: [
            word("quick", 0..<5, CGRect(x: 0.00, y: 0.10, width: 0.18, height: 0.08)),
            word("brown", 6..<11, CGRect(x: 0.20, y: 0.10, width: 0.18, height: 0.08)),
            word("fox", 12..<15, CGRect(x: 0.40, y: 0.10, width: 0.10, height: 0.08)),
        ]
    )
    let assembled = OCRSentenceAssembler.assemble(lines: [line], tapPoint: CGPoint(x: 0.27, y: 0.14))
    #expect(assembled.text == "quick brown fox")
    #expect(assembled.tappedWordRange == 6..<11)
    #expect(assembled.tappedWordBox == CGRect(x: 0.20, y: 0.10, width: 0.18, height: 0.08))
}

@Test func assemblerJoinsSoftWrappedLinesWithASpaceInReadingOrder() {
    // Provided out of reading order (lower line first) to exercise the sort.
    let lower = RecognizedLine(
        text: "lazy dog",
        box: CGRect(x: 0.0, y: 0.30, width: 0.3, height: 0.08),
        words: [
            word("lazy", 0..<4, CGRect(x: 0.00, y: 0.30, width: 0.14, height: 0.08)),
            word("dog", 5..<8, CGRect(x: 0.16, y: 0.30, width: 0.10, height: 0.08)),
        ]
    )
    let upper = RecognizedLine(
        text: "the quick",
        box: CGRect(x: 0.0, y: 0.10, width: 0.3, height: 0.08),
        words: [
            word("the", 0..<3, CGRect(x: 0.00, y: 0.10, width: 0.10, height: 0.08)),
            word("quick", 4..<9, CGRect(x: 0.12, y: 0.10, width: 0.16, height: 0.08)),
        ]
    )
    let assembled = OCRSentenceAssembler.assemble(lines: [lower, upper], tapPoint: CGPoint(x: 0.20, y: 0.34))
    #expect(assembled.text == "the quick lazy dog")
    // Tap landed on "dog" in the lower line; its global range follows the
    // 10-char "the quick " prefix.
    #expect(assembled.tappedWordRange == 15..<18)
}

@Test func assemblerDeHyphenatesSoftWrappedWord() {
    let top = RecognizedLine(
        text: "exam-",
        box: CGRect(x: 0.0, y: 0.10, width: 0.2, height: 0.08),
        words: [word("exam", 0..<4, CGRect(x: 0.0, y: 0.10, width: 0.16, height: 0.08))]
    )
    let bottom = RecognizedLine(
        text: "ple here",
        box: CGRect(x: 0.0, y: 0.20, width: 0.3, height: 0.08),
        words: [
            word("ple", 0..<3, CGRect(x: 0.00, y: 0.20, width: 0.10, height: 0.08)),
            word("here", 4..<8, CGRect(x: 0.12, y: 0.20, width: 0.14, height: 0.08)),
        ]
    )
    let assembled = OCRSentenceAssembler.assemble(lines: [top, bottom], tapPoint: CGPoint(x: 0.18, y: 0.24))
    #expect(assembled.text == "example here")
    #expect(assembled.tappedWordRange == 8..<12) // "here"
}

@Test func assemblerSubdividesVisionTokenWideWordBoxes() {
    // Mirrors the field bug: every `.byWords` word of "/Users/brownjack/project"
    // came back from Vision with the same token-wide box, so a tap anywhere in
    // the path always resolved the FIRST word ("Users") and the yellow box
    // covered the whole token. After normalization, the tap must resolve the
    // word actually under the finger, with a proportional slice as its box.
    let sharedBox = CGRect(x: 0.3, y: 0.10, width: 0.45, height: 0.05)
    let line = RecognizedLine(
        text: "open /Users/brownjack/project now",
        box: CGRect(x: 0.0, y: 0.10, width: 0.8, height: 0.05),
        words: [
            word("open", 0..<4, CGRect(x: 0.00, y: 0.10, width: 0.05, height: 0.05)),
            word("Users", 6..<11, sharedBox),
            word("brownjack", 12..<21, sharedBox),
            word("project", 22..<29, sharedBox),
            word("now", 30..<33, CGRect(x: 0.76, y: 0.10, width: 0.04, height: 0.05)),
        ]
    )
    // Shared run spans offsets 6..<29 over x 0.30...0.75. "project" (22..<29)
    // slices to x ≈ 0.613...0.75; tap inside that slice.
    let assembled = OCRSentenceAssembler.assemble(lines: [line], tapPoint: CGPoint(x: 0.70, y: 0.12))
    #expect(assembled.tappedWordRange == 22..<29)
    if let box = assembled.tappedWordBox {
        #expect(box.minX > 0.55)
        #expect(box.width < 0.2)
    } else {
        Issue.record("normalization produced no tapped word box")
    }
}

@Test func normalizeWordBoxesLeavesDistinctBoxesUntouched() {
    let words = [
        word("alpha", 0..<5, CGRect(x: 0.00, y: 0.1, width: 0.10, height: 0.05)),
        word("beta", 6..<10, CGRect(x: 0.12, y: 0.1, width: 0.08, height: 0.05)),
    ]
    #expect(OCRSentenceAssembler.normalizeWordBoxes(words) == words)
}

@Test func assemblerPrefersNarrowestContainingBoxOverFirstMatch() {
    // One degenerate token-wide box alongside properly-boxed words: a tap
    // inside the proper word must pick it, not the first containing box.
    let line = RecognizedLine(
        text: "alpha beta gamma",
        box: CGRect(x: 0.0, y: 0.10, width: 0.6, height: 0.05),
        words: [
            word("alpha", 0..<5, CGRect(x: 0.0, y: 0.10, width: 0.60, height: 0.05)),
            word("beta", 6..<10, CGRect(x: 0.25, y: 0.10, width: 0.10, height: 0.05)),
            word("gamma", 11..<16, CGRect(x: 0.40, y: 0.10, width: 0.15, height: 0.05)),
        ]
    )
    let assembled = OCRSentenceAssembler.assemble(lines: [line], tapPoint: CGPoint(x: 0.30, y: 0.12))
    #expect(assembled.tappedWordRange == 6..<10)
}

@Test func assemblerSynthesizesWordWhenLineCarriesNoWordGeometry() {
    // Vision sometimes throws for every boundingBox(for:) query on a line,
    // leaving words=[] while the line box itself is fine. The tap must still
    // resolve by proportional offset instead of failing with
    // "no word under tap".
    let line = RecognizedLine(
        text: "hello wonderful world",
        box: CGRect(x: 0.1, y: 0.10, width: 0.42, height: 0.05),
        words: []
    )
    // 21 UTF-16 units over x 0.10...0.52; tap at x=0.33 → offset 11 → expands
    // to "wonderful" (6..<15).
    let assembled = OCRSentenceAssembler.assemble(lines: [line], tapPoint: CGPoint(x: 0.33, y: 0.12))
    #expect(assembled.tappedWordRange == 6..<15)
    if let box = assembled.tappedWordBox {
        #expect(abs(box.minX - (0.1 + 0.42 * 6.0 / 21.0)) < 0.01)
        #expect(abs(box.width - 0.42 * 9.0 / 21.0) < 0.01)
    } else {
        Issue.record("no synthesized box for the geometry-less line")
    }
}

@Test func assemblerResolvesAcrossSideBySideRowFragments() {
    // Mirrors the field bug: Vision split the single visual row
    // "drwxr-xr-x  5 brownjack staff  160 Jun ..." into THREE side-by-side
    // observations separated by column gaps. Picking the line by vertical
    // distance alone chose an arbitrary fragment, so a tap on "160" resolved
    // "staff" (nearest word of the wrong fragment) and a tap on "brownjack"
    // resolved nothing at all. The tap's x must select the fragment.
    let left = RecognizedLine(
        text: "drwxr",
        box: CGRect(x: 0.20, y: 0.4827, width: 0.09, height: 0.0465),
        words: [word("drwxr", 0..<5, CGRect(x: 0.20, y: 0.4827, width: 0.09, height: 0.0465))]
    )
    let middle = RecognizedLine(
        text: "5 brownjack staff",
        box: CGRect(x: 0.31, y: 0.4788, width: 0.156, height: 0.0503),
        words: [
            word("5", 0..<1, CGRect(x: 0.310, y: 0.4788, width: 0.017, height: 0.0503)),
            word("brownjack", 2..<11, CGRect(x: 0.340, y: 0.4788, width: 0.090, height: 0.0503)),
            word("staff", 12..<17, CGRect(x: 0.417, y: 0.4788, width: 0.045, height: 0.0503)),
        ]
    )
    let right = RecognizedLine(
        text: "160 Jun",
        box: CGRect(x: 0.4865, y: 0.4788, width: 0.20, height: 0.0545),
        words: [
            word("160", 0..<3, CGRect(x: 0.4865, y: 0.4788, width: 0.032, height: 0.0545)),
            word("Jun", 4..<7, CGRect(x: 0.5250, y: 0.4788, width: 0.035, height: 0.0545)),
        ]
    )
    let lines = [left, middle, right]
    // Assembled row: "drwxr 5 brownjack staff 160 Jun"
    //                 0      6 8         18    24  28

    // Tap inside "160": the middle fragment is vertically CLOSER (midY
    // 0.5040 vs 0.5061) but does not span the tap's x — the right fragment
    // must win.
    let on160 = OCRSentenceAssembler.assemble(lines: lines, tapPoint: CGPoint(x: 0.50, y: 0.50))
    #expect(on160.text == "drwxr 5 brownjack staff 160 Jun")
    #expect(on160.tappedWordRange == 24..<27)

    // Tap inside "brownjack" at a y nearer the RIGHT fragment's midY: only
    // the middle fragment spans the x, so it must still win.
    let onBrownjack = OCRSentenceAssembler.assemble(lines: lines, tapPoint: CGPoint(x: 0.36, y: 0.508))
    #expect(onBrownjack.tappedWordRange == 8..<17)

    // Tap in the column gap between fragments (no line spans the x): the
    // nearest word across the whole row band resolves — "160" at distance
    // 0.0115 beats "staff" at 0.013.
    let inGap = OCRSentenceAssembler.assemble(lines: lines, tapPoint: CGPoint(x: 0.475, y: 0.50))
    #expect(inGap.tappedWordRange == 24..<27)
}

@Test func assemblerReturnsNilWhenTapMissesEveryLine() {
    let line = RecognizedLine(
        text: "hello world",
        box: CGRect(x: 0.0, y: 0.10, width: 0.4, height: 0.08),
        words: [
            word("hello", 0..<5, CGRect(x: 0.0, y: 0.10, width: 0.18, height: 0.08)),
            word("world", 6..<11, CGRect(x: 0.20, y: 0.10, width: 0.18, height: 0.08)),
        ]
    )
    let assembled = OCRSentenceAssembler.assemble(lines: [line], tapPoint: CGPoint(x: 0.5, y: 0.90))
    #expect(assembled.tappedWordRange == nil)
    #expect(assembled.tappedWordBox == nil)
}

@Test func assemblerSegmentsAPhraseSpanningTwoLines() {
    let top = RecognizedLine(
        text: "the quick",
        box: CGRect(x: 0.0, y: 0.10, width: 0.3, height: 0.08),
        words: [
            word("the", 0..<3, CGRect(x: 0.00, y: 0.10, width: 0.10, height: 0.08)),
            word("quick", 4..<9, CGRect(x: 0.12, y: 0.10, width: 0.16, height: 0.08)),
        ]
    )
    let bottom = RecognizedLine(
        text: "brown fox",
        box: CGRect(x: 0.0, y: 0.20, width: 0.3, height: 0.08),
        words: [
            word("brown", 0..<5, CGRect(x: 0.00, y: 0.20, width: 0.16, height: 0.08)),
            word("fox", 6..<9, CGRect(x: 0.18, y: 0.20, width: 0.10, height: 0.08)),
        ]
    )
    let assembled = OCRSentenceAssembler.assemble(lines: [top, bottom], tapPoint: CGPoint(x: 0.18, y: 0.14))
    #expect(assembled.text == "the quick brown fox")

    // "quick brown" spans the line break (offsets 4..<15).
    let segments = OCRSentenceAssembler.segments(forRange: 4..<15, in: assembled)
    #expect(segments.count == 2)
    #expect(segments[0].range == 4..<9)   // "quick" on the top line
    #expect(segments[1].range == 10..<15) // "brown" on the bottom line
}
