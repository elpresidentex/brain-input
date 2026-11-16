import XCTest
@testable import BrainCore

func tempURL(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)") }

final class LearningTests: XCTestCase {
    func testDiffFindsInsertionInsideLargerFieldAndTheFixedWord() {
        let inserted = "Ask Kaderzina to deploy the Kubernetes cluster with Terraform."
        let field = "Hi team,\n\nAsk Katarzyna to deploy the Kubernetes cluster with Terraform. Thanks!"
        let d = EditDiff.compare(inserted: inserted, field: field)
        XCTAssertEqual(d?.finalText, "Ask Katarzyna to deploy the Kubernetes cluster with Terraform.")
        XCTAssertEqual(d?.corrections, [Correction(from: "Kaderzina", to: "Katarzyna")])
    }

    func testDiffIgnoresRephrasingAndUnrelatedFields() {
        let d = EditDiff.compare(inserted: "I think we should move the launch to next week.", field: "I think we should postpone the launch to next week.")
        XCTAssertEqual(d?.corrections, [], "move → postpone is a rewrite, not a mishearing")
        XCTAssertNil(EditDiff.compare(inserted: "I think we should move the launch.", field: "Totally different text in another field"))
        XCTAssertNil(EditDiff.compare(inserted: "Something that was sent already", field: ""))
    }

    func testDiffLearnsBrandCasingAndTwoWordFixes() {
        let d = EditDiff.compare(inserted: "push it to github and tell cube control", field: "push it to GitHub and tell kubectl")
        XCTAssertTrue(d!.corrections.contains(Correction(from: "github", to: "GitHub")))
        XCTAssertTrue(d!.corrections.contains(Correction(from: "cube control", to: "kubectl")))
        let s = EditDiff.compare(inserted: "the build is green", field: "The build is green")
        XCTAssertEqual(s?.corrections, [], "sentence-start capital is not vocabulary")
    }

    func testWordFixedTwiceBecomesDictionaryEntryAndCanBeRemoved() {
        let dict = DictionaryStore(url: tempURL("dict.json"))
        let c = Correction(from: "Kaderzina", to: "Katarzyna")
        XCTAssertEqual(dict.record([c]), [])
        XCTAssertEqual(dict.candidates.count, 1); XCTAssertTrue(dict.entries.isEmpty)
        let promoted = dict.record([c])
        XCTAssertEqual(promoted.map(\.term), ["Katarzyna"])
        XCTAssertEqual(dict.entries.first?.source, "learned")
        XCTAssertEqual(dict.whisperPrompt(), "Katarzyna.")
        XCTAssertEqual(dict.applyKnownFixes(to: "ask kaderzina, not Kaderzinas"), "ask Katarzyna, not Kaderzinas")
        XCTAssertTrue(dict.promptLines()[0].contains("kaderzina"))
        let reloaded = DictionaryStore(url: dict_url(dict))
        XCTAssertEqual(reloaded.entries.map(\.term), ["Katarzyna"])
        reloaded.remove("Katarzyna"); XCTAssertTrue(reloaded.entries.isEmpty)
    }
    func dict_url(_ d: DictionaryStore) -> URL { Mirror(reflecting: d).children.first { $0.label == "url" }!.value as! URL }

