import Foundation

/// Vocabulaire personnel : mots à mieux reconnaître, et remplacements après la transcription.
public enum Vocabulary {
    /// Texte donné au modèle avant l'audio, pour l'orienter vers ces mots (noms propres, jargon).
    /// Les mots sont séparés par des virgules ou des retours à la ligne. Nil si la liste est vide.
    public static func prompt(words: String) -> String? {
        let list = Self.words(words)
        return list.isEmpty ? nil : list.joined(separator: ", ") + "."
    }

    /// Les mots de la liste, séparés par des virgules ou des retours à la ligne.
    public static func words(_ text: String) -> [String] {
        text.split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public struct Replacement: Equatable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// Une règle par ligne : « mot = remplacement ». Les lignes sans « = » ou sans mot sont ignorées.
    public static func replacements(_ text: String) -> [Replacement] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let sign = line.firstIndex(of: "=") else { return nil }
            let from = line[..<sign].trimmingCharacters(in: .whitespaces)
            let to = line[line.index(after: sign)...].trimmingCharacters(in: .whitespaces)
            return from.isEmpty ? nil : Replacement(from: from, to: to)
        }
    }

    /// Remplace les mots entiers (pas à l'intérieur d'un autre mot), sans tenir compte des majuscules.
    public static func apply(_ rules: [Replacement], to text: String) -> String {
        var result = text
        for rule in rules {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: rule.from) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.to))
        }
        return result
    }
}
