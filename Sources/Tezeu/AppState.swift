import AppKit
import ServiceManagement
import TezeuCore

@MainActor
@Observable
final class AppState {
    /// En dessous de cette durée, l'appui est ignoré (relâché trop vite).
    static let minimumSeconds = 0.5
    /// Durée maximale d'une écoute : évite de laisser le micro ouvert par oubli (mode double appui).
    static let maximumSeconds = 300.0
    /// Nombre de dictées gardées dans l'historique (en mémoire seulement).
    static let historyLimit = 50

    let permissions = Permissions()
    /// État de travail (écoute, transcription…). Les problèmes d'autorisation passent avant.
    var activity: AppStatus = .ready {
        didSet {
            pill.update(activity == .listening || activity == .transcribing ? self : nil)
            if case .error(let message) = activity, activity != oldValue { Self.announce(message) }
        }
    }
    /// Niveau sonore du micro pendant l'écoute, pour la pastille.
    private(set) var level: Float = 0
    /// Écoute lancée par double appui : elle continue sans tenir la touche.
    private(set) var handsFree = false
    /// Dernières dictées, les plus récentes en premier. En mémoire seulement : effacées à la fermeture.
    var history: [HistoryEntry] = []
    /// Résumé du dernier appui.
    var lastResult: String? {
        didSet { if let lastResult { Self.announce(lastResult) } }
    }
    /// Dernier texte transcrit, gardé en mémoire seulement, pour l'afficher dans le panneau.
    var lastTranscript: String?
    /// Test du micro en cours (réglages) : le niveau s'affiche, rien n'est transcrit.
    private(set) var micTesting = false
    /// Transcription d'un fichier audio (onglet Fichier). Le texte reste en mémoire seulement.
    private(set) var fileName: String?
    var fileText = ""
    /// Cadre d'essai de l'assistant de premier lancement.
    var tryText = ""
    private(set) var fileBusy = false
    private(set) var fileError: String?

