import CoreGraphics
import Foundation
import Testing
import CMultitouchSupport
@testable import MacScreenTransCore

@Test func endpointResolverAvoidsDuplicatingV1Path() {
    #expect(
        EndpointResolver.chatCompletionsURL(baseURL: "https://api.example.com/v1")?.absoluteString ==
        "https://api.example.com/v1/chat/completions"
    )
    #expect(
        EndpointResolver.chatCompletionsURL(baseURL: "https://api.example.com/")?.absoluteString ==
        "https://api.example.com/v1/chat/completions"
    )
}

@Test func endpointResolverRejectsRelativeAndUnsupportedEndpoints() {
    #expect(EndpointResolver.chatCompletionsURL(baseURL: "foo") == nil)
    #expect(EndpointResolver.chatCompletionsURL(baseURL: "ftp://api.example.com") == nil)
    #expect(EndpointResolver.chatCompletionsURL(baseURL: "https://") == nil)
}

@Test func wordContextExtractorFindsPointedWordAndBoundedContext() throws {
    let text = "It is an ironic twist that we might all end up as NPCs."
    let offset = text.utf16Offset(of: "twist")

    let selection = try #require(WordContextExtractor.selection(in: text, utf16Offset: offset, radius: 12))

    #expect(selection.word == "twist")
    #expect(selection.context.contains("ironic twist"))
    #expect(selection.context.utf16.count <= 29)
    #expect(selection.wordRangeInContext.lowerBound == selection.context.utf16Offset(of: "twist"))
}

@Test func wordContextExtractorHandlesApostrophesInsideWords() throws {
    let text = "Don't flatten the word's meaning into a generic dictionary entry."
    let offset = text.utf16Offset(of: "word") + 2

    let selection = try #require(WordContextExtractor.selection(in: text, utf16Offset: offset))

    #expect(selection.word == "word's")
}

@Test func wordContextExtractorJoinsSymbolCompoundsIntoOneWord() throws {
    // Field report: tapping the "D" of "R&D" looked up the single letter
    // "D". Symbol-joined compounds must resolve as ONE word when the joiner
    // is flanked by core characters on both sides.
    let text = "AI R&D evaluations. Fable runs on Node.js 3.14 today"

    let onD = try #require(WordContextExtractor.selection(
        in: text, utf16Offset: text.utf16Offset(of: "D evaluations")))
    #expect(onD.word == "R&D")

    let onJs = try #require(WordContextExtractor.selection(
        in: text, utf16Offset: text.utf16Offset(of: "js")))
    #expect(onJs.word == "Node.js")

    let onDigits = try #require(WordContextExtractor.selection(
        in: text, utf16Offset: text.utf16Offset(of: "14")))
    #expect(onDigits.word == "3.14")

    // A sentence-final dot is followed by whitespace — never joined.
    let onEvaluations = try #require(WordContextExtractor.selection(
        in: text, utf16Offset: text.utf16Offset(of: "evaluations")))
    #expect(onEvaluations.word == "evaluations")
}

@Test func wordContextExtractorReportsAbsoluteWordRangeInSourceForDuplicateWord() throws {
    // Same word twice in the same sentence. The extractor must report the
    // word's range anchored at the cursor offset — not at the first
    // occurrence — so downstream highlight code can target the right
    // instance instead of always falling back to "find first match".
    let text = "set the timer and set the alarm"
    let secondSet = text.range(of: "set the alarm")!.lowerBound.samePosition(in: text.utf16)!.utf16Offset(in: text)

    let selection = try #require(WordContextExtractor.selection(in: text, utf16Offset: secondSet))

    #expect(selection.word == "set")
    let source = try #require(selection.wordRangeInSource)
    #expect(source.lowerBound == secondSet)
    #expect(source.upperBound == secondSet + 3)
}

@Test func sseParserExtractsStreamingContentAndIgnoresDone() {
    let lines = [
        "data: {\"choices\":[{\"delta\":{\"content\":\"意群\"}}]}",
        "data: {\"choices\":[{\"delta\":{\"content\":\"翻译\"}}]}",
        "data: [DONE]"
    ]

    #expect(lines.compactMap(ChatCompletionStreamParser.contentDelta(fromSSELine:)) == ["意群", "翻译"])
}

@Test func senseGroupRendererFormatsCompletedJSON() {
    let raw = "{\"source_chunk\":\"an ironic twist\",\"target_chunk\":\"具有讽刺意味的转折\"}"

    #expect(
        SenseGroupResponseRenderer.displayText(for: raw) ==
        "单词: an ironic twist\n意群: an ironic twist\n译文: 具有讽刺意味的转折"
    )
}

@Test func senseGroupRendererAcceptsLegacyTranslationAliases() {
    let raw = "{\"source_chunk\":\"given a sentence\",\"translation\":\"给定一个句子\"}"

    #expect(
        SenseGroupResponseRenderer.displayText(for: raw) ==
        "单词: given a sentence\n意群: given a sentence\n译文: 给定一个句子"
    )
}

@Test func senseGroupRendererAcceptsChunkAliasAndMarkdownFence() {
    let raw = """
    ```json
    {"chunk":"given a sentence","translation":"给定一个句子"}
    ```
    """

    #expect(
        SenseGroupResponseRenderer.displayText(for: raw) ==
        "单词: given a sentence\n意群: given a sentence\n译文: 给定一个句子"
    )
}

@Test func senseGroupRendererHidesPartialJSONStream() {
    let raw = "{\"source_chunk\":\"an"

    #expect(SenseGroupResponseRenderer.displayText(for: raw) == "正在识别意群...")
}

