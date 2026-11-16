import Foundation

/// A small Model Context Protocol server (JSON-RPC 2.0, one message per line on stdio) that lets
/// Claude or Cursor search and read the notes. Read-only.
public final class MCPServer {
    private let store: NotesStore
    public init(store: NotesStore) { self.store = store }

    static let tools: [[String: Any]] = [
        tool("search_notes", "Full-text search over meeting notes and dictation history. Returns refs to pass to read_note.",
             ["query": ["type": "string", "description": "Words to look for"],
              "kind": ["type": "string", "enum": ["meeting", "dictation"], "description": "Limit to one kind"],
              "limit": ["type": "integer", "description": "Maximum results (default 10)"]], required: ["query"]),
        tool("read_note", "Read one note in full by its ref, e.g. Meetings/2026-11-16-1400-launch-sync.md.",
             ["ref": ["type": "string", "description": "A ref returned by search_notes or list_meetings"]], required: ["ref"]),
        tool("list_meetings", "List meeting notes, newest first.", ["limit": ["type": "integer", "description": "Maximum results (default 20)"]]),
        tool("last_meeting", "Read the most recent meeting note in full: summary, decisions, action items and transcript.", [:]),
        tool("recent_dictations", "The most recent dictations with app, time and final text.", ["limit": ["type": "integer", "description": "Maximum results (default 10)"]]),
    ]

    static func tool(_ name: String, _ description: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    /// Handles one JSON-RPC line; returns the reply line, or nil for notifications.
    public func handle(_ line: String) -> String? {
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = msg["id"] else { return nil }     // notification
        let params = msg["params"] as? [String: Any] ?? [:]
        func reply(_ result: [String: Any]) -> String { encode(["jsonrpc": "2.0", "id": id, "result": result]) }
        switch msg["method"] as? String {
        case "initialize":
            return reply(["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18", "capabilities": ["tools": [String: Any]()],
                          "serverInfo": ["name": "brain-input", "version": "0.1.0"],
                          "instructions": "Notes from Brain Input: meeting notes (with Me/Them transcripts) and dictation history. Read-only."])
        case "ping": return reply([:])
        case "tools/list": return reply(["tools": Self.tools])
        case "tools/call":
            let (text, isError) = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
            return reply(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
        }
    }

    func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        let limit = args["limit"] as? Int
        func list(_ hits: [SearchHit]) -> String {
            hits.isEmpty ? "No results." : hits.map { "\($0.date) · \($0.title)\nref: \($0.ref)\n\($0.snippet.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n\n")
        }
        switch name {
        case "search_notes":
            guard let q = args["query"] as? String, !q.trimmed.isEmpty else { return ("query is required", true) }
            return (list(store.search(q, kind: args["kind"] as? String, limit: limit ?? 10)), false)
        case "read_note":
            guard let ref = args["ref"] as? String, let text = store.read(ref: ref) else { return ("No note with that ref.", true) }
            return (text, false)
        case "list_meetings": return (list(store.meetings(limit: limit ?? 20)), false)
        case "last_meeting":
            guard let m = store.meetings(limit: 1).first, let text = store.read(ref: m.ref) else { return ("There are no meeting notes yet.", false) }
            return ("ref: \(m.ref)\n\n\(text)", false)
        case "recent_dictations":
            let rows = store.dictations(limit: limit ?? 10)
            return (rows.isEmpty ? "No dictations yet." : rows.map { "\($0.date.formatted(.iso8601)) · \($0.context.appName) · \($0.modeID)\n\($0.best)" }.joined(separator: "\n\n"), false)
        default: return ("Unknown tool: \(name)", true)
        }
    }

    private func encode(_ obj: [String: Any]) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8), encoding: .utf8)!
    }

    /// Serves until stdin closes.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmed.isEmpty, let out = handle(line) else { continue }
            FileHandle.standardOutput.write(Data((out + "\n").utf8))
        }
    }
}
