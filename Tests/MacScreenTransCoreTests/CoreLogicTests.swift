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

    #expect(SenseGroupResponseRenderer.displayText(for: raw) == "意群: an ironic twist\n释义: 具有讽刺意味的转折")
}

@Test func senseGroupRendererAcceptsLegacyTranslationAliases() {
    let raw = "{\"source_chunk\":\"given a sentence\",\"translation\":\"给定一个句子\"}"

    #expect(SenseGroupResponseRenderer.displayText(for: raw) == "意群: given a sentence\n释义: 给定一个句子")
}

@Test func senseGroupRendererAcceptsChunkAliasAndMarkdownFence() {
    let raw = """
    ```json
    {"chunk":"given a sentence","translation":"给定一个句子"}
    ```
    """

    #expect(SenseGroupResponseRenderer.displayText(for: raw) == "意群: given a sentence\n释义: 给定一个句子")
}

@Test func senseGroupRendererHidesPartialJSONStream() {
    let raw = "{\"source_chunk\":\"an"

    #expect(SenseGroupResponseRenderer.displayText(for: raw) == "正在识别意群...")
}

@Test func senseGroupRendererShowsPendingTargetForSourceOnlyJSON() {
    let raw = "{\"source_chunk\":\"given a sentence\"}"

    #expect(SenseGroupResponseRenderer.displayText(for: raw) == "意群: given a sentence\n释义: 正在补译...")
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
    #expect(prompt.contains("{\"source_chunk\":\"...\",\"target_chunk\":\"...\"}"))
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

    detector.process(contactCount: 3, timestamp: 10.0)
    detector.process(contactCount: 0, timestamp: 10.12)

    #expect(recognized)
}

@Test func threeFingerTapDetectorRejectsLongHold() {
    var recognized = false
    var detector = ThreeFingerTapDetector { recognized = true }

    detector.process(contactCount: 3, timestamp: 10.0)
    detector.process(contactCount: 0, timestamp: 10.9)

    #expect(!recognized)
}

@Test func threeFingerTapDetectorDebouncesRepeatedFrames() {
    var count = 0
    var detector = ThreeFingerTapDetector { count += 1 }

    detector.process(contactCount: 3, timestamp: 10.0)
    detector.process(contactCount: 0, timestamp: 10.12)
    detector.process(contactCount: 3, timestamp: 10.2)
    detector.process(contactCount: 0, timestamp: 10.28)
    detector.process(contactCount: 3, timestamp: 10.7)
    detector.process(contactCount: 0, timestamp: 10.78)

    #expect(count == 2)
}

@Test func threeFingerTapDetectorRequiresFullRelease() {
    var count = 0
    var detector = ThreeFingerTapDetector { count += 1 }

    detector.process(contactCount: 3, timestamp: 10.0)
    detector.process(contactCount: 2, timestamp: 10.1)
    detector.process(contactCount: 3, timestamp: 10.5)
    detector.process(contactCount: 4, timestamp: 10.6)

    #expect(count == 0)
}

private extension String {
    func utf16Offset(of needle: String) -> Int {
        let range = range(of: needle)!
        return range.lowerBound.samePosition(in: utf16)!.utf16Offset(in: self)
    }
}
