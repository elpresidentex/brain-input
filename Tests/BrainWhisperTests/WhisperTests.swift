import XCTest
import BrainCore
@testable import BrainWhisper

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/audio")
func samples(_ name: String) throws -> [Float] { try AudioLoader.load16kMono(fixtures.appendingPathComponent("\(name).wav")) }

/// One shared model for the whole test run (loading takes seconds).
enum Shared {
    static let transcriber: WhisperTranscriber? = {
        // Metal-only and a private support folder: no Core ML compile, nothing written to the real one.
        setenv("BRAININPUT_COREML", "0", 1)
        setenv("BRAININPUT_SUPPORT", FileManager.default.temporaryDirectory.appendingPathComponent("bi-support-tests").path, 1)
        return ModelLocator.path().map { WhisperTranscriber(modelPath: $0) }
    }()
    static func get() throws -> WhisperTranscriber {
        guard let t = transcriber else { throw XCTSkip("whisper model not found in \(ModelLocator.modelsDir.path)") }
        return t
    }
}

final class WhisperTests: XCTestCase {
    // Runs last (alphabetical): free the Metal context before the process exits.
    func testZZUnload() async { await Shared.transcriber?.unload() }

    func testEnglishFixture() async throws {
        let t = try await Shared.get().transcribe(samples: try samples("en_short"), prompt: nil)
        XCTAssertEqual(t.language, "en")
        XCTAssertTrue(t.text.lowercased().contains("report by friday"), t.text)
    }

    func testGermanFixtureIsDetectedAutomatically() async throws {
        let t = try await Shared.get().transcribe(samples: try samples("de_short"), prompt: nil)
        XCTAssertEqual(t.language, "de")
        XCTAssertTrue(t.text.contains("Bericht bis Freitag"), t.text)
    }

    func testDictionaryPromptFixesAMisheardName() async throws {
        let without = try await Shared.get().transcribe(samples: try samples("en_terms"), prompt: nil)
        let with = try await Shared.get().transcribe(samples: try samples("en_terms"), prompt: "Katarzyna, Kubernetes, Terraform.")
        XCTAssertFalse(without.text.contains("Katarzyna"), "fixture should be misheard without help: \(without.text)")
        XCTAssertTrue(with.text.contains("Katarzyna"), with.text)
    }

    /// Two fixture files as the two streams of a call: real whisper, real chunking, a real note on disk.
    func testTwoSidedMeetingBecomesMeAndThemTranscript() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bi-m-\(UUID().uuidString)")
        let store = try NotesStore(root: dir)
        let gap = { (s: Double) in [Float](repeating: 0, count: Int(s * 16000)) }
        let me1 = try samples("meeting_me_1"), them1 = try samples("meeting_them_1"), me2 = try samples("meeting_me_2")
        let me = me1 + gap(Double(them1.count) / 16000 + 3) + me2 + gap(2)
        let them = gap(Double(me1.count) / 16000 + 1.5) + them1 + gap(8)
        let session = MeetingSession(info: MeetingInfo(title: "Launch sync", app: "Zoom"), transcriber: try Shared.get(), journalDir: dir.appendingPathComponent("Meetings"))
        for i in stride(from: 0, to: max(me.count, them.count), by: 8000) {       // half-second buffers, like live capture
            if i < me.count { await session.feed(Array(me[i..<min(i + 8000, me.count)]), speaker: "Me") }
            if i < them.count { await session.feed(Array(them[i..<min(i + 8000, them.count)]), speaker: "Them") }
        }
        let segs = await session.finish()
        XCTAssertEqual(segs.map(\.speaker), ["Me", "Them", "Me"], "\(segs)")
        XCTAssertTrue(segs[0].text.contains("Thomas"), segs[0].text)
        XCTAssertTrue(segs[1].text.lowercased().contains("december"), segs[1].text)
        XCTAssertTrue(segs[2].text.contains("announcement"), segs[2].text)
        let url = try await MeetingNotes.write(info: MeetingInfo(title: "Launch sync", app: "Zoom"), segments: segs, model: nil, store: store)
        let md = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(md.contains("**Them**")); XCTAssertTrue(md.contains("# Launch sync"))
        print("MEETING NOTE >>>\n\(md)<<<")
    }

    func testSilenceGivesEmptyText() async throws {
        let t = try await Shared.get().transcribe(samples: [Float](repeating: 0, count: 32000), prompt: nil)
        XCTAssertEqual(t.text, "")
    }

    func testFullPipelineFromAudioToInsertedText() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bi-w-\(UUID().uuidString)")
        let store = try NotesStore(root: dir); let ins = MockInserter()
        let p = DictationPipeline(transcriber: try Shared.get(), inserter: ins, reader: MockContextReader(), store: store)
        let rec = await p.process(samples: try samples("en_short"))
        XCTAssertTrue(ins.field.lowercased().contains("report"), ins.field)
        XCTAssertEqual(store.dictations().first?.id, rec?.id)
    }
}

