import AppKit
import ApplicationServices
import AVFoundation

/// Suit les autorisations Micro et Accessibilité, et ouvre le bon écran des Réglages.
@MainActor
@Observable
final class Permissions {
    private(set) var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var hasMicDevice = AVCaptureDevice.default(for: .audio) != nil
    private(set) var accessibility = AXIsProcessTrusted()

    /// Premier problème à régler, ou nil si tout est bon.
    var problem: String? {
        if !hasMicDevice { return "Aucun micro détecté" }
        if mic == .denied || mic == .restricted { return "Micro refusé" }
        if mic != .authorized { return "Autorisation Micro requise" }
        if !accessibility { return "Autorisation Accessibilité requise" }
        return nil
    }

    func refresh() {
        // N'écrire que ce qui change : chaque écriture fait redessiner le panneau.
        let newMic = AVCaptureDevice.authorizationStatus(for: .audio)
        let newDevice = AVCaptureDevice.default(for: .audio) != nil
        let newAccessibility = AXIsProcessTrusted()
        if newMic != mic { mic = newMic }
        if newDevice != hasMicDevice { hasMicDevice = newDevice }
        if newAccessibility != accessibility { accessibility = newAccessibility }
    }

    /// Affiche la demande système la première fois, sinon ouvre les Réglages.
    func requestMic() {
        if mic == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        } else {
            Self.openSettings("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        // Ajoute l'app à la liste Accessibilité, puis ouvre l'écran pour cocher la case.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Self.openSettings("Privacy_Accessibility")
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
