import BrainCore
import FluidAudio
import CoreML
import Foundation

/// A speech model that is loaded once and then transcribes 16 kHz mono samples.
public protocol LocalSpeechModel: Transcriber {
    func load() async throws
    func unload() async
}

extension WhisperTranscriber: LocalSpeechModel {}

public enum ParakeetError: Error { case modelMissing(String) }

/// NVIDIA Parakeet TDT 0.6B v3 (25 European languages, German and English included) on the Neural Engine
/// through FluidAudio. Several times faster than whisper large-v3-turbo. The model files live in FluidAudio's own
/// cache folder; `download` fetches them on first run.
public actor ParakeetTranscriber: LocalSpeechModel {
    public static let modelName = "parakeet-tdt-0.6b-v3"
    private var manager: AsrManager?

    public init() {}

    /// The conformer encoder is the part Core ML must compile for the Neural Engine, and it does so again whenever
    /// the app binary changes (2-3 minutes of ANECompilerService at full CPU). On the GPU there is nothing to
    /// compile, so launches are instant. `defaults write <bundle id> parakeetEncoder ane` brings the ANE back.
    static var encoderUnits: MLComputeUnits {
        UserDefaults.standard.string(forKey: "parakeetEncoder") == "ane" ? .cpuAndNeuralEngine : .cpuAndGPU
    }

    /// FluidAudio's shared cache, so a model another app already fetched is reused. With BRAININPUT_SUPPORT set
    /// (tests, a trial run of the setup guide) the model goes under that folder instead.
    public static var cacheDirectory: URL {
        let std = AsrModels.defaultCacheDirectory(for: .v3)
        guard ProcessInfo.processInfo.environment["BRAININPUT_SUPPORT"] != nil else { return std }
        return ModelLocator.modelsDir.appendingPathComponent(std.lastPathComponent)
    }
    public static var isInstalled: Bool { AsrModels.modelsExist(at: cacheDirectory, version: .v3) }

    /// Fetches the model files (about 460 MB) unless they are already there. `progress` is 0...1, called on any queue.
    /// FluidAudio follows the download with a Neural Engine compile that can run for many minutes and that this app
    /// does not use (see `encoderUnits`), so this returns as soon as the files are complete and leaves that step behind.
    public static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        final class Flags: @unchecked Sendable { let lock = NSLock(); var filesDone = false; var result: Result<Void, Error>? }
        let flags = Flags()
        let dir = cacheDirectory
        let task = Task.detached {
            do {
                try await AsrModels.download(to: dir, version: .v3, encoderPrecision: .int8) { p in
                    if case .compiling = p.phase { flags.lock.withLock { flags.filesDone = true }; progress(1) }
                    else { progress(min(p.fractionCompleted, 0.99)) }
                }
                flags.lock.withLock { flags.result = .success(()) }
            } catch { flags.lock.withLock { flags.result = .failure(error) } }
        }
        while true {
            let (filesDone, result) = flags.lock.withLock { (flags.filesDone, flags.result) }
            if let result { try result.get(); return }
            if filesDone, isInstalled { task.cancel(); return }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    public static func remove() { try? FileManager.default.removeItem(at: cacheDirectory) }

    public func load() async throws {
        guard manager == nil else { return }
        guard Self.isInstalled else { throw ParakeetError.modelMissing(Self.cacheDirectory.path) }
        let models = try await AsrModels.load(from: Self.cacheDirectory, configuration: nil, version: .v3, encoderPrecision: .int8,
                                         encoderComputeUnits: Self.encoderUnits)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
    }

    public func unload() async { await manager?.cleanup(); manager = nil }

    public func transcribe(samples: [Float], prompt: String?) async throws -> Transcript {
        try await load()
        guard let manager else { return Transcript(text: "") }
        guard AudioMath.rms(samples) > 0.0015 else { return Transcript(text: "") }
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }   // the model wants at least 1 s
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state, language: nil)
        return Transcript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), language: nil)
    }
}
