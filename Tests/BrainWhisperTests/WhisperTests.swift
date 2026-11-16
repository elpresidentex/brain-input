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
