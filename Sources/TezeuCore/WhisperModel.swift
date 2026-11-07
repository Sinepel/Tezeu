import Foundation

/// Modèles vocaux proposés. Source : dépôt Hugging Face ggerganov/whisper.cpp (licence MIT),
/// figé sur un commit précis. L'empreinte SHA-256 de chaque fichier est vérifiée après téléchargement.
public struct WhisperModel: Identifiable, Hashable, Sendable {
    public let id: String // nom du fichier
    public let label: String
    public let bytes: Int64
    public let sha256: String

    public static let all = [
        WhisperModel(id: "ggml-large-v3-turbo-q5_0.bin", label: L("Équilibré (large-v3-turbo)"), bytes: 574_041_195,
                     sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
        WhisperModel(id: "ggml-small-q5_1.bin", label: L("Léger (small)"), bytes: 190_085_487,
                     sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"),
        WhisperModel(id: "ggml-base-q5_1.bin", label: L("Très léger (base)"), bytes: 59_707_625,
                     sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"),
    ]
    public static let `default` = all[0]

    public static let sourceLabel = "huggingface.co/ggerganov/whisper.cpp"
    private static let commit = "5359861c739e955e79d9a303bcbc70fb988958b1"

    public static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Tezeu/Models", directoryHint: .isDirectory)
    }

    public var remoteURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(Self.commit)/\(id)")!
    }
    public var localURL: URL { Self.directory.appending(path: id) }
    public var partURL: URL { Self.directory.appending(path: id + ".part") }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: localURL.path) }
    public var sizeLabel: String { bytes.formatted(.byteCount(style: .file)) }
}

/// Langues de dictée proposées. Les modèles sont multilingues : en ajouter une = ajouter son code ISO 639-1.
public enum Language: String, CaseIterable, Identifiable, Sendable {
    case french = "fr"
    case english = "en"
    case spanish = "es"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case auto = "auto"

    public var id: String { rawValue }

    /// Nom de la langue dans la langue du Mac (fourni par macOS).
    public var label: String {
        if self == .auto { return L("Détection automatique") }
        let name = Locale.current.localizedString(forLanguageCode: rawValue) ?? rawValue
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Langue du Mac si elle est proposée, sinon détection automatique.
    public static var systemDefault: Language {
        Locale.current.language.languageCode.flatMap { Language(rawValue: $0.identifier) } ?? .auto
    }
}
