import XCTest
@testable import BrainCore

final class MeetingTests: XCTestCase {
    func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16000)).map { Float(sin(Double($0) * 0.2)) * 0.2 } }
    func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16000)) }

    func testCutterSplitsAtPausesAndKeepsTimes() {
        var c = UtteranceCutter()
        var out = c.feed(silence(2) + tone(3) + silence(2) + tone(1.5))
        XCTAssertEqual(out.count, 1); XCTAssertEqual(out[0].start, 1.9, accuracy: 0.11)
        XCTAssertEqual(Double(out[0].samples.count) / 16000, 4.1, accuracy: 0.2)
        out = c.feed([], flush: true)
        XCTAssertEqual(out.count, 1); XCTAssertEqual(out[0].start, 6.9, accuracy: 0.11)
        var long = UtteranceCutter(); XCTAssertEqual(long.feed(tone(60)).count, 2, "long speech is cut every 25 s")
        var quiet = UtteranceCutter(); XCTAssertTrue(quiet.feed(silence(30), flush: true).isEmpty)
    }

    func testCallDetection() {
        XCTAssertEqual(CallDetector.match(micUsers: ["com.apple.controlcenter", "us.zoom.xos"]), "Zoom")
        XCTAssertEqual(CallDetector.match(micUsers: ["com.google.Chrome.helper"]), "Chrome")
        XCTAssertEqual(CallDetector.match(micUsers: ["com.microsoft.teams2"]), "Microsoft Teams")
        XCTAssertNil(CallDetector.match(micUsers: ["com.prakashjoshipax.VoiceInk", "com.arminbognar.BrainInput"]))
    }

    func testSessionJournalNoteAndCrashRecovery() async throws {
        let store = try tempStore(); let dir = store.root.appendingPathComponent("Meetings")
        let info = MeetingInfo(title: "", participants: ["Thomas Weber"], app: "Zoom")
        let session = MeetingSession(info: info, transcriber: MockTranscriber("We ship on Friday."), journalDir: dir)
        await session.feed(tone(2) + silence(2), speaker: "Me")
        await session.feed(silence(5) + tone(2) + silence(2), speaker: "Them")
        await session.feed(silence(6) + tone(2), speaker: "Me")
        // Crash now: the journal alone must already hold the finished utterances.
        try await Task.sleep(for: .milliseconds(200))
        let (rInfo, rSegs) = try XCTUnwrap(MeetingSession.recover(session.journal))
        XCTAssertEqual(rInfo.participants, ["Thomas Weber"]); XCTAssertEqual(rSegs.map(\.speaker), ["Me", "Them"])

        let segs = await session.finish()
        XCTAssertEqual(segs.map(\.speaker), ["Me", "Them", "Me"])
        XCTAssertEqual(segs[1].start, 4.9, accuracy: 0.11)
        let model = MockLanguageModel("TITLE: Ship date\n## Summary\nThey agreed to ship.\n## Decisions\n- Ship on Friday\n## Action items\n- Me: prepare the release")
        let url = try await MeetingNotes.write(info: info, segments: segs, model: model, store: store)
        let md = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(md.hasPrefix("# Ship date\n")); XCTAssertTrue(md.contains("Participants: Thomas Weber"))
        XCTAssertTrue(md.contains("- Ship on Friday")); XCTAssertTrue(md.contains("**Them** (00:04): We ship on Friday."))
        XCTAssertTrue(model.calls[0].user.contains("**Me** (00:00)"))
        XCTAssertEqual(store.meetings().first?.title, "Ship date")
        XCTAssertEqual(store.search("release", kind: "meeting").count, 1)

        // Recovery writes a note from the leftover journal, without a model.
        let n = await MeetingNotes.recoverAll(store: store)
        XCTAssertEqual(n, 1)
        XCTAssertTrue(store.meetings().contains { $0.title == "Meeting (recovered)" })
        let recovered = try XCTUnwrap(store.read(ref: store.meetings().first { $0.title.contains("recovered") }!.ref))
        XCTAssertTrue(recovered.contains("_Not generated")); XCTAssertTrue(recovered.contains("**Me** (00:00): We ship on Friday."))
    }
}
