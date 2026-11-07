import AppKit
import ServiceManagement
import TezeuCore

@MainActor
@Observable
final class AppState {
    /// En dessous de cette durée, l'appui est ignoré (relâché trop vite).
    static let minimumSeconds = 0.5
    /// Volume moyen (RMS) sous lequel on considère l'enregistrement comme du silence.
    /// ponytail: seuil fixe (~ -50 dBFS) ; à rendre réglable si un micro très faible est rejeté.
    static let silenceRMS: Float = 0.003
    /// Durée maximale d'une écoute : évite de laisser le micro ouvert par oubli (mode double appui).
    static let maximumSeconds = 300.0
    /// Nombre de dictées gardées dans l'historique (en mémoire seulement).
    static let historyLimit = 50

    let permissions = Permissions()
    /// État de travail (écoute, transcription…). Les problèmes d'autorisation passent avant.
    var activity: AppStatus = .ready {
        didSet { pill.update(activity == .listening || activity == .transcribing ? self : nil) }
    }
    /// Niveau sonore du micro pendant l'écoute, pour la pastille.
    private(set) var level: Float = 0
    /// Écoute lancée par double appui : elle continue sans tenir la touche.
    private(set) var handsFree = false
    /// Dernières dictées, les plus récentes en premier. En mémoire seulement : effacées à la fermeture.
    var history: [HistoryEntry] = []
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
    /// UID du micro choisi, ou nil pour le micro par défaut du Mac.
    var microphone: String? {
        didSet { UserDefaults.standard.set(microphone, forKey: "microphone") }
    }
    var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "sounds") }
    }
    var showPill: Bool {
        didSet { UserDefaults.standard.set(showPill, forKey: "pill") }
    }
    /// Mots à mieux reconnaître, séparés par des virgules ou des retours à la ligne.
    var vocabulary: String {
        didSet { UserDefaults.standard.set(vocabulary, forKey: "vocabulary") }
    }
    /// Remplacements après la transcription, un par ligne : « mot = remplacement ».
    var replacements: String {
        didSet { UserDefaults.standard.set(replacements, forKey: "replacements") }
    }
    /// Identifiants des modèles présents sur le disque.
    private(set) var installedModels: Set<String> = []
    private(set) var downloadProgress: Double?
    private(set) var downloadError: String?
    /// Lancement à l'ouverture de session (Réglages > Général > Ouverture).
    private(set) var launchAtLogin = false
    private(set) var launchAtLoginNote: String?

    @ObservationIgnored private var monitor: HotKeyMonitor?
    @ObservationIgnored private let recorder = Recorder()
    @ObservationIgnored private let pill = ListeningPill()
    // Partagé avec AppDelegate, qui le libère avant de quitter.
    static let transcriber = Transcriber()

    var status: AppStatus {
        if let problem = permissions.problem { return .error(problem) }
        if !installedModels.contains(model.id) { return .error(L("Modèle vocal à télécharger")) }
        return activity
    }

    init() {
        let defaults = UserDefaults.standard
        let savedKey = defaults.string(forKey: "hotKey").flatMap(HotKey.init(rawValue:)) ?? .rightOption
        hotKey = savedKey
        language = defaults.string(forKey: "language").flatMap(Language.init(rawValue:)) ?? .systemDefault
        model = WhisperModel.all.first { $0.id == defaults.string(forKey: "model") } ?? .default
        microphone = defaults.string(forKey: "microphone")
        soundsEnabled = defaults.object(forKey: "sounds") as? Bool ?? true
        showPill = defaults.object(forKey: "pill") as? Bool ?? true
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        replacements = defaults.string(forKey: "replacements") ?? ""
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
        monitor.onAction = { [weak self] action in self?.handle(action) }
        self.monitor = monitor
        // Premier lancement, ou autorisation perdue : on ouvre la fenêtre pour guider.
        if case .error = status { MainWindow.shared.show(state: self) }
    }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        if status == .requiresApproval {
            launchAtLoginNote = L("À autoriser dans Réglages Système > Général > Ouverture.")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginNote = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginNote = error.localizedDescription
        }
        refreshLaunchAtLogin()
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
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

    private func handle(_ action: DictationGesture.Action) {
        switch action {
        case .none: break
        case .start: startListening()
        case .stop: finishListening(cancel: nil)
        case .cancel(let reason): finishListening(cancel: reason)
        }
    }

    private func startListening() {
        // Une erreur de dictée précédente n'empêche pas de réessayer ; un problème d'autorisation ou de modèle, si.
        guard permissions.problem == nil, installedModels.contains(model.id),
              activity != .listening, activity != .transcribing else {
            monitor?.reset()
            return
        }
        do {
            try recorder.start(deviceID: microphone)
        } catch {
            monitor?.reset()
            activity = .error(L("Micro indisponible"))
            return
        }
        handsFree = monitor?.isHandsFree ?? false
        level = 0
        activity = .listening
        if soundsEnabled { NSSound(named: "Tink")?.play() }

        // Niveau du micro pour la pastille, et arrêt automatique au bout de la durée maximale.
        Task { [weak self] in
            let started = Date()
            while let self, self.activity == .listening {
                self.level = self.recorder.level
                if Date().timeIntervalSince(started) > Self.maximumSeconds {
                    self.monitor?.reset()
                    self.finishListening(cancel: nil)
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func finishListening(cancel: DictationGesture.Cancel?) {
        guard activity == .listening else { return }
        var samples = recorder.stop()
        let seconds = Double(samples.count) / Transcriber.sampleRate
        let rms = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()

        if cancel != nil || seconds < Self.minimumSeconds || rms < Self.silenceRMS {
            samples.removeAll() // rien à transcrire : l'audio est effacé tout de suite
            activity = .ready
            lastResult = switch cancel {
            case .tap: L("Appui bref. Pour dicter sans tenir la touche, appuie deux fois.")
            case .otherKey: L("Annulé : une autre touche a été pressée")
            case .escape: L("Annulé avec Échap")
            case nil: seconds < Self.minimumSeconds ? L("Trop court, ignoré") : L("Rien entendu (silence)")
            }
            return
        }

        if soundsEnabled { NSSound(named: "Pop")?.play() }
        activity = .transcribing
        let model = model, language = language
        let prompt = Vocabulary.prompt(words: vocabulary), rules = Vocabulary.replacements(replacements)
        Task {
            do {
                let raw = try await Self.transcriber.transcribe(samples, modelURL: model.localURL, language: language, prompt: prompt)
                samples.removeAll() // l'audio n'est plus nécessaire
                let text = Vocabulary.apply(rules, to: raw).trimmingCharacters(in: .whitespacesAndNewlines)
                lastTranscript = text
                guard !text.isEmpty else {
                    lastResult = L("Rien reconnu")
                    activity = .ready
                    return
                }
                let outcome = await Paster.paste(text)
                history.insert(HistoryEntry(text: text, pasted: outcome == .pasted), at: 0)
                history = Array(history.prefix(Self.historyLimit))
                switch outcome {
                case .pasted:
                    lastResult = L("Collé (%.1f s d'audio)", seconds)
                    activity = .ready
                case .keptInClipboard(let reason):
                    // L'icône passe en erreur pour que l'échec se voie sans ouvrir le panneau.
                    lastResult = L("%@. Texte gardé dans le presse-papiers : colle-le avec ⌘V.", reason)
                    activity = .error(L("Collage impossible"))
                }
            } catch {
                samples.removeAll()
                activity = .error(error.localizedDescription)
            }
        }
    }
}

/// Une dictée de l'historique.
struct HistoryEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    /// Faux si le texte n'a pas pu être collé (gardé dans le presse-papiers).
    let pasted: Bool
}
