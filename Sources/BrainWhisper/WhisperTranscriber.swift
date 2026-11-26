// Derived from VoiceInk (GPL-3.0): VoiceInk/Infrastructure/Providers/Transcription/Whisper/LibWhisper.swift
import AVFoundation
import BrainCore
import Foundation
import whisper

public enum WhisperError: Error { case modelMissing(String), loadFailed(String), runFailed }

/// whisper.cpp must not be entered from two threads at once, hence an actor.
public actor WhisperTranscriber: Transcriber {
    private var ctx: OpaquePointer?
    public let modelPath: String

    public init(modelPath: String) { self.modelPath = modelPath }

    deinit { if let ctx { whisper_free(ctx) } }

    public func load() throws {
        guard ctx == nil else { return }
        guard FileManager.default.fileExists(atPath: modelPath) else { throw WhisperError.modelMissing(modelPath) }
        whisper_log_set({ _, _, _ in }, nil)
        var p = whisper_context_default_params()
        p.use_gpu = true
        p.flash_attn = true
        guard let c = whisper_init_from_file_with_params(modelPath, p) else { throw WhisperError.loadFailed(modelPath) }
        ctx = c
    }

    public func unload() { if let ctx { whisper_free(ctx) }; ctx = nil }

    public func transcribe(samples: [Float], prompt: String?) async throws -> Transcript {
        try run(samples: samples, prompt: prompt, language: nil)
    }

    public func transcribe(samples: [Float], prompt: String?, language: String?) async throws -> Transcript {
        try run(samples: samples, prompt: prompt, language: language)
    }

    private func run(samples: [Float], prompt: String?, language fixed: String?) throws -> Transcript {
        var stats = TranscribeStats(); stats.engine = "whisper"; stats.startedAt = Date()
        let wasLoaded = ctx != nil, tLoad = Date()
        try load()
        if !wasLoaded { stats.loadMs = msSince(tLoad) }
        guard let ctx else { throw WhisperError.runFailed }
        // Whisper invents text for silence, so skip input with no speech-level energy.
        guard AudioMath.rms(samples) > 0.0015 else { stats.silenceGated = true; return Transcript(text: "", language: nil, stats: stats) }
        var audio = samples
        if audio.count < 17_600 { audio += [Float](repeating: 0, count: 17_600 - audio.count) }
        stats.samples = audio.count
        let tRun = Date()

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false; params.print_progress = false
        params.print_timestamps = false; params.print_special = false
        params.translate = false
        params.no_context = true
        params.no_timestamps = true
        params.suppress_nst = true
        params.temperature = 0
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

        let lang = Array((fixed ?? "auto").utf8CString)
        let promptC = prompt.map { Array($0.utf8CString) }
        let rc: Int32 = lang.withUnsafeBufferPointer { l in
            params.language = l.baseAddress
            func run() -> Int32 { audio.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) } }
            if let promptC {
                return promptC.withUnsafeBufferPointer { p in params.initial_prompt = p.baseAddress; return run() }
            }
            return run()
        }
        guard rc == 0 else { throw WhisperError.runFailed }
        stats.inferenceMs = msSince(tRun)
        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) { text += String(cString: whisper_full_get_segment_text(ctx, i)) }
        let id = whisper_full_lang_id(ctx)
        let language = id >= 0 ? whisper_lang_str(id).map { String(cString: $0) } : nil
        return Transcript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: language, stats: stats)
    }
}

public enum AudioMath {
    public static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for v in s { sum += v * v }
        return (sum / Float(s.count)).squareRoot()
    }
}

public enum AudioLoader {
    public static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    /// Loads an audio file AVAudioFile can open (wav, m4a, mp3, aiff, caf, flac) as 16 kHz mono Float32. Reads in
    /// blocks, so an hour of 48 kHz stereo does not need a 1.4 GB buffer first.
    public static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let block: AVAudioFrameCount = 1 << 18
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else { return [] }
        let r = StreamResampler()
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 1024)
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: block)
            if buf.frameLength == 0 { break }
            out += r.convert(buf)
        }
        return out
    }

    public enum LoadError: Error, LocalizedError {
        case noAudio(String)
        public var errorDescription: String? {
            switch self { case .noAudio(let name): "\(name) has no audio track that macOS can decode" }
        }
    }

    /// Loads any file with sound in it: audio files first through AVAudioFile, then anything AVFoundation can open
    /// (video such as mp4 and mov, other containers) through AVAssetReader, which decodes and resamples itself.
    public static func loadAny16kMono(_ url: URL) async throws -> [Float] {
        if let samples = try? load16kMono(url), !samples.isEmpty { return samples }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw LoadError.noAudio(url.lastPathComponent) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? LoadError.noAudio(url.lastPathComponent) }
        var out: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let n = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: n)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            out += chunk
        }
        if reader.status == .failed { throw reader.error ?? LoadError.noAudio(url.lastPathComponent) }
        guard !out.isEmpty else { throw LoadError.noAudio(url.lastPathComponent) }
        return out
    }
}

/// Converts a stream of buffers in any format to 16 kHz mono Float32.
public final class StreamResampler {
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    public init() {}

    public func convert(_ buf: AVAudioPCMBuffer) -> [Float] {
        if inFormat != buf.format {
            inFormat = buf.format
            converter = AVAudioConverter(from: buf.format, to: AudioLoader.format)
        }
        guard let converter, buf.frameLength > 0 else { return [] }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 512
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioLoader.format, frameCapacity: cap) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard error == nil, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}
