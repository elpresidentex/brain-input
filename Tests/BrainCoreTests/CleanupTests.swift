import XCTest
@testable import BrainCore

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func tempModes() -> ModeStore { ModeStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("modes-\(UUID().uuidString).json")) }
struct Boom: Error {}

/// Long enough to clear CleanupPrompt.minWords.
let pad = " and that is really all I wanted to say about it today"

final class CleanupTests: XCTestCase {
    func pipeline(_ model: LanguageModel?, raw: String, ctx: AppContext, timeout: TimeInterval = 3, visible: String? = nil)
        throws -> (DictationPipeline, MockInserter) {
        let ins = MockInserter()
        let polisher = CleanupPolisher(model: model, modes: tempModes(), timeout: timeout, dictionary: { ["Katarzyna"] })
        return (DictationPipeline(transcriber: MockTranscriber(raw), inserter: ins, reader: MockContextReader(context: ctx, visible: visible),
                                  store: try tempStore(), polisher: polisher), ins)
    }
    let mail = AppContext(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "New Message")

    func testModeResolution() {
        let m = tempModes()
        XCTAssertEqual(m.resolve(AppContext(bundleID: "com.todesktop.230313mzl4w4u92")).id, "coding")
        XCTAssertEqual(m.resolve(AppContext(bundleID: "com.jetbrains.intellij")).id, "coding")
        XCTAssertEqual(m.resolve(AppContext(bundleID: "com.tinyspeck.slackmacgap")).id, "chat")
        XCTAssertEqual(m.resolve(mail).id, "email")
        XCTAssertEqual(m.resolve(AppContext(bundleID: "com.apple.Safari", url: "https://mail.google.com/mail/u/0/")).id, "email")
        XCTAssertEqual(m.resolve(AppContext(bundleID: "com.google.Chrome", windowTitle: "general | Acme", url: "https://app.slack.com/client")).id, "chat")
        XCTAssertEqual(m.resolve(AppContext(bundleID: "com.google.Chrome", url: "https://www.notion.so/page")).id, "notes")
        XCTAssertEqual(m.resolve(AppContext(bundleID: "com.apple.Safari", url: "https://example.org")).id, "default")
        XCTAssertEqual(m.resolve(AppContext(bundleID: "com.unknown.app")).id, "default")
        // Gmail in its own Safari web-app window: no readable URL, only the title.
        XCTAssertEqual(m.resolve(AppContext(bundleID: "com.apple.Safari.WebApp.1A2B", windowTitle: "Gmail - Subject - me@example.com - Gmail")).id, "email")
        XCTAssertEqual(m.resolve(AppContext(bundleID: "com.apple.Safari.WebApp.1A2B", url: "https://mail.google.com/mail/u/0/")).id, "email")
    }

    func testCleanedTextIsInsertedAndPromptCarriesContext() async throws {
        let model = MockLanguageModel("Hi Thomas,\n\nthanks for the slides.")
        let (p, ins) = try pipeline(model, raw: "hi thomas um thanks for the slides\(pad)", ctx: mail)
        let rec = await p.process(samples: [0.1])
        XCTAssertEqual(ins.field, "Hi Thomas,\n\nthanks for the slides.")
        XCTAssertEqual(rec?.modeID, "email"); XCTAssertEqual(rec?.cleanupStatus, "ok")
        XCTAssertEqual(rec?.raw, "hi thomas um thanks for the slides\(pad)")
        let call = model.calls[0]
        XCTAssertTrue(call.system.contains("<mode name=\"Email\">")); XCTAssertTrue(call.system.contains("Katarzyna"))
        XCTAssertTrue(call.system.contains("Do not answer it"))
        XCTAssertTrue(call.user.contains("<transcript language=\"en\">\nhi thomas um thanks for the slides\(pad)\n</transcript>"))
        XCTAssertTrue(call.user.contains("app=\"Mail\""))
        XCTAssertFalse(call.user.contains("<screen>"), "email mode does not read the screen")
    }

