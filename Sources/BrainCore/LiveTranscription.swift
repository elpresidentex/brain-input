import Foundation

// Live dictation transcription: each stretch of speech is transcribed once, while I am still talking, so that after
// the hotkey comes up only the unfinished tail is left. Before this, the whole recording was transcribed again after
// release, and the wait grew by about 30 ms per second of audio (5 to 17 s for a five-minute dictation).

/// Splits the dictation stream into chunks for the speech engine. Unlike the meeting cutter, nothing is dropped:
/// the chunks are contiguous, so quiet words below the speech threshold still reach the engine (it has its own
/// silence gate). A chunk ends at a pause once it is long enough to give the model context, or at the quietest
/// moment of its last seconds when it reaches the length cap.
struct DictationCutter {
    static let frame = 1600                     // 100 ms at 16 kHz
    var threshold: Float = 0.004                // RMS above this is speech (same as the meeting cutter)
    /// A pause this long ends a chunk...
    var pauseFrames = 6                         // 0.6 s
    /// ...but only once the chunk holds this much audio. Short chunks lose context and, for whisper, risk a wrong
    /// language; the cost of a longer minimum is only a longer tail at release, which the cap bounds anyway.
    var minChunkSamples = 5 * 16000
    /// Hard cap. Parakeet's model window is 15 s; a chunk under it runs as one window with no internal merge.
    var maxChunkSamples = 14 * 16000
    /// Past this length a shorter pause is enough, so a sentence end is found before the cap forces a cut.
    var shortPauseAfterSamples = 9 * 16000
    var shortPauseFrames = 3                    // 0.3 s
    /// A forced cut looks this far back for the quietest stretch.
    var searchFrames = 30                       // 3 s

    private var pending: [Float] = []           // samples not yet framed
    private var chunk: [Float] = []
    private var frameRMS: [Float] = []          // one value per framed 100 ms of `chunk`
    private var silentRun = 0                   // trailing non-speech frames
    private var speechFrames = 0

    /// Audio of the chunk still open (for the live preview).
    var open: [Float] { chunk + pending }
    var openHasSpeech: Bool { speechFrames > 0 }

    /// Feeds samples; returns chunks that are finished, in order.
    mutating func feed(_ samples: [Float]) -> [[Float]] {
        pending += samples
        var out: [[Float]] = []
        var i = 0
        while pending.count - i >= Self.frame {
            let f = pending[i..<i + Self.frame]; i += Self.frame
            var sum: Float = 0; for v in f { sum += v * v }
            let rms = (sum / Float(Self.frame)).squareRoot()
            chunk += f; frameRMS.append(rms)
            if rms > threshold { speechFrames += 1; silentRun = 0 } else { silentRun += 1 }
            let pause = chunk.count >= shortPauseAfterSamples ? shortPauseFrames : pauseFrames
            if chunk.count >= minChunkSamples, speechFrames > 0, silentRun >= pause {
                out.append(take(frames: frameRMS.count))
            } else if chunk.count >= maxChunkSamples {
                out.append(take(frames: quietestCut()))
            }
        }
        pending.removeFirst(i)
        return out
    }

    /// Ends the stream: the open chunk, if any audio is left.
    mutating func flush() -> [Float]? {
        let rest = chunk + pending
        chunk = []; frameRMS = []; pending = []; silentRun = 0; speechFrames = 0
        return rest.isEmpty ? nil : rest
    }

