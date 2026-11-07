import CryptoKit
import Foundation
import TezeuCore

enum DownloadError: LocalizedError {
    case badStatus(Int)
    case badChecksum

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): "Le serveur a répondu \(code)."
        case .badChecksum: "Le fichier reçu ne correspond pas à l'empreinte attendue. Il a été supprimé."
        }
    }
}

/// SEUL code réseau de l'app. Appelé uniquement quand l'utilisateur clique sur « Télécharger ».
/// Session éphémère : ni cookies, ni cache.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let model: WhisperModel
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    static func install(_ model: WhisperModel, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: WhisperModel.directory, withIntermediateDirectories: true)
        try await ModelDownloader(model: model, onProgress: onProgress).run()
    }

    private init(model: WhisperModel, onProgress: @escaping @Sendable (Double) -> Void) {
        self.model = model
        self.onProgress = onProgress
    }

    private func run() async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: model.remoteURL).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite _: Int64) {
        onProgress(Double(written) / Double(model.bytes))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Le fichier temporaire disparaît au retour de cette méthode : on le déplace tout de suite.
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw DownloadError.badStatus(status) }
            try? FileManager.default.removeItem(at: model.partURL)
            try FileManager.default.moveItem(at: location, to: model.partURL)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = Result<Void, Error> {
            if let error { throw error }
            if let moveError { throw moveError }
            guard try Self.sha256(of: model.partURL) == model.sha256 else { throw DownloadError.badChecksum }
            try? FileManager.default.removeItem(at: model.localURL)
            try FileManager.default.moveItem(at: model.partURL, to: model.localURL)
        }
        if case .failure = result { try? FileManager.default.removeItem(at: model.partURL) }
        continuation?.resume(with: result)
        continuation = nil
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
