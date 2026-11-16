import Foundation

public struct MeetingSegment: Codable, Equatable, Sendable {
    public var speaker: String     // "Me" (microphone) or "Them" (system audio)
    public var start: Double       // seconds since the recording began
    public var text: String
}

public struct MeetingInfo: Codable, Equatable, Sendable {
    public var title: String
    public var startedAt: Date
    public var participants: [String]
    public var app: String
    public init(title: String, startedAt: Date = Date(), participants: [String] = [], app: String = "") {
        self.title = title; self.startedAt = startedAt; self.participants = participants; self.app = app
    }
}

/// Cuts one audio stream into utterances at pauses, so each turn becomes its own timed segment.
struct UtteranceCutter {
    static let frame = 1600                 // 100 ms at 16 kHz
    var threshold: Float = 0.004
    var maxSeconds = 25.0
    private var pending: [Float] = []       // samples not yet framed
    private var chunk: [Float] = []
    private var preroll: [Float] = []
    private var chunkStart = 0              // absolute sample index of chunk[0]
    private var consumed = 0                // absolute sample index of the next frame
    private var silentFrames = 0
    private var speechFrames = 0

    /// Feeds samples; returns finished utterances with their start time in seconds.
    mutating func feed(_ samples: [Float], flush: Bool = false) -> [(start: Double, samples: [Float])] {
        pending += samples
        var out: [(Double, [Float])] = []
        var i = 0
        while pending.count - i >= Self.frame {
            let f = Array(pending[i..<i + Self.frame]); i += Self.frame
            var sum: Float = 0; for v in f { sum += v * v }
            let speech = (sum / Float(Self.frame)).squareRoot() > threshold
            if speechFrames == 0 && !speech {
                preroll = f                 // keep 100 ms before speech starts
            } else {
                if chunk.isEmpty { chunk = preroll; chunkStart = consumed - preroll.count; preroll = [] }
                chunk += f
                if speech { speechFrames += 1; silentFrames = 0 } else { silentFrames += 1 }
                let tooLong = Double(chunk.count) / 16000 >= maxSeconds
                if (silentFrames >= 10 && speechFrames >= 4) || tooLong { out.append(emit()) }
                else if silentFrames >= 10 { reset() }        // a click, not speech
            }
            consumed += Self.frame
        }
        pending.removeFirst(i)
        if flush {
            if speechFrames >= 4 { chunk += pending; out.append(emit()) }
            pending = []; reset()
        }
        return out
    }

    private mutating func emit() -> (Double, [Float]) {
        let r = (Double(max(0, chunkStart)) / 16000, chunk)
        reset()
        return r
    }
    private mutating func reset() { chunk = []; silentFrames = 0; speechFrames = 0 }
}

/// One meeting: two streams in, timed "Me"/"Them" segments out. Every finished segment is appended
/// to a journal file at once, so a crash loses at most the utterance being spoken.
public actor MeetingSession {
    public nonisolated let info: MeetingInfo
    public nonisolated let journal: URL
    private let transcriber: Transcriber
    private let prompt: String?
    private var cutters: [String: UtteranceCutter] = [:]
    private var segments: [MeetingSegment] = []
    private var jobs: [Task<Void, Never>] = []

    public init(info: MeetingInfo, transcriber: Transcriber, journalDir: URL, whisperPrompt: String? = nil) {
        self.info = info; self.transcriber = transcriber; self.prompt = whisperPrompt
        journal = journalDir.appendingPathComponent(".inprogress-\(Int(info.startedAt.timeIntervalSince1970)).jsonl")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        try? ((try? enc.encode(info)) ?? Data()).write(to: journal)
    }

    public func feed(_ samples: [Float], speaker: String) {
        let done = cutters[speaker, default: UtteranceCutter()].feed(samples)
        for u in done { enqueue(u.samples, start: u.start, speaker: speaker) }
    }

    private func enqueue(_ samples: [Float], start: Double, speaker: String) {
        let previous = jobs.last
        jobs.append(Task {
            await previous?.value      // keep journal order stable
            guard let t = try? await transcriber.transcribe(samples: samples, prompt: prompt) else { return }
            let text = DictationPipeline.tidy(t.text)
            if !text.isEmpty { self.append(MeetingSegment(speaker: speaker, start: start, text: text)) }
        })
    }

    private func append(_ s: MeetingSegment) {
        segments.append(s)
        guard let line = try? JSONEncoder().encode(s), let h = try? FileHandle(forWritingTo: journal) else { return }
        h.seekToEndOfFile(); h.write(Data("\n".utf8) + line); try? h.close()
    }

    public var segmentCount: Int { segments.count }

    /// Flushes both streams, waits for transcription, returns the segments in time order.
    public func finish() async -> [MeetingSegment] {
        for speaker in Array(cutters.keys) {
            for u in cutters[speaker]!.feed([], flush: true) { enqueue(u.samples, start: u.start, speaker: speaker) }
        }
        for j in jobs { await j.value }
        return segments.sorted { $0.start < $1.start }
    }

    /// Reads back a journal left behind by a crash.
    public static func recover(_ journal: URL) -> (MeetingInfo, [MeetingSegment])? {
        guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let first = lines.first, let info = try? dec.decode(MeetingInfo.self, from: Data(first.utf8)) else { return nil }
        let segs = lines.dropFirst().compactMap { try? dec.decode(MeetingSegment.self, from: Data($0.utf8)) }
        return (info, segs.sorted { $0.start < $1.start })
    }
}

