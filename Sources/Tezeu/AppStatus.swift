/// État affiché par l'icône de la barre de menus.
enum AppStatus: Equatable {
    case ready
    case listening
    case transcribing
    case error(String)

    var symbol: String {
        switch self {
        case .ready: "mic"
        case .listening: "waveform"
        case .transcribing: "ellipsis.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var label: String {
        switch self {
        case .ready: "Prêt"
        case .listening: "Écoute…"
        case .transcribing: "Transcription…"
        case .error(let message): message
        }
    }
}
