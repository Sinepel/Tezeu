// Programme de vérification de Tézeu.
//   swift run -c release SelfCheck transcribe <fichier audio> [--auto] [--model <chemin .bin>]
// Transcrit un fichier audio avec le même code que l'app. Utile pour tester sans micro.
import AppKit
import AVFoundation
import Foundation
import TezeuCore

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

    let samples = try loadAudio(URL(filePath: path))
    print("Audio : \(String(format: "%.1f", Double(samples.count) / Transcriber.sampleRate)) s")
    print("Modèle : \(modelURL.lastPathComponent), langue : \(language.label)")
    let start = Date()
    let transcriber = Transcriber()
    let text = try await transcriber.transcribe(samples, modelURL: modelURL, language: language)
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
    precondition(pasteboard.string(forType: .string) == "texte dicté", "le texte dicté n'est pas dans le presse-papiers")
    precondition(pasteboard.changeCount == ours)
    Clipboard.restore(snapshot, to: pasteboard)

    let items = pasteboard.pasteboardItems ?? []
    precondition(items.count == 2, "nombre d'éléments différent : \(items.count)")
    precondition(items[0].string(forType: .string) == "ancien texte é ✓", "texte non remis")
    precondition(items[0].string(forType: html) == "<b>ancien</b>", "format HTML non remis")
    precondition(items[1].data(forType: custom) == Data([0, 1, 2, 255]), "format binaire non remis")
    print("OK  presse-papiers riche sauvegardé puis remis à l'identique")

    // 2. Presse-papiers vide : il doit rester vide après la remise.
    pasteboard.clearContents()
    let empty = Clipboard.snapshot(of: pasteboard)
    Clipboard.setText("texte dicté", on: pasteboard)
    Clipboard.restore(empty, to: pasteboard)
    precondition((pasteboard.pasteboardItems ?? []).isEmpty, "le presse-papiers vide n'a pas été remis vide")
    print("OK  presse-papiers vide remis vide")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "transcribe":
    try await transcribeCommand(Array(args.dropFirst()))
case "clipboard", nil:
    clipboardCheck()
default:
    print("""
    Usage :
      swift run -c release SelfCheck                 (vérifie le presse-papiers)
      swift run -c release SelfCheck transcribe <fichier audio> [--auto] [--model <chemin>]
    """)
}
