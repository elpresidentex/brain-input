import XCTest
@testable import BrainCore

final class MCPTests: XCTestCase {
    func json(_ s: String?) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data((s ?? "{}").utf8))) as? [String: Any] ?? [:] }
    func text(_ reply: String?) -> String { (((json(reply)["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }

    func testProtocolAndTools() async throws {
        let store = try tempStore()
        try store.saveNote(folder: "Meetings", filename: "2026-11-10-0900-old.md", title: "Old sync", date: Date(), markdown: "# Old sync\n\nNothing much.")
        try store.saveNote(folder: "Meetings", filename: "2026-11-16-1400-launch-sync.md", title: "Launch sync", date: Date(),
                           markdown: "# Launch sync\n\n## Decisions\n\n- Launch on 1 December\n\n## Transcript\n\n**Them** (00:06): first of December")
        await DictationPipeline(transcriber: MockTranscriber("Remind me about the Terraform migration"), inserter: MockInserter(), reader: MockContextReader(), store: store).process(samples: [0.1])
        let s = MCPServer(store: store)

        let initReply = json(s.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        XCTAssertEqual((initReply["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "notifications get no reply")
        let tools = (json(s.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["search_notes", "read_note", "list_meetings", "last_meeting", "recent_dictations"])

        let last = text(s.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"last_meeting","arguments":{}}}"#))
        XCTAssertTrue(last.contains("# Launch sync")); XCTAssertTrue(last.contains("Launch on 1 December"))
        let found = text(s.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"december","kind":"meeting"}}}"#))
        XCTAssertTrue(found.contains("ref: Meetings/2026-11-16-1400-launch-sync.md"))
        let read = text(s.handle(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_note","arguments":{"ref":"Meetings/2026-11-10-0900-old.md"}}}"#))
        XCTAssertTrue(read.contains("Nothing much."))
        XCTAssertTrue(text(s.handle(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"recent_dictations","arguments":{"limit":1}}}"#)).contains("Terraform migration"))
        let bad = json(s.handle(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_note","arguments":{"ref":"../../.ssh/id_rsa"}}}"#))
        XCTAssertEqual((bad["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertNotNil(json(s.handle(#"{"jsonrpc":"2.0","id":8,"method":"nope"}"#))["error"])
        XCTAssertNotNil(json(s.handle("not json"))["error"])
    }
}