    func testEditLearnerEndToEnd() async throws {
        let store = try tempStore(); let dict = DictionaryStore(url: tempURL("dict.json"))
        let reader = MockContextReader(context: AppContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack"))
        let ins = MockInserter()
        let p = DictationPipeline(transcriber: MockTranscriber("ask Kaderzina about the cluster"), inserter: ins, reader: reader, store: store,
                                  whisperPrompt: { dict.whisperPrompt() })
        let learner = EditLearner(reader: reader, dictionary: dict) { id, text in await p.setFinalText(text, for: id) }

        // First dictation, I fix the name by hand.
        var rec = await p.process(samples: [0.1])!
        await learner.track(rec)
        reader.field = "ask Katarzyna about the cluster"
        var promoted = await learner.check()
        XCTAssertEqual(promoted, []); XCTAssertEqual(store.dictation(id: rec.id)?.finalText, "ask Katarzyna about the cluster")
        promoted = await learner.check()
        XCTAssertEqual(promoted, [], "the same dictation votes only once")

        // Second dictation, same fix: now it is learned.
        rec = await p.process(samples: [0.1])!
        await learner.track(rec)
        reader.field = "ask Katarzyna about the cluster"
        promoted = await learner.check()
        XCTAssertEqual(promoted.map(\.term), ["Katarzyna"])

        // Another app in front: nothing is read.
        await learner.track(rec); reader.context.bundleID = "com.apple.mail"
        let none = await learner.check(); XCTAssertEqual(none, [])

        // The third dictation gets the term as whisper prompt.
        let t = MockTranscriber("x"); let p2 = DictationPipeline(transcriber: t, inserter: ins, reader: reader, store: store, whisperPrompt: { dict.whisperPrompt() })
        await p2.process(samples: [0.1])
        XCTAssertEqual(t.prompts.first ?? nil, "Katarzyna.")
    }

    func testStyleCardMarkdownRoundTripAndVersions() {
        let store = StyleStore(dir: tempURL("Style"))
        var card = StyleCard(modeID: "email"); card.description = "Short paragraphs.\nSigns off with \"Viele Grüße\"."
        card.examples = ["Hallo Sabine,\n\ndanke dir!\n\nViele Grüße\nArmin", "Quick one: can we move to 3?"]
        let v1 = store.save(card)
        XCTAssertEqual(v1.version, 1)
        let read = store.current("email")!
        XCTAssertEqual(read.description, card.description); XCTAssertEqual(read.examples, card.examples)
        var edited = read; edited.description = "Edited by me."; edited.source = "edited"
        XCTAssertEqual(store.save(edited).version, 2)
        XCTAssertEqual(store.history("email").map(\.version), [1])
        XCTAssertEqual(store.history("email").first?.description, card.description)
        XCTAssertTrue(store.promptText("email")!.contains("Edited by me."))
        XCTAssertNil(store.promptText("chat"))
    }

    func testStyleRegenerationFromDictationsAfterEdits() async throws {
        let notes = try tempStore(); let styles = StyleStore(dir: tempURL("Style"))
        var learner = StyleLearner(store: styles, notes: notes); learner.threshold = 3
        for i in 0..<3 {
            var r = DictationRecord(); r.modeID = "chat"; r.inserted = "model wrote this sentence number \(i) for me"
            r.finalText = "lol ok, my own edit number \(i) is what counts"; r.date = Date().addingTimeInterval(Double(i))
            try notes.saveDictation(r)
        }
        XCTAssertTrue(learner.isDue("chat")); XCTAssertFalse(learner.isDue("email"))
        let model = MockLanguageModel("Lowercase, short, no full stops. Says lol.\nEXAMPLES:\nlol ok, my own edit number 1 is what counts\n---\nan invented example that I never wrote")
        let card = try await learner.regenerate("chat", model: model)
        XCTAssertEqual(card.description, "Lowercase, short, no full stops. Says lol.")
        XCTAssertEqual(card.examples, ["lol ok, my own edit number 1 is what counts"], "invented examples are dropped")
        XCTAssertTrue(model.calls[0].user.contains("my own edit number 2")); XCTAssertFalse(model.calls[0].user.contains("model wrote this"))
        XCTAssertFalse(learner.isDue("chat"), "samples older than the card are not counted again")
        // The card reaches the clean-up prompt.
        let sys = CleanupPrompt.system(mode: Mode.defaults[1], styleCard: styles.promptText("chat"), dictionary: [])
        XCTAssertTrue(sys.contains("<style>")); XCTAssertTrue(sys.contains("Says lol."))
    }

    func testImportSeedsCardWithoutModelAndWithModel() async throws {
        let styles = StyleStore(dir: tempURL("Style")); let learner = StyleLearner(store: styles, notes: try tempStore())
        let seeded = try await learner.regenerate("email", model: nil, imported: ["Hi Tom,\n\nsounds good.\n\nBest\nArmin"])
        XCTAssertEqual(seeded.examples.count, 1); XCTAssertEqual(seeded.source, "imported")
        let model = MockLanguageModel("Brief. Signs off \"Best\\nArmin\".\nEXAMPLES:\nHi Tom,\n\nsounds good.\n\nBest\nArmin")
        let card = try await learner.regenerate("email", model: model, imported: ["Hi Tom,\n\nsounds good.\n\nBest\nArmin"])
        XCTAssertEqual(card.version, 2); XCTAssertTrue(card.description.hasPrefix("Brief."))
        XCTAssertTrue(model.calls[0].user.contains("<previous_card>"))
    }
}