@Test func senseGroupRendererShowsPendingTargetForSourceOnlyJSON() {
    let raw = "{\"source_chunk\":\"given a sentence\"}"

    #expect(
        SenseGroupResponseRenderer.displayText(for: raw) ==
        "单词: given a sentence\n意群: given a sentence\n译文: 正在补译..."
    )
}

@Test func senseGroupRendererEmitsMiniDictionaryFieldsForFullResponse() {
    let raw = "{\"source_chunk\":\"an ironic twist\",\"target_chunk\":\"具有讽刺意味的转折\",\"word_pos\":\"n.\",\"word_brief\":\"转折\"}"

    let response = SenseGroupResponseRenderer.response(for: raw)
    #expect(response?.source == "an ironic twist")
    #expect(response?.target == "具有讽刺意味的转折")
    #expect(response?.wordPOS == "n.")
    #expect(response?.wordBrief == "转折")
    #expect(response?.hasWordPOS == true)
    #expect(response?.hasWordBrief == true)

    let display = SenseGroupResponseRenderer.displayText(for: raw)
    #expect(display.contains("单词: an ironic twist"))
    #expect(display.contains("词性: n."))
    #expect(display.contains("释义: 转折"))
    #expect(display.contains("意群: an ironic twist"))
    #expect(display.contains("译文: 具有讽刺意味的转折"))
}

@Test func senseGroupRendererAcceptsPOSAndBriefAliases() {
    let raw = "{\"source_chunk\":\"quick\",\"target_chunk\":\"敏捷的\",\"pos\":\"adj.\",\"definition\":\"快速的\"}"

    let response = SenseGroupResponseRenderer.response(for: raw)
    #expect(response?.wordPOS == "adj.")
    #expect(response?.wordBrief == "快速的")
}

@Test func senseGroupRendererReturnsResponseWithoutPOSOrBriefForLegacyJSON() {
    let raw = "{\"source_chunk\":\"X\",\"target_chunk\":\"Y\"}"

    let response = SenseGroupResponseRenderer.response(for: raw)
    #expect(response != nil)
    #expect(response?.wordPOS == "")
    #expect(response?.wordBrief == "")
    #expect(response?.hasWordPOS == false)
    #expect(response?.hasWordBrief == false)
}

@Test func senseGroupRendererOmitsEmptyPOSAndBriefLines() {
    let raw = "{\"source_chunk\":\"X\",\"target_chunk\":\"Y\"}"

    let display = SenseGroupResponseRenderer.displayText(for: raw)
    #expect(!display.contains("词性:"))
    // 释义 is the word-brief tag in the new schema. With no brief returned,
    // that line must be omitted entirely.
    #expect(!display.contains("释义:"))
    #expect(display.contains("意群: X"))
    #expect(display.contains("译文: Y"))
}

@Test func senseGroupRendererHonorsExplicitOverrideWord() {
    let raw = "{\"source_chunk\":\"an ironic twist\",\"target_chunk\":\"具有讽刺意味的转折\",\"word_pos\":\"n.\",\"word_brief\":\"转折\"}"

    let display = SenseGroupResponseRenderer.displayText(for: raw, overrideWord: "quick")
    #expect(display.hasPrefix("单词: quick\n"))
    // The phrase translation pair is unaffected by the override.
    #expect(display.contains("意群: an ironic twist"))
    #expect(display.contains("译文: 具有讽刺意味的转折"))
}

@Test func senseGroupRendererTreatsBlankOverrideWordAsSourceFallback() {
    let raw = "{\"source_chunk\":\"twist\",\"target_chunk\":\"转折\"}"

    let display = SenseGroupResponseRenderer.displayText(for: raw, overrideWord: "   ")
    #expect(display.contains("单词: twist"))
}

@Test func senseGroupRendererDetectsStructuredResponseFromNewFields() {
    #expect(SenseGroupResponseRenderer.isLikelyStructuredResponse("{\"word_pos\":\"adj.\"}"))
    #expect(SenseGroupResponseRenderer.isLikelyStructuredResponse("{\"word_brief\":\"快速的\"}"))
}

@Test func senseGroupRendererRequestsFallbackForMissingOrNonChineseTarget() throws {
    let sourceOnly = try #require(SenseGroupResponseRenderer.response(for: "{\"source_chunk\":\"exact substring of the sentence\"}"))
    let englishTarget = try #require(
        SenseGroupResponseRenderer.response(
            for: "{\"source_chunk\":\"exact substring of the sentence\",\"target_chunk\":\"exact substring of the sentence\"}"
        )
    )
    let chineseTarget = try #require(
        SenseGroupResponseRenderer.response(
            for: "{\"source_chunk\":\"exact substring of the sentence\",\"target_chunk\":\"句子的精确子字符串\"}"
        )
    )

    #expect(SenseGroupResponseRenderer.needsTranslationFallback(sourceOnly, targetLanguage: "zh"))
    #expect(SenseGroupResponseRenderer.needsTranslationFallback(englishTarget, targetLanguage: "zh"))
    #expect(!SenseGroupResponseRenderer.needsTranslationFallback(chineseTarget, targetLanguage: "zh"))
}

@Test func senseGroupRendererCleansFallbackTranslationText() {
    #expect(SenseGroupResponseRenderer.plainTranslationText(for: "\"句子的精确子字符串\"") == "句子的精确子字符串")
    #expect(SenseGroupResponseRenderer.plainTranslationText(for: "释义: 句子的精确子字符串") == "句子的精确子字符串")
    #expect(
        SenseGroupResponseRenderer.plainTranslationText(
            for: "{\"source_chunk\":\"exact substring of the sentence\",\"target_text\":\"句子的精确子字符串\"}"
        ) == "句子的精确子字符串"
    )
}