    /// Frame count to cut after, when the cap forces a cut. First choice: the middle of the longest run of silent
    /// frames after the minimum chunk length (a sentence end, usually 0.3-0.5 s). Without a run of at least two
    /// frames: the middle of the quietest 300 ms of the last `searchFrames`. A single quiet frame is never enough on
    /// its own: the closure of a plosive ("suppor|t team") is 100 ms of near silence inside a word.
    func quietestCut() -> Int {
        let n = frameRMS.count
        guard n >= 3 else { return n }
        let first = min(n - 1, max(1, minChunkSamples / Self.frame))
        var bestStart = -1, bestLen = 0, runStart = -1
        for k in first..<n {
            if frameRMS[k] <= threshold {
                if runStart < 0 { runStart = k }
                let len = k - runStart + 1
                if len >= bestLen { bestLen = len; bestStart = runStart }     // ties: the later run, a longer chunk
            } else { runStart = -1 }
        }
        if bestLen >= 2 { return bestStart + bestLen / 2 + 1 }
        let from = max(1, n - searchFrames)
        var best = n - 2, bestEnergy = Float.infinity
        for k in from..<(n - 1) {
            let e = frameRMS[k - 1] + frameRMS[k] + frameRMS[k + 1]
            if e < bestEnergy { bestEnergy = e; best = k }
        }
        return best + 1
    }

    /// Removes the first `frames` frames from the open chunk and returns them; the rest starts the next chunk.
    private mutating func take(frames: Int) -> [Float] {
        let cut = frames * Self.frame
        let done = Array(chunk[..<cut])
        chunk.removeFirst(cut); frameRMS.removeFirst(frames)
        speechFrames = frameRMS.filter { $0 > threshold }.count
        silentRun = 0
        for v in frameRMS.reversed() { if v > threshold { break }; silentRun += 1 }
        return done
    }
}

/// What live transcription hands to the pipeline at release.
public struct LiveResult: Sendable {
    public var transcript: Transcript
    public var chunks: Int
    /// Release (finish called) to the last chunk's text.
    public var tailMs: Int
    /// Part of the tail spent on chunks that were already queued before release.
    public var backlogMs: Int
    /// Engine time spent on all chunks, during and after recording.
    public var engineMs: Int
    public var previewRuns: Int
    public var previewEngineMs: Int
}

