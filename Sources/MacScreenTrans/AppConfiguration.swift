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
    static let defaultModel = TranslationConfig.defaultModel

    static func bootstrapDefaults() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            DefaultsKey.endpoint: EndpointResolver.defaultBaseURL,
            DefaultsKey.apiKey: "",
            DefaultsKey.model: defaultModel,
            DefaultsKey.targetLanguage: "zh",
            DefaultsKey.promptTemplate: PromptBuilder.defaultPromptTemplate
        ])

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
        let config = current
        return !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            EndpointResolver.chatCompletionsURL(baseURL: config.endpoint) != nil &&
            !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