@Test func promptBuilderUsesConfiguredTemplateAndPayload() throws {
    let selection = WordSelection(word: "twist", context: "It's an ironic twist.", wordRangeInContext: 15..<20)
    let config = TranslationConfig(
        endpoint: "https://api.example.com",
        apiKey: "sk-test",
        model: "gpt-test",
        targetLanguage: "zh",
        promptTemplate: "Explain {word} in {target_language} using {context}."
    )

    let messages = PromptBuilder.messages(selection: selection, config: config)

    #expect(messages.first?.role == "system")
    #expect(messages.first?.content.contains("Explain twist in zh") == true)
    // Payload carries {word, sentence, position, target_language} and
    // MUST NOT carry any of the legacy pointed_clause / pointed_sentence
    // / pointed_word_* fields. Duplicate-word disambiguation is now done
    // via the 3-word `position` substring (consumed by both the LLM and
    // the client-side range-anchor localisation in AXWordReader).
    let userContent = try #require(messages.last?.content)
    let userData = try #require(userContent.data(using: .utf8))
    let payload = try #require(try JSONSerialization.jsonObject(with: userData) as? [String: Any])
    #expect(payload["word"] as? String == "twist")
    #expect(payload["sentence"] as? String != nil)
    #expect(payload["position"] as? String == "an ironic twist")
    #expect(payload["target_language"] as? String == "zh")
    #expect(payload["pointed_clause"] == nil)
    #expect(payload["pointed_sentence"] == nil)
    #expect(payload["pointed_word_start"] == nil)
    #expect(payload["pointed_word_end"] == nil)
    #expect(payload["context"] == nil)
}

@Test func promptBuilderNarrowsSentenceToClickedSentenceAcrossEnglishBoundary() throws {
    // Two sentences in one context window. The user clicks the SECOND
    // occurrence of "prompt" (in the second sentence). The payload's
    // `sentence` field must be only that second sentence — with the
    // trailing period kept (right boundary included) and the leading
    // period of the previous sentence excluded (left boundary excluded).
    let context = "Copy the below prompt into Codex. The prompt instructs Codex to create folders."
    let secondPrompt = context.utf16Offset(of: "prompt instructs")
    let selection = WordSelection(
        word: "prompt",
        context: context,
        wordRangeInContext: secondPrompt..<(secondPrompt + 6)
    )
    let config = TranslationConfig(promptTemplate: PromptBuilder.defaultPromptTemplate)

    let messages = PromptBuilder.messages(selection: selection, config: config)
    let userContent = try #require(messages.last?.content)
    let userData = try #require(userContent.data(using: .utf8))
    let payload = try #require(try JSONSerialization.jsonObject(with: userData) as? [String: Any])
    let sentence = try #require(payload["sentence"] as? String)
    let position = try #require(payload["position"] as? String)

    #expect(sentence == "The prompt instructs Codex to create folders.")
    // Sentence narrowing already pruned the first "prompt" — the narrowed
    // sentence has only one occurrence, so the cloze pass is a no-op and
    // no `___` placeholder is emitted.
    #expect(!sentence.contains("___"))
    // Position is computed from the FULL context (not the narrowed
    // sentence). The anchor sits in the middle of the second sentence's
    // tokens, so the 3-word window is "The prompt instructs".
    #expect(position == "The prompt instructs")
}

@Test func promptBuilderSentenceForSelectionReturnsClickedSentence() {
    // The repeat-tap gesture translates the whole sentence around the
    // popup's word. sentence(for:) must return the clicked sentence —
    // unclozed, boundaries handled like the prompt payload's extraction.
    let context = "Copy the below prompt into Codex. The prompt instructs Codex to create folders."
    let secondPrompt = context.utf16Offset(of: "prompt instructs")
    let selection = WordSelection(
        word: "prompt",
        context: context,
        wordRangeInContext: secondPrompt..<(secondPrompt + 6)
    )
    #expect(PromptBuilder.sentence(for: selection) == "The prompt instructs Codex to create folders.")
}

@Test func promptBuilderNarrowsSentenceToClickedSentenceAcrossChineseBoundary() throws {
    // Chinese full-stop "。" must be recognised as a sentence boundary
    // too, otherwise CJK context windows still send the entire passage
    // and the LLM keeps picking the first occurrence.
    let context = "这个 prompt 写得不好。下面的 prompt 用来调用助手。"
    let secondPrompt = context.utf16Offset(of: "prompt 用来调用助手")
    let selection = WordSelection(
        word: "prompt",
        context: context,
        wordRangeInContext: secondPrompt..<(secondPrompt + 6)
    )
    let config = TranslationConfig(promptTemplate: PromptBuilder.defaultPromptTemplate)

    let messages = PromptBuilder.messages(selection: selection, config: config)
    let userContent = try #require(messages.last?.content)
    let userData = try #require(userContent.data(using: .utf8))
    let payload = try #require(try JSONSerialization.jsonObject(with: userData) as? [String: Any])
    let sentence = try #require(payload["sentence"] as? String)
    let position = try #require(payload["position"] as? String)

    #expect(sentence == "下面的 prompt 用来调用助手。")
    // Sentence narrowing already pruned the first "prompt" — the cloze
    // pass is a no-op for the surviving single occurrence.
    #expect(!sentence.contains("___"))
    // Tokens around the anchor: "下面的", "prompt", "用来调用助手" — middle
    // case, so position is "下面的 prompt 用来调用助手" (verbatim slice with
    // both inter-token spaces).
    #expect(position == "下面的 prompt 用来调用助手")
}

