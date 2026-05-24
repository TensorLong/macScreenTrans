import Foundation

public struct SenseGroupDisplayResponse: Equatable, Sendable {
    public let source: String
    public let target: String

    public var hasSource: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasTarget: Bool {
        !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum SenseGroupResponseRenderer {
    public static func response(for rawText: String) -> SenseGroupDisplayResponse? {
        let trimmed = stripMarkdownFence(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let source = firstString(in: object, keys: ["source_chunk", "chunk", "source", "source_text"])
        let target = firstString(in: object, keys: ["target_chunk", "translation", "target", "translated_text"])

        guard !source.isEmpty || !target.isEmpty else {
            return nil
        }

        return SenseGroupDisplayResponse(source: source, target: target)
    }

    public static func displayText(for rawText: String) -> String {
        guard let response = response(for: rawText) else {
            return rawText
        }

        var lines: [String] = []
        if response.hasSource {
            lines.append("意群: \(response.source)")
        }
        if response.hasTarget {
            lines.append("释义: \(response.target)")
        }
        return lines.joined(separator: "\n")
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return ""
    }

    private static func stripMarkdownFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return trimmed }
        _ = lines.removeFirst()
        guard lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" else {
            return trimmed
        }
        _ = lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
