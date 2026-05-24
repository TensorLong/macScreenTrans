import Foundation

public struct SenseGroupDisplayResponse: Equatable, Sendable {
    public let source: String
    public let target: String
    public let wordPOS: String
    public let wordBrief: String

    public init(source: String, target: String, wordPOS: String = "", wordBrief: String = "") {
        self.source = source
        self.target = target
        self.wordPOS = wordPOS
        self.wordBrief = wordBrief
    }

    public var hasSource: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasTarget: Bool {
        !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasWordPOS: Bool {
        !wordPOS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasWordBrief: Bool {
        !wordBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum SenseGroupResponseRenderer {
    public static func response(for rawText: String) -> SenseGroupDisplayResponse? {
        let trimmed = stripMarkdownFence(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let source = firstString(
            in: object,
            keys: ["source_chunk", "chunk", "source", "source_text", "source_phrase", "phrase", "sense_group"]
        )
        let target = firstString(
            in: object,
            keys: ["target_chunk", "translation", "target", "translated_text", "target_text", "target_phrase", "translated", "meaning"]
        )
        let wordPOS = firstString(
            in: object,
            keys: ["word_pos", "pos", "part_of_speech"]
        )
        let wordBrief = firstString(
            in: object,
            keys: ["word_brief", "brief", "word_definition", "definition", "word_meaning"]
        )

        // Backward compat: a response is "valid" if it has the legacy phrase
        // pair. word_pos / word_brief are optional and never gate the result.
        guard !source.isEmpty || !target.isEmpty else {
            return nil
        }

        return SenseGroupDisplayResponse(
            source: source,
            target: target,
            wordPOS: wordPOS,
            wordBrief: wordBrief
        )
    }

    public static func displayText(for rawText: String) -> String {
        displayText(for: rawText, overrideWord: nil)
    }

    /// Render the popup text with an explicit word override. Use this when the
    /// caller knows the actual target word (from AXWordReader.selection.word)
    /// and wants to display it independently of what the LLM put in source_chunk.
    public static func displayText(for rawText: String, overrideWord: String?) -> String {
        guard let response = response(for: rawText) else {
            if isLikelyStructuredResponse(rawText) {
                return "正在识别意群..."
            }
            return rawText
        }

        let word = (overrideWord?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? response.source.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = []
        if !word.isEmpty {
            lines.append("单词: \(word)")
        }
        if response.hasWordPOS {
            lines.append("词性: \(response.wordPOS)")
        }
        if response.hasWordBrief {
            lines.append("释义: \(response.wordBrief)")
        }
        if response.hasSource {
            lines.append("意群: \(response.source)")
        }
        if response.hasSource && !response.hasTarget {
            lines.append("译文: 正在补译...")
        }
        if response.hasTarget {
            lines.append("译文: \(response.target)")
        }
        return lines.isEmpty ? "正在等待规范译文..." : lines.joined(separator: "\n")
    }

    public static func needsTranslationFallback(
        _ response: SenseGroupDisplayResponse,
        targetLanguage: String
    ) -> Bool {
        let source = response.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = response.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return true }

        if !source.isEmpty, source.compare(target, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }

        if targetLanguage.lowercased().hasPrefix("zh"),
           source.containsLatinLetter,
           !target.containsCJKCharacter {
            return true
        }

        return isPromptPlaceholder(target)
    }

    public static func plainTranslationText(for rawText: String) -> String {
        let trimmed = stripMarkdownFence(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        if let response = response(for: trimmed), response.hasTarget {
            return response.target
        }

        var text = trimmed
        if let data = trimmed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? String {
            text = value
        }

        for prefix in ["释义:", "译文:", "翻译:", "Translation:", "translation:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if text.count >= 2,
           ((text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'"))) {
            text = String(text.dropFirst().dropLast())
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isLikelyStructuredResponse(_ rawText: String) -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") ||
            trimmed.hasPrefix("```") ||
            trimmed.contains("\"source_chunk\"") ||
            trimmed.contains("\"target_chunk\"") ||
            trimmed.contains("\"translation\"") ||
            trimmed.contains("\"word_pos\"") ||
            trimmed.contains("\"word_brief\"")
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

    private static func isPromptPlaceholder(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "exact substring of the sentence" ||
            normalized == "smallest meaningful phrase" ||
            normalized == "target language" ||
            normalized == "..."
    }
}

private extension String {
    var containsCJKCharacter: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    var containsLatinLetter: Bool {
        range(of: "[A-Za-z]", options: .regularExpression) != nil
    }
}
