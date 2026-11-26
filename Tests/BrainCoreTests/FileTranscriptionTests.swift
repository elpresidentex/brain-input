import XCTest
@testable import BrainCore

private func tone(_ s: Double) -> [Float] { (0..<Int(s * 16000)).map { Float(sin(Double($0) * 0.2)) * 0.2 } }
private func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * 16000)) }

/// Records each call; answers with `reply`, by default "part N." and language "de".
private final class RecordingTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(samples: Int, language: String?)] = []
    var reply: (Int, [Float]) -> Transcript = { i, _ in Transcript(text: "  part \(i). ", language: "de") }
    func transcribe(samples: [Float], prompt: String?) async throws -> Transcript {
        try await transcribe(samples: samples, prompt: prompt, language: nil)
    }
    func transcribe(samples: [Float], prompt: String?, language: String?) async throws -> Transcript {
        let i: Int = lock.withLock { calls.append((samples.count, language)); return calls.count }
        return reply(i, samples)
    }
}

/// Tokens the way FluidAudio reports them: word pieces with a leading space at word starts.
private func tokens(_ words: [(String, Double, Double)]) -> [TimedToken] { words.map { TimedToken(text: $0.0, start: $0.1, end: $0.2) } }

final class FileTranscriptionTests: XCTestCase {
    func testWholeFileGoesToTheEngineInOneCall() async throws {
        let audio = tone(720)                                           // 12 minutes, no pauses at all
        let engine = RecordingTranscriber()
        let log = ProgressLog()
        let r = try await FileTranscription.run(samples: audio, transcriber: engine, prompt: nil) { await log.add($0) }
        XCTAssertEqual(engine.calls.count, 1, "files must not be cut: every cut costs accuracy")
        XCTAssertEqual(engine.calls[0].samples, audio.count)
        XCTAssertNil(engine.calls[0].language, "the language must be detected, not fixed")
        XCTAssertEqual(r.text, "part 1.")
        XCTAssertEqual(r.language, "de")
        XCTAssertEqual(r.segments.first?.start, 0)
        XCTAssertEqual(r.audioSeconds, 720, accuracy: 1e-9)
        let p = await log.values
        XCTAssertEqual(p, [0, 1])
    }

    func testTokenTimingsGiveSentenceTimestampsAndPauseParagraphs() async throws {
        let toks = tokens([(" Hallo", 1.0, 1.4), (" zusammen", 1.4, 2.0), (".", 2.0, 2.1),
                           (" Haupt", 3.0, 3.3), ("bahnhofs", 3.3, 3.9), ("-", 3.9, 4.0), (" und", 4.0, 4.2), (" Vorort", 4.2, 5.0), (".", 5.0, 5.1),
                           (" Weiter", 30.0, 30.4), ("?", 30.4, 30.5), (" Ja", 31.0, 31.2)])
        let engine = RecordingTranscriber()
        engine.reply = { _, _ in Transcript(text: "Hallo zusammen. Hauptbahnhofs- und Vorort. Weiter? Ja", tokens: toks) }
        let r = try await FileTranscription.run(samples: tone(40), transcriber: engine, prompt: nil)
        XCTAssertEqual(r.segments.map(\.text), ["Hallo zusammen.", "Hauptbahnhofs- und Vorort.", "Weiter?", "Ja"])
        XCTAssertEqual(r.segments.map(\.start), [1.0, 3.0, 30.0, 31.0])
        XCTAssertEqual(r.segments[2].pauseBefore, 24.9, accuracy: 1e-9)
        // A new paragraph only at the long pause after 20 s, never inside a sentence.
        XCTAssertEqual(r.text, "Hallo zusammen. Hauptbahnhofs- und Vorort.\n\nWeiter? Ja")
        let md = FileTranscription.markdown(title: "t", sourceName: "t.ogg", date: Date(), model: "parakeet", result: r)
        XCTAssertTrue(md.contains("**[00:01]** Hallo zusammen.") && md.contains("**[00:30]** Weiter? Ja"), md)
    }