@Test func promptBuilderUsesFullContextWhenSentenceHasNoBoundary() throws {
    // No boundary punctuation anywhere → `sentence` must degrade to the
    // entire context, NOT empty-string out.
    let context = "abcdef hello world ghijkl"
    let helloStart = context.utf16Offset(of: "hello")
    let selection = WordSelection(
        word: "hello",
        context: context,
        wordRangeInContext: helloStart..<(helloStart + 5)
    )
    let config = TranslationConfig(promptTemplate: PromptBuilder.defaultPromptTemplate)

    let messages = PromptBuilder.messages(selection: selection, config: config)
    let userContent = try #require(messages.last?.content)
    let userData = try #require(userContent.data(using: .utf8))
    let payload = try #require(try JSONSerialization.jsonObject(with: userData) as? [String: Any])
    let sentence = try #require(payload["sentence"] as? String)

    #expect(sentence == context)
}

@Test func promptBuilderKeepsCommasInsideSentenceWhenClickingDuplicateWord() throws {
    // Same word twice WITHIN A SINGLE SENTENCE (comma-separated clauses).
    // Comma is intentionally NOT a sentence boundary — the narrowed
    // sentence must contain BOTH clauses. Duplicate-word disambiguation
    // now combines the `position` field with a client-side cloze pass that
    // replaces every NON-anchor occurrence of the pointed word with `___`,
    // so the LLM sees a single literal occurrence and cannot pick wrong.
    let context = "Set the timer, and set the alarm."
    let secondSet = context.utf16Offset(of: "set the alarm")
    let selection = WordSelection(
        word: "set",
        context: context,
        wordRangeInContext: secondSet..<(secondSet + 3)
    )
    let config = TranslationConfig(promptTemplate: PromptBuilder.defaultPromptTemplate)

    let messages = PromptBuilder.messages(selection: selection, config: config)
    let userContent = try #require(messages.last?.content)
    let userData = try #require(userContent.data(using: .utf8))
    let payload = try #require(try JSONSerialization.jsonObject(with: userData) as? [String: Any])
    let sentence = try #require(payload["sentence"] as? String)
    let position = try #require(payload["position"] as? String)

    // First "Set" (case-insensitive match) becomes `___`; the clicked
    // second "set" stays intact so the LLM still has one literal anchor.
    #expect(sentence == "___ the timer, and set the alarm.")
    // Anchor sits on the SECOND "set". Its neighbours are "and" (left)
    // and "the" (right), so the verbatim slice is "and set the".
    #expect(position == "and set the")
}

// MARK: - Position derivation
//
// These tests pin the `PromptBuilder.position(for:)` behavior against the
// design's three boundary cases: middle (one neighbour each side), head
// (sentence-initial → two right neighbours), tail (sentence-final → two
// left neighbours), plus verbatim preservation of interstitial commas /
// markdown stars and the "fewer than 3 tokens → whole context" fallback.

@Test func promptBuilderPositionPicksMiddleNeighboursForUserRepro() throws {
    // The user's actual repro: a markdown bullet with three "plan" tokens
    // and one "Plan" capitalisation. The user clicks the SECOND lowercase
    // "plan" (in "keep plan status updates"). Position must be the verbatim
    // 3-word window "keep plan status".
    let context = "- Make sure it's clear the plan is *immutable*, keep plan status updates in a separate file, don't let the agent cheat by updating the plan"
    let secondPlan = context.utf16Offset(of: "plan status")
    let selection = WordSelection(
        word: "plan",
        context: context,
        wordRangeInContext: secondPlan..<(secondPlan + 4)
    )

    #expect(PromptBuilder.position(for: selection) == "keep plan status")
}

@Test func promptBuilderPositionTakesTwoRightNeighboursAtSentenceHead() throws {
    // Anchor on the very first token — there's no left neighbour, so the
    // position window walks two tokens right.
    let context = "Plan A is good."
    let plan = context.utf16Offset(of: "Plan")
    let selection = WordSelection(
        word: "Plan",
        context: context,
        wordRangeInContext: plan..<(plan + 4)
    )

    #expect(PromptBuilder.position(for: selection) == "Plan A is")
}

@Test func promptBuilderPositionTakesTwoLeftNeighboursAtSentenceTail() throws {
    // Anchor on the very last token in the user's bullet — no right
    // neighbour. Take two tokens to the left of the anchor instead.
    let context = "- Make sure it's clear the plan is *immutable*, keep plan status updates in a separate file, don't let the agent cheat by updating the plan"
    let utf16 = Array(context.utf16)
    // The last "plan" begins at utf16.count - 4 (length of "plan").
    let lastPlanStart = utf16.count - 4
    let selection = WordSelection(
        word: "plan",
        context: context,
        wordRangeInContext: lastPlanStart..<utf16.count
    )

    #expect(PromptBuilder.position(for: selection) == "updating the plan")
}

@Test func promptBuilderPositionKeepsInterstitialCommasVerbatim() throws {
    // Interstitial commas / whitespace between the chosen tokens must be
    // preserved EXACTLY — the position string is a verbatim substring of
    // the context. Here both gaps carry a comma + space, so the slice is
    // "foo, bar, baz".
    let context = "foo, bar, baz"
    let bar = context.utf16Offset(of: "bar")
    let selection = WordSelection(
        word: "bar",
        context: context,
        wordRangeInContext: bar..<(bar + 3)
    )

    #expect(PromptBuilder.position(for: selection) == "foo, bar, baz")
}

@Test func promptBuilderPositionFallsBackToWholeContextWhenFewerThanThreeTokens() throws {
    // Only two tokens in the context — the design says return the whole
    // context unchanged.
    let context = "Hello there"
    let hello = context.utf16Offset(of: "Hello")
    let selection = WordSelection(
        word: "Hello",
        context: context,
        wordRangeInContext: hello..<(hello + 5)
    )

    #expect(PromptBuilder.position(for: selection) == "Hello there")
}

