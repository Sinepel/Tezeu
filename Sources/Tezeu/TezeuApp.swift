import TezeuCore
import SwiftUI

@main
struct TezeuApp: App {
    // Pas de @State : sans Xcode, son plugin manque. L'App n'est créée qu'une fois, un `let` suffit.
    private let state = AppState()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            // Au repos : les lèvres de l'icône. Pendant le travail ou en cas d'erreur : un symbole d'état.
            if state.status == .ready, let icon = MenuBarIcon.image {
                Image(nsImage: icon)
            } else {
                Image(systemName: state.status.symbol)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var whisperReleased = false

    /// Libère whisper.cpp avant de quitter, sinon il plante à la fermeture.
    /// (Cas où l'app est fermée de l'extérieur : déconnexion, commande quit…)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.whisperReleased { return .terminateNow }
        Task {
            await AppState.transcriber.unload()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Icône de la barre de menus au repos : lèvres en noir et blanc, adaptées au mode clair ou sombre.
@MainActor
enum MenuBarIcon {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 22, height: 13)
        image.isTemplate = true
        return image
    }()
}

/// Panneau court de la barre de menus. Les réglages sont dans la fenêtre de l'app.
struct MenuView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(state.status.label, systemImage: state.status.symbol)
                .font(.headline)
            if let last = state.lastResult {
                Text(last).font(.caption).foregroundStyle(.secondary)
            }
            if let text = state.lastTranscript, !text.isEmpty {
                Text(text).textSelection(.enabled).lineLimit(6)
            }
            Text(L("Maintiens %@ pour dicter, ou appuie deux fois.", state.hotKey.label))
                .font(.caption).foregroundStyle(.secondary)

            Picker(L("Langue"), selection: Binding(get: { state.language }, set: { state.language = $0 })) {
                ForEach(Language.allCases) { Text($0.label).tag($0) }
            }

            Divider()
            Button(L("Ouvrir Tézeu…")) { MainWindow.shared.show(state: state) }
            Button(L("Quitter Tézeu")) { state.quit() }
        }
        .padding()
        .frame(width: 300)
        .onAppear { state.permissions.refresh() }
    }
}

struct ModelSection: View {
    let state: AppState

    var body: some View {
        let model = state.model
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("Modèle"), selection: Binding(get: { state.model }, set: { state.model = $0 })) {
                ForEach(WhisperModel.all) { m in
                    Text(verbatim: "\(m.label) · \(m.sizeLabel)\(state.installedModels.contains(m.id) ? " ✓" : "")").tag(m)
                }
            }
            .disabled(state.downloadProgress != nil)

            if let progress = state.downloadProgress {
                ProgressView(value: progress) {
                    Text(L("Téléchargement… %d %%", Int(progress * 100))).font(.caption)
                }
            } else if !state.installedModels.contains(model.id) {
                Text(L("Source : %@\nTaille : %@. L'empreinte sera vérifiée.", WhisperModel.sourceLabel, model.sizeLabel))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Télécharger le modèle (%@)", model.sizeLabel)) { state.downloadModel() }
            }
            if let error = state.downloadError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted, let action {
                Button(L("Autoriser"), action: action)
            }
        }
    }
}