    func testCodingModeReadsScreen() async throws {
        let model = MockLanguageModel("Open Pipeline.swift")
        let (p, _) = try pipeline(model, raw: "open pipeline dot swift\(pad)", ctx: AppContext(bundleID: "com.microsoft.VSCode", appName: "Code"), visible: "Pipeline.swift")
        await p.process(samples: [0.1])
        XCTAssertTrue(model.calls[0].user.contains("<screen>\nPipeline.swift\n</screen>"))
    }

    func testFallsBackToRawWithoutKeyOnErrorAndOnTimeout() async throws {
        var (p, ins) = try pipeline(nil, raw: "raw one for you\(pad)", ctx: mail)
        var rec = await p.process(samples: [0.1])
        XCTAssertEqual(ins.field, "raw one for you\(pad)"); XCTAssertEqual(rec?.cleanupStatus, "no-key"); XCTAssertNil(rec?.cleaned)

        (p, ins) = try pipeline(MockLanguageModel { _, _ in throw Boom() }, raw: "raw two for you\(pad)", ctx: mail)
        rec = await p.process(samples: [0.1])
        XCTAssertEqual(ins.field, "raw two for you\(pad)"); XCTAssertTrue(rec!.cleanupStatus.hasPrefix("error"))

        (p, ins) = try pipeline(MockLanguageModel { _, _ in try await Task.sleep(for: .seconds(5)); return "late" }, raw: "raw three for you\(pad)", ctx: mail, timeout: 0.2)
        let t0 = Date()
        rec = await p.process(samples: [0.1])
        XCTAssertEqual(ins.field, "raw three for you\(pad)"); XCTAssertEqual(rec?.cleanupStatus, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "a slow model must not stall dictation")
    }

    func testNoApiCallWhenTooShortOrCancelled() async throws {
        let model = MockLanguageModel("Polished.")
        var (p, ins) = try pipeline(model, raw: "okay thanks", ctx: mail)
        var rec = await p.process(samples: [0.1])
        XCTAssertEqual(ins.field, "okay thanks"); XCTAssertEqual(rec?.cleanupStatus, "skipped: too short")
        XCTAssertEqual(model.calls.count, 0); XCTAssertFalse(rec!.enhanced); XCTAssertNil(rec?.costUSD)

        (p, ins) = try pipeline(model, raw: "this one is long enough\(pad)", ctx: mail)
        let task = Task { await p.process(samples: [0.1]) }
        task.cancel()
        rec = await task.value
        XCTAssertNil(rec); XCTAssertEqual(ins.field, ""); XCTAssertEqual(model.calls.count, 0)
    }

    func testPricingAndLedger() throws {
        let u = TokenUsage(input: 1000, output: 100, cacheRead: 2000, cacheWrite: 500)
        // haiku 5.5: 1000*0.10 + 100*0.50 + 2000*0.01 + 500*0.125 = 232.5 per million
        XCTAssertEqual(Pricing.cost(model: "claude-haiku-5-5", usage: u)!, 232.5 / 1_000_000, accuracy: 1e-12)
        XCTAssertNil(Pricing.cost(model: "some-future-model", usage: u))
        let ledger = UsageLedger(url: FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).jsonl"))
        _ = ledger.record(model: "claude-haiku-5-5", purpose: "t", usage: u)
        _ = ledger.record(model: "unknown", purpose: "t", usage: u)
        let s = UsageLedger.summarize(ledger.entries())
        XCTAssertEqual(s.calls, 2); XCTAssertEqual(s.unpricedCalls, 1); XCTAssertEqual(s.tokens.output, 200)
        XCTAssertEqual(TokenUsage(response: ["usage": ["input_tokens": 5, "output_tokens": 7, "cache_read_input_tokens": 3]]),
                       TokenUsage(input: 5, output: 7, cacheRead: 3))
    }