/// Transcribes a dictation chunk by chunk while it is being recorded. Chunks run one at a time, in order, through
/// the shared speech engine. `finish(all:)` returns nil when the caller should fall back to one full pass: a chunk
/// failed, or nothing was recognised at all.
public actor IncrementalTranscriber {
    private let transcriber: Transcriber
    private let prompt: String?
    private var cutter: DictationCutter
    private var fed = 0                          // samples received so far
    private var texts: [Int: String] = [:]
    private var lengths: [Int: Int] = [:]
    private var stats: [Int: TranscribeStats] = [:]
    private var failures = 0
    private var enqueued = 0
    private var done = 0
    private var last: Task<Void, Never>?
    private var cancelled = false
    private var finished = false
    private var language: String?
    private var languagePinned = false
    private var engineMs = 0
    // Preview of the open chunk
    private var previewBusy = false
    private var previewText = ""
    private var previewSamples = 0
    private var openGeneration = 0               // bumped whenever a chunk closes
    private var provisional: [Int: String] = [:] // preview text of a closed chunk, shown until its real text arrives
    private var openStart = 0                    // absolute sample index where the open chunk begins
    private var ends: [Int: Int] = [:]           // absolute end sample of each chunk
    /// How far into the recording the text shown by preview() reaches, in samples (diagnostics: preview lag).
    public private(set) var previewCovers = 0
    /// Least new audio, in samples, before the preview runs again (0.15 s). Parakeet always runs a padded 15 s window
    /// (about 0.26 s whatever the length), so with a small floor the preview runs back to back and the text trails
    /// speech by about 0.4 s; a 0.5 s floor made it 0.7 s.
    public private(set) var minPreviewStep = 2_400
    private var lastPreviewMs = 0
    /// New audio needed before the next preview: at least as long as the last preview took, so a slow model (whisper,
    /// about 1 s a run) never queues previews faster than it can run them.
    public var previewStep: Int { max(minPreviewStep, lastPreviewMs * 16) }
    public func setMinPreviewStep(_ n: Int) { minPreviewStep = n }
    public private(set) var previewRuns = 0
    public private(set) var previewEngineMs = 0
    /// The preview transcribes the last `previewWindow` samples, reaching back across the chunk seam, and keeps only
    /// the words after it (by token timings), so the first words after a pause are heard with the sentence before
    /// them. Previewing the open chunk alone started every 5-14 s from a fraction of a second of audio. Off for an
    /// engine without token timings (whisper), which falls back to the open chunk.
    private var windowPreview = true
    public func setWindowPreview(_ on: Bool) { windowPreview = on }
    /// 14.5 s: under Parakeet's 15 s model window, so the preview stays one engine run.
    static let previewWindow = 232_000
    private var recent: [Float] = []             // the last fed samples, at least previewWindow of them
    private var recentStart = 0                  // absolute index of recent[0]

    public init(transcriber: Transcriber, prompt: String?) {
        self.transcriber = transcriber; self.prompt = prompt; cutter = DictationCutter()
    }

    init(transcriber: Transcriber, prompt: String?, cutter: DictationCutter) {
        self.transcriber = transcriber; self.prompt = prompt; self.cutter = cutter
    }

    public var samplesFed: Int { fed }
    /// Each chunk's length in samples and its text, in order (diagnostics and tests).
    public var chunkLog: [(samples: Int, text: String)] { (0..<enqueued).map { (lengths[$0] ?? 0, texts[$0] ?? "") } }
    public var chunksQueued: Int { enqueued }
    public var chunksDone: Int { done }
    public var previewInFlight: Bool { previewBusy }
    /// True while a chunk or preview is using the engine.
    public var engineBusy: Bool { done < enqueued || previewBusy }
    /// The preview may run with at most the chunk that just closed still in the engine: it then waits only for that
    /// one run (about 0.26 s on Parakeet) instead of skipping a turn, so the text does not stall at every chunk seam.
    private var previewMayRun: Bool { !previewBusy && enqueued - done <= 1 }

    public func feed(_ samples: [Float]) {
        guard !cancelled, !finished, !samples.isEmpty else { return }
        fed += samples.count
        recent += samples
        if recent.count > 2 * Self.previewWindow {
            let drop = recent.count - Self.previewWindow
            recent.removeFirst(drop); recentStart += drop
        }
        for c in cutter.feed(samples) { enqueue(c) }
    }

    /// Feeds samples that start at absolute index `start` of the recording. Overlap with what was already fed (a feed
    /// that arrives after finish topped up the recording) is dropped, so no audio is transcribed twice.
    public func feed(_ samples: [Float], from start: Int) {
        let skip = fed - start
        guard skip < samples.count else { return }
        feed(skip > 0 ? Array(samples[skip...]) : samples)
    }

    /// Stops all work; queued chunks never reach the engine.
    public func cancel() { cancelled = true; last = nil }
    public var isCancelled: Bool { cancelled }

    /// Text so far: every finished chunk, in order.
    public var committedText: String { Self.join((0..<enqueued).compactMap { texts[$0] }) }

    /// Committed text plus a preview of the open chunk. The preview only runs when the engine is (nearly) free and enough new
    /// audio arrived (previewStep), and never covers more than one chunk, so its cost is bounded. Cheap to call
    /// often: without new audio it returns at once.
    public func preview() async -> String {
        let open = cutter.open
        if !cancelled, previewMayRun, cutter.openHasSpeech, open.count > previewSamples + previewStep {
            previewBusy = true
            let generation = openGeneration
            let boundary = openStart, end = fed           // the open chunk is boundary..<end
            let from = windowPreview && open.count < Self.previewWindow ? max(recentStart, end - Self.previewWindow) : boundary
            let audio = from < boundary ? Array(recent[(from - recentStart)...]) : open
            let t0 = Date()
            let t = try? await transcriber.transcribe(samples: audio, prompt: prompt, language: pinnedLanguage)
            let ms = msSince(t0)
            previewBusy = false; previewRuns += 1; previewEngineMs += ms; lastPreviewMs = ms
            if let t {
                if from < boundary, t.tokens == nil, !t.text.trimmed.isEmpty {
                    windowPreview = false                 // no token timings: cannot cut at the seam
                } else if from < boundary || generation == openGeneration {
                    // A chunk that closed during the run moved the seam: cut at where the open chunk starts now,
                    // and hand the words of the chunk that just closed to its provisional text.
                    let cut = openStart
                    if cut <= end {
                        previewText = from < boundary ? Self.text(of: t, from: Double(cut - from) / 16000) : DictationPipeline.tidy(t.text)
                        previewSamples = end - cut
                        previewCovers = max(previewCovers, end)
                        if generation + 1 == openGeneration, from < boundary, texts[enqueued - 1] == nil {
                            let closed = Self.text(of: t, from: Double(boundary - from) / 16000, to: Double(cut - from) / 16000)
                            if !closed.isEmpty { provisional[enqueued - 1] = closed }
                        }
                    }
                }
            }
        }
        let shown = (0..<enqueued).compactMap { texts[$0] ?? provisional[$0] }
        return Self.join(shown + [previewText])
    }

    /// The words of `t` that end between `from` and `to` seconds (token timings; a word starts at a token with a
    /// leading space). By the end, not the start or middle: Parakeet stamps words a little early, so the first word
    /// after a seam often starts "before" it and was lost until its chunk committed. A chunk closes in a pause, so the
    /// last word of the closed chunk ends well before the seam.
    static func text(of t: Transcript, from: Double, to: Double = .infinity) -> String {
        guard let tokens = t.tokens else { return "" }
        var words: [(text: String, start: Double, end: Double)] = []
        for (k, tok) in tokens.enumerated() where !tok.text.isEmpty {
            if k == 0 || tok.text.hasPrefix(" ") || words.isEmpty { words.append((tok.text, tok.start, tok.end)) }
            else { words[words.count - 1].text += tok.text; words[words.count - 1].end = tok.end }
        }
        let kept = words.filter { $0.end > from && $0.end <= to }
        return DictationPipeline.tidy(kept.map(\.text).joined())
    }

    private func enqueue(_ samples: [Float]) {
        let i = enqueued; enqueued += 1
        lengths[i] = samples.count
        openStart += samples.count; ends[i] = openStart
        let previous = last
        if !previewText.isEmpty { provisional[i] = previewText }
        previewText = ""; previewSamples = 0; openGeneration += 1
        last = Task { [transcriber, prompt] in
            await previous?.value                                  // one at a time, in order
            if self.isCancelled { self.markDone(i, text: nil, stats: nil, ms: 0, failed: false, language: nil); return }
            let lang = self.pinnedLanguage
            let t0 = Date()
            do {
                let t = try await transcriber.transcribe(samples: samples, prompt: prompt, language: lang)
                self.markDone(i, text: DictationPipeline.tidy(t.text), stats: t.stats, ms: msSince(t0), failed: false,
                                    language: samples.count >= 3 * 16000 ? t.language : nil)
            } catch {
                self.markDone(i, text: nil, stats: nil, ms: msSince(t0), failed: true, language: nil)
            }
        }
    }

    private var pinnedLanguage: String? { languagePinned ? language : nil }

    private func markDone(_ i: Int, text: String?, stats s: TranscribeStats?, ms: Int, failed: Bool, language l: String?) {
        done += 1; engineMs += ms
        if failed { failures += 1 }
        if let text, !text.isEmpty { texts[i] = text }
        if let e = ends[i] { previewCovers = max(previewCovers, e) }
        if let s { stats[i] = s }
        // The first chunk of at least 3 s decides the language for the rest (whisper only; others report none).
        if !languagePinned, let l { language = l; languagePinned = true }
    }

    /// Called at release with the whole recording. Feeds whatever the live feed missed, closes the open chunk, waits
    /// for every chunk, and returns the joined transcript, or nil when the caller must do one full pass instead.
    public func finish(all samples: [Float]) async -> LiveResult? {
        let t0 = Date()
        if samples.count > fed { feed(Array(samples[fed...])) }
        finished = true                                            // late feeds from the live loop are ignored
        let backlog = last
        await backlog?.value
        let backlogMs = msSince(t0)
        if let rest = cutter.flush() { enqueue(rest) }
        await last?.value
        guard !cancelled, !Task.isCancelled, failures == 0 else { return nil }
        let text = committedText
        guard !text.isEmpty else { return nil }
        var tail = stats[enqueued - 1] ?? TranscribeStats()
        tail.startedAt = nil                                       // queue wait is measured by the pipeline, not here
        let t = Transcript(text: text, language: language, stats: tail)
        return LiveResult(transcript: t, chunks: enqueued, tailMs: msSince(t0), backlogMs: backlogMs, engineMs: engineMs,
                          previewRuns: previewRuns, previewEngineMs: previewEngineMs)
    }

    /// Chunk texts joined with single spaces (what FluidAudio's own long-audio path does at its window seams).
    static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmed }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Word-level edit distance, for comparing chunked against one-shot transcripts.
