import Foundation

public struct WordSelection: Equatable, Sendable {
    public let word: String
    public let context: String
    public let wordRangeInContext: Range<Int>
    /// UTF-16 range of `word` inside the original `text` passed to
    /// `WordContextExtractor.selection`. Optional because synthetic
    /// WordSelection values (LLM-fallback, settings smoke-test) don't have
    /// a meaningful source string. When present, downstream code uses it
    /// to anchor "find word in element text" lookups to the clicked
    /// occurrence — without it, the lookups would silently pick the first
    /// occurrence and mis-place the yellow/green highlight whenever the
    /// same word appears twice in the surrounding text.
    public let wordRangeInSource: Range<Int>?

    public init(
        word: String,
        context: String,
        wordRangeInContext: Range<Int>,
        wordRangeInSource: Range<Int>? = nil
    ) {
        self.word = word
        self.context = context
        self.wordRangeInContext = wordRangeInContext
        self.wordRangeInSource = wordRangeInSource
    }
}

public enum WordContextExtractor {
    public static func selection(in text: String, utf16Offset: Int, radius: Int = 200) -> WordSelection? {
        guard !text.isEmpty else { return nil }

        let characters = characterInfos(in: text)
        guard let pointedIndex = characterIndex(atUTF16Offset: utf16Offset, in: characters),
              isTokenCharacter(at: pointedIndex, in: characters) else {
            return nil
        }

        var startIndex = pointedIndex
        while startIndex > 0, isTokenCharacter(at: startIndex - 1, in: characters) {
            startIndex -= 1
        }

        var endIndex = pointedIndex
        while endIndex + 1 < characters.count, isTokenCharacter(at: endIndex + 1, in: characters) {
            endIndex += 1
        }

        let wordStart = characters[startIndex].utf16Range.lowerBound
        let wordEnd = characters[endIndex].utf16Range.upperBound
        let contextStartOffset = boundaryOffset(near: max(0, wordStart - radius), in: characters, roundingDown: true)
        let contextEndOffset = boundaryOffset(near: min(text.utf16.count, wordEnd + radius), in: characters, roundingDown: false)

        guard let contextStart = stringIndex(in: text, utf16Offset: contextStartOffset),
              let contextEnd = stringIndex(in: text, utf16Offset: contextEndOffset),
              let wordStartIndex = stringIndex(in: text, utf16Offset: wordStart),
              let wordEndIndex = stringIndex(in: text, utf16Offset: wordEnd) else {
            return nil
        }

        let word = String(text[wordStartIndex..<wordEndIndex])
        let context = String(text[contextStart..<contextEnd])
        return WordSelection(
            word: word,
            context: context,
            wordRangeInContext: (wordStart - contextStartOffset)..<(wordEnd - contextStartOffset),
            wordRangeInSource: wordStart..<wordEnd
        )
    }

    private struct CharacterInfo {
        let character: Character
        let utf16Range: Range<Int>
    }

    private static func characterInfos(in text: String) -> [CharacterInfo] {
        var result: [CharacterInfo] = []
        var offset = 0
        for character in text {
            let width = String(character).utf16.count
            result.append(CharacterInfo(character: character, utf16Range: offset..<(offset + width)))
            offset += width
        }
        return result
    }

    private static func characterIndex(atUTF16Offset offset: Int, in characters: [CharacterInfo]) -> Int? {
        let clamped = min(max(0, offset), characters.last?.utf16Range.upperBound ?? 0)
        if let exact = characters.firstIndex(where: { $0.utf16Range.contains(clamped) }) {
            return exact
        }
        if clamped == characters.last?.utf16Range.upperBound {
            return characters.indices.last
        }
        if let previous = characters.lastIndex(where: { $0.utf16Range.upperBound == clamped && isCoreToken($0.character) }) {
            return previous
        }
        return nil
    }

    private static func isTokenCharacter(at index: Int, in characters: [CharacterInfo]) -> Bool {
        let character = characters[index].character
        if isCoreToken(character) {
            return true
        }
        if character == "'" || character == "\u{2019}" || character == "-" {
            let hasLeft = index > 0 && isCoreToken(characters[index - 1].character)
            let hasRight = index + 1 < characters.count && isCoreToken(characters[index + 1].character)
            return hasLeft && hasRight
        }
        return false
    }

    private static func isCoreToken(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.properties.isAlphabetic
        }
    }

    private static func boundaryOffset(near offset: Int, in characters: [CharacterInfo], roundingDown: Bool) -> Int {
        if characters.isEmpty { return 0 }
        if let containing = characters.first(where: { $0.utf16Range.contains(offset) }) {
            if !roundingDown, offset == containing.utf16Range.lowerBound {
                return containing.utf16Range.lowerBound
            }
            return roundingDown ? containing.utf16Range.lowerBound : containing.utf16Range.upperBound
        }
        return min(max(0, offset), characters.last?.utf16Range.upperBound ?? 0)
    }

    private static func stringIndex(in text: String, utf16Offset: Int) -> String.Index? {
        guard utf16Offset >= 0 && utf16Offset <= text.utf16.count else { return nil }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        return String.Index(utf16Index, within: text)
    }
}
