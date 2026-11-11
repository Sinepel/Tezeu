import Foundation

/// Phrases que Whisper invente souvent sur du silence ou du bruit (il a appris sur des vidéos sous-titrées).
public enum Hallucinations {
    /// Mentions de sous-titres : enlevées où qu'elles soient.
    private static let credits = [
        "sous-titres réalisés par la communauté d'amara.org",
        "sous-titres réalisés par",
        "sous-titrage st' 501",
        "sous-titrage st'501",
        "sous-titrage société radio-canada",
        "subtitles by the amara.org community",
        "amara.org",
    ]

    /// Phrases enlevées seulement si c'est tout le texte (sinon, ça peut être une vraie dictée).
    private static let wholeOnly: Set<String> = [
        "merci d'avoir regardé",
        "merci d'avoir regardé cette vidéo",
        "merci d'avoir regardé cette vidéo et à bientôt",
        "n'oubliez pas de vous abonner",
        "abonnez-vous",
        "thank you for watching",
        "thanks for watching",
        "please subscribe",
    ]

    public static func clean(_ text: String) -> String {
        var result = text
        for credit in credits {
            let pattern = "[^.!?\\n]*" + NSRegularExpression.escapedPattern(for: credit) + "[^.!?\\n]*[.!?]*"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        let key = result.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).subtracting(["'", "-"]))
        // Que de la ponctuation (« ... ») ou une phrase inventée connue : rien à coller.
        if wholeOnly.contains(key) || !result.contains(where: { $0.isLetter || $0.isNumber }) { return "" }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Enlève le silence au début et à la fin d'un enregistrement.
public enum SilenceTrim {
    /// `threshold` : volume (RMS) sous lequel un bloc de 20 ms compte comme silence.
    /// Garde 0,25 s de marge de chaque côté pour ne pas couper le début ou la fin d'un mot.
    public static func trim(_ samples: [Float], threshold: Float, sampleRate: Double) -> [Float] {
        let window = max(1, Int(sampleRate * 0.02))
        let margin = Int(sampleRate * 0.25)
        func loud(_ start: Int) -> Bool {
            let block = samples[start..<min(start + window, samples.count)]
            return (block.reduce(0) { $0 + $1 * $1 } / Float(block.count)).squareRoot() >= threshold
        }
        let starts = Array(stride(from: 0, to: samples.count, by: window))
        guard let first = starts.first(where: loud), let last = starts.last(where: loud) else { return samples }
        return Array(samples[max(0, first - margin)..<min(samples.count, last + window + margin)])
    }
}
