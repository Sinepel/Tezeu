import AVFoundation
import CoreAudio
import TezeuCore

enum RecorderError: Error {
    case noMic
}

/// Enregistre le micro en mémoire seulement, en 16 kHz mono (format attendu par whisper.cpp).
/// Rien n'est écrit sur le disque.
@MainActor
final class Recorder {

    private var engine: AVAudioEngine?
    private var capture: Capture?

    /// Micros disponibles : identifiant (UID Core Audio) et nom.
    static func microphones() -> [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// Niveau sonore actuel (RMS du dernier bloc), pour la pastille d'écoute.
    var level: Float { capture?.level ?? 0 }

    /// `deviceID` : UID du micro choisi, ou nil pour le micro par défaut du Mac.
    /// Si ce micro n'est plus branché, le micro par défaut est utilisé.
    func start(deviceID: String?) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceID, var device = Self.audioDevice(uid: deviceID), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Transcriber.sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw RecorderError.noMic }

        let capture = Capture(converter: converter, outFormat: outFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat, block: capture.tapBlock())
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.capture = capture
    }

    /// Arrête le micro et rend les échantillons. Le Recorder n'en garde aucune copie.
    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        defer { capture = nil }
        return capture?.take() ?? []
    }

    private static func audioDevice(uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}

/// Reçoit l'audio sur le fil du micro, le convertit et l'accumule. Protégé par un verrou.
private final class Capture: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastLevel: Float = 0

    var level: Float { lock.withLock { lastLevel } }

    init(converter: AVAudioConverter, outFormat: AVAudioFormat) {
        self.converter = converter
        self.outFormat = outFormat
    }

    nonisolated func tapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in process(buffer) }
    }

    func take() -> [Float] {
        lock.withLock {
            defer { samples = [] }
            return samples
        }
    }

    private func process(_ input: AVAudioPCMBuffer) {
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        nonisolated(unsafe) var fed = false
        var error: NSError?
        lock.withLock {
            _ = converter.convert(to: output, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return input
            }
            if error == nil, let channel = output.floatChannelData {
                let block = UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength))
                samples.append(contentsOf: block)
                lastLevel = block.isEmpty ? 0 : (block.reduce(0) { $0 + $1 * $1 } / Float(block.count)).squareRoot()
            }
        }
    }
}