@Test func promptBuilderPositionDisambiguatesSetTheAlarm() throws {
    // The known-limitation case for the previous sentence-narrowing
    // approach: "Set the timer and set the alarm." with the user pointing
    // at the SECOND "set". Position is "and set the" — the disambiguator
    // the LLM (and our range-anchor localisation) now gets.
    let context = "Set the timer and set the alarm."
    let secondSet = context.utf16Offset(of: "set the alarm")
    let selection = WordSelection(
        word: "set",
        context: context,
        wordRangeInContext: secondSet..<(secondSet + 3)
    )

    #expect(PromptBuilder.position(for: selection) == "and set the")
}

@Test func promptBuilderPositionPreservesMarkdownStars() throws {
    // Markdown asterisks live between tokens. They count as interstitial
    // and stay in the verbatim slice. Here the anchor is "immutable",
    // surrounded by "*immutable*" — the two neighbours are "is" (left)
    // and "keep" (right, jumping over ", "), so position is
    // "is *immutable*, keep".
    let context = "the plan is *immutable*, keep plan status"
    let immutable = context.utf16Offset(of: "immutable")
    let selection = WordSelection(
        word: "immutable",
        context: context,
        wordRangeInContext: immutable..<(immutable + 9)
    )

    #expect(PromptBuilder.position(for: selection) == "is *immutable*, keep")
}

// MARK: - Cloze pass
//
// The cloze pass replaces every non-anchor occurrence of the pointed word
// with `___` so the LLM only ever sees a single literal instance of the
// pointed word. This is the validated fix for the duplicate-word
// disambiguation bug. These tests pin the contract directly via the
// internal helper plus an end-to-end check through `messages(selection:config:)`.

@Test func clozeReplacesSecondOccurrenceLeavingAnchorIntact() {
    // Anchor sits on the SECOND "plan"; the first occurrence becomes `___`.
    let sentence = "the plan is good, the plan is bad"
    let anchor = sentence.utf16Offset(of: "plan is bad")
    let result = PromptBuilder.clozeSentence(
        originalSentence: sentence,
        anchorRangeInSentence: anchor..<(anchor + 4),
        word: "plan"
    )
    #expect(result == "the ___ is good, the plan is bad")
}

@Test func clozeIsCaseInsensitive() {
    // "Plan A" at the sentence head is uppercase; the anchor is the
    // lowercase "Plan" later. Case-folded matching means the uppercase
    // form still becomes `___`.
    let sentence = "Plan A is good. Plan B is bad."
    let secondPlan = sentence.utf16Offset(of: "Plan B")
    let result = PromptBuilder.clozeSentence(
        originalSentence: sentence,
        anchorRangeInSentence: secondPlan..<(secondPlan + 4),
        word: "plan"
    )
    #expect(result == "___ A is good. Plan B is bad.")
}

@Test func clozeHandlesCJK() {
    // CJK has no inter-word whitespace — make sure UTF-16 offset math still
    // lands on the right occurrence. "计划" appears twice; clicking the
    // second one leaves it intact and turns the first into `___`.
    let sentence = "他有一个计划，但这个计划不好"
    let secondPlan = sentence.utf16Offset(of: "计划不好")
    let result = PromptBuilder.clozeSentence(
        originalSentence: sentence,
        anchorRangeInSentence: secondPlan..<(secondPlan + 2),
        word: "计划"
    )
    #expect(result == "他有一个___，但这个计划不好")
}

@Test func clozeHandlesThreePlusOccurrencesInUserRepro() {
    // The user's actual bullet has three "plan" tokens plus one "Plan"
    // capitalisation. Clicking the SECOND lowercase "plan" must leave that
    // single occurrence intact and turn every other one (including the
    // capitalised match) into `___`.
    let sentence = "- Make sure it's clear the plan is *immutable*, keep plan status updates in a separate file, don't let the agent cheat by updating the plan"
    let anchor = sentence.utf16Offset(of: "plan status")
    let result = PromptBuilder.clozeSentence(
        originalSentence: sentence,
        anchorRangeInSentence: anchor..<(anchor + 4),
        word: "plan"
    )
    // Exactly one literal "plan" survives — the clicked one. Every other
    // occurrence (regardless of case) becomes `___`.
    #expect(result == "- Make sure it's clear the ___ is *immutable*, keep plan status updates in a separate file, don't let the agent cheat by updating the ___")
    // Sanity: count the surviving literal occurrences of "plan" — exactly
    // one match (case-sensitive lowercase, since the anchor stayed
    // lowercase). The capital "Plan" / second "Plan" reference here was
    // imaginary; this sentence has three lowercase "plan" tokens, the
    // user's actual repro. The cloze leaves exactly the anchor alone.
    let surviving = result.components(separatedBy: "plan").count - 1
    #expect(surviving == 1)
}

@Test func clozeWithSingleOccurrenceIsNoOp() {
    // Sanity check: when the pointed word appears exactly once, the cloze
    // pass must return the sentence unchanged.
    let sentence = "It's an ironic twist that we might all end up as NPCs."
    let anchor = sentence.utf16Offset(of: "twist")
    let result = PromptBuilder.clozeSentence(
        originalSentence: sentence,
        anchorRangeInSentence: anchor..<(anchor + 5),
        word: "twist"
    )
    #expect(result == sentence)
    #expect(!result.contains("___"))
}

