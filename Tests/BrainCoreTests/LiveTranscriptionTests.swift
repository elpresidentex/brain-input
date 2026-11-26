import XCTest
@testable import BrainCore

private func tone(_ s: Double, amp: Float = 0.2) -> [Float] { (0..<Int(s * 16000)).map { Float(sin(Double($0) * 0.2)) * amp } }
private func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * 16000)) }

/// Answers each call from a closure, records what it was given, and can be slowed down or made to fail.
private final class ScriptedTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(samples: Int, language: String?)] = []
    var calls: [(samples: Int, language: String?)] { lock.withLock { _calls } }
    let reply: @Sendable (_ index: Int, _ samples: [Float]) async throws -> Transcript
    init(reply: @escaping @Sendable (Int, [Float]) async throws -> Transcript) { self.reply = reply }
    func transcribe(samples: [Float], prompt: String?) async throws -> Transcript {
        try await transcribe(samples: samples, prompt: prompt, language: nil)
    }
    func transcribe(samples: [Float], prompt: String?, language: String?) async throws -> Transcript {
        let i: Int = lock.withLock { _calls.append((samples.count, language)); return _calls.count - 1 }
        return try await reply(i, samples)
    }
}

final class DictationCutterTests: XCTestCase {
    func testChunksAreContiguousAndLoseNothing() {
        var c = DictationCutter()
        var input: [Float] = []
        for _ in 0..<5 { input += tone(4) + silence(0.8) + tone(3, amp: 0.002) + silence(0.2) }   // includes quiet speech
        var out: [[Float]] = []
        for i in stride(from: 0, to: input.count, by: 1234) { out += c.feed(Array(input[i..<min(i + 1234, input.count)])) }
        if let rest = c.flush() { out.append(rest) }
        XCTAssertGreaterThan(out.count, 1)
        XCTAssertEqual(out.flatMap { $0 }, input, "chunks concatenate back to the exact input, quiet parts included")
    }

    func testPauseEndsAChunkOnlyAfterTheMinimumLength() {
        var c = DictationCutter()
        XCTAssertTrue(c.feed(tone(2) + silence(1) + tone(2)).isEmpty, "4 s is under the 5 s minimum, the pause is kept inside")
        let out = c.feed(tone(2) + silence(0.7))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(Double(out[0].count) / 16000, 7.6, accuracy: 0.11, "cut once 0.6 s of pause follows 5 s of audio")
    }

    func testShorterPauseIsEnoughInALongChunk() {
        var c = DictationCutter()
        let out = c.feed(tone(9.5) + silence(0.35) + tone(1))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(Double(out[0].count) / 16000, 9.8, accuracy: 0.11)
    }

    func testForcedCutAtTheCapPrefersASentencePauseOverAPlosiveGap() {
        var c = DictationCutter()
        // 6 s speech, 0.25 s pause (too short to cut at 6 s), more speech with one 100 ms gap near the end.
        let audio = tone(6) + silence(0.25) + tone(6.5) + silence(0.1) + tone(3)
        let out = c.feed(audio)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(Double(out[0].count) / 16000, 6.2, accuracy: 0.11, "cut inside the 0.25 s pause, not at the 100 ms gap")
        XCTAssertLessThanOrEqual(out[0].count, c.maxChunkSamples)
    }

    func testForcedCutWithoutAnyPauseStaysUnderTheCap() {
        var c = DictationCutter()
        let out = c.feed(tone(40))
        XCTAssertGreaterThanOrEqual(out.count, 2)
        XCTAssertTrue(out.allSatisfy { $0.count <= c.maxChunkSamples })
        XCTAssertEqual(out.flatMap { $0 } + (c.flush() ?? []), tone(40))
    }

    func testSilenceOnlyStillFlushes() {
        var c = DictationCutter()
        XCTAssertTrue(c.feed(silence(3)).isEmpty)
        XCTAssertEqual(c.flush()?.count, 48_000, "the engine's own gate decides about silence")
        XCTAssertNil(c.flush())
    }
}

final class IncrementalTranscriberTests: XCTestCase {
    /// Five 5.6 s utterances, each followed by a pause long enough to cut.
    private let speech: [Float] = (0..<5).flatMap { _ in tone(5) + silence(0.6) }

    func testChunksKeepTheirOrderWhenTheEngineIsUneven() async throws {
        let engine = ScriptedTranscriber { i, _ in
            try await Task.sleep(for: .milliseconds([60, 5, 30, 1, 20, 10][i % 6]))
            return Transcript(text: "part\(i)")
        }
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        for i in stride(from: 0, to: speech.count, by: 1600) { await live.feed(Array(speech[i..<min(i + 1600, speech.count)])) }
        let rOpt = await live.finish(all: speech)
        let r = try XCTUnwrap(rOpt)
        XCTAssertEqual(r.transcript.text, (0..<r.chunks).map { "part\($0)" }.joined(separator: " "))
        XCTAssertGreaterThanOrEqual(r.chunks, 5)
        XCTAssertEqual(engine.calls.map(\.samples).reduce(0, +), speech.count, "every sample transcribed exactly once")
    }

