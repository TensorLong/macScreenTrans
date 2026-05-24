import CoreGraphics
import Foundation
import Testing
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

@Test func promptBuilderUsesConfiguredTemplateAndPayload() {
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
    #expect(messages.last?.content.contains("\"pointed_word_start\":15") == true)
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
    #expect(prompt.contains("source_chunk MUST be an exact substring"))
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
    // centroid drifts a long way across the trackpad. Drift > 0.05 must reject.
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

@Test func threeFingerTapDetectorAcceptsDriftJustBelowThreshold() {
    // Drift = 0.049 (just under the 0.05 ceiling) — should fire.
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 3, timestamp: 10.00, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.05, centroidX: 0.549, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.10, centroidX: 0.549, centroidY: 0.5)

    #expect(recognized)
}

@Test func threeFingerTapDetectorRejectsDriftJustAboveThreshold() {
    // Drift = 0.051 (just over the 0.05 ceiling) — should reject.
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 3, timestamp: 10.00, centroidX: 0.5, centroidY: 0.5)
    detector.process(contactCount: 3, timestamp: 10.05, centroidX: 0.551, centroidY: 0.5)
    detector.process(contactCount: 0, timestamp: 10.10, centroidX: 0.551, centroidY: 0.5)

    #expect(!recognized)
}

@Test func threeFingerTapDetectorTracksPeakDriftEvenIfFingersReturn() {
    // Centroid drifts to 0.6 mid-touch then returns to start. The detector
    // should record max drift = 0.1 across the lifetime, not final drift = 0.
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

private extension String {
    func utf16Offset(of needle: String) -> Int {
        let range = range(of: needle)!
        return range.lowerBound.samePosition(in: utf16)!.utf16Offset(in: self)
    }
}
