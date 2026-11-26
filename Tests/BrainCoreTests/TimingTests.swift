import XCTest
@testable import BrainCore

final class TimingTests: XCTestCase {
    func testPerfectLinearRelationshipIsDetected() {
        let x = (1...20).map(Double.init), y = x.map { 200 + 30 * $0 }
        let f = TimingReport.fit(x, y)
        XCTAssertEqual(f.pearson, 1, accuracy: 1e-9); XCTAssertEqual(f.spearman, 1, accuracy: 1e-9)
        XCTAssertEqual(f.slope, 30, accuracy: 1e-9); XCTAssertEqual(f.intercept, 200, accuracy: 1e-6)
    }

    func testMonotonicButNonLinearShowsInSpearman() {
        let x = (1...20).map(Double.init), y = x.map { $0 * $0 * $0 }
        let f = TimingReport.fit(x, y)
        XCTAssertEqual(f.spearman, 1, accuracy: 1e-9); XCTAssertLessThan(f.pearson, 1)
    }

    func testPipelineRecordsStageBreakdownAndSeed() async throws {
        let store = try tempStore()
        let p = DictationPipeline(transcriber: StatsTranscriber(), inserter: MockInserter(), reader: MockContextReader(), store: store)
        let rec = await p.process(samples: [Float](repeating: 0.1, count: 16000),
                                  seed: TraceSeed(stopMs: 12, previewInFlight: true, previewRuns: 3, previewEngineMs: 900, meetingActive: true))
        let d = try XCTUnwrap(rec?.timings.detail)
        XCTAssertEqual(d.stopMs, 12); XCTAssertTrue(d.previewInFlight); XCTAssertEqual(d.previewRuns, 3); XCTAssertTrue(d.meetingActive)
        XCTAssertEqual(d.engine, "fake"); XCTAssertEqual(d.inferenceMs, 40); XCTAssertEqual(d.loadMs, 7)
        XCTAssertGreaterThanOrEqual(d.queueWaitMs, 25)          // the fake engine starts 30 ms after the call
        XCTAssertFalse(d.thermal.isEmpty)
        // Survives storage, and old records without detail still decode.
        XCTAssertEqual(store.dictations().first?.timings.detail?.engine, "fake")
        var old = DictationRecord(); old.raw = "x"          // a record from before detail existed has no "detail" key
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let json = try enc.encode(old)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("\"detail\""))
        XCTAssertNoThrow(try JSONDecoder.iso.decode(DictationRecord.self, from: json))
    }

    func testReportNamesTheCauseOfASlowTranscription() throws {
        var recs: [DictationRecord] = []
        for i in 1...12 {   // normal: 50 ms per audio second
            var r = DictationRecord(); r.raw = String(repeating: "word ", count: i * 3)
            r.timings.audioMs = i * 2000; r.timings.transcribeMs = 200 + i * 100; r.timings.totalMs = r.timings.transcribeMs
            recs.append(r)
        }
        var slow = DictationRecord(); slow.raw = "just a few words"
        slow.timings.audioMs = 4000; slow.timings.transcribeMs = 5000
        var d = TimingDetail(); d.queueWaitMs = 4300; d.inferenceMs = 600; d.previewInFlight = true
        slow.timings.detail = d
        recs.append(slow)
        let text = TimingReport.render(recs)
        XCTAssertTrue(text.contains("SLOWER THAN LENGTH EXPLAINS"))
        XCTAssertTrue(text.contains("waited for engine (live preview was running) 4300 ms of 5000"), text)
        XCTAssertTrue(text.contains("TRANSCRIBE TIME VS LENGTH"))
    }
}

private final class StatsTranscriber: Transcriber, @unchecked Sendable {
    func transcribe(samples: [Float], prompt: String?) async throws -> Transcript {
        try await Task.sleep(for: .milliseconds(30))
        var s = TranscribeStats(); s.engine = "fake"; s.startedAt = Date(); s.loadMs = 7; s.inferenceMs = 40
        return Transcript(text: "hello there", language: "en", stats: s)
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