    func testFinishTopsUpWhatTheFeedMissedAndIgnoresLateFeeds() async throws {
        let engine = ScriptedTranscriber { i, _ in Transcript(text: "p\(i)") }
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        await live.feed(Array(speech[0..<40_000]), from: 0)
        await live.feed(Array(speech[20_000..<60_000]), from: 20_000)        // overlapping feed: only the new part counts
        let fed = await live.samplesFed
        XCTAssertEqual(fed, 60_000)
        let finished = await live.finish(all: speech)
        XCTAssertNotNil(finished)                      // the last ~22 s never came through the feed
        await live.feed(Array(speech[60_000...]), from: 60_000)               // the live loop's last feed, arriving late
        XCTAssertEqual(engine.calls.map(\.samples).reduce(0, +), speech.count)
    }

    func testAFailedChunkMeansFallBack() async {
        let engine = ScriptedTranscriber { i, _ in if i == 1 { throw Boom() }; return Transcript(text: "ok") }
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        await live.feed(speech)
        let r = await live.finish(all: speech)
        XCTAssertNil(r)
    }

    func testNothingHeardMeansFallBack() async {
        let live = IncrementalTranscriber(transcriber: ScriptedTranscriber { _, _ in Transcript(text: "") }, prompt: nil)
        await live.feed(speech)
        let r = await live.finish(all: speech)
        XCTAssertNil(r)
    }

    func testLanguageOfTheFirstLongChunkIsPinnedForTheRest() async throws {
        let engine = ScriptedTranscriber { i, _ in Transcript(text: "w\(i)", language: i == 0 ? "de" : "en") }
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        await live.feed(speech)
        let rOpt = await live.finish(all: speech)
        let r = try XCTUnwrap(rOpt)
        XCTAssertEqual(r.transcript.language, "de")
        XCTAssertNil(engine.calls.first?.language)
        XCTAssertTrue(engine.calls.dropFirst().allSatisfy { $0.language == "de" }, "\(engine.calls)")
    }

    func testCancelStopsQueuedChunksFromReachingTheEngine() async {
        let engine = ScriptedTranscriber { _, _ in try await Task.sleep(for: .milliseconds(100)); return Transcript(text: "x") }
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        await live.feed(speech)                     // queues several chunks; the first is running
        await live.cancel()
        let r = await live.finish(all: speech)
        XCTAssertNil(r)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertLessThanOrEqual(engine.calls.count, 1, "at most the chunk already in the engine ran")
    }

    func testPreviewShowsCommittedTextAndTheOpenChunk() async throws {
        let engine = ScriptedTranscriber { _, s in Transcript(text: s.count > 70_000 ? "closed chunk" : "still talking") }
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        await live.setWindowPreview(false)          // the open-chunk preview (engines without token timings)
        await live.feed(tone(5) + silence(0.6) + tone(2))
        try await Task.sleep(for: .milliseconds(50))
        let p = await live.preview()
        XCTAssertEqual(p, "closed chunk still talking")
        let again = await live.preview()            // no new audio: no new engine call
        XCTAssertEqual(again, p)
        XCTAssertEqual(engine.calls.count, 2)
    }

    func testPreviewWaitsForAsMuchNewAudioAsItsLastRunTook() async throws {
        // A slow engine: each preview takes 0.2 s, so the next needs at least 0.2 s of new audio, not just 0.05 s.
        let engine = ScriptedTranscriber { _, _ in try await Task.sleep(for: .milliseconds(200)); return Transcript(text: "words") }
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        await live.setWindowPreview(false)          // the open-chunk preview (engines without token timings)
        await live.setMinPreviewStep(800)                            // 0.05 s floor
        await live.feed(tone(1))
        _ = await live.preview()
        let step = await live.previewStep
        XCTAssertGreaterThanOrEqual(step, 200 * 16, "step grows to the last run's duration")
        await live.feed(tone(0.1))                                   // 0.1 s: more than the floor, less than the step
        _ = await live.preview()
        XCTAssertEqual(engine.calls.count, 1)
        await live.feed(tone(0.3))
        _ = await live.preview()
        XCTAssertEqual(engine.calls.count, 2)
    }

