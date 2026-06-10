import Foundation

public enum ChatCompletionStreamParser {
    public static func contentDelta(fromSSELine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }

        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }

        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first,
            let delta = first["delta"] as? [String: Any],
            let content = delta["content"] as? String,
            !content.isEmpty
        else {
            return nil
        }

        return content
    }

    /// OpenAI-compatible servers (LiteLLM, vLLM, some Ollama failure modes)
    /// can answer HTTP 200 and then deliver the failure as an in-stream
    /// `{"error": ...}` payload — either as an SSE `data:` chunk or as a bare
    /// JSON line. Surface the message so the client can throw instead of
    /// silently ending an empty stream that the UI misreports as
    /// "模型没有返回内容".
    public static func errorMessage(fromSSELine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: String
        if trimmed.hasPrefix("data:") {
            payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.hasPrefix("{") {
            payload = trimmed
        } else {
            return nil
        }
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"]
        else {
            return nil
        }

        if let message = error as? String, !message.isEmpty {
            return message
        }
        if let dictionary = error as? [String: Any] {
            if let message = dictionary["message"] as? String, !message.isEmpty {
                return message
            }
            return String(describing: dictionary)
        }
        return "server returned an error payload"
    }
}
