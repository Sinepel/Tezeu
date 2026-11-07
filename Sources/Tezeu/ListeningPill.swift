import AppKit
import SwiftUI
import TezeuCore

/// Petite pastille flottante en haut de l'écran pendant l'écoute et la transcription.
/// Elle ne prend jamais le focus et laisse passer les clics : l'app active reste active.
@MainActor
final class ListeningPill {
    private var panel: NSPanel?

    /// Affiche la pastille pour cet état, ou la cache si `state` est nil.
    func update(_ state: AppState?) {
        guard let state, state.showPill else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel(state)
        self.panel = panel
        if !panel.isVisible {
            // Écran où se trouve la souris, en haut au centre.
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let area = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.maxY - panel.frame.height - 10))
            }
            panel.orderFrontRegardless()
        }
    }

    private func makePanel(_ state: AppState) -> NSPanel {
        let size = NSSize(width: 300, height: 44)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: PillView(state: state))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        return panel
    }
}

private struct PillView: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 10) {
            if state.activity == .transcribing {
                ProgressView().controlSize(.small)
                Text(L("Transcription…"))
            } else {
                LevelBars(level: state.level)
                Text(state.handsFree ? L("Appuie sur la touche pour finir · Échap annule") : L("Écoute…"))
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Cinq barres qui suivent le volume du micro.
private struct LevelBars: View {
    let level: Float

    var body: some View {
        // Volume en dB ramené entre 0 (−50 dB, silence) et 1 (−10 dB, voix forte).
        let db = 20 * log10(max(level, 1e-6))
        let value = CGFloat(min(1, max(0, (db + 50) / 40)))
        HStack(spacing: 3) {
            ForEach(Array([0.5, 0.8, 1, 0.8, 0.5].enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 4 + 16 * value * weight)
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: value)
    }
}
