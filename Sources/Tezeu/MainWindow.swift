import AppKit
import SwiftUI
import TezeuCore

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
        TabView {
            HistoryTab(state: state)
                .tabItem { Label(L("Historique"), systemImage: "clock") }
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
                Picker(L("Langue"), selection: Binding(get: { state.language }, set: { state.language = $0 })) {
                    ForEach(Language.allCases) { Text($0.label).tag($0) }
                }
                Picker(L("Micro"), selection: Binding(get: { state.microphone }, set: { state.microphone = $0 })) {
                    Text(L("Micro par défaut du Mac")).tag(String?.none)
                    ForEach(Recorder.microphones(), id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                }
                Toggle(L("Sons au début et à la fin de l'écoute"),
                       isOn: Binding(get: { state.soundsEnabled }, set: { state.soundsEnabled = $0 }))
                Toggle(L("Pastille en haut de l'écran pendant l'écoute"),
                       isOn: Binding(get: { state.showPill }, set: { state.showPill = $0 }))
            }

            Section(L("Modèle vocal")) {
                ModelSection(state: state)
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
}

// MARK: - À propos

struct AboutTab: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
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