    func testTokensThatDoNotMatchTheTextAreIgnored() {
        let t = Transcript(text: "Eins. Zwei.", tokens: tokens([(" Drei", 0, 1)]))
        let s = FileTranscription.sentences(t, offset: 10)
        XCTAssertEqual(s.map(\.text), ["Eins.", "Zwei."])
        XCTAssertEqual(s.map(\.start), [10, nil], "without usable timings only the span start is known")
    }

    func testParagraphsWithoutTimingsBreakByLength() {
        let sentence = String(repeating: "wort ", count: 40).trimmed + "."
        let r = FileTranscript(segments: [.init(start: 0, text: sentence)] + (0..<5).map { _ in .init(start: nil, text: sentence) },
                               language: "de", audioSeconds: 60, engineMs: 0)
        let p = r.paragraphs()
        XCTAssertGreaterThan(p.count, 1)
        XCTAssertTrue(p.allSatisfy { $0.text.hasSuffix(".") })
        XCTAssertEqual(p.map(\.text).joined(separator: " "), r.segments.map(\.text).joined(separator: " "), "text lost or changed")
    }

    func testCancelDuringTheCallDiscardsTheResult() async throws {
        let engine = RecordingTranscriber()
        engine.reply = { _, _ in withUnsafeCurrentTask { $0?.cancel() }; return Transcript(text: "too late.") }
        do { _ = try await FileTranscription.run(samples: tone(5), transcriber: engine, prompt: nil); XCTFail("expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(engine.calls.count, 1)
    }

    func testCancelBeforeTheCallSkipsTheEngine() async throws {
        let engine = RecordingTranscriber()
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await FileTranscription.run(samples: tone(5), transcriber: engine, prompt: nil) }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(engine.calls.count, 0)
    }

    func testSavedTranscriptIsSearchableAndSurvivesReindex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bi-transcripts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let r = FileTranscript(segments: [.init(start: 0, text: "Welcome to the quarterly roadmap."), .init(start: 75, text: "Thanks, bye.")],
                               language: "en", audioSeconds: 80, engineMs: 10)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let ref = try FileTranscription.save(r, sourceName: "Voice Memo 12.m4a", model: "parakeet", date: date, store: store)
        XCTAssertTrue(ref.hasPrefix("Transcripts/") && ref.hasSuffix("-voice-memo-12.md"), ref)
        let ref2 = try FileTranscription.save(r, sourceName: "Voice Memo 12.m4a", model: "parakeet", date: date, store: store)
        XCTAssertNotEqual(ref, ref2, "a second transcript of the same file overwrote the first")
        let md = try XCTUnwrap(store.read(ref: ref))
        XCTAssertTrue(md.contains("# Voice Memo 12\n"), md)
        XCTAssertTrue(md.contains("**[00:00]** Welcome to the quarterly roadmap."), md)
        XCTAssertTrue(md.contains("**[01:15]** Thanks, bye."), md)
        XCTAssertEqual(store.search("roadmap", kind: "transcript").count, 2)
        XCTAssertTrue(store.meetings().isEmpty, "transcripts must not show up as meetings")
        XCTAssertEqual(store.transcripts().count, 2)
        try store.reindex()
        XCTAssertEqual(store.transcripts().count, 2)
        XCTAssertEqual(store.search("roadmap").first?.kind, "transcript")
    }

    func testTimestampFormat() {
        XCTAssertEqual(FileTranscription.timestamp(0), "00:00")
        XCTAssertEqual(FileTranscription.timestamp(125.7), "02:05")
        XCTAssertEqual(FileTranscription.timestamp(3725), "1:02:05")
    }
}

private actor ProgressLog {
    var values: [Double] = []
    func add(_ v: Double) { values.append(v) }
}
