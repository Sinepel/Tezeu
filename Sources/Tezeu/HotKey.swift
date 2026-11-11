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

/// Combinaisons de touches proposées pour les raccourcis (mains libres, recoller).
enum Shortcut: String, CaseIterable, Identifiable {
    case none, controlOptionSpace, optionSpace, shiftOptionSpace, controlOptionD, controlOptionV, shiftOptionV

    /// Choix pour démarrer et arrêter l'écoute.
    static let toggleChoices: [Shortcut] = [.none, .controlOptionSpace, .optionSpace, .shiftOptionSpace, .controlOptionD]
    /// Choix pour recoller la dernière dictée.
    static let pasteAgainChoices: [Shortcut] = [.none, .controlOptionV, .shiftOptionV]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: L("Aucun")
        case .controlOptionSpace: "⌃⌥ " + L("Espace")
        case .optionSpace: "⌥ " + L("Espace")
        case .shiftOptionSpace: "⇧⌥ " + L("Espace")
        case .controlOptionD: "⌃⌥ D"
        case .controlOptionV: "⌃⌥ V"
        case .shiftOptionV: "⇧⌥ V"
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
        case .controlOptionV: (UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey))
        case .shiftOptionV: (UInt32(kVK_ANSI_V), UInt32(shiftKey | optionKey))
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

    /// Raccourcis enregistrés auprès de macOS : la combinaison n'arrive pas dans l'app active
    /// (pas d'espace ni de lettre tapée en plus).
    enum Slot: UInt32 { case toggle = 1, pasteAgain = 2 }

    /// Appelé par le raccourci « recoller la dernière dictée ».
    var onPasteAgain: () -> Void = {}

    private var gesture = DictationGesture()
    private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var toggleDown = false
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

    /// Enregistre (ou retire) un raccourci. Faux si macOS le refuse (déjà pris par une autre app).
    @discardableResult
    func register(_ shortcut: Shortcut, for slot: Slot) -> Bool {
        if let ref = hotKeyRefs.removeValue(forKey: slot) { UnregisterEventHotKey(ref) }
        if slot == .toggle { toggleDown = false }
        guard let carbon = shortcut.carbon else { return true }

        if handlerRef == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard let slot = Slot(rawValue: hotKeyID.id) else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                MainActor.assumeIsolated { monitor.shortcutEvent(slot, pressed: pressed) }
                return noErr
            }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x545A4555), id: slot.rawValue) // « TZEU »
        guard RegisterEventHotKey(carbon.keyCode, carbon.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return false }
        hotKeyRefs[slot] = ref
        return true
    }

    private func shortcutEvent(_ slot: Slot, pressed: Bool) {
        switch slot {
        case .toggle:
            // Touche gardée enfoncée : un seul déclenchement.
            if pressed, !toggleDown { emit(gesture.toggle()) }
            toggleDown = pressed
        case .pasteAgain:
            if pressed { onPasteAgain() }
        }
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
