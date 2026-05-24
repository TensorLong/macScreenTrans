import Foundation

public enum SenseGroupResponseRenderer {
    public static func displayText(for rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return rawText
        }

        let source = (object["source_chunk"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = (object["target_chunk"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !source.isEmpty || !target.isEmpty else {
            return rawText
        }

        var lines: [String] = []
        if !source.isEmpty {
            lines.append("意群: \(source)")
        }
        if !target.isEmpty {
            lines.append("释义: \(target)")
        }
        return lines.joined(separator: "\n")
    }
}
