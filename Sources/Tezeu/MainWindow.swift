import AppKit
import SwiftUI
import TezeuCore
import UniformTypeIdentifiers

/// Fenêtre de l'app : historique, réglages, à propos.
/// Tant qu'elle est ouverte, Tézeu apparaît dans le Dock et dans ⌘Tab, comme une app normale.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(state: state)))
            window.title = "Tézeu"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 600, height: 560))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        // Fenêtre fermée : l'app retourne dans la barre de menus seulement.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MainView: View {
    let state: AppState

    var body: some View {
        if state.onboardingDone {
            tabs
        } else {
            OnboardingView(state: state)
                .frame(minWidth: 520, minHeight: 460)
        }
    }

    private var tabs: some View {
        TabView {
            HistoryTab(state: state)
                .tabItem { Label(L("Historique"), systemImage: "clock") }
            FileTab(state: state)
                .tabItem { Label(L("Fichier"), systemImage: "waveform") }
            SettingsTab(state: state)
                .tabItem { Label(L("Réglages"), systemImage: "gearshape") }
            AboutTab()
                .tabItem { Label(L("À propos"), systemImage: "info.circle") }
        }
        .frame(minWidth: 520, minHeight: 460)
    }
}

// MARK: - Historique

struct HistoryTab: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Gardé en mémoire seulement : effacé quand tu quittes Tézeu."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Tout effacer")) { state.history.removeAll() }
                    .disabled(state.history.isEmpty)
            }
            if state.history.isEmpty {
                Spacer()
                Text(L("Aucune dictée pour l'instant."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(state.history) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text).textSelection(.enabled)
                            HStack(spacing: 6) {
                                Text(entry.date, style: .time)
                                if !entry.pasted { Text(L("non collé")) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Copier")) { Clipboard.setText(entry.text, on: .general) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
    }
}

// MARK: - Premier lancement

/// Assistant en 3 étapes : autorisations, modèle, essai.
struct OnboardingView: View {
    let state: AppState

    var body: some View {
        let p = state.permissions
        let permissionsOK = p.problem == nil
        let modelOK = state.installedModels.contains(state.model.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(L("Bienvenue dans Tézeu")).font(.title2.bold())
                        Text(L("Trois étapes, et tu peux dicter partout."))
                            .foregroundStyle(.secondary)
                    }
                }

                Step(number: 1, title: L("Autorisations"), done: permissionsOK) {
                    PermissionRow(
                        title: L("Micro"),
                        detail: p.hasMicDevice ? L("Pour entendre ta voix.") : L("Branche un micro."),
                        granted: p.hasMicDevice && p.mic == .authorized,
                        action: p.hasMicDevice ? { p.requestMic() } : nil
                    )
                    PermissionRow(
                        title: L("Accessibilité"),
                        detail: L("Pour la touche et le collage."),
                        granted: p.accessibility,
                        action: { p.requestAccessibility() }
                    )
                }

                Step(number: 2, title: L("Modèle vocal"), done: modelOK) {
                    ModelSection(state: state)
                }

                Step(number: 3, title: L("Essai"), done: false) {
                    Text(L("Clique dans le cadre. Maintiens %@, dis une phrase, relâche.", state.hotKey.label))
                        .font(.callout)
                    TextEditor(text: Binding(get: { state.tryText }, set: { state.tryText = $0 }))
                        .font(.body).frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                        .disabled(!permissionsOK || !modelOK)
                }

                HStack {
                    Spacer()
                    Button(L("Terminer")) { state.onboardingDone = true }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                    .foregroundStyle(done ? .green : .secondary)
                    .accessibilityLabel(done ? L("Étape %d, faite", number) : L("Étape %d", number))
                Text(title).font(.headline)
            }
            content.padding(.leading, 26)
        }
    }
}

// MARK: - Fichier

/// Transcrit un fichier audio glissé ou choisi. Rien ne sort du Mac, le fichier n'est ni modifié ni copié.
struct FileTab: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(L("Choisir un fichier audio…")) { choose() }
                    .disabled(state.fileBusy || !state.installedModels.contains(state.model.id))
                Text(L("ou glisse-le ici. Formats : wav, m4a, mp3, aiff."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.fileBusy, let name = state.fileName {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L("Transcription de %@… Un long fichier peut prendre plusieurs minutes.", name))
                }
            } else if let name = state.fileName {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            if let error = state.fileError {
                Text(error).foregroundStyle(.red)
            }
            TextEditor(text: Binding(get: { state.fileText }, set: { state.fileText = $0 }))
                .font(.body)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Text(L("Le texte reste en mémoire : copie-le avant de quitter."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Copier")) { Clipboard.setText(state.fileText, on: .general) }
                    .disabled(state.fileText.isEmpty)
            }
        }
        .padding()
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !state.fileBusy else { return false }
            state.transcribeFile(url)
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.transcribeFile(url)
        }
    }
}

