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
