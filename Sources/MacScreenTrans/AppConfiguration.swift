import Foundation
import MacScreenTransCore

enum DefaultsKey {
    static let endpoint = "endpoint"
    static let apiKey = "apiKey"
    static let model = "model"
    static let targetLanguage = "targetLanguage"
    static let promptTemplate = "promptTemplate"
}

enum AppConfiguration {
    static func bootstrapDefaults() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            DefaultsKey.endpoint: EndpointResolver.defaultBaseURL,
            DefaultsKey.apiKey: "",
            DefaultsKey.model: "gpt-4o-mini",
            DefaultsKey.targetLanguage: "zh",
            DefaultsKey.promptTemplate: PromptBuilder.defaultPromptTemplate
        ])
    }

    static var current: TranslationConfig {
        let defaults = UserDefaults.standard
        return TranslationConfig(
            endpoint: defaults.string(forKey: DefaultsKey.endpoint) ?? EndpointResolver.defaultBaseURL,
            apiKey: defaults.string(forKey: DefaultsKey.apiKey) ?? "",
            model: defaults.string(forKey: DefaultsKey.model) ?? "gpt-4o-mini",
            targetLanguage: defaults.string(forKey: DefaultsKey.targetLanguage) ?? "zh",
            promptTemplate: defaults.string(forKey: DefaultsKey.promptTemplate) ?? PromptBuilder.defaultPromptTemplate
        )
    }

    static var hasMinimumLLMConfig: Bool {
        let config = current
        return !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            EndpointResolver.chatCompletionsURL(baseURL: config.endpoint) != nil &&
            !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