// MARK: - Réglages

struct SettingsTab: View {
    let state: AppState

    var body: some View {
        let p = state.permissions
        Form {
            Section(L("Dictée")) {
                Picker(L("Touche"), selection: Binding(get: { state.hotKey }, set: { state.hotKey = $0 })) {
                    ForEach(HotKey.allCases) { Text($0.label).tag($0) }
                }
                Text(L("Maintiens la touche pendant que tu parles. Ou appuie deux fois : l'écoute continue sans tenir la touche, un appui de plus l'arrête. Échap annule."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L("Raccourci mains libres"),
                       selection: Binding(get: { state.toggleShortcut }, set: { state.toggleShortcut = $0 })) {
                    ForEach(Shortcut.toggleChoices) { Text($0.label).tag($0) }
                }
                if state.shortcutAvailable {
                    Text(L("Un appui démarre l'écoute, un appui de plus l'arrête. Pas besoin de tenir les touches."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("Ce raccourci est déjà pris par une autre app. Choisis-en un autre."))
                        .font(.caption).foregroundStyle(.red)
                }
                Picker(L("Recoller la dernière dictée"),
                       selection: Binding(get: { state.pasteAgainShortcut }, set: { state.pasteAgainShortcut = $0 })) {
                    ForEach(Shortcut.pasteAgainChoices) { Text($0.label).tag($0) }
                }
                if !state.pasteAgainAvailable {
                    Text(L("Ce raccourci est déjà pris par une autre app. Choisis-en un autre."))
                        .font(.caption).foregroundStyle(.red)
                }
                Picker(L("Langue"), selection: Binding(get: { state.language }, set: { state.language = $0 })) {
                    ForEach(Language.allCases) { Text($0.label).tag($0) }
                }
                Toggle(L("Sons au début et à la fin de l'écoute"),
                       isOn: Binding(get: { state.soundsEnabled }, set: { state.soundsEnabled = $0 }))
                Toggle(L("Pastille en haut de l'écran pendant l'écoute"),
                       isOn: Binding(get: { state.showPill }, set: { state.showPill = $0 }))
                if state.showPill {
                    Toggle(L("Pastille compacte (barres seulement)"),
                           isOn: Binding(get: { state.compactPill }, set: { state.compactPill = $0 }))
                }
            }

            Section(L("Micro")) {
                Picker(L("Micro"), selection: Binding(get: { state.microphone }, set: { state.microphone = $0 })) {
                    Text(L("Micro par défaut du Mac")).tag(String?.none)
                    ForEach(Recorder.microphones(), id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                }
                MicTest(state: state)
            }

            Section(L("Langue par app")) {
                ForEach(state.appLanguages.keys.sorted(), id: \.self) { id in
                    HStack {
                        AppName(bundleID: id)
                        Spacer()
                        Picker(L("Langue"), selection: Binding(get: { state.appLanguages[id] ?? .auto },
                                                               set: { state.appLanguages[id] = $0 })) {
                            ForEach(Language.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Button { state.appLanguages[id] = nil } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(L("Retirer"))
                            .accessibilityLabel(L("Retirer"))
                    }
                }
                Button(L("Ajouter une app…")) { addApp() }
                Text(L("Dans ces apps, Tézeu dicte dans la langue choisie ici, au lieu de la langue du réglage Dictée."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Texte")) {
                Toggle(L("Commandes vocales"),
                       isOn: Binding(get: { state.voiceCommands }, set: { state.voiceCommands = $0 }))
                Text(L("Dis « virgule », « point final », « point d'interrogation », « deux points », « à la ligne », « nouveau paragraphe ». En anglais : « comma », « new line »…"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Espace et majuscule automatiques"),
                       isOn: Binding(get: { state.autoSpacing }, set: { state.autoSpacing = $0 }))
                Text(L("Regarde le texte juste avant le curseur, si l'app le permet. Ce texte n'est pas gardé."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L("Insertion"), selection: Binding(get: { state.insertMethod }, set: { state.insertMethod = $0 })) {
                    ForEach(InsertMethod.allCases) { Text($0.label).tag($0) }
                }
                if state.insertMethod == .paste {
                    LabeledContent(L("Délai avant de remettre le presse-papiers")) {
                        HStack {
                            Slider(value: Binding(get: { state.restoreDelay }, set: { state.restoreDelay = $0 }),
                                   in: 0.2...2, step: 0.1)
                            Text(L("%.1f s", state.restoreDelay)).monospacedDigit().frame(width: 40)
                        }
                    }
                    Text(L("À allonger si une app colle l'ancien contenu au lieu de ta dictée."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L("Modèle vocal")) {
                ModelSection(state: state)
                Toggle(L("Préparer le modèle au lancement (première dictée plus rapide)"),
                       isOn: Binding(get: { state.preloadModel }, set: { state.preloadModel = $0 }))
                InstalledModels(state: state)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Mots à reconnaître"))
                    Text(L("Noms propres, jargon… séparés par des virgules."))
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { state.vocabulary }, set: { state.vocabulary = $0 }))
                        .font(.body).frame(height: 50)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Remplacements"))
                    Text(L("Un par ligne : mot = remplacement. Exemple : tezeu = Tézeu. Laisser vide après « = » supprime le mot."))
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { state.replacements }, set: { state.replacements = $0 }))
                        .font(.body.monospaced()).frame(height: 70)
                }
            } header: {
                Text(L("Vocabulaire"))
            }

            Section(L("Autorisations")) {
                PermissionRow(
                    title: L("Micro"),
                    detail: p.hasMicDevice ? L("Pour entendre ta voix.") : L("Branche un micro."),
                    granted: p.hasMicDevice && p.mic == .authorized,
                    action: p.hasMicDevice ? { p.requestMic() } : nil
                )
                PermissionRow(
                    title: L("Accessibilité"),
                    detail: L("Pour la touche et le collage."),
                    granted: p.accessibility,
                    action: { p.requestAccessibility() }
                )
            }

            Section {
                Toggle(L("Lancer à l'ouverture de session"), isOn: Binding(
                    get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }
                ))
                if let note = state.launchAtLoginNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            p.refresh()
            state.refreshLaunchAtLogin()
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.message = L("Choisis une app")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier, state.appLanguages[id] == nil else { return }
        state.appLanguages[id] = state.language == .english ? .french : .english
    }
}

/// Test du micro : niveau en direct, comparé au seuil de silence réglable.
private struct MicTest: View {
    let state: AppState

    var body: some View {
        let db = 20 * log10(max(Double(state.level), 1e-6))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(state.micTesting ? L("Arrêter le test") : L("Tester le micro")) { state.toggleMicTest() }
                if state.micTesting {
                    ProgressView(value: min(1, max(0, (db + 70) / 60)))
                        .accessibilityLabel(L("Niveau du micro"))
                    Text(db > state.silenceDB ? L("Voix entendue") : L("Silence"))
                        .font(.caption).frame(width: 90, alignment: .leading)
                }
            }
            LabeledContent(L("Seuil de silence")) {
                HStack {
                    Slider(value: Binding(get: { state.silenceDB }, set: { state.silenceDB = $0 }), in: -70 ... -30, step: 1)
                    Text(L("%d dB", Int(state.silenceDB))).monospacedDigit().frame(width: 50)
                }
            }
            Text(L("Baisse le seuil si ta voix est prise pour du silence (micro faible). Remonte-le dans un lieu bruyant."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Modèles présents sur le disque, avec un bouton pour les supprimer.
private struct InstalledModels: View {
    let state: AppState

    var body: some View {
        let installed = WhisperModel.all.filter { state.installedModels.contains($0.id) }
        if !installed.isEmpty {
            ForEach(installed) { m in
                HStack {
                    Text(verbatim: "\(m.label) · \(m.sizeLabel)")
                    Spacer()
                    Button(L("Supprimer"), role: .destructive) { state.deleteModel(m) }
                }
            }
        }
    }
}

// MARK: - À propos

struct AboutTab: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(verbatim: "Tézeu").font(.title.bold())
            Text(L("Version %@", version)).foregroundStyle(.secondary)
            Text(L("Dictée 100 % locale. Ta voix et ton texte restent sur ton Mac."))
                .multilineTextAlignment(.center)

            Divider().padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Crédits")).font(.headline)
                Credit(name: "whisper.cpp", detail: L("Reconnaissance vocale, par Georgi Gerganov et ses contributeurs. Licence MIT."),
                       link: "https://github.com/ggml-org/whisper.cpp")
                Credit(name: "Whisper", detail: L("Modèles vocaux, par OpenAI. Licence MIT."),
                       link: "https://huggingface.co/ggerganov/whisper.cpp")
                Credit(name: "Tézeu", detail: L("Par Constantin Boulanger. Licence MIT. Code source :"),
                       link: "https://github.com/Sinepel/Tezeu")
            }
            .frame(maxWidth: 440, alignment: .leading)
            Spacer()
        }
        .padding(24)
    }
}

private struct Credit: View {
    let name: String
    let detail: String
    let link: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: name).bold()
            Text(detail).font(.caption).foregroundStyle(.secondary)
            // Ouvert dans le navigateur, seulement si tu cliques. L'app elle-même ne se connecte pas.
            if let url = URL(string: link) {
                Link(link.replacingOccurrences(of: "https://", with: ""), destination: url).font(.caption)
            }
        }
    }
}

/// Icône et nom d'une app à partir de son identifiant.
private struct AppName: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 6) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
        }
    }
}
