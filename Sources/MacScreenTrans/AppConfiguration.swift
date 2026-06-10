import Foundation
import MacScreenTransCore

enum DefaultsKey {
    static let endpoint = "endpoint"
    static let apiKey = "apiKey"
    static let model = "model"
    static let targetLanguage = "targetLanguage"
    static let promptTemplate = "promptTemplate"
    static let promptTemplateVersion = "promptTemplateVersion"
    // Model catalog cache: newline-joined ids fetched from /v1/models, the
    // resolved models URL they came from (cache key — a changed endpoint
    // invalidates the list, a changed API key does not), and the fetch time.
    static let fetchedModels = "fetchedModels"
    static let fetchedModelsSource = "fetchedModelsSource"
    static let fetchedModelsAt = "fetchedModelsAt"
}

enum AppConfiguration {
    static let defaultModel = TranslationConfig.defaultModel

    /// Bump this when `PromptBuilder.defaultPromptTemplate` gains required JSON
    /// fields (or changes rule semantics) that older stored templates won't
    /// emit. `bootstrapDefaults()` forcibly overwrites the stored prompt
    /// template when the persisted version is below this number — silent
    /// migration, no user-facing notification. v2 added rules 10 (word_pos)
    /// and 11 (word_brief), which v0.1.x stored prompts don't request.
    private static let currentPromptTemplateVersion = 2

    static func bootstrapDefaults() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            DefaultsKey.endpoint: EndpointResolver.defaultBaseURL,
            DefaultsKey.apiKey: "",
            DefaultsKey.model: defaultModel,
            DefaultsKey.targetLanguage: "zh",
            DefaultsKey.promptTemplate: PromptBuilder.defaultPromptTemplate,
            // Register 0 so a freshly-installed defaults store reads back
            // as "needs migration" on first launch, then we bump to current.
            // A v0.1.x user already has no entry for this key either, so
            // `integer(forKey:)` returns 0 there too — same migration path.
            DefaultsKey.promptTemplateVersion: 0
        ])

        let storedVersion = defaults.integer(forKey: DefaultsKey.promptTemplateVersion)
        if storedVersion < currentPromptTemplateVersion {
            // Forcibly overwrite the stored prompt template. `register` only
            // seeds keys that are ABSENT; v0.1.x users have the OLD prompt
            // frozen in NSUserDefaults, and that stale prompt never asks
            // the LLM for `word_pos` / `word_brief`. Overwrite + bump.
            defaults.set(PromptBuilder.defaultPromptTemplate, forKey: DefaultsKey.promptTemplate)
            defaults.set(currentPromptTemplateVersion, forKey: DefaultsKey.promptTemplateVersion)
        }

        if defaults.string(forKey: DefaultsKey.endpoint) == "https://api.openai.com",
           defaults.string(forKey: DefaultsKey.apiKey)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           defaults.string(forKey: DefaultsKey.model) == "gpt-4o-mini" {
            defaults.set(EndpointResolver.defaultBaseURL, forKey: DefaultsKey.endpoint)
            defaults.set(defaultModel, forKey: DefaultsKey.model)
        }
    }

    static var current: TranslationConfig {
        let defaults = UserDefaults.standard
        return TranslationConfig(
            endpoint: defaults.string(forKey: DefaultsKey.endpoint) ?? EndpointResolver.defaultBaseURL,
            apiKey: defaults.string(forKey: DefaultsKey.apiKey) ?? "",
            model: defaults.string(forKey: DefaultsKey.model) ?? defaultModel,
            targetLanguage: defaults.string(forKey: DefaultsKey.targetLanguage) ?? "zh",
            promptTemplate: defaults.string(forKey: DefaultsKey.promptTemplate) ?? PromptBuilder.defaultPromptTemplate
        )
    }

    static var hasMinimumLLMConfig: Bool {
        // The API key is deliberately NOT required: keyless local endpoints
        // (Ollama, LM Studio) are a first-class configuration.
        let config = current
        return EndpointResolver.chatCompletionsURL(baseURL: config.endpoint) != nil &&
            !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Marketing version pulled from `CFBundleShortVersionString` so the
    /// menu bar item and Settings footer stay in sync with the plist
    /// without code edits at release time. Falls back to "?" if the
    /// Info dictionary is unreadable (e.g. running as a raw SwiftPM
    /// executable without the app bundle around it).
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
