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

/// Détecte l'appui et le relâchement de la touche choisie, dans toutes les apps.
/// Nécessite l'autorisation Accessibilité.
@MainActor
final class HotKeyMonitor {
    var key: HotKey
    var onPress: () -> Void = {}
    /// `cancelled` = une autre touche a été pressée pendant l'appui (ex. un raccourci).
    var onRelease: (_ cancelled: Bool) -> Void = { _ in }

    private var isDown = false
    private var otherKeyPressed = false
    private var monitors: [Any] = []

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

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged, event.keyCode == key.keyCode else {
            if isDown { otherKeyPressed = true }
            return
        }
        let down = event.modifierFlags.rawValue & key.deviceMask != 0
        if down, !isDown {
            isDown = true
            otherKeyPressed = false
            onPress()
        } else if !down, isDown {
            isDown = false
            onRelease(otherKeyPressed)
        }
    }
}
