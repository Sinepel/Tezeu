import Foundation

/// Commandes vocales simples : « à la ligne », « virgule », « point d'interrogation »…
/// Ce sont des remplacements fixes, sans IA. Français et anglais seulement.
public enum VoiceCommands {
    private enum Output {
        case punctuation(String)
        case newline(String)
    }

    private static let french: [(String, Output)] = [
        ("nouveau paragraphe", .newline("\n\n")),
        ("à la ligne", .newline("\n")),
        ("nouvelle ligne", .newline("\n")),
        ("point d'interrogation", .punctuation("?")),
        ("point d’interrogation", .punctuation("?")),
        ("point d'exclamation", .punctuation("!")),
        ("point d’exclamation", .punctuation("!")),
        ("points de suspension", .punctuation("…")),
        ("point final", .punctuation(".")),
        ("point-virgule", .punctuation(";")),
        ("point virgule", .punctuation(";")),
        ("deux-points", .punctuation(":")),
        ("deux points", .punctuation(":")),
        ("virgule", .punctuation(",")),
    ]

    private static let english: [(String, Output)] = [
        ("new paragraph", .newline("\n\n")),
        ("new line", .newline("\n")),
        ("question mark", .punctuation("?")),
        ("exclamation mark", .punctuation("!")),
        ("exclamation point", .punctuation("!")),
        ("full stop", .punctuation(".")),
        ("semicolon", .punctuation(";")),
        ("colon", .punctuation(":")),
        ("comma", .punctuation(",")),
    ]

    /// Langues dont les commandes sont connues.
    public static func isSupported(_ language: Language) -> Bool {
        language == .french || language == .english
    }

    public static func apply(_ text: String, language: Language) -> String {
        let commands = language == .french ? french : language == .english ? english : []
        guard !commands.isEmpty else { return text }

        // 1. Chaque commande devient un repère \u{1}n\u{1}. On enlève aussi la ponctuation
        //    et les espaces que le modèle a mis autour (« Bonjour, virgule, ça va. »).
        var marked = text
        for (index, command) in commands.enumerated() {
            let phrase = NSRegularExpression.escapedPattern(for: command.0)
            let pattern = "[\\s,.;:]*(?<![\\p{L}\\p{N}])" + phrase + "(?![\\p{L}\\p{N}])[\\s,.;:]*"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            marked = regex.stringByReplacingMatches(
                in: marked, range: NSRange(marked.startIndex..., in: marked), withTemplate: "\u{1}\(index)\u{1}")
        }
        guard marked != text else { return text }

        // 2. Les repères sont remplacés par leur signe, avec les bons espaces.
        let parts = marked.components(separatedBy: "\u{1}")
        var result = parts[0]
        var capitalizeNext = false
        for i in stride(from: 1, to: parts.count, by: 2) {
            guard let index = Int(parts[i]) else { continue }
            var next = i + 1 < parts.count ? parts[i + 1] : ""
            while result.last?.isWhitespace == true && result.last?.isNewline == false { result.removeLast() }
            switch commands[index].1 {
            case .newline(let breaks):
                result += breaks
                next = String(next.drop { $0 == " " })
                capitalizeNext = true
            case .punctuation(let sign):
                // En français, espace insécable avant ? ! : ;
                if language == .french, "?!:;".contains(sign), !result.isEmpty, result.last?.isNewline == false {
                    result += "\u{00A0}"
                }
                result += sign
                next = String(next.drop { $0 == " " })
                if !next.isEmpty { result += " " }
                capitalizeNext = ".?!…".contains(sign)
            }
            if capitalizeNext, let first = next.first {
                next = first.uppercased() + next.dropFirst()
            }
            result += next
        }
        return result
    }
}

/// Ajuste le début du texte dicté selon ce qui est écrit juste avant le curseur :
/// espace si on colle derrière un mot, majuscule en début de phrase, minuscule au milieu d'une phrase.
public enum AutoSpacing {
    /// `before` : texte avant le curseur (nil si l'app ne le donne pas : rien n'est changé).
    /// `keepCase` : mots à ne jamais mettre en minuscule (noms propres du vocabulaire).
    public static func fit(_ text: String, after before: String?, keepCase: Set<String> = []) -> String {
        guard let before, let first = text.first else { return text }
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        var result = text

        if trimmed.isEmpty || trimmed.last.map({ ".?!…\n".contains($0) }) == true {
            result = first.uppercased() + text.dropFirst()
        } else if first.isUppercase {
            // Au milieu d'une phrase. On garde la majuscule pour un sigle (« USA ») ou un mot du vocabulaire.
            let word = String(text.prefix { $0.isLetter })
            let isAcronym = word.count > 1 && word.allSatisfy(\.isUppercase)
            let isKept = keepCase.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
            if !isAcronym && !isKept && word != "I" {
                result = first.lowercased() + text.dropFirst()
            }
        }

        if let last = before.last, !last.isWhitespace, !"([{«\"'’/-".contains(last),
           let start = result.first, !",.;:!?)]}»…".contains(start) {
            result = " " + result
        }
        return result
    }
}
