import TezeuCore
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
        case .ready: L("Prêt")
        case .listening: L("Écoute…")
        case .transcribing: L("Transcription…")
        case .error(let message): message
        }
    }
}