@Test func clozeAppliedThroughMessagesForUserRepro() throws {
    // End-to-end check through `messages(selection:config:)`. The user's
    // actual bullet, clicking the SECOND lowercase "plan". The payload's
    // `sentence` field must be the cloze version.
    let context = "- Make sure it's clear the plan is *immutable*, keep plan status updates in a separate file, don't let the agent cheat by updating the plan"
    let secondPlan = context.utf16Offset(of: "plan status")
    let selection = WordSelection(
        word: "plan",
        context: context,
        wordRangeInContext: secondPlan..<(secondPlan + 4)
    )
    let config = TranslationConfig(promptTemplate: PromptBuilder.defaultPromptTemplate)

    let messages = PromptBuilder.messages(selection: selection, config: config)
    let userContent = try #require(messages.last?.content)
    let userData = try #require(userContent.data(using: .utf8))
    let payload = try #require(try JSONSerialization.jsonObject(with: userData) as? [String: Any])
    let sentence = try #require(payload["sentence"] as? String)

    // Cloze drops every non-anchor "plan" to `___`; the clicked one
    // remains as the single literal anchor for the LLM. The bullet has no
    // sentence-boundary punctuation, so `sentence` covers the whole
    // context with the cloze applied.
    #expect(sentence == "- Make sure it's clear the ___ is *immutable*, keep plan status updates in a separate file, don't let the agent cheat by updating the ___")
    // `position` is unaffected by the cloze (still computed from the
    // original `context`).
    let position = try #require(payload["position"] as? String)
    #expect(position == "keep plan status")
}

@Test func openRouterStreamingSmokeWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let apiKey = environment["MACSCREENTRANS_OPENROUTER_API_KEY"], !apiKey.isEmpty else {
        return
    }

    let selection = WordSelection(
        word: "twist",
        context: "It's an ironic twist that we might all end up as NPCs.",
        wordRangeInContext: 15..<20
    )
    let config = TranslationConfig(
        endpoint: environment["MACSCREENTRANS_OPENROUTER_ENDPOINT"] ?? "https://openrouter.ai/api/v1",
        apiKey: apiKey,
        model: environment["MACSCREENTRANS_OPENROUTER_MODEL"] ?? "openai/gpt-4o-mini",
        targetLanguage: "zh",
        promptTemplate: PromptBuilder.defaultPromptTemplate
    )

    var output = ""
    var chunkCount = 0
    for try await delta in OpenAIStreamingClient().streamExplanation(selection: selection, config: config) {
        output += delta
        chunkCount += 1
        if output.utf16.count > 16 {
            break
        }
    }

    #expect(chunkCount > 0)
    #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test func defaultPromptKeepsReferenceSenseGroupContract() {
    let prompt = PromptBuilder.defaultPromptTemplate

    #expect(prompt.contains("ONLY a JSON object"))
    // Sentence-based contract aligned with the Android sibling: the
    // payload now carries only {word, sentence, target_language} and
    // source_chunk must be a substring of `sentence`. Any reintroduction
    // of `pointed_clause` / « » markers would mean we regressed the
    // simplification.
    #expect(prompt.contains("source_chunk MUST be an exact substring of the sentence"))
    #expect(prompt.contains("source_chunk MUST contain the pointed word"))
    // The cloze-placeholder rule must be present so the LLM never emits
    // `___` as part of source_chunk.
    #expect(prompt.contains("source_chunk MUST NOT contain `___`"))
    #expect(prompt.contains("Three consecutive underscores"))
    #expect(prompt.contains("placeholder"))
    #expect(!prompt.contains("pointed_clause"))
    #expect(!prompt.contains("«"))
    #expect(!prompt.contains("»"))
    #expect(prompt.contains("target_chunk MUST translate ONLY source_chunk"))
    #expect(prompt.contains("word_pos MUST be a short English POS abbreviation"))
    #expect(prompt.contains("word_brief MUST be a 5-15 character"))
    #expect(prompt.contains("{\"source_chunk\":\"...\",\"target_chunk\":\"...\",\"word_pos\":\"...\",\"word_brief\":\"...\"}"))
}

@Test func translationOnlyPromptKeepsFallbackPlainTextContract() {
    let prompt = PromptBuilder.translationOnlyPromptTemplate

    #expect(prompt.contains("Translate the phrase"))
    #expect(prompt.contains("Output ONLY the translated text"))
    #expect(prompt.contains("No JSON"))
}

@Test func threeFingerTapDetectorRecognizesShortThreeFingerTouch() {
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 3, timestamp: 10.0, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.12, centroidX: 0.5, centroidY: 0.5)

    #expect(recognized)
}

@Test func threeFingerTapDetectorRejectsLongHold() {
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 3, timestamp: 10.0, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.9, centroidX: 0.5, centroidY: 0.5)

    #expect(!recognized)
}

@Test func threeFingerTapDetectorDebouncesRepeatedFrames() {
    var count = 0
    var detector = ThreeFingerTapDetector { count += 1 }

    detector.process(contactCount: 3, timestamp: 10.0, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.12, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.2, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.28, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.7, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.78, centroidX: 0.5, centroidY: 0.5)

    #expect(count == 2)
}

@Test func threeFingerTapDetectorRequiresFullRelease() {
    var count = 0
    var detector = ThreeFingerTapDetector { count += 1 }

    detector.process(contactCount: 3, timestamp: 10.0, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 2, timestamp: 10.1, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.5, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 4, timestamp: 10.6, centroidX: 0.5, centroidY: 0.5)

    #expect(count == 0)
}

@Test func threeFingerTapDetectorAcceptsRealisticReleaseRamp() {
    // MultitouchSupport rarely reports a clean 3 → 0 transition; fingers lift
    // one at a time, so the typical sequence is 0 → 1 → 2 → 3 → 2 → 1 → 0.
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 1, timestamp: 10.00, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 2, timestamp: 10.01, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.02, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 2, timestamp: 10.10, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 1, timestamp: 10.11, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.12, centroidX: 0.5, centroidY: 0.5)

    #expect(recognized)
}

