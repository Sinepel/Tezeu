import TezeuCore
import AppKit
import Carbon.HIToolbox

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

/// Combinaison de touches pour l'écoute mains libres : un appui démarre, un appui de plus arrête.
enum ToggleShortcut: String, CaseIterable, Identifiable {
    case none, controlOptionSpace, optionSpace, shiftOptionSpace, controlOptionD

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: L("Aucun")
        case .controlOptionSpace: "⌃⌥ " + L("Espace")
        case .optionSpace: "⌥ " + L("Espace")
        case .shiftOptionSpace: "⇧⌥ " + L("Espace")
        case .controlOptionD: "⌃⌥ D"
        }
    }

    /// Code de touche et modificateurs au format Carbon.
    fileprivate var carbon: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .none: nil
        case .controlOptionSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
        case .shiftOptionSpace: (UInt32(kVK_Space), UInt32(shiftKey | optionKey))
        case .controlOptionD: (UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey))
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

    /// Raccourci mains libres. Enregistré auprès de macOS : la combinaison n'arrive pas
    /// dans l'app active (pas d'espace tapée en plus).
    var shortcut: ToggleShortcut = .none {
        didSet { registerShortcut() }
    }
    /// Faux si macOS a refusé le raccourci (déjà pris par une autre app).
    private(set) var shortcutAvailable = true

    private var gesture = DictationGesture()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var shortcutDown = false
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

    private func registerShortcut() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        shortcutDown = false
        shortcutAvailable = true
        guard let carbon = shortcut.carbon else { return }

        if handlerRef == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                MainActor.assumeIsolated { monitor.shortcutEvent(pressed: pressed) }
                return noErr
            }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x545A4555), id: 1) // « TZEU »
        let status = RegisterEventHotKey(carbon.keyCode, carbon.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        shortcutAvailable = status == noErr
    }

    private func shortcutEvent(pressed: Bool) {
        // Touche gardée enfoncée : un seul déclenchement.
        if pressed, !shortcutDown { emit(gesture.toggle()) }
        shortcutDown = pressed
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