public enum MeetingNotes {
    static let system = """
    You write the notes for a meeting from its transcript. Lines marked "Me" are the note owner (their microphone); lines marked \
    "Them" are everyone else on the call, not told apart. The transcript comes from speech recognition and may contain errors.

    Reply in Markdown with exactly these parts, in this order, and nothing else:
    TITLE: a title of at most eight words (one line)
    ## Summary
    Three to six sentences on what was discussed and concluded.
    ## Decisions
    A bullet per decision that was actually made. Write "- None recorded" if there were none.
    ## Action items
    A bullet per task someone took on, starting with who ("Me:" or "Them:" or a name if one was said) and including any date \
    mentioned. Write "- None recorded" if there were none.

    Use only what the transcript says. Do not invent names, dates or commitments. Write in the main language of the transcript.
    """

    static func clock(_ s: Double) -> String { String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) }

    /// Consecutive segments of one speaker are joined into a turn.
    public static func transcript(_ segments: [MeetingSegment]) -> String {
        var lines: [String] = []; var last = ""
        for s in segments {
            if s.speaker == last, !lines.isEmpty { lines[lines.count - 1] += " " + s.text }
            else { lines.append("**\(s.speaker)** (\(clock(s.start))): \(s.text)"); last = s.speaker }
        }
        return lines.joined(separator: "\n\n")
    }

    /// Summarises (when a model is available) and writes the Markdown note. Returns its URL.
    @discardableResult
    public static func write(info: MeetingInfo, segments: [MeetingSegment], endedAt: Date = Date(), model: LanguageModel?,
                             store: NotesStore) async throws -> URL {
        let body = transcript(segments)
        let spokenWords = segments.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }   // under 10: not worth a paid summary
        var title = info.title
        var sections = "## Summary\n\n_Not generated: " + (spokenWords < 10 ? "too little was said to summarise._" : "no API key was set when this meeting ended._")
            + "\n\n## Decisions\n\n_Not generated._\n\n## Action items\n\n_Not generated._"
        if let model, spokenWords >= 10 {
            do {
                let out = try await model.complete(system: system, user: "<transcript>\n\(body)\n</transcript>", maxTokens: 3000).trimmed
                if let range = out.range(of: "## Summary") {
                    let head = out[..<range.lowerBound]
                    if let t = head.components(separatedBy: "\n").first(where: { $0.hasPrefix("TITLE:") })?.dropFirst(6).trimmingCharacters(in: .whitespaces),
                       !t.isEmpty, info.title.isEmpty || info.title.hasPrefix("Meeting") { title = t }
                    sections = String(out[range.lowerBound...])
                }
            } catch { sections = sections.replacingOccurrences(of: "no API key was set when this meeting ended", with: "the summary call failed (\(String(describing: error).prefix(80)))") }
        }
        if title.isEmpty { title = "Meeting" }
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
        let fileFmt = DateFormatter(); fileFmt.dateFormat = "yyyy-MM-dd-HHmm"
        let minutes = max(1, Int(endedAt.timeIntervalSince(info.startedAt) / 60))
        var md = "# \(title)\n\n- Date: \(dateFmt.string(from: info.startedAt)) (\(minutes) min)\n"
        if !info.app.isEmpty { md += "- Call app: \(info.app)\n" }
        md += "- Participants: \(info.participants.isEmpty ? "not known (no calendar event found)" : info.participants.joined(separator: ", "))\n"
        md += "- Recorded locally by Brain Input; \"Me\" is the microphone, \"Them\" is the call audio.\n\n"
        md += sections + "\n\n## Transcript\n\n" + (body.isEmpty ? "_Nothing was transcribed._" : body) + "\n"
        let slug = title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(6).joined(separator: "-")
        return try store.saveNote(folder: "Meetings", filename: "\(fileFmt.string(from: info.startedAt))-\(slug.isEmpty ? "meeting" : slug).md",
                                  title: title, date: info.startedAt, markdown: md)
    }

    /// Turns journals left by a crash into notes. Returns how many were recovered.
    @discardableResult
    public static func recoverAll(store: NotesStore, model: LanguageModel? = nil, except: URL? = nil) async -> Int {
        let dir = store.root.appendingPathComponent("Meetings")
        var n = 0
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix(".inprogress-") {
            let url = dir.appendingPathComponent(f)
            guard url != except, let (info, segs) = MeetingSession.recover(url) else { continue }
            var i = info; if !i.title.contains("recovered") { i.title = (i.title.isEmpty ? "Meeting" : i.title) + " (recovered)" }
            let end = info.startedAt.addingTimeInterval((segs.last?.start ?? 0) + 30)
            if (try? await write(info: i, segments: segs, endedAt: end, model: model, store: store)) != nil { try? FileManager.default.removeItem(at: url); n += 1 }
        }
        return n
    }
}

/// Decides whether a process holding the microphone looks like a call.
public enum CallDetector {
    public static let apps: [(prefix: String, name: String)] = [
        ("us.zoom.xos", "Zoom"), ("com.microsoft.teams", "Microsoft Teams"), ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.apple.FaceTime", "FaceTime"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "WhatsApp"), ("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit.GPU", "Safari"), ("company.thebrowser.Browser", "Arc"), ("org.mozilla.firefox", "Firefox"),
        ("com.microsoft.edgemac", "Edge"), ("com.brave.Browser", "Brave"),
    ]
    /// First known call app among the bundle IDs currently capturing microphone input.
    public static func match(micUsers: [String]) -> String? {
        for id in micUsers { if let hit = apps.first(where: { id.hasPrefix($0.prefix) }) { return hit.name } }
        return nil
    }
}
