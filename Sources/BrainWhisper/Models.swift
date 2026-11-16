import BrainCore
import Foundation

/// A speech model the app can download and run. Everything runs on this Mac; the download is the only network use.
public struct SpeechModel: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var sizeMB: Int
    public var recommended: Bool
    /// nil: fetched by FluidAudio from its own model repository.
    public var url: URL?
}

/// The models on offer, where they live, and how to fetch them.
public enum ModelLocator {
    public static var modelsDir: URL { BrainPaths.supportDir.appendingPathComponent("Models") }
    /// With a Core ML encoder (`<model>-encoder.mlmodelc`) beside a whisper model the encoder runs through Core ML;
    /// without one whisper.cpp falls back to Metal. BRAININPUT_COREML=0 forces Metal; the test suite does that.
    public static var useCoreML: Bool { ProcessInfo.processInfo.environment["BRAININPUT_COREML"] != "0" }
    public static let defaultModel = "ggml-large-v3-turbo-q5_0.bin"

    public static let catalog: [SpeechModel] = [
        SpeechModel(id: ParakeetTranscriber.modelName, name: "Parakeet v3",
                    summary: "Fastest. 25 European languages, including English, German, Spanish and French.",
                    sizeMB: 460, recommended: true, url: nil),
        SpeechModel(id: defaultModel, name: "Whisper large-v3 turbo",
                    summary: "About 100 languages. Slower than Parakeet; pick it for languages Parakeet does not cover.",
                    sizeMB: 550, recommended: false,
                    url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")),
    ]

    public static func isInstalled(_ id: String) -> Bool {
        id == ParakeetTranscriber.modelName ? ParakeetTranscriber.isInstalled : path(for: id) != nil
    }

    public static func path(for name: String = defaultModel) -> String? {
        let p = modelsDir.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Installed models: Parakeet first, then every whisper file in the models folder (including ones put there by hand).
    public static func available() -> [String] {
        let whisper = ((try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []).filter { $0.hasSuffix(".bin") }.sorted()
        return (ParakeetTranscriber.isInstalled ? [ParakeetTranscriber.modelName] : []) + whisper
    }

    public static func displayName(_ id: String) -> String { catalog.first { $0.id == id }?.name ?? id }

    /// Parakeet when installed (faster and as accurate for the languages it covers), else whisper.
    public static var preferredModel: String { ParakeetTranscriber.isInstalled ? ParakeetTranscriber.modelName : defaultModel }

    /// The engine for a model name from the settings.
    public static func makeTranscriber(for name: String) -> (any LocalSpeechModel)? {
        if name == ParakeetTranscriber.modelName { return ParakeetTranscriber.isInstalled ? ParakeetTranscriber() : nil }
        return path(for: name).map { WhisperTranscriber(modelPath: $0) }
    }

    /// Downloads a catalog model. `progress` is 0...1 and may be called on any queue.
    public static func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = model.url else { try await ParakeetTranscriber.download(progress: progress); return }
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let delegate = DownloadProgressDelegate(progress)
        let (tmp, resp) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "BrainInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "The model server answered with HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)."])
        }
        let dst = modelsDir.appendingPathComponent(model.id)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }

    public static func remove(_ id: String) {
        if id == ParakeetTranscriber.modelName { ParakeetTranscriber.remove(); return }
        try? FileManager.default.removeItem(at: modelsDir.appendingPathComponent(id))
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(_ p: @escaping @Sendable (Double) -> Void) { progress = p }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