    func testPreviewDoesNotSkipATurnWhileTheChunkThatJustClosedRuns() async throws {
        // The closed chunk takes 0.3 s; the preview of the new open chunk queues behind it instead of waiting a turn.
        let engine = ScriptedTranscriber { _, s in
            if s.count > 70_000 { try await Task.sleep(for: .milliseconds(300)); return Transcript(text: "closed chunk") }
            return Transcript(text: "still talking")
        }
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        await live.setWindowPreview(false)          // the open-chunk preview (engines without token timings)
        await live.feed(tone(5) + silence(0.6) + tone(2))            // first chunk closes and starts in the engine
        let p = await live.preview()
        XCTAssertEqual(engine.calls.count, 2, "the preview ran while the closed chunk was still in the engine")
        XCTAssertTrue(p.hasSuffix("still talking"), p)
        try await Task.sleep(for: .milliseconds(400))
        let after = await live.preview()
        XCTAssertEqual(after, "closed chunk still talking")
    }

    func testWordsAreCutAtTheSeamByWhereTheyEnd() {
        // "after" is stamped as starting 0.1 s before the seam at 2.0 s but ends after it: it belongs to the open chunk.
        let t = Transcript(text: "Correct. After that we", tokens: [
            TimedToken(text: "Correct", start: 0.5, end: 1.2), TimedToken(text: ".", start: 1.2, end: 1.3),
            TimedToken(text: " Af", start: 1.9, end: 2.1), TimedToken(text: "ter", start: 2.1, end: 2.3),
            TimedToken(text: " that", start: 2.4, end: 2.6), TimedToken(text: " we", start: 2.7, end: 2.8)])
        XCTAssertEqual(IncrementalTranscriber.text(of: t, from: 2.0), "After that we")
        XCTAssertEqual(IncrementalTranscriber.text(of: t, from: 0, to: 2.0), "Correct.")
    }

    func testWindowPreviewHearsTheChunkBeforeTheSeamButShowsOnlyTheOpenChunk() async throws {
        // An engine with token timings: one word per second of audio, each ending at its second.
        let engine = ScriptedTranscriber { _, s in
            let n = s.count / 16000
            let toks = (0..<n).map { TimedToken(text: " w\($0)", start: Double($0) + 0.2, end: Double($0) + 0.9) }
            return Transcript(text: toks.map(\.text).joined(), tokens: toks)
        }
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        await live.feed(tone(5) + silence(0.6) + tone(2))            // chunk 0 is 5.6 s, the open chunk 2 s
        try await Task.sleep(for: .milliseconds(50))
        let p = await live.preview()
        XCTAssertEqual(engine.calls.last?.samples, Int(7.6 * 16000), "the preview reaches back across the seam")
        // Chunk 0's own text is w0-w4; the preview adds only the words ending after the seam at 5.6 s, none twice.
        XCTAssertEqual(p, "w0 w1 w2 w3 w4 w5 w6")
    }

    func testWindowPreviewFallsBackToTheOpenChunkWithoutTokenTimings() async throws {
        let engine = ScriptedTranscriber { _, s in Transcript(text: s.count > 70_000 ? "closed chunk" : "still talking") }
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        await live.feed(tone(5) + silence(0.6) + tone(2))
        try await Task.sleep(for: .milliseconds(50))
        _ = await live.preview()                                     // window run: no timings, so it switches off
        await live.feed(tone(0.5))
        let p = await live.preview()
        XCTAssertEqual(p, "closed chunk still talking")
    }

    func testPreviewCoversTracksHowFarTheShownTextReaches() async throws {
        let engine = ScriptedTranscriber { _, s in Transcript(text: s.count > 70_000 ? "closed chunk" : "still talking") }
        let live = IncrementalTranscriber(transcriber: engine, prompt: nil)
        await live.setWindowPreview(false)          // the open-chunk preview (engines without token timings)
        let audio = tone(5) + silence(0.6) + tone(2)
        await live.feed(audio)
        try await Task.sleep(for: .milliseconds(50))
        _ = await live.preview()
        let covers = await live.previewCovers
        XCTAssertGreaterThan(covers, audio.count - 1600 * 2, "committed chunk plus the open chunk's preview")
        XCTAssertLessThanOrEqual(covers, audio.count)
    }
}

final class LivePipelineTests: XCTestCase {
    private let speech: [Float] = (0..<4).flatMap { _ in tone(5) + silence(0.6) }

    func testLiveChunksAreInsertedSavedAndTimed() async throws {
        let store = try tempStore(); let ins = MockInserter()
        let engine = ScriptedTranscriber { i, _ in Transcript(text: "Part \(i).") }
        let p = DictationPipeline(transcriber: engine, inserter: ins, reader: MockContextReader(), store: store)
        let live = await p.makeLive()
        await live.feed(speech)
        let recOpt = await p.process(samples: speech, live: live)
        let rec = try XCTUnwrap(recOpt)
        XCTAssertEqual(ins.field, "Part 0. Part 1. Part 2. Part 3.")
        let d = try XCTUnwrap(rec.timings.detail)
        XCTAssertEqual(d.chunks, 4); XCTAssertEqual(d.liveFallback, false); XCTAssertNotNil(d.tailMs)
        XCTAssertEqual(store.dictations().first?.timings.detail?.chunks, 4)
    }