@Test func threeFingerTapDetectorRejectsFourFingerTap() {
    var count = 0
    var detector = ThreeFingerTapDetector { count += 1 }

    detector.process(contactCount: 1, timestamp: 10.00, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 2, timestamp: 10.01, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.02, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 4, timestamp: 10.03, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.10, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.12, centroidX: 0.5, centroidY: 0.5)

    #expect(count == 0)
}

@Test func threeFingerTapDetectorRejectsTwoFingerTap() {
    var count = 0
    var detector = ThreeFingerTapDetector { count += 1 }

    detector.process(contactCount: 1, timestamp: 10.00, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 2, timestamp: 10.02, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 1, timestamp: 10.10, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.12, centroidX: 0.5, centroidY: 0.5)

    #expect(count == 0)
}

@Test func threeFingerTapDetectorRejectsThreeFingerSwipeByDrift() {
    // System three-finger swipe (Mission Control, desktop switching): the
    // centroid drifts a long way across the trackpad. Drift > 0.08 must reject.
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 3, timestamp: 10.00, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.05, centroidX: 0.6, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.15, centroidX: 0.7, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.18, centroidX: 0.7, centroidY: 0.5)

    #expect(!recognized)
}

@Test func threeFingerTapDetectorRejectsSubMinimumDurationJitter() {
    // 10ms total — sensor jitter, not a human tap. Below 20ms floor.
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 3, timestamp: 10.000, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.010, centroidX: 0.5, centroidY: 0.5)

    #expect(!recognized)
}

@Test func threeFingerTapDetectorAcceptsStationaryTap() {
    // A real tap: drift well under 0.05, duration well under ceiling.
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 3, timestamp: 10.00, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.05, centroidX: 0.501, centroidY: 0.502)
    detector.process(contactCount: 0, timestamp: 10.10, centroidX: 0.501, centroidY: 0.502)

    #expect(recognized)
}

@Test func threeFingerTapDetectorMeasuresDurationFromThreeFingersDown() {
    // Staggered landing: finger 1 at t=0, finger 2 at t=0.15, finger 3 at
    // t=0.25, release at t=0.45. Total contact is 0.45s (over the 0.28s
    // ceiling), but the three-fingers-down phase is only 0.20s — the tap
    // must fire. The old anchor (first firm contact) rejected this with
    // "duration > max".
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 1, timestamp: 10.00, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 2, timestamp: 10.15, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.25, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.45, centroidX: 0.5, centroidY: 0.5)

    #expect(recognized)
}

@Test func threeFingerTapDetectorAcceptsDriftJustBelowThreshold() {
    // Drift = 0.079 (just under the 0.08 ceiling) — should fire.
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 3, timestamp: 10.00, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.05, centroidX: 0.579, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.10, centroidX: 0.579, centroidY: 0.5)

    #expect(recognized)
}

@Test func threeFingerTapDetectorRejectsDriftJustAboveThreshold() {
    // Drift = 0.081 (just over the 0.08 ceiling) — should reject.
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 3, timestamp: 10.00, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.05, centroidX: 0.581, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.10, centroidX: 0.581, centroidY: 0.5)

    #expect(!recognized)
}

@Test func threeFingerTapDetectorTracksPeakDriftEvenIfFingersReturn() {
    // Centroid drifts to 0.6 mid-touch then returns to start. The detector
    // should record max drift = 0.1 across the lifetime, not final drift = 0.
    // 0.1 > 0.08 ceiling, so this must still reject.
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 3, timestamp: 10.00, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.05, centroidX: 0.6, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.10, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.15, centroidX: 0.5, centroidY: 0.5)

    #expect(!recognized)
}

@Test func screenCoordinateConverterFlipsQuartzRectToAppKit() {
    // Primary screen is 1440x900 at origin (0, 0).
    let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // A Quartz rect 100pt from the top, 30pt tall, at x=200, width=80.
    let quartz = CGRect(x: 200, y: 100, width: 80, height: 30)

    let appkit = ScreenCoordinateConverter.appKitRect(
        fromQuartzRect: quartz,
        primaryScreenFrame: primary
    )

    #expect(appkit.origin.x == 200)
    // In AppKit space the bottom edge of the rect is at primary.maxY - quartz.maxY = 900 - 130 = 770.
    #expect(appkit.origin.y == 770)
    #expect(appkit.width == 80)
    #expect(appkit.height == 30)
}

@Test func popupPlacementPrefersAboveWordWhenSpaceAllows() {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let word = CGRect(x: 600, y: 400, width: 80, height: 22)
    let popup = CGSize(width: 390, height: 230)

    let placement = ScreenCoordinateConverter.popupPlacement(
        wordRect: word,
        popupSize: popup,
        screenVisibleFrame: visible,
        verticalGap: 6
    )

    #expect(placement.isAboveWord == true)
    // The popup's bottom edge should sit verticalGap above the word's top edge.
    #expect(placement.origin.y == word.maxY + 6)
    // The popup is centered on the word so its midpoint matches the word's midpoint.
    let wordCenter = word.midX
    let popupCenter = placement.origin.x + popup.width / 2
    #expect(abs(popupCenter - wordCenter) < 0.001)
    // tailX should point right at the word's center, in popup-local space.
    #expect(abs(placement.tailX - (wordCenter - placement.origin.x)) < 0.001)
}

@Test func popupPlacementFlipsBelowWhenNotEnoughRoomAbove() {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    // Word sits very high on screen — no room above for the popup.
    let word = CGRect(x: 600, y: 870, width: 80, height: 22)
    let popup = CGSize(width: 390, height: 230)

    let placement = ScreenCoordinateConverter.popupPlacement(
        wordRect: word,
        popupSize: popup,
        screenVisibleFrame: visible,
        verticalGap: 6
    )

    #expect(placement.isAboveWord == false)
    // Popup top sits verticalGap below the word's bottom.
    let popupTop = placement.origin.y + popup.height
    #expect(popupTop == word.minY - 6)
}

