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

    @discardableResult
    public func process(samples: [Float], onStage: (@Sendable (DictationStage) -> Void)? = nil) async -> DictationRecord? {
        let t0 = Date()
        var rec = DictationRecord()
        rec.timings.audioMs = samples.count / 16
        onStage?(.transcribing)
        async let ctx = reader.currentContext()
        let transcript: Transcript
        do { transcript = try await transcriber.transcribe(samples: samples, prompt: whisperPrompt()) }
        catch { onStage?(.failed); return nil }
        rec.timings.transcribeMs = msSince(t0)
        rec.context = await ctx
        rec.raw = rawFixes(Self.tidy(transcript.text))
        rec.language = transcript.language
        guard !rec.raw.isEmpty else { onStage?(.empty); return nil }
        if Task.isCancelled { return nil }

        var text = rec.raw
        if let polisher {
            onStage?(.polishing)
            let p = await polisher.polish(raw: rec.raw, language: rec.language, context: rec.context, reader: reader)
            rec.modeID = p.modeID; rec.cleanupStatus = p.status; rec.timings.cleanupMs = p.ms; rec.costUSD = p.costUSD
            if let cleaned = p.text?.trimmed, !cleaned.isEmpty { rec.cleaned = cleaned; text = cleaned }
        }

        if Task.isCancelled { return nil }       // cancelled with Esc: nothing is inserted or saved
        onStage?(.inserting)
        let t2 = Date()
        let ok = await inserter.insert(text)
        rec.inserted = text
        rec.timings.insertMs = msSince(t2)
        rec.timings.totalMs = msSince(t0)
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
