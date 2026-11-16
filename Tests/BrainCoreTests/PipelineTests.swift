import XCTest
@testable import BrainCore

func tempStore() throws -> NotesStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bi-test-\(UUID().uuidString)")
    return try NotesStore(root: dir)
}

final class PipelineTests: XCTestCase {
    func testRawDictationIsInsertedAndStored() async throws {
        let store = try tempStore(); let ins = MockInserter()
        let p = DictationPipeline(transcriber: MockTranscriber(" Hello world. [BLANK_AUDIO]"), inserter: ins,
                                  reader: MockContextReader(), store: store)
        let rec = await p.process(samples: [Float](repeating: 0.1, count: 16000))
        XCTAssertEqual(ins.field, "Hello world.")
        XCTAssertEqual(rec?.raw, "Hello world.")
        XCTAssertEqual(rec?.context.appName, "TextEdit")
        XCTAssertEqual(rec?.timings.audioMs, 1000)
        XCTAssertEqual(store.dictations().count, 1)
        let day = NotesStore.dayFmt.string(from: Date())
        let md = try String(contentsOf: store.root.appendingPathComponent("Dictations/\(day).md"), encoding: .utf8)
        XCTAssertTrue(md.contains("Hello world."))
        XCTAssertEqual(store.search("hello").first?.kind, "dictation")
    }

    func testEmptyTranscriptInsertsNothing() async throws {
        let ins = MockInserter()
        let p = DictationPipeline(transcriber: MockTranscriber("[BLANK_AUDIO]"), inserter: ins, reader: MockContextReader(), store: try tempStore())
        let rec = await p.process(samples: [])
        XCTAssertNil(rec); XCTAssertEqual(ins.field, "")
    }

    func testReindexRebuildsFromMarkdown() async throws {
        let store = try tempStore()
        let p = DictationPipeline(transcriber: MockTranscriber("Quarterly numbers --> look fine"), inserter: MockInserter(), reader: MockContextReader(), store: store)
        await p.process(samples: [0.1])
        try store.saveNote(folder: "Meetings", filename: "2026-11-16-1400-sync.md", title: "Sync", date: Date(), markdown: "# Sync\n\nWe discussed zebras.")
        for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: store.root.appendingPathComponent(".index.sqlite\(ext)")) }
        let again = try NotesStore(root: store.root)
        XCTAssertEqual(try again.reindex(), 2)
        XCTAssertEqual(again.dictations().first?.raw, "Quarterly numbers --> look fine")
        XCTAssertEqual(again.search("zebras").first?.ref, "Meetings/2026-11-16-1400-sync.md")
        XCTAssertNotNil(again.read(ref: "Meetings/2026-11-16-1400-sync.md"))
        XCTAssertNil(again.read(ref: "../../etc/passwd"))
    }
}