/// Chunked (live) against one-shot transcription of the long fixtures, on the real engines.
final class LiveFixtureTests: XCTestCase {
    func compare(_ engine: Transcriber, _ name: String, loops: Int, maxRate: Double) async throws {
        let clip = try samples(name)
        let audio = (0..<loops).flatMap { _ in clip + [Float](repeating: 0, count: 16000) }
        let one = try await engine.transcribe(samples: audio, prompt: nil)
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        for i in stride(from: 0, to: audio.count, by: 1600) { await live.feed(Array(audio[i..<min(i + 1600, audio.count)]), from: i) }
        let finished = await live.finish(all: audio)
        let r = try XCTUnwrap(finished, "live transcription fell back")
        let rate = WordDiff.rate(r.transcript.text, reference: one.text)
        print(String(format: "LIVE %@ x%d: %d chunks, word difference %d of %d (%.1f%%)\n  one:  %@\n  live: %@", name, loops, r.chunks,
                     WordDiff.distance(one.text, r.transcript.text), WordDiff.words(one.text).count, rate * 100, one.text, r.transcript.text))
        XCTAssertGreaterThan(r.chunks, 1, "the fixture must actually be chunked")
        XCTAssertLessThanOrEqual(rate, maxRate)
    }

    func testWhisperChunkedMatchesOneShotEnglish() async throws { try await compare(try Shared.get(), "en_long", loops: 1, maxRate: 0.05) }
    func testWhisperChunkedMatchesOneShotGerman() async throws { try await compare(try Shared.get(), "de_long", loops: 1, maxRate: 0.05) }

    static let parakeet = ParakeetTranscriber()
    func parakeet() throws -> ParakeetTranscriber {
        guard ParakeetTranscriber.isInstalled else { throw XCTSkip("Parakeet v3 not installed in \(ParakeetTranscriber.cacheDirectory.path)") }
        return Self.parakeet
    }
    func testParakeetChunkedMatchesOneShotEnglish() async throws { try await compare(try parakeet(), "en_long", loops: 4, maxRate: 0.03) }
    func testParakeetChunkedMatchesOneShotGerman() async throws { try await compare(try parakeet(), "de_long", loops: 4, maxRate: 0.03) }
    func testZZParakeetUnload() async { await Self.parakeet.unload() }
}

final class FileLoadingTests: XCTestCase {
    /// The same speech as m4a (AVAudioFile) and inside a video-type container (AVAssetReader fallback) loads to about the
    /// same 16 kHz samples as the wav.
    func testCompressedAndVideoContainersLoad() async throws {
        let wav = fixtures.appendingPathComponent("en_short.wav")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bi-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let reference = try AudioLoader.load16kMono(wav)
        for (name, args) in [("a.m4a", ["-f", "m4af", "-d", "aac"]), ("a.mp4", ["-f", "mp4f", "-d", "aac"]), ("a.caf", ["-f", "caff", "-d", "LEF32@44100", "-c", "2"])] {
            let out = dir.appendingPathComponent(name)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert"); p.arguments = args + [wav.path, out.path]
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, name)
            let s = try await AudioLoader.loadAny16kMono(out)
            XCTAssertEqual(Double(s.count), Double(reference.count), accuracy: 16000 * 0.1, name)
        }
    }

    func testFileWithoutAudioFailsClearly() async throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("bi-notaudio-\(UUID().uuidString).mp3")
        try Data("not audio".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        do { _ = try await AudioLoader.loadAny16kMono(f); XCTFail("expected an error") } catch {}
    }

    /// On Parakeet a file under five minutes must come out exactly as one pass of the model, with every sentence
    /// timed from the token timings.
    func testFileTranscriptionOnParakeetMatchesOnePass() async throws {
        guard ParakeetTranscriber.isInstalled else { throw XCTSkip("Parakeet not installed") }
        let p = ParakeetTranscriber()
        let audio = try samples("de_long") + [Float](repeating: 0, count: 16000) + (try samples("en_long"))
        let one = try await p.transcribe(samples: audio, prompt: nil)
        XCTAssertEqual(one.tokens?.map(\.text).joined().trimmingCharacters(in: .whitespaces), one.text, "token timings no longer add up to the text")
        let r = try await FileTranscription.run(samples: audio, transcriber: p, prompt: nil)
        XCTAssertEqual(r.paragraphs().map(\.text).joined(separator: " "), one.text)
        XCTAssertGreaterThan(r.segments.count, 1)
        XCTAssertTrue(r.segments.allSatisfy { $0.start != nil }, "a sentence lost its timestamp")
        await p.unload()
    }

    func testFileTranscriptionOnRealModel() async throws {
        let audio = try samples("en_long")
        let r = try await FileTranscription.run(samples: audio, transcriber: try Shared.get(), prompt: nil)
        XCTAssertEqual(r.language, "en")
        XCTAssertFalse(r.text.isEmpty)
        let one = try await Shared.get().transcribe(samples: audio, prompt: nil)
        XCTAssertLessThan(WordDiff.rate(r.text, reference: one.text), 0.1, r.text)
    }
}
