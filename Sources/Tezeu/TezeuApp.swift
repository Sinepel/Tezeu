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
            Image(systemName: state.status.symbol)
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

struct MenuView: View {
    let state: AppState

    var body: some View {
        let p = state.permissions
        VStack(alignment: .leading, spacing: 12) {
            Label(state.status.label, systemImage: state.status.symbol)
                .font(.headline)
            if let last = state.lastResult {
                Text(last).font(.caption).foregroundStyle(.secondary)
            }
            if let text = state.lastTranscript, !text.isEmpty {
                Text(text).textSelection(.enabled).lineLimit(6)
            }

            Picker("Touche", selection: Binding(get: { state.hotKey }, set: { state.hotKey = $0 })) {
                ForEach(HotKey.allCases) { Text($0.label).tag($0) }
            }
            Picker("Langue", selection: Binding(get: { state.language }, set: { state.language = $0 })) {
                ForEach(Language.allCases) { Text($0.label).tag($0) }
            }

            Divider()
            ModelSection(state: state)

            Divider()
            Text("Autorisations").font(.subheadline.bold())

            PermissionRow(
                title: "Micro",
                detail: p.hasMicDevice ? "Pour entendre ta voix." : "Branche un micro.",
                granted: p.hasMicDevice && p.mic == .authorized,
                action: p.hasMicDevice ? { p.requestMic() } : nil
            )
            PermissionRow(
                title: "Accessibilité",
                detail: "Pour la touche et le collage.",
                granted: p.accessibility,
                action: { p.requestAccessibility() }
            )

            Divider()
            Button("Quitter Tézeu") { state.quit() }
        }
        .padding()
        .frame(width: 300)
        .onAppear { p.refresh() }
    }
}

struct ModelSection: View {
    let state: AppState

    var body: some View {
        let model = state.model
        VStack(alignment: .leading, spacing: 6) {
            Picker("Modèle", selection: Binding(get: { state.model }, set: { state.model = $0 })) {
                ForEach(WhisperModel.all) { m in
                    Text("\(m.label) · \(m.sizeLabel)\(state.installedModels.contains(m.id) ? " ✓" : "")").tag(m)
                }
            }
            .disabled(state.downloadProgress != nil)

            if let progress = state.downloadProgress {
                ProgressView(value: progress) {
                    Text("Téléchargement… \(Int(progress * 100)) %").font(.caption)
                }
            } else if !state.installedModels.contains(model.id) {
                Text("Source : \(WhisperModel.sourceLabel)\nTaille : \(model.sizeLabel). L'empreinte sera vérifiée.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Télécharger le modèle (\(model.sizeLabel))") { state.downloadModel() }
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
                Button("Autoriser", action: action)
            }
        }
    }
}
