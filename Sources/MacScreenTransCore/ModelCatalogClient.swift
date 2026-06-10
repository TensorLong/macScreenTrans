import Foundation

public enum ModelCatalogError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidHTTPResponse
    case httpFailure(Int, String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Model list endpoint is invalid"
        case .invalidHTTPResponse:
            return "Model list endpoint returned an invalid response"
        case let .httpFailure(status, body):
            return "Model list request failed with HTTP \(status): \(body)"
        case .malformedResponse:
            return "Model list response could not be parsed"
        }
    }
}

/// Fetches the model catalog from an OpenAI-compatible `GET /v1/models`
/// endpoint so users can pick a model instead of typing its id by hand.
public final class ModelCatalogClient: Sendable {
    public static let modelsPath = "v1/models"

    private let session: URLSession

    public convenience init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.init(session: URLSession(configuration: configuration))
    }

    init(session: URLSession) {
        self.session = session
    }

    public func fetchModelIDs(endpoint: String, apiKey: String) async throws -> [String] {
        guard let url = EndpointResolver.endpointURL(baseURL: endpoint, path: Self.modelsPath) else {
            throw ModelCatalogError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Keyless local endpoints (Ollama, LM Studio) are first-class: only
        // send Authorization when a key is actually configured.
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.invalidHTTPResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data.prefix(4096), encoding: .utf8) ?? "<no body>"
            throw ModelCatalogError.httpFailure(http.statusCode, body)
        }

        return try Self.modelIDs(fromResponseData: data)
    }

    /// Parses the model id list out of a `/v1/models` response.
    ///
    /// Accepts the OpenAI schema `{"data": [{"id": "..."}]}` plus the looser
    /// shapes real servers ship: a bare top-level array, `{"models": [...]}`
    /// (Ollama native `/api/tags`), and entries keyed `name`/`model` instead
    /// of `id`. Ids are deduplicated and sorted case-insensitively.
    public static func modelIDs(fromResponseData data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw ModelCatalogError.malformedResponse
        }

        let entries: [Any]
        if let object = root as? [String: Any] {
            guard let array = (object["data"] ?? object["models"]) as? [Any] else {
                throw ModelCatalogError.malformedResponse
            }
            entries = array
        } else if let array = root as? [Any] {
            entries = array
        } else {
            throw ModelCatalogError.malformedResponse
        }

        var seen = Set<String>()
        var ids: [String] = []
        for entry in entries {
            let id: String?
            if let text = entry as? String {
                id = text
            } else if let object = entry as? [String: Any] {
                id = (object["id"] ?? object["name"] ?? object["model"]) as? String
            } else {
                id = nil
            }
            guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
