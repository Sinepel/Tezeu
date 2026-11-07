import AppKit
import TezeuCore

@MainActor
@Observable
final class AppState {
    /// En dessous de cette durée, l'appui est ignoré (relâché trop vite).
    static let minimumSeconds = 0.5
    /// Volume moyen (RMS) sous lequel on considère l'enregistrement comme du silence.
    /// ponytail: seuil fixe (~ -50 dBFS) ; à rendre réglable si un micro très faible est rejeté.
    static let silenceRMS: Float = 0.003

    let permissions = Permissions()
    /// État de travail (écoute, transcription…). Les problèmes d'autorisation passent avant.
    var activity: AppStatus = .ready
    /// Résumé du dernier appui.
    var lastResult: String?
    /// Dernier texte transcrit, gardé en mémoire seulement, pour l'afficher dans le panneau.
    var lastTranscript: String?

    var hotKey: HotKey {
        didSet {
            UserDefaults.standard.set(hotKey.rawValue, forKey: "hotKey")
            monitor?.key = hotKey
        }
    }
    var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }
    var model: WhisperModel {
        didSet { UserDefaults.standard.set(model.id, forKey: "model") }
    }
    /// Identifiants des modèles présents sur le disque.
    private(set) var installedModels: Set<String> = []
    private(set) var downloadProgress: Double?
    private(set) var downloadError: String?

    @ObservationIgnored private var monitor: HotKeyMonitor?
    @ObservationIgnored private let recorder = Recorder()
    // Partagé avec AppDelegate, qui le libère avant de quitter.
    static let transcriber = Transcriber()

    var status: AppStatus {
        if let problem = permissions.problem { return .error(problem) }
        if !installedModels.contains(model.id) { return .error("Modèle vocal à télécharger") }
        return activity
    }

    init() {
        let defaults = UserDefaults.standard
        let savedKey = defaults.string(forKey: "hotKey").flatMap(HotKey.init(rawValue:)) ?? .rightOption
        hotKey = savedKey
        language = defaults.string(forKey: "language").flatMap(Language.init(rawValue:)) ?? .french
        model = WhisperModel.all.first { $0.id == defaults.string(forKey: "model") } ?? .default
        refreshInstalledModels()

        // La détection de touche doit démarrer APRÈS le lancement de l'app : installée plus tôt
        // (pendant l'init de SwiftUI), elle empêche le panneau de recevoir les clics.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.startMonitoring() }
        }

        // macOS ne prévient pas quand une autorisation change : on relit toutes les 2 s.
        Task { [weak self] in
            while let self {
                self.permissions.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func startMonitoring() {
        let monitor = HotKeyMonitor(key: hotKey)
        monitor.onPress = { [weak self] in self?.keyPressed() }
        monitor.onRelease = { [weak self] cancelled in self?.keyReleased(cancelled: cancelled) }
        self.monitor = monitor
    }

    /// Libère whisper.cpp puis ferme l'app (sinon whisper plante à la fermeture).
    func quit() {
        Task {
            await Self.transcriber.unload()
            AppDelegate.whisperReleased = true
            NSApplication.shared.terminate(nil)
        }
    }

    func downloadModel() {
        guard downloadProgress == nil else { return }
        let model = model
        downloadProgress = 0
        downloadError = nil
        Task {
            do {
                try await ModelDownloader.install(model) { progress in
                    Task { @MainActor in
                        if self.downloadProgress != nil { self.downloadProgress = progress }
                    }
                }
            } catch {
                downloadError = error.localizedDescription
            }
            downloadProgress = nil
            refreshInstalledModels()
        }
    }

    private func refreshInstalledModels() {
        installedModels = Set(WhisperModel.all.filter(\.isInstalled).map(\.id))
    }

    private func keyPressed() {
        // Une erreur de dictée précédente n'empêche pas de réessayer ; un problème d'autorisation ou de modèle, si.
        guard permissions.problem == nil, installedModels.contains(model.id),
              activity != .listening, activity != .transcribing else { return }
        do {
            try recorder.start()
            activity = .listening
        } catch {
            activity = .error("Micro indisponible")
        }
    }

    private func keyReleased(cancelled: Bool) {
        guard activity == .listening else { return }
        var samples = recorder.stop()
        let seconds = Double(samples.count) / Transcriber.sampleRate
        let rms = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()

        if cancelled || seconds < Self.minimumSeconds || rms < Self.silenceRMS {
            samples.removeAll() // rien à transcrire : l'audio est effacé tout de suite
            activity = .ready
            lastResult = cancelled ? "Annulé : une autre touche a été pressée"
                : seconds < Self.minimumSeconds ? "Trop court, ignoré"
                : "Rien entendu (silence)"
            return
        }

        activity = .transcribing
        let model = model, language = language
        Task {
            do {
                let text = try await Self.transcriber.transcribe(samples, modelURL: model.localURL, language: language)
                samples.removeAll() // l'audio n'est plus nécessaire
                lastTranscript = text
                guard !text.isEmpty else {
                    lastResult = "Rien reconnu"
                    activity = .ready
                    return
                }
                switch await Paster.paste(text) {
                case .pasted:
                    lastResult = String(format: "Collé (%.1f s d'audio)", seconds)
                    activity = .ready
                case .keptInClipboard(let reason):
                    // L'icône passe en erreur pour que l'échec se voie sans ouvrir le panneau.
                    lastResult = "\(reason). Texte gardé dans le presse-papiers : colle-le avec ⌘V."
                    activity = .error("Collage impossible")
                }
            } catch {
                samples.removeAll()
                activity = .error(error.localizedDescription)
            }
        }
    }
}
