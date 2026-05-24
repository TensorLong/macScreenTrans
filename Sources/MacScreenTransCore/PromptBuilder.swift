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
    You output ONLY a JSON object. No prose. No markdown. No code fences. No prefix or suffix text.

    Task: given a sentence and a pointed word, find the SMALLEST meaningful phrase
    (sense group) in the sentence that contains the pointed word, then translate
    ONLY that phrase into the target language.

    Rules:
    1. source_chunk MUST be an exact substring of the sentence.
    2. source_chunk MUST contain the pointed word.
    3. Pick the smallest natural phrase that carries meaning on its own (usually 2-6 words).
    4. Do NOT return the whole sentence as source_chunk.
    5. For verbs, include the object/complement (e.g. "make a decision", not "make").
    6. For nouns, include tight modifiers/articles (e.g. "an ironic twist", not "twist").
    7. target_chunk MUST translate ONLY source_chunk, not the surrounding sentence.

    Output schema (return this exact JSON object and nothing else):
    {"source_chunk":"...","target_chunk":"..."}

    Example
    Input:  {"word":"twist","sentence":"It's an ironic twist that we might all end up as NPCs.","target_language":"zh"}
    Output: {"source_chunk":"an ironic twist","target_chunk":"具有讽刺意味的转折"}
    """

    public static let translationOnlyPromptTemplate = """
    Translate the phrase in the user payload to {target_language}.
    Output ONLY the translated text. No JSON, no markdown, no explanations.
    """

    public static func messages(selection: WordSelection, config: TranslationConfig) -> [ChatMessage] {
        let system = fillTemplate(config.promptTemplate, selection: selection, config: config)
        let payload: [String: Any] = [
            "word": selection.word,
            "sentence": selection.context,
            "context": selection.context,
            "pointed_word_start": selection.wordRangeInContext.lowerBound,
            "pointed_word_end": selection.wordRangeInContext.upperBound,
            "target_language": config.targetLanguage
        ]
        let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let user = payloadData.flatMap { String(data: $0, encoding: .utf8) } ?? selection.context
        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user)
        ]
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
