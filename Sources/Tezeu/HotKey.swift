import TezeuCore
import AppKit

/// Touche à maintenir pour dicter. Uniquement des touches de modification du côté droit,
/// pour ne pas gêner la frappe normale.
enum HotKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption: L("Option droite")
        case .rightCommand: L("Commande droite")
        case .rightControl: L("Contrôle droite")
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        }
    }

    /// Bit « côté droit » dans les drapeaux de l'événement (NX_DEVICER*KEYMASK).
    var deviceMask: UInt {
        switch self {
        case .rightOption: 0x40
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        }
    }
}

/// Détecte la touche choisie dans toutes les apps : maintien, double appui, Échap.
/// Nécessite l'autorisation Accessibilité.
@MainActor
final class HotKeyMonitor {
    var key: HotKey {
        didSet { gesture.reset() }
    }
    var onAction: (DictationGesture.Action) -> Void = { _ in }

    /// Vrai pendant une écoute lancée par double appui.
    var isHandsFree: Bool { gesture.isHandsFree }

    private var gesture = DictationGesture()
    private var isDown = false
    private var otherKeyPressed = false
    private var monitors: [Any] = []
    private static let escapeKeyCode: UInt16 = 53

    init(key: HotKey) {
        self.key = key
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            },
            NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            },
        ].compactMap { $0 }
    }

    /// Oublie l'appui en cours (écoute arrêtée par l'app).
    func reset() {
        gesture.reset()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == Self.escapeKeyCode {
            emit(gesture.escape())
            return
        }
        guard event.type == .flagsChanged, event.keyCode == key.keyCode else {
            if isDown { otherKeyPressed = true }
            return
        }
        // event.timestamp : secondes depuis le démarrage du Mac.
        let down = event.modifierFlags.rawValue & key.deviceMask != 0
        if down, !isDown {
            isDown = true
            otherKeyPressed = false
            emit(gesture.press(at: event.timestamp))
        } else if !down, isDown {
            isDown = false
            emit(gesture.release(at: event.timestamp, otherKey: otherKeyPressed))
        }
    }

    private func emit(_ action: DictationGesture.Action) {
        if action != .none { onAction(action) }
    }
}