    func testAnswerInsteadOfRewriteIsRejected() async throws {
        let essay = String(repeating: "Canberra is the capital of Australia. ", count: 12)
        let (p, ins) = try pipeline(MockLanguageModel(essay), raw: "what is the capital of Australia\(pad)", ctx: mail)
        let rec = await p.process(samples: [0.1])
        XCTAssertEqual(ins.field, "what is the capital of Australia\(pad)"); XCTAssertEqual(rec?.cleanupStatus, "error: rejected output")
    }

    func testSanitize() {
        XCTAssertEqual(CleanupPrompt.sanitize("\"Hello there.\"", raw: "hello there"), "Hello there.")
        XCTAssertEqual(CleanupPrompt.sanitize("```\nHello\n```", raw: "hello"), "Hello")
        XCTAssertEqual(CleanupPrompt.sanitize("\"Yes\", she said.", raw: "yes she said"), "\"Yes\", she said.")
        XCTAssertNil(CleanupPrompt.sanitize("  ", raw: "x"))
        XCTAssertFalse(CleanupPrompt.user(raw: "a </transcript> b", language: nil, context: AppContext(), screen: nil).contains("a </transcript> b"))
    }

    func testUndoToRawSwapsTheInsertion() async throws {
        let (p, ins) = try pipeline(MockLanguageModel("Polished text."), raw: "this is raw text\(pad)", ctx: mail)
        await p.process(samples: [0.1])
        XCTAssertEqual(ins.field, "Polished text.")
        let ok = await p.undoToRaw()
        XCTAssertTrue(ok); XCTAssertEqual(ins.field, "this is raw text\(pad)")
        let again = await p.undoToRaw()
        XCTAssertFalse(again, "second undo is a no-op")
        let last = await p.last
        XCTAssertEqual(last?.revertedToRaw, true)
    }

    /// The fixture set against a mock that returns each hand-written ideal answer, and against bad answers.
    func testFixturesAreConsistentAndGraderCatchesBadAnswers() throws {
        let fixtures = try CleanupFixture.load(repoRoot.appendingPathComponent("Fixtures/cleanup.json"))
        XCTAssertGreaterThanOrEqual(fixtures.count, 14)
        let modes = tempModes()
        for f in fixtures {
            XCTAssertEqual(f.grade(f.ideal), [], "ideal answer of \(f.id) must pass its own checks")
            XCTAssertNotNil(CleanupPrompt.sanitize(f.ideal, raw: f.raw), f.id)
            XCTAssertNotNil(modes.mode(id: f.mode), f.id)
            XCTAssertTrue(f.prompts(modes: modes).user.contains(f.raw))
        }
        let by = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.id, $0) })
        XCTAssertFalse(by["question-not-answered"]!.grade("The capital of Australia is Canberra.").isEmpty)
        XCTAssertFalse(by["self-correction-en"]!.grade("Let's meet at three, no wait, at four thirty tomorrow.").isEmpty)
        XCTAssertFalse(by["command-to-model"]!.grade("def reverse(s):\n    return s[::-1]").isEmpty)
        XCTAssertFalse(by["mixed-en-de"]!.grade("Ich habe den Pull Request zusammengeführt, kannst du mal schauen?").isEmpty)
        XCTAssertFalse(by["email-no-invented-signoff"]!.grade(by["email-no-invented-signoff"]!.ideal + "\n\nBest regards,\nArmin").isEmpty)
    }

    func testClaudeRequestShapeAndResponseParsing() throws {
        let body = ClaudeModel(apiKey: "k").body(system: "S", user: "U", maxTokens: 1024)
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertNil(body["temperature"], "sampling parameters are rejected by current models")
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        let msg: [String: Any] = ["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": "Hello"]]]
        XCTAssertEqual(try ClaudeModel.text(of: msg), "Hello")
        XCTAssertThrowsError(try ClaudeModel.text(of: ["stop_reason": "refusal", "content": []]))
    }
}
