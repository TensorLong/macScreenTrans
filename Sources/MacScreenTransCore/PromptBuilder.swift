import Foundation

public struct ChatMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct TranslationConfig: Equatable, Sendable {
    public static let defaultModel = "openai/gpt-4o-mini"

    public var endpoint: String
    public var apiKey: String
    public var model: String
    public var targetLanguage: String
    public var promptTemplate: String

    public init(
        endpoint: String = EndpointResolver.defaultBaseURL,
        apiKey: String = "",
        model: String = TranslationConfig.defaultModel,
        targetLanguage: String = "zh",
        promptTemplate: String = PromptBuilder.defaultPromptTemplate
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.targetLanguage = targetLanguage
        self.promptTemplate = promptTemplate
    }
}

public enum PromptBuilder {
    public static let defaultPromptTemplate = """
    You output ONLY a JSON object. No prose. No markdown. No code fences.

    Task: given a sentence and a pointed word, find the SMALLEST meaningful phrase
    (sense group) in the sentence that contains the pointed word, then translate
    ONLY that phrase into the target language. The sentence may contain `___` as
    a placeholder where unrelated words have been removed; treat it as a non-word
    and never include it in source_chunk.

    Rules:
    1. source_chunk MUST be an exact substring of the sentence.
    2. source_chunk MUST contain the pointed word.
    3. source_chunk MUST NOT contain `___`. Three consecutive underscores in the sentence are a placeholder for unrelated words and are NOT part of any sense group.
    4. Pick the smallest natural phrase that carries meaning on its own (usually 2-6 words).
    5. Do NOT return the whole sentence as source_chunk.
    6. For verbs, include the object/complement (e.g. "make a decision", not "make").
    7. For nouns, include tight modifiers/articles (e.g. "an ironic twist", not "twist").
    8. target_chunk MUST translate ONLY source_chunk.
    9. target_chunk MUST be non-empty and written in the requested target language.
    10. word_pos MUST be a short English POS abbreviation with trailing period (one of: adj., n., v., adv., prep., conj., pron., interj.).
    11. word_brief MUST be a 5-15 character zh dictionary-style definition for the POINTED word only. Separate multiple senses with "；". Do NOT include the POS in word_brief.
    12. The user payload includes a `position` field — a 3-word substring of `sentence` containing the pointed word. Use `position` to identify which part of `sentence` the user is pointing at when selecting the sense group.

    Output schema (return this exact JSON object and nothing else):
    {"source_chunk":"...","target_chunk":"...","word_pos":"...","word_brief":"..."}

    Example
    Input:  {"word":"twist","sentence":"It's an ironic twist that we might all end up as NPCs.","position":"an ironic twist","target_language":"zh"}
    Output: {"source_chunk":"an ironic twist","target_chunk":"具有讽刺意味的转折","word_pos":"n.","word_brief":"转折；转变"}
    """

    public static let translationOnlyPromptTemplate = """
    Translate the phrase in the user payload to {target_language}.
    Output ONLY the translated text. No JSON, no markdown, no explanations.
    """

