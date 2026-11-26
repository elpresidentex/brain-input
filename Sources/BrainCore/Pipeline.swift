import Foundation

public enum DictationStage: String, Sendable { case transcribing, polishing, inserting, done, empty, failed }

/// Hotkey release to inserted text. Never fails because the language model did: every path that
/// does not produce cleaned text falls through to the raw transcript.
public actor DictationPipeline {
    private let transcriber: Transcriber
    private let inserter: TextInserter
    private let reader: ContextReader
    private let store: NotesStore
    private let polisher: Polisher?
    private let whisperPrompt: @Sendable () -> String?
    private let onInserted: (@Sendable (DictationRecord) async -> Void)?
    private let rawFixes: @Sendable (String) -> String
    public private(set) var last: DictationRecord?

    public init(transcriber: Transcriber, inserter: TextInserter, reader: ContextReader, store: NotesStore,
                polisher: Polisher? = nil, whisperPrompt: @escaping @Sendable () -> String? = { nil },
                rawFixes: @escaping @Sendable (String) -> String = { $0 },
                onInserted: (@Sendable (DictationRecord) async -> Void)? = nil) {
        self.transcriber = transcriber; self.inserter = inserter; self.reader = reader; self.store = store
        self.polisher = polisher; self.whisperPrompt = whisperPrompt; self.onInserted = onInserted; self.rawFixes = rawFixes
    }

    /// A live transcriber for the dictation about to be recorded, using this pipeline's engine and dictionary prompt.
    public func makeLive() -> IncrementalTranscriber {
        IncrementalTranscriber(transcriber: transcriber, prompt: whisperPrompt())
    }

    @discardableResult
    public func process(samples: [Float], seed: TraceSeed = TraceSeed(),
                        onStage: (@Sendable (DictationStage) -> Void)? = nil) async -> DictationRecord? {
        await process(samples: samples, live: nil, seed: seed, onStage: onStage)
    }

    /// With `live`, the chunks transcribed during recording are used and only the tail is left to do. When live
    /// transcription gives up (a chunk failed, or it heard nothing), the whole recording is transcribed in one pass,
    /// exactly as without it.
    @discardableResult
    public func process(samples: [Float], live: IncrementalTranscriber?, seed: TraceSeed = TraceSeed(),
                        onStage: (@Sendable (DictationStage) -> Void)? = nil) async -> DictationRecord? {
        let t0 = Date()
        var rec = DictationRecord()
        rec.timings.audioMs = samples.count / 16
        var d = TimingDetail()
        d.stopMs = seed.stopMs; d.previewInFlight = seed.previewInFlight; d.previewRuns = seed.previewRuns
        d.previewEngineMs = seed.previewEngineMs; d.meetingActive = seed.meetingActive
        d.thermal = TimingDetail.thermalName(ProcessInfo.processInfo.thermalState)
        d.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        onStage?(.transcribing)
        let reader = self.reader
        async let ctx: (AppContext, Int) = { let t = Date(); let c = await reader.currentContext(); return (c, msSince(t)) }()
        let tPrompt = Date(); let prompt = whisperPrompt(); d.promptMs = msSince(tPrompt)
        var transcript: Transcript
        var tCall = Date()
        if let live {
            if let r = await live.finish(all: samples) {
                transcript = r.transcript
                d.chunks = r.chunks; d.tailMs = r.tailMs; d.backlogMs = r.backlogMs; d.liveEngineMs = r.engineMs
                d.previewRuns = r.previewRuns; d.previewEngineMs = r.previewEngineMs; d.liveFallback = false
            } else {
                let liveCancelled = await live.isCancelled
                if Task.isCancelled || liveCancelled { return nil }   // Esc: nothing inserted or saved
                d.liveFallback = true
                tCall = Date()
                do { transcript = try await transcriber.transcribe(samples: samples, prompt: prompt) }
                catch { onStage?(.failed); return nil }
            }
        } else {
            do { transcript = try await transcriber.transcribe(samples: samples, prompt: prompt) }
            catch { onStage?(.failed); return nil }
        }
        rec.timings.transcribeMs = msSince(t0)
        if let s = transcript.stats {
            d.engine = s.engine; d.loadMs = s.loadMs; d.inferenceMs = s.inferenceMs; d.silenceGated = s.silenceGated; d.samples = s.samples
            d.queueWaitMs = s.startedAt.map { max(0, Int($0.timeIntervalSince(tCall) * 1000)) } ?? 0
        }
        let tCtx = Date()
        let (context, contextMs) = await ctx
        d.contextMs = contextMs; d.contextWaitMs = msSince(tCtx)
        rec.context = context
        rec.raw = rawFixes(Self.tidy(transcript.text))
        rec.language = transcript.language
        guard !rec.raw.isEmpty else { onStage?(.empty); return nil }
        if Task.isCancelled { return nil }

        var text = rec.raw
        if let polisher {
            onStage?(.polishing)
            let p = await polisher.polish(raw: rec.raw, language: rec.language, context: rec.context, reader: reader)
            rec.modeID = p.modeID; rec.cleanupStatus = p.status; rec.timings.cleanupMs = p.ms; rec.costUSD = p.costUSD
            d.cleanup = p.detail
            if let cleaned = p.text?.trimmed, !cleaned.isEmpty { rec.cleaned = cleaned; text = cleaned }
        }

        if Task.isCancelled { return nil }       // cancelled with Esc: nothing is inserted or saved
        onStage?(.inserting)
        let t2 = Date()
        let ok = await inserter.insert(text)
        rec.inserted = text
        rec.timings.insertMs = msSince(t2)
        rec.timings.totalMs = msSince(t0)
        rec.timings.detail = d
        try? store.saveDictation(rec)
        last = rec
        onStage?(ok ? .done : .failed)
        await onInserted?(rec)
        return rec
    }

    /// Swaps the last cleaned insertion for the raw transcript.
    @discardableResult
    public func undoToRaw() async -> Bool {
        guard var rec = last, !rec.revertedToRaw, rec.inserted != rec.raw else { return false }
        guard await inserter.replaceLast(rec.inserted, with: rec.raw) else { return false }
        rec.revertedToRaw = true; rec.inserted = rec.raw
        try? store.saveDictation(rec)
        last = rec
        return true
    }

    /// Records what the field contained after my edits (called by the learning code).
    public func setFinalText(_ text: String, for id: String) {
        guard var rec = store.dictation(id: id) else { return }
        rec.finalText = text
        try? store.saveDictation(rec)
        if last?.id == id { last = rec }
    }

    /// Strips whisper's non-speech tags such as [BLANK_AUDIO] or (Musik).
    public static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[[^\]]{0,40}\]|\((?i:music|musik|applause|applaus|silence|stille|laughter|lachen)[^)]{0,20}\)"#,
                                       with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return t.trimmed
    }
}
