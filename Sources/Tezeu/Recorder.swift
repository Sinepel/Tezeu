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
    private var deviceID: String?
    private var configObserver: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    private var restarts = 0

    /// Relances au plus par enregistrement (évite une boucle si le micro change sans arrêt).
    private static let maxRestarts = 3

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
        self.deviceID = deviceID
        restarts = 0
        capture = Capture(outFormat: Self.outFormat)
        do {
            try startEngine()
        } catch {
            capture = nil
            throw error
        }

        // Filet de sécurité : certains micros Bluetooth (AirPods…) donnent un silence parfait,
        // ou rien du tout, juste après l'ouverture. Un vrai micro n'est jamais à zéro absolu.
        watchdog = Task { [weak self] in
            for _ in 0..<2 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let capture = self.capture, !Task.isCancelled else { return }
                if capture.heardSomething { return }
                self.restartEngine()
            }
        }
    }

    /// Arrête le micro et rend les échantillons. Le Recorder n'en garde aucune copie.
    func stop() -> [Float] {
        watchdog?.cancel()
        watchdog = nil
        stopEngine()
        defer { capture = nil }
        return capture?.take() ?? []
    }

    private static let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Transcriber.sampleRate,
                                                 channels: 1, interleaved: false)!

    private func startEngine() throws {
        guard let capture else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceID, var device = Self.audioDevice(uid: deviceID), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inFormat, to: Self.outFormat)
        else { throw RecorderError.noMic }

        capture.use(converter)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat, block: capture.tapBlock())
        engine.prepare()
        try engine.start()
        self.engine = engine

        // Le micro a changé de format ou d'appareil (ex. AirPods qui passent en mode appel) :
        // macOS arrête le moteur sans prévenir. On le relance avec le nouveau format.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Relance le micro en gardant l'audio déjà reçu.
    private func restartEngine() {
        guard capture != nil, restarts < Self.maxRestarts else { return }
        restarts += 1
        stopEngine()
        try? startEngine()
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
    private let outFormat: AVAudioFormat
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var lastLevel: Float = 0
    private var heard = false

    var level: Float { lock.withLock { lastLevel } }

    /// Vrai dès qu'un bloc audio non nul est arrivé.
    var heardSomething: Bool { lock.withLock { heard } }

    init(outFormat: AVAudioFormat) {
        self.outFormat = outFormat
    }

    /// Nouveau convertisseur après une relance du micro (le format d'entrée a pu changer).
    func use(_ converter: AVAudioConverter) {
        lock.withLock { self.converter = converter }
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
            guard let converter, converter.inputFormat == input.format else { return }
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
                if lastLevel > 0 { heard = true }
            }
        }
    }
}