@Test func popupPlacementClampsHorizontallyAtScreenEdge() {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    // Word near the left edge of the screen.
    let word = CGRect(x: 10, y: 400, width: 40, height: 20)
    let popup = CGSize(width: 390, height: 230)

    let placement = ScreenCoordinateConverter.popupPlacement(
        wordRect: word,
        popupSize: popup,
        screenVisibleFrame: visible,
        verticalGap: 6
    )

    // The popup must stay 8pt away from the screen's left edge.
    #expect(placement.origin.x >= visible.minX + 8 - 0.001)
    // The tail still points at the word's center, even though the popup is offset.
    let tailScreenX = placement.origin.x + placement.tailX
    #expect(abs(tailScreenX - word.midX) < 0.001)
}

// MARK: - C-bridge centroid tests
//
// These two tests close the v0.2.1 coverage gap. v0.2.1 shipped a 120-byte
// MSMTTouch where the canonical layout is 96 bytes. `touches[0]` happened to
// be correct (normalizedVector at offset 32 either way) but touches[i] for
// i >= 1 read garbage from the canonical `angle` / `majorAxis` bytes — the
// centroid drifted wildly and every 3-finger tap was rejected. These tests
// drive `MSComputeCentroid` directly with a synthesized 96-byte-per-touch
// buffer so the bug would be caught immediately by `scripts/test`, without
// the user needing to be the QA.

/// Per-touch stride is locked to the canonical MTTouch size of 96 bytes.
private let mtTouchStride = 96

/// Byte offsets inside MTTouch — must match the C struct layout in
/// `CMultitouchSupport.c`. The static_asserts in the C file guard the C
/// side; this constant set guards the test fixture against drift.
private enum MTTouchOffset {
    static let state = 20
    static let normalizedPosX = 32
    static let normalizedPosY = 36
}

/// Writes a 4-byte little-endian Int32 at `offset` into `buffer`.
private func writeInt32(_ value: Int32, at offset: Int, into buffer: UnsafeMutableRawPointer) {
    buffer.advanced(by: offset).bindMemory(to: Int32.self, capacity: 1).pointee = value
}

/// Writes a 4-byte float at `offset` into `buffer`.
private func writeFloat(_ value: Float, at offset: Int, into buffer: UnsafeMutableRawPointer) {
    buffer.advanced(by: offset).bindMemory(to: Float.self, capacity: 1).pointee = value
}

/// Fills the `i`-th touch slot (each 96 bytes) inside `buffer` with the
/// supplied `state`, normalized x and normalized y.
private func writeTouch(into buffer: UnsafeMutableRawPointer, index: Int, state: Int32, x: Float, y: Float) {
    let slot = buffer.advanced(by: index * mtTouchStride)
    writeInt32(state, at: MTTouchOffset.state, into: slot)
    writeFloat(x, at: MTTouchOffset.normalizedPosX, into: slot)
    writeFloat(y, at: MTTouchOffset.normalizedPosY, into: slot)
}

@Test func cBridgeCentroidAveragesThreeFirmTouches() {
    // Three firm touches (state = 4 = Touching) at (0.3, 0.4), (0.5, 0.4),
    // (0.7, 0.4). The centroid must be the arithmetic mean of the three:
    // ((0.3 + 0.5 + 0.7) / 3, 0.4) = (0.5, 0.4). firmCount must be 3.
    let byteCount = mtTouchStride * 3
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
    defer { buffer.deallocate() }
    memset(buffer, 0, byteCount)

    writeTouch(into: buffer, index: 0, state: 4, x: 0.3, y: 0.4)
    writeTouch(into: buffer, index: 1, state: 4, x: 0.5, y: 0.4)
    writeTouch(into: buffer, index: 2, state: 4, x: 0.7, y: 0.4)

    var firmCount: Int32 = 0
    var cx: Float = 0
    var cy: Float = 0
    MSComputeCentroid(buffer, 3, &firmCount, &cx, &cy)

    #expect(firmCount == 3)
    #expect(abs(cx - 0.5) < 0.0001)
    #expect(abs(cy - 0.4) < 0.0001)
}

@Test func cBridgeCentroidExcludesLiftingFingers() {
    // Three touch slots, but only two are firm (state = 4). The third is in
    // state = 5 (BreakTouch — finger lifting). The centroid must average
    // ONLY the firm touches: ((0.3 + 0.5) / 2, 0.4) = (0.4, 0.4). firmCount
    // must be 2 so the downstream Swift detector doesn't see "3 fingers"
    // when one is on the way out.
    let byteCount = mtTouchStride * 3
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
    defer { buffer.deallocate() }
    memset(buffer, 0, byteCount)

    writeTouch(into: buffer, index: 0, state: 4, x: 0.3, y: 0.4)
    writeTouch(into: buffer, index: 1, state: 4, x: 0.5, y: 0.4)
    writeTouch(into: buffer, index: 2, state: 5, x: 0.99, y: 0.99)  // lifting — must be ignored

    var firmCount: Int32 = 0
    var cx: Float = 0
    var cy: Float = 0
    MSComputeCentroid(buffer, 3, &firmCount, &cx, &cy)

    #expect(firmCount == 2)
    #expect(abs(cx - 0.4) < 0.0001)
    #expect(abs(cy - 0.4) < 0.0001)
}

private extension String {
    func utf16Offset(of needle: String) -> Int {
        let range = range(of: needle)!
        return range.lowerBound.samePosition(in: utf16)!.utf16Offset(in: self)
    }
}
