/// Reconnaît les deux façons de dicter avec la même touche :
/// - maintenir : l'écoute dure tant que la touche est enfoncée ;
/// - double appui : deux appuis brefs lancent l'écoute, un appui de plus l'arrête.
/// Logique pure (l'heure est passée en paramètre, en secondes) pour être testée par SelfCheck.
public struct DictationGesture {
    public enum Action: Equatable {
        case none, start, stop
        case cancel(Cancel)
    }

    public enum Cancel: Equatable {
        /// Appui bref : peut-être le premier d'un double appui.
        case tap
        /// Autre touche pressée pendant l'appui (un raccourci clavier).
        case otherKey
        case escape
    }

    /// Durée maximale d'un appui « bref ».
    public static let tapMax = 0.3
    /// Délai maximal entre la fin du premier appui bref et le second appui.
    public static let doubleTapWindow = 0.4

    private enum Phase {
        case idle
        case holding(since: Double)
        /// Second appui d'un double appui, touche encore enfoncée.
        case secondPress(since: Double)
        case handsFree
        /// Appui qui arrête l'écoute mains libres : on attend son relâchement.
        case stopping
    }

    private var phase = Phase.idle
    private var lastTapEnd: Double?

    public init() {}

    /// Vrai pendant une écoute lancée par double appui.
    public var isHandsFree: Bool {
        switch phase {
        case .secondPress, .handsFree: true
        default: false
        }
    }

    public mutating func press(at time: Double) -> Action {
        switch phase {
        case .idle:
            if let end = lastTapEnd, time - end <= Self.doubleTapWindow {
                lastTapEnd = nil
                phase = .secondPress(since: time)
            } else {
                phase = .holding(since: time)
            }
            return .start
        case .handsFree:
            phase = .stopping
            return .stop
        default:
            return .none
        }
    }

    public mutating func release(at time: Double, otherKey: Bool) -> Action {
        switch phase {
        case .holding(let since):
            phase = .idle
            if otherKey { return .cancel(.otherKey) }
            if time - since < Self.tapMax {
                lastTapEnd = time
                return .cancel(.tap)
            }
            return .stop
        case .secondPress(let since):
            if otherKey {
                phase = .idle
                return .cancel(.otherKey)
            }
            // Second appui bref : l'écoute continue sans tenir la touche.
            // Second appui long : on le traite comme un appui maintenu.
            if time - since <= Self.tapMax {
                phase = .handsFree
                return .none
            }
            phase = .idle
            return .stop
        case .stopping:
            phase = .idle
            return .none
        case .idle, .handsFree:
            return .none
        }
    }

    public mutating func escape() -> Action {
        lastTapEnd = nil
        switch phase {
        case .holding, .secondPress, .handsFree:
            phase = .idle
            return .cancel(.escape)
        case .idle, .stopping:
            return .none
        }
    }

    /// Oublie l'appui en cours (ex. écoute arrêtée au bout de la durée maximale).
    /// Le relâchement qui suit éventuellement sera ignoré.
    public mutating func reset() {
        phase = .idle
        lastTapEnd = nil
    }
}
