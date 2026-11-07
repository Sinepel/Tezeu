// Programme de vérification de Tézeu.
//   swift run -c release SelfCheck transcribe <fichier audio> [--auto] [--model <chemin .bin>] [--words "mot1, mot2"]
// Transcrit un fichier audio avec le même code que l'app. Utile pour tester sans micro.
import AppKit
import AVFoundation
import Foundation
import TezeuCore

/// Comme precondition, mais affiche le message aussi en mode release.
func check(_ condition: Bool, _ message: @autoclosure () -> String = "") {
    if !condition { fail("ÉCHEC  " + message()) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Lit un fichier audio et le convertit en 16 kHz mono Float32.
func loadAudio(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Transcriber.sampleRate,
                                        channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: file.processingFormat, to: outFormat),
          let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(
              Double(file.length) * outFormat.sampleRate / file.processingFormat.sampleRate) + 1024)
    else { fail("Format audio non pris en charge") }
    try file.read(into: input)

    nonisolated(unsafe) var fed = false
    var error: NSError?
    _ = converter.convert(to: output, error: &error) { _, status in
        if fed {
            status.pointee = .endOfStream
            return nil
        }
        fed = true
        status.pointee = .haveData
        return input
    }
    if let error { throw error }
    guard let channel = output.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
}

func transcribeCommand(_ args: [String]) async throws {
    guard let path = args.first else { fail("Indique un fichier audio.") }
    let language: Language = args.contains("--auto") ? .auto : .french
    let modelURL: URL
    if let i = args.firstIndex(of: "--model"), i + 1 < args.count {
        modelURL = URL(filePath: args[i + 1])
    } else if let installed = WhisperModel.all.first(where: \.isInstalled) {
        modelURL = installed.localURL
    } else {
        fail("Aucun modèle installé. Télécharge-le depuis l'app, ou passe --model <chemin>.")
    }

    var words = ""
    if let i = args.firstIndex(of: "--words"), i + 1 < args.count { words = args[i + 1] }

    let samples = try loadAudio(URL(filePath: path))
    print("Audio : \(String(format: "%.1f", Double(samples.count) / Transcriber.sampleRate)) s")
    print("Modèle : \(modelURL.lastPathComponent), langue : \(language.label)")
    let start = Date()
    let transcriber = Transcriber()
    let text = try await transcriber.transcribe(samples, modelURL: modelURL, language: language,
                                                prompt: Vocabulary.prompt(words: words))
    await transcriber.unload()
    print("Durée de transcription : \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
    print("Texte : \(text)")
}

/// Vérifie la sauvegarde et la remise du presse-papiers, sur un presse-papiers privé
/// (celui de l'utilisateur n'est pas touché).
@MainActor
func clipboardCheck() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("local.tezeu.selfcheck.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let custom = NSPasteboard.PasteboardType("local.tezeu.test")
    let html = NSPasteboard.PasteboardType.html

    // 1. Contenu riche : 2 éléments, plusieurs formats.
    pasteboard.clearContents()
    let first = NSPasteboardItem()
    first.setString("ancien texte é ✓", forType: .string)
    first.setString("<b>ancien</b>", forType: html)
    let second = NSPasteboardItem()
    second.setData(Data([0, 1, 2, 255]), forType: custom)
    pasteboard.writeObjects([first, second])

    let snapshot = Clipboard.snapshot(of: pasteboard)
    let ours = Clipboard.setText("texte dicté", on: pasteboard)
    check(pasteboard.string(forType: .string) == "texte dicté", "le texte dicté n'est pas dans le presse-papiers")
    check(pasteboard.changeCount == ours)
    Clipboard.restore(snapshot, to: pasteboard)

    let items = pasteboard.pasteboardItems ?? []
    check(items.count == 2, "nombre d'éléments différent : \(items.count)")
    check(items[0].string(forType: .string) == "ancien texte é ✓", "texte non remis")
    check(items[0].string(forType: html) == "<b>ancien</b>", "format HTML non remis")
    check(items[1].data(forType: custom) == Data([0, 1, 2, 255]), "format binaire non remis")
    print("OK  presse-papiers riche sauvegardé puis remis à l'identique")

    // 2. Presse-papiers vide : il doit rester vide après la remise.
    pasteboard.clearContents()
    let empty = Clipboard.snapshot(of: pasteboard)
    Clipboard.setText("texte dicté", on: pasteboard)
    Clipboard.restore(empty, to: pasteboard)
    check((pasteboard.pasteboardItems ?? []).isEmpty, "le presse-papiers vide n'a pas été remis vide")
    print("OK  presse-papiers vide remis vide")
}

/// Vérifie que chaque texte passé à la fonction L du code a une traduction anglaise, et qu'il n'y en a pas en trop.
func localizationCheck() {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let regex = /L\("((?:[^"\\]|\\.)*)"/
    var keys = Set<String>()
    let files = FileManager.default.enumerator(at: root.appending(path: "Sources"), includingPropertiesForKeys: nil)!
    for case let url as URL in files where url.pathExtension == "swift" {
        let source = try! String(contentsOf: url, encoding: .utf8)
        for match in source.matches(of: regex) {
            keys.insert(String(match.1).replacingOccurrences(of: "\\n", with: "\n"))
        }
    }
    let strings = root.appending(path: "Resources/en.lproj/Localizable.strings")
    let english = NSDictionary(contentsOf: strings) as! [String: String]
    let missing = keys.subtracting(english.keys), extra = Set(english.keys).subtracting(keys)
    if !missing.isEmpty { fail("ÉCHEC  traductions anglaises manquantes : \(missing.sorted())") }
    if !extra.isEmpty { fail("ÉCHEC  traductions anglaises en trop : \(extra.sorted())") }
    print("OK  \(keys.count) textes, tous traduits en anglais")
}