public enum WordDiff {
    public static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Substitutions + insertions + deletions needed to turn `a` into `b`, counted in words.
    public static func distance(_ a: String, _ b: String) -> Int {
        let x = words(a), y = words(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// Distance relative to the reference length (a word error rate against `reference`).
    public static func rate(_ hypothesis: String, reference: String) -> Double {
        let n = words(reference).count
        return n == 0 ? (words(hypothesis).isEmpty ? 0 : 1) : Double(distance(reference, hypothesis)) / Double(n)
    }
}

/// How long after a word is spoken it first shows up in the preview: the honest measure of a live preview. The
/// reference is one pass over the whole recording with token timings; each preview snapshot is aligned to the
/// reference words spoken so far (longest common subsequence), and a word counts as shown from the first snapshot
/// that matches it.
public enum PreviewLag {
    public struct Word: Sendable { public var text: String; public var end: Double }

    /// Reference words (as WordDiff.words splits them) with the time each one ends, from the engine's tokens.
    public static func words(from tokens: [TimedToken]) -> [Word] {
        var groups: [(text: String, end: Double)] = []
        for t in tokens {
            if groups.isEmpty || t.text.hasPrefix(" ") { groups.append((t.text, t.end)) }
            else { groups[groups.count - 1].text += t.text; groups[groups.count - 1].end = t.end }
        }
        return groups.flatMap { g in WordDiff.words(g.text).map { Word(text: $0, end: g.end) } }
    }

    /// First time each reference word was shown, or nil if no snapshot ever matched it. Snapshots are (time, text)
    /// in time order; a word can only match once it has been spoken (its end at most `slack` seconds later).
    public static func firstShown(reference: [Word], snapshots: [(t: Double, text: String)], slack: Double = 0.3) -> [Double?] {
        var shown = [Double?](repeating: nil, count: reference.count)
        for s in snapshots {
            let n = reference.firstIndex { $0.end > s.t + slack } ?? reference.count
            let hyp = WordDiff.words(s.text)
            guard n > 0, !hyp.isEmpty else { continue }
            // LCS between reference[0..<n] and hyp, then walk back to mark matched reference words.
            let m = hyp.count
            var dp = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
            for i in 1...n { for j in 1...m {
                dp[i][j] = reference[i - 1].text == hyp[j - 1] ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
            } }
            var i = n, j = m
            while i > 0, j > 0 {
                if reference[i - 1].text == hyp[j - 1], dp[i][j] == dp[i - 1][j - 1] + 1 {
                    if shown[i - 1] == nil { shown[i - 1] = s.t }
                    i -= 1; j -= 1
                } else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 } else { j -= 1 }
            }
        }
        return shown
    }

    /// One line: median, p90 and max of shown-minus-spoken, and how many words never showed.
    public static func summary(reference: [Word], shown: [Double?]) -> String {
        let lags = zip(reference, shown).compactMap { w, s in s.map { max(0, $0 - w.end) } }.sorted()
        guard !lags.isEmpty else { return "no word was ever shown" }
        return String(format: "word on screen after it was spoken: median %.2f s, p90 %.2f s, max %.2f s; %d of %d words never shown",
                      lags[lags.count / 2], lags[lags.count * 9 / 10], lags.last!, reference.count - lags.count, reference.count)
    }
}
