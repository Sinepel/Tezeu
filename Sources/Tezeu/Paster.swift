import AppKit
import ApplicationServices
import Carbon
import TezeuCore

/// Façon d'insérer le texte dans l'app ouverte.
enum InsertMethod: String, CaseIterable, Identifiable {
    /// ⌘V puis remise de l'ancien presse-papiers. Rapide.
    case paste
    /// Frappe simulée, caractère par caractère. Plus lent, mais ne touche pas au presse-papiers
    /// et marche dans les apps qui bloquent ⌘V.
    case type

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paste: L("Coller (rapide)")
        case .type: L("Taper le texte (sans presse-papiers)")
        }
    }
}

/// Insère le texte dans l'app ouverte. En mode collage, l'ancien presse-papiers est remis ensuite.
/// Si l'insertion n'est pas possible, le texte reste dans le presse-papiers.
@MainActor
enum Paster {
    enum Outcome: Equatable {
        case pasted
        /// Le texte est resté dans le presse-papiers ; le message dit pourquoi.
        case keptInClipboard(String)
    }

    /// `restoreDelay` : secondes avant de remettre l'ancien presse-papiers (l'app cible doit avoir lu le texte).
    static func insert(_ text: String, method: InsertMethod, restoreDelay: Double) async -> Outcome {
        let pasteboard = NSPasteboard.general

        if let reason = blockReason() {
            Clipboard.setText(text, on: pasteboard)
            return .keptInClipboard(reason)
        }
        if method == .type {
            await type(text)
            return .pasted
        }

        let previous = Clipboard.snapshot(of: pasteboard)
        let ours = Clipboard.setText(text, on: pasteboard)
        postCommandV()
        try? await Task.sleep(for: .seconds(restoreDelay))

        // Si quelqu'un a copié autre chose entre-temps, on ne l'écrase pas.
        if pasteboard.changeCount == ours {
            Clipboard.restore(previous, to: pasteboard)
        }
        return .pasted
    }

    /// Raison de ne pas coller, ou nil si le collage est possible.
    private static func blockReason() -> String? {
        if !AXIsProcessTrusted() {
            return L("Accessibilité non autorisée")
        }
        // Saisie protégée active (champ de mot de passe, Terminal en mode sécurisé…) : on n'insiste pas.
        if IsSecureEventInputEnabled() {
            return L("Champ protégé (mot de passe)")
        }
        guard let focused = focusedElement() else {
            return L("Aucun champ de texte actif")
        }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == kAXSecureTextFieldSubrole {
            return L("Champ protégé (mot de passe)")
        }
        return nil
    }

    private static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }

    /// Les derniers caractères avant le curseur dans le champ actif, ou nil si l'app ne les donne pas.
    /// Lus seulement pour ajuster l'espace et la majuscule ; jamais gardés ni écrits.
    static func textBeforeCursor() -> String? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), let element = focusedElement() else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return nil }
        if selection.location <= 0 { return "" }

        let length = min(selection.location, 40)
        var range = CFRange(location: selection.location - length, length: length)
        guard let wanted = AXValueCreate(.cfRange, &range) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, wanted, &text) == .success
        else { return nil }
        return text as? String
    }

    /// Tape le texte comme au clavier, par petits morceaux. Les retours à la ligne envoient la touche Entrée.
    private static func type(_ text: String) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        func post(_ chars: [UniChar], key: CGKeyCode = 0) {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown) else { continue }
                event.flags = []
                if !chars.isEmpty { event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars) }
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 {
                post([], key: 36) // Entrée
                try? await Task.sleep(for: .milliseconds(5))
            }
            let units = Array(line.utf16)
            // Morceaux de 16 unités au plus (limite des événements clavier), sans couper un emoji en deux.
            var start = 0
            while start < units.count {
                var end = min(start + 16, units.count)
                if end < units.count, UTF16.isTrailSurrogate(units[end]) { end -= 1 }
                post(Array(units[start..<end]))
                start = end
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// Envoie ⌘V. La touche 9 est « V » en AZERTY comme en QWERTY.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