/// Vérifie le maintien de la touche, le double appui, Échap et les autres touches.
func gestureCheck() {
    typealias G = DictationGesture
    // Maintien : début à l'appui, fin au relâchement.
    var g = G()
    check(g.press(at: 0) == .start && g.release(at: 2, otherKey: false) == .stop, "maintien")
    // Raccourci clavier pendant l'appui : annulé.
    check(g.press(at: 10) == .start && g.release(at: 11, otherKey: true) == .cancel(.otherKey), "autre touche")
    // Double appui : l'écoute continue après le second relâchement, un appui de plus l'arrête.
    g = G()
    check(g.press(at: 0) == .start && g.release(at: 0.1, otherKey: false) == .cancel(.tap), "premier appui bref")
    check(g.press(at: 0.3) == .start && g.isHandsFree, "second appui")
    check(g.release(at: 0.4, otherKey: false) == .none && g.isHandsFree, "mains libres")
    check(g.press(at: 20) == .stop && !g.isHandsFree, "appui d'arrêt")
    check(g.release(at: 20.1, otherKey: false) == .none, "relâchement après l'arrêt")
    // Après l'arrêt, un appui bref isolé ne relance pas le mode mains libres.
    check(g.press(at: 30) == .start && g.release(at: 30.1, otherKey: false) == .cancel(.tap), "appui bref isolé")
    check(g.press(at: 31) == .start && !g.isHandsFree, "second appui trop tard = maintien")
    check(g.release(at: 32, otherKey: false) == .stop, "maintien après délai")
    // Second appui long : traité comme un maintien.
    g = G()
    _ = g.press(at: 0); _ = g.release(at: 0.1, otherKey: false)
    check(g.press(at: 0.3) == .start && g.release(at: 2, otherKey: false) == .stop, "second appui long")
    // Échap annule l'écoute mains libres.
    g = G()
    _ = g.press(at: 0); _ = g.release(at: 0.1, otherKey: false); _ = g.press(at: 0.2); _ = g.release(at: 0.3, otherKey: false)
    check(g.escape() == .cancel(.escape) && g.press(at: 5) == .start, "Échap")
    // Remise à zéro (durée maximale) : le relâchement suivant est ignoré.
    g = G()
    _ = g.press(at: 0); g.reset()
    check(g.release(at: 400, otherKey: false) == .none, "remise à zéro")
    print("OK  maintien, double appui, Échap et autres touches")
}

/// Vérifie le vocabulaire donné au modèle et les remplacements.
func vocabularyCheck() {
    check(Vocabulary.prompt(words: " Tézeu, Sinepel\n\nwhisper.cpp ,") == "Tézeu, Sinepel, whisper.cpp.", "liste de mots")
    check(Vocabulary.prompt(words: " , \n") == nil, "liste vide")
    let rules = Vocabulary.replacements("tezeu = Tézeu\nligne sans signe\n = vide\neuh =\nCB = C. Boulanger $1")
    check(rules.count == 3, "règles lues : \(rules.count)")
    check(Vocabulary.apply(rules, to: "J'utilise tezeu et TEZEU, pas tezeux.") == "J'utilise Tézeu et Tézeu, pas tezeux.", "mots entiers")
    check(Vocabulary.apply(rules, to: "Bon, euh, Euhh") == "Bon, , Euhh", "mot supprimé")
    check(Vocabulary.apply(rules, to: "Signé CB") == "Signé C. Boulanger $1", "caractères spéciaux")
    print("OK  vocabulaire et remplacements")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "transcribe":
    try await transcribeCommand(Array(args.dropFirst()))
case "clipboard", nil:
    clipboardCheck()
    gestureCheck()
    vocabularyCheck()
    localizationCheck()
default:
    print("""
    Usage :
      swift run -c release SelfCheck                 (presse-papiers, touche, vocabulaire, traductions)
      swift run -c release SelfCheck transcribe <fichier audio> [--auto] [--model <chemin>] [--words "mot1, mot2"]
    """)
}
