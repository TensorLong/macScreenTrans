import Foundation

public enum OpenAIStreamingError: LocalizedError {
    case invalidEndpoint
    case invalidHTTPResponse
    case httpFailure(Int, String)
    /// The server answered HTTP 200 but delivered the failure as an
    /// in-stream `{"error": ...}` payload (LiteLLM, vLLM, Ollama runner
    /// crashes mid-generation all do this).
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "LLM endpoint is invalid"
        case .invalidHTTPResponse:
            return "LLM endpoint returned an invalid response"
        case let .httpFailure(status, body):
            return "LLM request failed with HTTP \(status): \(body)"
        case let .serverError(message):
            return "LLM server reported an error: \(message)"
        }
    }
}

public final class OpenAIStreamingClient: Sendable {
    private let session: URLSession

    public convenience init() {
        let configuration = URLSessionConfiguration.default
        // Generous enough for a local 7B model cold-loading off disk on a
        // slower machine; measured Apple-Silicon cold starts are ~6s to
        // first byte, but Intel + memory pressure can multiply that.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
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
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Keyless local endpoints (Ollama, LM Studio) are first-class: only
        // send Authorization when a key is actually configured and let the
        // server 401 if it wanted one.
        let trimmedKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
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
            if let message = ChatCompletionStreamParser.errorMessage(fromSSELine: line) {
                throw OpenAIStreamingError.serverError(message)
            }
            if let delta = ChatCompletionStreamParser.contentDelta(fromSSELine: line) {
                continuation.yield(delta)
            }
        }
    }
}
