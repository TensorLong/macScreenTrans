import Foundation

public enum EndpointResolver {
    public static let defaultBaseURL = "https://api.openai.com"
    public static let chatCompletionsPath = "v1/chat/completions"

    public static func chatCompletionsURL(baseURL: String?) -> URL? {
        endpointURL(baseURL: baseURL, path: chatCompletionsPath)
    }

    public static func endpointURL(baseURL: String?, path: String) -> URL? {
        let rawBase = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (rawBase?.isEmpty == false ? rawBase! : defaultBaseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = base.hasSuffix("/v1") && trimmedPath.hasPrefix("v1/")
            ? String(trimmedPath.dropFirst(3))
            : trimmedPath
        guard let url = URL(string: "\(base)/\(normalizedPath)"),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}
