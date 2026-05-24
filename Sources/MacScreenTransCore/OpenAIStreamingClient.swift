import Foundation

public enum OpenAIStreamingError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case invalidHTTPResponse
    case httpFailure(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is not configured"
        case .invalidEndpoint:
            return "LLM endpoint is invalid"
        case .invalidHTTPResponse:
            return "LLM endpoint returned an invalid response"
        case let .httpFailure(status, body):
            return "LLM request failed with HTTP \(status): \(body)"
        }
    }
}

public final class OpenAIStreamingClient: Sendable {
    private let session: URLSession

    public convenience init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        self.init(session: URLSession(configuration: configuration))
    }

    init(session: URLSession) {
        self.session = session
    }

    public func streamExplanation(
        selection: WordSelection,
        config: TranslationConfig
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(selection: selection, config: config, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        selection: WordSelection,
        config: TranslationConfig,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIStreamingError.missingAPIKey
        }
        guard let url = EndpointResolver.chatCompletionsURL(baseURL: config.endpoint) else {
            throw OpenAIStreamingError.invalidEndpoint
        }

        let messages = PromptBuilder.messages(selection: selection, config: config)
        let body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? TranslationConfig.defaultModel : config.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "temperature": 0.0
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIStreamingError.invalidHTTPResponse
        }
        guard 200..<300 ~= http.statusCode else {
            var body = Data()
            for try await byte in bytes {
                guard body.count < 4096 else { break }
                body.append(byte)
            }
            let text = String(data: body, encoding: .utf8) ?? "<no body>"
            throw OpenAIStreamingError.httpFailure(http.statusCode, text)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let delta = ChatCompletionStreamParser.contentDelta(fromSSELine: line) {
                continuation.yield(delta)
            }
        }
    }
}
