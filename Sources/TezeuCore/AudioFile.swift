import AVFoundation

public enum AudioFileError: LocalizedError {
    case unsupported

    public var errorDescription: String? {
        L("Format audio non pris en charge")
    }
}

/// Lit un fichier audio (wav, m4a, mp3, aiff, caf…) et le convertit en 16 kHz mono Float32.
/// Tout reste en mémoire.
public enum AudioFile {
    public static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Transcriber.sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(
                  Double(file.length) * outFormat.sampleRate / file.processingFormat.sampleRate) + 1024)
        else { throw AudioFileError.unsupported }
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
}