    public static func messages(selection: WordSelection, config: TranslationConfig) -> [ChatMessage] {
        let system = fillTemplate(config.promptTemplate, selection: selection, config: config)
        let extracted = Self.extractSentenceWithOffset(context: selection.context, anchor: selection.wordRangeInContext)
        // Map the anchor (UTF-16 range in `context`) into the same coordinate
        // space within the extracted sentence by subtracting the sentence's
        // start offset in `context`. If the math falls outside the sentence
        // (defensive — synthetic selections), the cloze helper just no-ops
        // because no occurrence will match the bogus anchor range.
        let anchorLo = selection.wordRangeInContext.lowerBound - extracted.startInContextUTF16
        let anchorHi = selection.wordRangeInContext.upperBound - extracted.startInContextUTF16
        let anchorRangeInSentence = anchorLo..<anchorHi
        let cloze = Self.clozeSentence(
            originalSentence: extracted.sentence,
            anchorRangeInSentence: anchorRangeInSentence,
            word: selection.word
        )
        let positionString = Self.position(for: selection)
        let payload: [String: Any] = [
            "word": selection.word,
            "sentence": cloze,
            "position": positionString,
            "target_language": config.targetLanguage
        ]
        let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let user = payloadData.flatMap { String(data: $0, encoding: .utf8) } ?? selection.context
        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user)
        ]
    }

    /// Replace every case-insensitive occurrence of `word` inside
    /// `originalSentence` with `___` EXCEPT the one whose UTF-16 range
    /// equals `anchorRangeInSentence`. The clicked occurrence is left
    /// intact so the LLM can still see one literal instance of the pointed
    /// word. This is the cloze preprocessing that closes the duplicate-word
    /// disambiguation gap when the model would otherwise pick the wrong
    /// occurrence's sense group.
    ///
    /// Matching is done over UTF-16 so the offset math stays consistent with
    /// `selection.wordRangeInContext`. Case-folding is performed via
    /// `String.lowercased()` — for English / CJK (our only targets today)
    /// this preserves UTF-16 width so the byte offsets remain valid. If the
    /// anchor range lies outside `originalSentence` (defensive — synthetic
    /// selections), the function still replaces every occurrence; that
    /// degrades gracefully because the only place this is called from has
    /// already verified the anchor lives inside `originalSentence`.
    static func clozeSentence(
        originalSentence: String,
        anchorRangeInSentence: Range<Int>,
        word: String
    ) -> String {
        guard !word.isEmpty, !originalSentence.isEmpty else { return originalSentence }

        let hayUTF16 = Array(originalSentence.utf16)
        let needleUTF16 = Array(word.lowercased().utf16)
        guard needleUTF16.count > 0, needleUTF16.count <= hayUTF16.count else {
            return originalSentence
        }

        let hayLower = Array(originalSentence.lowercased().utf16)
        // Defensive: lowercased() can in principle change UTF-16 width, but
        // not for English / CJK. If widths diverge, fall back to the
        // original sentence rather than build a corrupt cloze.
        guard hayLower.count == hayUTF16.count else { return originalSentence }

        // Collect non-anchor occurrence ranges, scanning left-to-right with
        // non-overlapping matches.
        var ranges: [Range<Int>] = []
        var i = 0
        while i + needleUTF16.count <= hayLower.count {
            var matched = true
            for k in 0..<needleUTF16.count {
                if hayLower[i + k] != needleUTF16[k] {
                    matched = false
                    break
                }
            }
            if matched {
                let occRange = i..<(i + needleUTF16.count)
                if occRange != anchorRangeInSentence {
                    ranges.append(occRange)
                }
                i += needleUTF16.count
            } else {
                i += 1
            }
        }

        guard !ranges.isEmpty else { return originalSentence }

        // Apply replacements right-to-left so earlier offsets stay valid.
        var result = Array(originalSentence.utf16)
        let placeholder = Array("___".utf16)
        for range in ranges.reversed() {
            result.replaceSubrange(range, with: placeholder)
        }
        return String(utf16CodeUnits: result, count: result.count)
    }

    /// Derive the 3-word `position` string from `selection`. The position is
    /// a verbatim substring of `selection.context` containing the anchor
    /// token plus one neighbour on each side; punctuation, whitespace, and
    /// markdown stars between the three words are preserved exactly as they
    /// appear in the context.
    ///
    /// A "token" is a maximal run of letters / digits / CJK characters
    /// (alphanumerics + alphabetic Unicode scalars). Everything between
    /// tokens is interstitial and stays in the returned slice.
    ///
    /// Boundary handling:
    /// - Anchor at the sentence head (no left neighbour) → take the anchor
    ///   plus the next two right tokens.
    /// - Anchor at the sentence tail (no right neighbour) → take the two
    ///   left tokens plus the anchor.
    /// - Context with fewer than 3 tokens → return the whole context.
    ///
    /// The anchor token is the token whose UTF-16 range covers
    /// `selection.wordRangeInContext`. When the anchor range somehow doesn't
    /// land on a token (defensive — synthetic selections can have weird
    /// ranges), we fall back to returning the whole context.
    public static func position(for selection: WordSelection) -> String {
        let context = selection.context
        let anchor = selection.wordRangeInContext
        return positionString(in: context, anchorUTF16Range: anchor)
    }

    /// Internal helper exposed for testing — derives the position string for
    /// the given context and UTF-16 anchor range. Pure function over String.
    static func positionString(in context: String, anchorUTF16Range anchor: Range<Int>) -> String {
        guard !context.isEmpty else { return context }

        // Tokenize: walk character by character, accumulating UTF-16 offsets,
        // and split into maximal runs of "token" characters (letters/digits/
        // CJK). Each token is recorded with its UTF-16 range inside `context`.
        struct Token {
            let utf16Range: Range<Int>
        }
        var tokens: [Token] = []
        var offset = 0
        var currentStart: Int? = nil
        for character in context {
            let width = String(character).utf16.count
            if isTokenChar(character) {
                if currentStart == nil {
                    currentStart = offset
                }
            } else {
                if let start = currentStart {
                    tokens.append(Token(utf16Range: start..<offset))
                    currentStart = nil
                }
            }
            offset += width
        }
        if let start = currentStart {
            tokens.append(Token(utf16Range: start..<offset))
        }

        // Fewer than 3 tokens: position degrades to the whole context.
        guard tokens.count >= 3 else {
            return context
        }

        // Find the anchor token — the one whose UTF-16 range overlaps the
        // anchor range. Defensive: if the anchor straddles a non-token gap
        // or sits entirely in interstitial whitespace, fall back to the
        // whole context.
        guard let anchorIdx = tokens.firstIndex(where: { token in
            // Any overlap counts: token.start < anchor.end && anchor.start < token.end.
            token.utf16Range.lowerBound < anchor.upperBound
                && anchor.lowerBound < token.utf16Range.upperBound
        }) else {
            return context
        }

        // Decide the three token indices to include.
        let lo: Int
        let hi: Int
        if anchorIdx == 0 {
            // Sentence head — take anchor + two right neighbours.
            lo = 0
            hi = min(tokens.count - 1, 2)
        } else if anchorIdx == tokens.count - 1 {
            // Sentence tail — take two left neighbours + anchor.
            hi = anchorIdx
            lo = max(0, anchorIdx - 2)
        } else {
            // Middle — one neighbour on each side.
            lo = anchorIdx - 1
            hi = anchorIdx + 1
        }

        let sliceStart = tokens[lo].utf16Range.lowerBound
        let sliceEnd = tokens[hi].utf16Range.upperBound

        // Convert UTF-16 offsets back to String.Index. Mirror the conversion
        // used in extractSentence — samePosition over context.utf16.index.
        guard let startIdx = context.utf16.index(context.utf16.startIndex, offsetBy: sliceStart).samePosition(in: context),
              let endIdx = context.utf16.index(context.utf16.startIndex, offsetBy: sliceEnd).samePosition(in: context) else {
            return context
        }
        return String(context[startIdx..<endIdx])
    }

    /// A "token character" for `position` derivation: any letter, digit, or
    /// alphabetic CJK scalar. Everything else (whitespace, punctuation,
    /// markdown stars, etc.) is interstitial — it stays in the verbatim
    /// position string but doesn't itself bound a token.
    private static func isTokenChar(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.properties.isAlphabetic
        }
    }

    /// Extract the single sentence around `anchor` from `context` by walking
    /// outward to the nearest sentence boundary in either direction, and
    /// report where that sentence begins inside `context` (UTF-16 offset).
    /// The LLM only ever sees this one sentence, so a context window that
    /// spans multiple sentences can never let the model pick a chunk from
    /// an unrelated region. Callers that need to map ranges from `context`
    /// coordinates into `sentence` coordinates (e.g. the cloze pass)
    /// subtract `startInContextUTF16`.
    ///
    /// Boundary characters: `. ? ! 。 ？ ！ \n \r`.
    /// - Left boundary is **excluded** from the returned sentence (it
    ///   stays with the previous sentence).
    /// - Right boundary is **included** so the trailing terminator (`.`,
    ///   `。`, etc.) remains attached to the sentence the user clicked.
    ///
    /// If no boundary is found in either direction, the entire `context`
    /// is returned unchanged.
    ///
    /// The anchor is a UTF-16 range inside `context` (matching
    /// `WordSelection.wordRangeInContext`). We walk by Swift `Character`
    /// to stay grapheme-correct, so surrogate-pair emoji or combining
    /// marks inside the context never split a boundary check mid-codepoint.
    private static func extractSentenceWithOffset(
        context: String,
        anchor: Range<Int>
    ) -> (sentence: String, startInContextUTF16: Int) {
        let utf16Count = context.utf16.count
        guard anchor.lowerBound >= 0,
              anchor.upperBound <= utf16Count,
              anchor.lowerBound < anchor.upperBound else {
            return (context, 0)
        }
        let boundarySet: Set<Character> = [
            ".", "?", "!",
            "。", "？", "！",
            "\n", "\r"
        ]

        // Build a flat list of (character, utf16Start, utf16End) so we can
        // walk by grapheme but still compare against the UTF-16 anchor range.
        struct Slot {
            let character: Character
            let utf16Start: Int
            let utf16End: Int
        }
        var slots: [Slot] = []
        slots.reserveCapacity(context.count)
        var offset = 0
        for character in context {
            let width = String(character).utf16.count
            slots.append(Slot(character: character, utf16Start: offset, utf16End: offset + width))
            offset += width
        }

        // Locate the slot index that contains anchor.lowerBound and the
        // slot whose end matches anchor.upperBound (or the last slot it
        // overlaps).
        guard let firstAnchorSlot = slots.firstIndex(where: { $0.utf16Start <= anchor.lowerBound && anchor.lowerBound < $0.utf16End }) else {
            return (context, 0)
        }
        var lastAnchorSlot = firstAnchorSlot
        while lastAnchorSlot + 1 < slots.count, slots[lastAnchorSlot].utf16End < anchor.upperBound {
            lastAnchorSlot += 1
        }

        // Walk LEFT: stop just after the nearest boundary so the boundary
        // char itself stays in the PREVIOUS sentence.
        var leftSlot = firstAnchorSlot
        while leftSlot > 0, !boundarySet.contains(slots[leftSlot - 1].character) {
            leftSlot -= 1
        }

        // Walk RIGHT: include the trailing boundary so e.g.
        // "The prompt instructs Codex to create folders." keeps the period.
        var rightSlot = lastAnchorSlot
        while rightSlot + 1 < slots.count, !boundarySet.contains(slots[rightSlot].character) {
            rightSlot += 1
        }
        // Include rightSlot itself. If it's a boundary char, the boundary
        // stays inside this sentence (e.g. trailing period); if we walked
        // off the end without finding one, there simply is no trailing
        // punctuation to include and the result degrades to the full
        // remainder of the context — which is exactly the documented
        // "no boundary anywhere" fallback behaviour.
        let sentenceEndUTF16 = slots[rightSlot].utf16End
        let sentenceStartUTF16 = slots[leftSlot].utf16Start

        guard let startIdx = context.utf16.index(context.utf16.startIndex, offsetBy: sentenceStartUTF16).samePosition(in: context),
              let endIdx = context.utf16.index(context.utf16.startIndex, offsetBy: sentenceEndUTF16).samePosition(in: context) else {
            return (context, 0)
        }
        let raw = String(context[startIdx..<endIdx])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Account for whitespace/newlines the trim consumed from the left
        // side. Walk `slots` from `leftSlot` forward counting whitespace
        // runs until we hit a non-whitespace character — that's where the
        // trimmed sentence actually begins inside `context`.
        var trimmedStartSlot = leftSlot
        while trimmedStartSlot <= rightSlot,
              slots[trimmedStartSlot].character.isWhitespace
                || slots[trimmedStartSlot].character.isNewline {
            trimmedStartSlot += 1
        }
        let trimmedStartInContextUTF16 = trimmedStartSlot <= rightSlot
            ? slots[trimmedStartSlot].utf16Start
            : sentenceStartUTF16
        return (trimmed, trimmedStartInContextUTF16)
    }

    private static func fillTemplate(
        _ template: String,
        selection: WordSelection,
        config: TranslationConfig
    ) -> String {
        template
            .replacingOccurrences(of: "{word}", with: selection.word)
            .replacingOccurrences(of: "{context}", with: selection.context)
            .replacingOccurrences(of: "{sentence}", with: selection.context)
            .replacingOccurrences(of: "{target_language}", with: config.targetLanguage)
    }
}