    var hotKey: HotKey {
        didSet {
            UserDefaults.standard.set(hotKey.rawValue, forKey: "hotKey")
            monitor?.key = hotKey
        }
    }
    var toggleShortcut: Shortcut {
        didSet {
            UserDefaults.standard.set(toggleShortcut.rawValue, forKey: "toggleShortcut")
            shortcutAvailable = monitor?.register(toggleShortcut, for: .toggle) ?? true
        }
    }
    /// Faux si une autre app utilise déjà le raccourci mains libres.
    private(set) var shortcutAvailable = true
    var pasteAgainShortcut: Shortcut {
        didSet {
            UserDefaults.standard.set(pasteAgainShortcut.rawValue, forKey: "pasteAgainShortcut")
            pasteAgainAvailable = monitor?.register(pasteAgainShortcut, for: .pasteAgain) ?? true
        }
    }
    /// Faux si une autre app utilise déjà le raccourci pour recoller.
    private(set) var pasteAgainAvailable = true
    var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }
    /// Langue par app : identifiant de l'app (ex. com.apple.Terminal) → langue.
    /// Prioritaire sur `language` quand cette app est au premier plan au début de la dictée.
    var appLanguages: [String: Language] {
        didSet { UserDefaults.standard.set(appLanguages.mapValues(\.rawValue), forKey: "appLanguages") }
    }
    /// Langue de la dictée en cours (celle de l'app au premier plan au début de l'écoute).
    @ObservationIgnored private var listeningLanguage: Language?
    var model: WhisperModel {
        didSet {
            UserDefaults.standard.set(model.id, forKey: "model")
            preloadIfNeeded()
        }
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
    /// Commandes vocales : « à la ligne », « virgule »… (français et anglais).
    var voiceCommands: Bool {
        didSet { UserDefaults.standard.set(voiceCommands, forKey: "voiceCommands") }
    }
    /// Espace et majuscule selon le texte avant le curseur.
    var autoSpacing: Bool {
        didSet { UserDefaults.standard.set(autoSpacing, forKey: "autoSpacing") }
    }
    var insertMethod: InsertMethod {
        didSet { UserDefaults.standard.set(insertMethod.rawValue, forKey: "insertMethod") }
    }
    /// Secondes avant de remettre l'ancien presse-papiers (collage).
    var restoreDelay: Double {
        didSet { UserDefaults.standard.set(restoreDelay, forKey: "restoreDelay") }
    }
    /// Volume (en dB) sous lequel l'enregistrement est considéré comme du silence.
    var silenceDB: Double {
        didSet { UserDefaults.standard.set(silenceDB, forKey: "silenceDB") }
    }
    /// Charger le modèle dès le lancement, pour que la première dictée soit rapide.
    var preloadModel: Bool {
        didSet {
            UserDefaults.standard.set(preloadModel, forKey: "preloadModel")
            preloadIfNeeded()
        }
    }
    /// Pastille réduite aux barres de niveau, sans texte.
    var compactPill: Bool {
        didSet { UserDefaults.standard.set(compactPill, forKey: "compactPill") }
    }
    /// Mode debug : un onglet Diagnostic montre ce qui s'est passé à chaque dictée.
    /// Gardé en mémoire seulement (jamais écrit sur le disque), effacé quand l'app quitte.
    var debugMode: Bool {
        didSet {
            UserDefaults.standard.set(debugMode, forKey: "debugMode")
            if !debugMode { diagnostics = [] }
        }
    }
    private(set) var diagnostics: [Diagnostic] = []
    /// App au premier plan au début de l'écoute (identifiant seulement).
    @ObservationIgnored private var listeningApp: String?
    /// Assistant de premier lancement terminé.
    var onboardingDone: Bool {
        didSet { UserDefaults.standard.set(onboardingDone, forKey: "onboardingDone") }
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
        toggleShortcut = defaults.string(forKey: "toggleShortcut").flatMap(Shortcut.init(rawValue:)) ?? .controlOptionSpace
        pasteAgainShortcut = defaults.string(forKey: "pasteAgainShortcut").flatMap(Shortcut.init(rawValue:)) ?? .controlOptionV
        language = defaults.string(forKey: "language").flatMap(Language.init(rawValue:)) ?? .systemDefault
        appLanguages = (defaults.dictionary(forKey: "appLanguages") as? [String: String] ?? [:])
            .compactMapValues(Language.init(rawValue:))
        model = WhisperModel.all.first { $0.id == defaults.string(forKey: "model") } ?? .default
        microphone = defaults.string(forKey: "microphone")
        soundsEnabled = defaults.object(forKey: "sounds") as? Bool ?? true
        showPill = defaults.object(forKey: "pill") as? Bool ?? true
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        replacements = defaults.string(forKey: "replacements") ?? ""
        voiceCommands = defaults.object(forKey: "voiceCommands") as? Bool ?? true
        autoSpacing = defaults.object(forKey: "autoSpacing") as? Bool ?? true
        insertMethod = defaults.string(forKey: "insertMethod").flatMap(InsertMethod.init(rawValue:)) ?? .paste
        restoreDelay = defaults.object(forKey: "restoreDelay") as? Double ?? 0.4
        silenceDB = defaults.object(forKey: "silenceDB") as? Double ?? -50
        preloadModel = defaults.object(forKey: "preloadModel") as? Bool ?? true
        compactPill = defaults.object(forKey: "compactPill") as? Bool ?? false
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        debugMode = defaults.bool(forKey: "debugMode")
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
        monitor.onPasteAgain = { [weak self] in self?.pasteAgain() }
        shortcutAvailable = monitor.register(toggleShortcut, for: .toggle)
        pasteAgainAvailable = monitor.register(pasteAgainShortcut, for: .pasteAgain)
        self.monitor = monitor
        // Premier lancement, ou autorisation perdue : on ouvre la fenêtre pour guider.
        if case .error = status { MainWindow.shared.show(state: self) }
        else if !onboardingDone { MainWindow.shared.show(state: self) }
        preloadIfNeeded()
    }

    private func preloadIfNeeded() {
        guard preloadModel, installedModels.contains(model.id) else { return }
        let url = model.localURL
        Task { try? await Self.transcriber.preload(modelURL: url) }
    }

    /// Supprime un modèle du disque.
    func deleteModel(_ target: WhisperModel) {
        Task {
            await Self.transcriber.unload()
            try? FileManager.default.removeItem(at: target.localURL)
            refreshInstalledModels()
            preloadIfNeeded()
        }
    }

    /// Lance ou arrête le test du micro : le niveau s'affiche, rien n'est enregistré ni transcrit.
    func toggleMicTest() {
        if micTesting {
            var samples = recorder.stop()
            samples.removeAll()
            micTesting = false
            level = 0
            return
        }
        guard permissions.problem == nil, activity != .listening, activity != .transcribing else { return }
        do {
            try recorder.start(deviceID: microphone)
        } catch {
            lastResult = L("Micro indisponible")
            return
        }
        micTesting = true
        Task { [weak self] in
            let started = Date()
            while let self, self.micTesting {
                self.level = self.recorder.level
                if Date().timeIntervalSince(started) > 20 { self.toggleMicTest() }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Transcrit un fichier audio. L'audio et le texte restent en mémoire.
    func transcribeFile(_ url: URL) {
        guard !fileBusy, installedModels.contains(model.id) else { return }
        fileName = url.lastPathComponent
        fileText = ""
        fileError = nil
        fileBusy = true
        let model = model, language = language
        let prompt = Vocabulary.prompt(words: vocabulary), rules = Vocabulary.replacements(replacements)
        Task {
            do {
                // Lecture du fichier hors du fil principal : un long fichier prend du temps.
                var samples = try await Task.detached { try AudioFile.samples(from: url) }.value
                let raw = try await Self.transcriber.transcribe(samples, modelURL: model.localURL,
                                                                language: language, prompt: prompt)
                samples.removeAll()
                fileText = Vocabulary.apply(rules, to: Hallucinations.clean(raw))
                if fileText.isEmpty { fileError = L("Rien reconnu") }
            } catch {
                fileError = error.localizedDescription
            }
            fileBusy = false
        }
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
            preloadIfNeeded()
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

    /// Lit le message avec VoiceOver, s'il est allumé. Jamais au début de l'écoute :
    /// la voix de VoiceOver serait enregistrée par le micro (le son de début suffit).
    private static func announce(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Recolle la dernière dictée dans l'app active (si l'insertion avait raté, ou pour la répéter).
    private func pasteAgain() {
        guard let text = history.first?.text, activity != .listening, activity != .transcribing else {
            NSSound.beep()
            return
        }
        Task {
            var text = text
            if autoSpacing {
                text = AutoSpacing.fit(text, after: Paster.textBeforeCursor(), keepCase: Set(Vocabulary.words(vocabulary)))
            }
            let outcome = await Paster.insert(text, method: insertMethod, restoreDelay: restoreDelay)
            lastResult = switch outcome {
            case .pasted: L("Dernière dictée recollée")
            case .keptInClipboard(let reason): L("%@. Texte gardé dans le presse-papiers : colle-le avec ⌘V.", reason)
            }
        }
    }

    private func startListening() {
        // Une erreur de dictée précédente n'empêche pas de réessayer ; un problème d'autorisation ou de modèle, si.
        guard permissions.problem == nil, installedModels.contains(model.id), !micTesting,
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
        // Seul l'identifiant de l'app est lu, jamais son contenu.
        listeningApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        listeningLanguage = listeningApp.flatMap { appLanguages[$0] }
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
        let stats = recorder.stats
        var samples = recorder.stop()
        let seconds = Double(samples.count) / Transcriber.sampleRate
        let silenceRMS = Float(pow(10, silenceDB / 20))
        let rms = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        var diag = Diagnostic(app: listeningApp ?? "?", device: stats.device, format: stats.format,
                              buffers: stats.buffers, dropped: stats.dropped, restarts: stats.restarts,
                              seconds: seconds, averageDB: Diagnostic.dB(rms), peakDB: Diagnostic.dB(stats.peak),
                              thresholdDB: silenceDB, model: model.label,
                              language: (listeningLanguage ?? language).label)

        if cancel != nil || seconds < Self.minimumSeconds || rms < silenceRMS {
            samples.removeAll() // rien à transcrire : l'audio est effacé tout de suite
            activity = .ready
            lastResult = switch cancel {
            case .tap: L("Appui bref. Pour dicter sans tenir la touche, appuie deux fois.")
            case .otherKey: L("Annulé : une autre touche a été pressée")
            case .escape: L("Annulé avec Échap")
            case nil: seconds < Self.minimumSeconds ? L("Trop court, ignoré") : L("Rien entendu (silence)")
            }
            addDiagnostic(diag)
            return
        }

        if fileBusy {
            samples.removeAll()
            activity = .ready
            lastResult = L("Un fichier est en cours de transcription. Réessaie après.")
            addDiagnostic(diag)
            return
        }

        if soundsEnabled { NSSound(named: "Pop")?.play() }
        // Silences du début et de la fin enlevés : moins de phrases inventées par le modèle, et plus rapide.
        samples = SilenceTrim.trim(samples, threshold: silenceRMS, sampleRate: Transcriber.sampleRate)
        diag.keptSeconds = Double(samples.count) / Transcriber.sampleRate
        let baseDiag = diag
        activity = .transcribing
        let model = model, language = listeningLanguage ?? language
        let prompt = Vocabulary.prompt(words: vocabulary), rules = Vocabulary.replacements(replacements)
        let keepCase = Set(Vocabulary.words(vocabulary))
        Task {
            var diag = baseDiag
            let started = Date()
            do {
                let raw = try await Self.transcriber.transcribe(samples, modelURL: model.localURL, language: language, prompt: prompt)
                samples.removeAll() // l'audio n'est plus nécessaire
                diag.transcribeSeconds = Date().timeIntervalSince(started)
                diag.raw = raw
                var text = Vocabulary.apply(rules, to: Hallucinations.clean(raw))
                if voiceCommands { text = VoiceCommands.apply(text, language: language) }
                text = text.trimmingCharacters(in: .whitespaces)
                lastTranscript = text
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    lastResult = L("Rien reconnu")
                    activity = .ready
                    addDiagnostic(diag)
                    return
                }
                if autoSpacing {
                    text = AutoSpacing.fit(text, after: Paster.textBeforeCursor(), keepCase: keepCase)
                }
                let outcome = await Paster.insert(text, method: insertMethod, restoreDelay: restoreDelay)
                history.insert(HistoryEntry(text: lastTranscript ?? text, pasted: outcome == .pasted), at: 0)
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
                addDiagnostic(diag)
            } catch {
                samples.removeAll()
                activity = .error(error.localizedDescription)
                addDiagnostic(diag, result: error.localizedDescription)
            }
        }
    }

    private func addDiagnostic(_ diag: Diagnostic, result: String? = nil) {
        guard debugMode else { return }
        var diag = diag
        diag.result = result ?? lastResult ?? ""
        diagnostics.insert(diag, at: 0)
        diagnostics = Array(diagnostics.prefix(20))
    }
}

/// Ce qui s'est passé pendant une dictée (mode debug). Gardé en mémoire seulement.
struct Diagnostic: Identifiable {
    let id = UUID()
    let date = Date()
    var app: String
    var device: String
    var format: String
    var buffers: Int
    var dropped: Int
    var restarts: Int
    var seconds: Double
    var averageDB: Double
    var peakDB: Double
    var thresholdDB: Double
    var model: String
    var language: String
    var keptSeconds: Double?
    var transcribeSeconds: Double?
    /// Texte brut du modèle, avant filtres et commandes vocales. Affiché, jamais copié ni écrit.
    var raw: String?
    var result = ""

    static func dB(_ rms: Float) -> Double { 20 * log10(max(Double(rms), 1e-6)) }

    /// Lignes techniques, sans le texte dicté (pour « Copier »).
    var lines: [String] {
        var lines = [
            "\(L("Résultat")) : \(result)",
            "\(L("App")) : \(app)",
            "\(L("Micro")) : \(device) (\(format))",
            "\(L("Blocs audio")) : \(buffers), \(L("perdus")) : \(dropped), \(L("relances du micro")) : \(restarts)",
            String(format: "\(L("Durée")) : %.1f s, \(L("gardée après silences")) : %@", seconds,
                   keptSeconds.map { String(format: "%.1f s", $0) } ?? "–"),
            String(format: "\(L("Volume moyen")) : %.0f dB, \(L("crête")) : %.0f dB, \(L("seuil de silence")) : %.0f dB",
                   averageDB, peakDB, thresholdDB),
            "\(L("Modèle")) : \(model), \(L("langue")) : \(language)",
        ]
        if let transcribeSeconds { lines.append(String(format: "\(L("Transcription")) : %.1f s", transcribeSeconds)) }
        return lines
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
