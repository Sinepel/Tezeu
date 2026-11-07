import AppKit
import ApplicationServices
import Carbon
import TezeuCore

/// Colle le texte dans l'app ouverte, puis remet l'ancien presse-papiers.
/// Si le collage n'est pas possible, le texte reste dans le presse-papiers.
@MainActor
enum Paster {
    enum Outcome {
        case pasted
        /// Le texte est resté dans le presse-papiers ; le message dit pourquoi.
        case keptInClipboard(String)
    }

    /// Délai avant de remettre l'ancien presse-papiers : l'app cible doit avoir lu le texte.
    /// ponytail: délai fixe ; à allonger si une app lente colle l'ancien contenu.
    static let restoreDelay = Duration.milliseconds(400)

    static func paste(_ text: String) async -> Outcome {
        let pasteboard = NSPasteboard.general

        if let reason = blockReason() {
            Clipboard.setText(text, on: pasteboard)
            return .keptInClipboard(reason)
        }

        let previous = Clipboard.snapshot(of: pasteboard)
        let ours = Clipboard.setText(text, on: pasteboard)
        postCommandV()
        try? await Task.sleep(for: restoreDelay)

        // Si quelqu'un a copié autre chose entre-temps, on ne l'écrase pas.
        if pasteboard.changeCount == ours {
            Clipboard.restore(previous, to: pasteboard)
        }
        return .pasted
    }

    /// Raison de ne pas coller, ou nil si le collage est possible.
    private static func blockReason() -> String? {
        if !AXIsProcessTrusted() {
            return "Accessibilité non autorisée"
        }
        // Saisie protégée active (champ de mot de passe, Terminal en mode sécurisé…) : on n'insiste pas.
        if IsSecureEventInputEnabled() {
            return "Champ protégé (mot de passe)"
        }
        var focused: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            return "Aucun champ de texte actif"
        }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == kAXSecureTextFieldSubrole {
            return "Champ protégé (mot de passe)"
        }
        return nil
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
