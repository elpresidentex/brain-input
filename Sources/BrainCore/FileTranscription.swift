import Foundation

// Transcribing a whole audio file the user drops in: one engine call over the whole file, as VoiceInk does. Every
// cut costs accuracy: the first version cut at about 10 s like live dictation does, and a 164 s German voice message
// came back with sentences ended mid-thought, compounds torn apart and words lost at the
// seams, where one pass of the same model did not. The engine handles long audio itself (FluidAudio: overlapping
// 15 s windows merged by token; whisper: its own 30 s windows). Timestamps and paragraphs come from the engine's
// token timings, so they cost no accuracy.

public struct FileTranscript: Sendable, Equatable {
    /// One sentence. `start` is nil when the engine gave no timings (whisper), except for the first sentence (0).
    public struct Segment: Sendable, Equatable {
        public var start: Double?
        public var text: String
        /// Silence before this sentence, in seconds (0 when unknown).
        public var pauseBefore: Double = 0
        public init(start: Double?, text: String, pauseBefore: Double = 0) { self.start = start; self.text = text; self.pauseBefore = pauseBefore }
    }
    public var segments: [Segment]
    public var language: String?
    public var audioSeconds: Double
    public var engineMs: Int

    /// The whole transcript as plain text, one blank line between paragraphs.
    public var text: String { paragraphs().map(\.text).joined(separator: "\n\n") }

    /// Sentences grouped into paragraphs, broken only between sentences: at a clear pause once a paragraph holds
    /// `minSeconds`, always by `maxSeconds`; without timings, by length.
    public func paragraphs(minSeconds: Double = 20, maxSeconds: Double = 45, pause: Double = 1.2, maxChars: Int = 700) -> [Segment] {
        var out: [Segment] = []
        var lastStart: Double?
        for s in segments where !s.text.isEmpty {
            if let cur = out.last {
                let since = s.start.flatMap { a in (cur.start ?? lastStart).map { a - $0 } }
                let breakHere = since.map { $0 >= maxSeconds || ($0 >= minSeconds && s.pauseBefore >= pause) } ?? (cur.text.count >= maxChars)
                if !breakHere { out[out.count - 1].text += " " + s.text; continue }
            }
            out.append(s)
            if let st = s.start { lastStart = st }
        }
        return out
    }
}

public enum FileTranscription {
    /// Transcribes 16 kHz mono samples in one engine call. `progress` gets 0 before and 1 after. The call itself
    /// cannot be interrupted; a task cancelled meanwhile throws `CancellationError` once it returns.
    public static func run(samples: [Float], transcriber: Transcriber, prompt: String?,
                           progress: @Sendable (Double) async -> Void = { _ in }) async throws -> FileTranscript {
        let t0 = Date()
        try Task.checkCancellation()
        await progress(0)
        let t = try await transcriber.transcribe(samples: samples, prompt: prompt, language: nil)
        try Task.checkCancellation()
        await progress(1)
        return FileTranscript(segments: sentences(t, offset: 0), language: t.language, audioSeconds: Double(samples.count) / 16000,
                              engineMs: msSince(t0))
    }

    /// The engine's text as sentences. With token timings each sentence gets its own start and the pause before it;
    /// the text is the tokens joined, which is what the engine's own text is made of. If they disagree, or without
    /// timings, the text is split at sentence ends and only the first sentence carries a start (`offset`).
    static func sentences(_ t: Transcript, offset: Double) -> [FileTranscript.Segment] {
        let full = DictationPipeline.tidy(t.text)
        guard !full.isEmpty else { return [] }
        if let tokens = t.tokens, !tokens.isEmpty, tokens.map(\.text).joined().trimmed == t.text.trimmed {
            var out: [FileTranscript.Segment] = []
            var text = "", start: Double?, pause = 0.0, prevEnd: Double?
            for tok in tokens {
                if text.trimmed.isEmpty, !tok.text.trimmed.isEmpty {
                    start = offset + tok.start; pause = prevEnd.map { max(0, tok.start - $0) } ?? 0
                }
                text += tok.text
                if !tok.text.trimmed.isEmpty { prevEnd = tok.end }
                if endsSentence(tok.text) {
                    let s = DictationPipeline.tidy(text)
                    if !s.isEmpty { out.append(.init(start: start, text: s, pauseBefore: pause)) }
                    text = ""
                }
            }
            let rest = DictationPipeline.tidy(text)
            if !rest.isEmpty { out.append(.init(start: start, text: rest, pauseBefore: pause)) }
            return out
        }
        var out: [FileTranscript.Segment] = []
        var cur = ""
        for word in full.split(separator: " ", omittingEmptySubsequences: true) {
            cur += (cur.isEmpty ? "" : " ") + word
            if endsSentence(String(word)) { out.append(.init(start: out.isEmpty ? offset : nil, text: cur)); cur = "" }
        }
        if !cur.isEmpty { out.append(.init(start: out.isEmpty ? offset : nil, text: cur)) }
        return out
    }

    static func endsSentence(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'»«“”’)"))
        return t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") || t.hasSuffix("…")
    }

    public static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static let fileFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; return f }()

    public static func markdown(title: String, sourceName: String, date: Date, model: String, result: FileTranscript) -> String {
        var md = "# \(title)\n\n"
        md += "- Source: \(sourceName)\n"
        md += "- Transcribed: \(date.formatted(date: .abbreviated, time: .shortened)) with \(model)\n"
        md += "- Length: \(timestamp(result.audioSeconds))\(result.language.map { " · language \($0)" } ?? "")\n"
        md += "\n## Transcript\n\n"
        let paras = result.paragraphs()
        md += paras.isEmpty ? "_No speech recognised._\n"
            : paras.map { p in (p.start.map { "**[\(timestamp($0))]** " } ?? "") + p.text }.joined(separator: "\n\n") + "\n"
        return md
    }

    /// Saves the transcript as `Transcripts/<date>-<slug>.md` and indexes it for search. Returns the note's ref.
    @discardableResult
    public static func save(_ result: FileTranscript, sourceName: String, model: String, date: Date = Date(),
                            store: NotesStore) throws -> String {
        let title = (sourceName as NSString).deletingPathExtension
        let slug = title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .prefix(6).joined(separator: "-")
        var name = "\(fileFmt.string(from: date))-\(slug.isEmpty ? "audio" : slug)"
        var n = 2
        while FileManager.default.fileExists(atPath: store.root.appendingPathComponent("Transcripts/\(name).md").path) {
            name = "\(fileFmt.string(from: date))-\(slug.isEmpty ? "audio" : slug)-\(n)"; n += 1
        }
        try store.saveNote(folder: "Transcripts", filename: "\(name).md", title: title, date: date,
                           markdown: markdown(title: title, sourceName: sourceName, date: date, model: model, result: result),
                           kind: "transcript")
        return "Transcripts/\(name).md"
    }
}
