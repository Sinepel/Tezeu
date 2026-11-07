import Foundation
import whisper

public enum TranscriberError: LocalizedError {
    case loadFailed
    case failed

    public var errorDescription: String? {
        switch self {
        case .loadFailed: L("Impossible de charger le modèle vocal")
        case .failed: L("La transcription a échoué")
        }
    }
}

/// Fait tourner whisper.cpp (puce Apple via Metal), hors du fil principal.
/// Garde un seul modèle chargé en mémoire.
public actor Transcriber {
    /// Format attendu : 16 kHz, mono, Float32.
    public static let sampleRate = 16_000.0

    private var context: OpaquePointer?
    private var loadedPath: String?

    public init() {
        // Coupe les messages techniques de whisper.cpp. Ils ne contiennent pas le texte dicté,
        // mais l'app n'a pas besoin de journal.
        whisper_log_set({ _, _, _ in }, nil)
    }

    /// À appeler avant de quitter : whisper.cpp plante (GGML_ASSERT) si son contexte Metal
    /// est encore ouvert à la fermeture du programme.
    public func unload() {
        if let context { whisper_free(context) }
        context = nil
        loadedPath = nil
    }

    /// Charge le modèle à l'avance, pour que la première dictée soit rapide.
    public func preload(modelURL: URL) throws {
        _ = try load(modelURL.path)
    }

    /// `prompt` : texte qui oriente le modèle vers certains mots (voir `Vocabulary.prompt`).
    public func transcribe(_ samples: [Float], modelURL: URL, language: Language, prompt: String? = nil) throws -> String {
        let ctx = try load(modelURL.path)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.no_context = true
        params.suppress_blank = true

        // whisper.cpp attend au moins 1 s d'audio : on complète avec du silence.
        var audio = samples
        let minimum = Int(Self.sampleRate * 1.1)
        if audio.count < minimum {
            audio += [Float](repeating: 0, count: minimum - audio.count)
        }

        let status = language.rawValue.withCString { lang in
            params.language = lang
            return (prompt ?? "").withCString { promptText in
                params.initial_prompt = prompt == nil ? nil : promptText
                return audio.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
            }
        }
        guard status == 0 else { throw TranscriberError.failed }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let segment = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: segment)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load(_ path: String) throws -> OpaquePointer {
        if let context, loadedPath == path { return context }
        if let context {
            whisper_free(context)
            self.context = nil
        }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(path, cparams) else {
            throw TranscriberError.loadFailed
        }
        context = ctx
        loadedPath = path
        return ctx
    }
}