    func testFailedChunkFallsBackToOneFullPass() async throws {
        let store = try tempStore(); let ins = MockInserter()
        let engine = ScriptedTranscriber { i, s in
            if i == 1 { throw Boom() }
            return Transcript(text: s.count == 358_400 ? "Whole recording." : "chunk")
        }
        let p = DictationPipeline(transcriber: engine, inserter: ins, reader: MockContextReader(), store: store)
        let live = await p.makeLive()
        await live.feed(speech)
        let recOpt = await p.process(samples: speech, live: live)
        let rec = try XCTUnwrap(recOpt)
        XCTAssertEqual(ins.field, "Whole recording.")
        XCTAssertEqual(rec.timings.detail?.liveFallback, true)
        XCTAssertNil(rec.timings.detail?.chunks)
        XCTAssertEqual(engine.calls.last?.samples, speech.count)
    }

    func testEscDuringTheTailInsertsAndSavesNothing() async throws {
        let store = try tempStore(); let ins = MockInserter()
        let engine = ScriptedTranscriber { _, _ in try await Task.sleep(for: .milliseconds(150)); return Transcript(text: "words") }
        let p = DictationPipeline(transcriber: engine, inserter: ins, reader: MockContextReader(), store: store)
        let live = await p.makeLive()
        await live.feed(speech)
        let task = Task { await p.process(samples: speech, live: live) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel(); await live.cancel()          // what cancelDictation() does
        let rec = await task.value
        XCTAssertNil(rec)
        XCTAssertEqual(ins.field, "")
        XCTAssertTrue(store.dictations().isEmpty)
        XCTAssertLessThan(engine.calls.count, 5, "no full-pass fallback after a cancel")
    }

    func testRecordsFromBeforeLiveTranscriptionStillDecode() throws {
        // A stored record written by the previous build (commit fac9143): detail without any live-transcription keys.
        let json = """
        {"id":"A","date":"2026-11-22T10:00:00Z","context":{"bundleID":"x","appName":"X","windowTitle":""},"modeID":"default",
         "raw":"hi","inserted":"hi","cleanupStatus":"disabled","revertedToRaw":false,
         "timings":{"audioMs":1000,"transcribeMs":200,"cleanupMs":0,"insertMs":5,"totalMs":210,
           "detail":{"stopMs":3,"previewInFlight":false,"previewRuns":0,"previewEngineMs":0,"meetingActive":false,"engine":"parakeet",
             "promptMs":0,"queueWaitMs":0,"loadMs":0,"inferenceMs":150,"silenceGated":false,"contextMs":4,"contextWaitMs":0,
             "samples":16000,"thermal":"nominal","lowPower":false}}}
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let rec = try d.decode(DictationRecord.self, from: Data(json.utf8))
        XCTAssertEqual(rec.timings.detail?.inferenceMs, 150)
        XCTAssertNil(rec.timings.detail?.chunks); XCTAssertNil(rec.timings.detail?.liveFallback)
    }

    func testReportComparesChunkedAndOneShot() {
        var recs: [DictationRecord] = []
        for i in 1...6 {
            var a = DictationRecord(); a.raw = "one shot words"; a.timings.audioMs = i * 30_000; a.timings.transcribeMs = i * 900
            a.timings.detail = TimingDetail(); recs.append(a)
            var b = DictationRecord(); b.raw = "chunked words"; b.timings.audioMs = i * 30_000; b.timings.transcribeMs = 300 + i % 2 * 50
            var d = TimingDetail(); d.chunks = i * 3; d.tailMs = b.timings.transcribeMs; d.backlogMs = 10; d.liveFallback = false
            b.timings.detail = d; recs.append(b)
        }
        let text = TimingReport.render(recs)
        XCTAssertTrue(text.contains("LIVE TRANSCRIPTION (6 chunked, 0 fell back to one pass, 6 one-shot)"), text)
        XCTAssertTrue(text.contains("tail after release: median 325 ms"), text)
    }

    func testWordDiff() {
        XCTAssertEqual(WordDiff.distance("Hello, world. This is it", "hello world this is it"), 0)
        XCTAssertEqual(WordDiff.distance("a b c d", "a x c"), 2)
        XCTAssertEqual(WordDiff.rate("a b", reference: "a b c d"), 0.5)
    }
}
