import Foundation

public struct SearchHit: Sendable, Codable, Equatable {
    public var kind: String     // dictation | meeting
    public var ref: String      // path relative to the notes root (plus #id for dictations)
    public var title: String
    public var date: String
    public var snippet: String
}

/// Markdown files under ~/BrainInput are the source of truth; `.index.sqlite` beside them is a
/// rebuildable index (full-text search plus the structured dictation history).
public final class NotesStore: @unchecked Sendable {
    public let root: URL
    private let db: SQLiteDB
    private let fm = FileManager.default
    private let lock = NSLock()

    public init(root: URL = BrainPaths.notesRoot) throws {
        self.root = root
        for d in ["Dictations", "Meetings", "Style"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        db = try SQLiteDB(path: root.appendingPathComponent(".index.sqlite").path)
        try db.exec("CREATE TABLE IF NOT EXISTS dictations(id TEXT PRIMARY KEY, ts REAL, day TEXT, json TEXT)")
        try db.exec("CREATE INDEX IF NOT EXISTS dict_ts ON dictations(ts)")
        try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(kind UNINDEXED, ref UNINDEXED, title, date UNINDEXED, body,
            tokenize='unicode61 remove_diacritics 2')
            """)
    }

    // MARK: Dictations

    static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    static let enc: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public func saveDictation(_ r: DictationRecord) throws {
        lock.lock(); defer { lock.unlock() }
        let day = Self.dayFmt.string(from: r.date)
        try upsert(r, day: day)
        try writeDayFile(day)
    }

    private func upsert(_ r: DictationRecord, day: String) throws {
        let json = String(data: try Self.enc.encode(r), encoding: .utf8)!
        try db.exec("INSERT OR REPLACE INTO dictations(id, ts, day, json) VALUES(?,?,?,?)",
                    [r.id, r.date.timeIntervalSince1970, day, json])
        let ref = "Dictations/\(day).md#\(r.id)"
        try db.exec("DELETE FROM fts WHERE ref = ?", [ref])
        try db.exec("INSERT INTO fts(kind, ref, title, date, body) VALUES('dictation',?,?,?,?)",
                    [ref, "Dictation in \(r.context.appName)", "\(day) \(Self.timeFmt.string(from: r.date))",
                     r.best + "\n" + r.raw])
    }

    private func writeDayFile(_ day: String) throws {
        let rows = try db.query("SELECT json FROM dictations WHERE day = ? ORDER BY ts", [day])
        var md = "# Dictations \(day)\n"
        for row in rows {
            guard let json = row["json"] as? String, let r = try? Self.dec.decode(DictationRecord.self, from: Data(json.utf8))
            else { continue }
            md += "\n## \(Self.timeFmt.string(from: r.date)) · \(r.context.appName.isEmpty ? "?" : r.context.appName) · \(r.modeID)\n"
            md += "<!-- bi:\(json.replacingOccurrences(of: "-->", with: "--\\u003e")) -->\n\n"
            md += r.best + "\n"
            if r.raw != r.best { md += "\n<details><summary>Raw transcript</summary>\n\n\(r.raw)\n\n</details>\n" }
        }
        try md.write(to: root.appendingPathComponent("Dictations/\(day).md"), atomically: true, encoding: .utf8)
    }

    public func dictations(limit: Int = 200, matching query: String? = nil) -> [DictationRecord] {
        let rows = (try? db.query("SELECT json FROM dictations ORDER BY ts DESC LIMIT ?", [limit])) ?? []
        let all = rows.compactMap { ($0["json"] as? String).flatMap { try? Self.dec.decode(DictationRecord.self, from: Data($0.utf8)) } }
        guard let q = query?.lowercased(), !q.isEmpty else { return all }
        return all.filter { $0.best.lowercased().contains(q) || $0.raw.lowercased().contains(q) }
    }

    public func dictation(id: String) -> DictationRecord? {
        let rows = (try? db.query("SELECT json FROM dictations WHERE id = ?", [id])) ?? []
        return (rows.first?["json"] as? String).flatMap { try? Self.dec.decode(DictationRecord.self, from: Data($0.utf8)) }
    }

    // MARK: Notes (meetings and anything else that is a whole Markdown file)

    @discardableResult
    public func saveNote(folder: String, filename: String, title: String, date: Date, markdown: String) throws -> URL {
        let url = root.appendingPathComponent(folder).appendingPathComponent(filename)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        try indexNote(rel: "\(folder)/\(filename)", title: title, date: Self.dayFmt.string(from: date), body: markdown)
        return url
    }

    private func indexNote(rel: String, title: String, date: String, body: String) throws {
        try db.exec("DELETE FROM fts WHERE ref = ?", [rel])
        try db.exec("INSERT INTO fts(kind, ref, title, date, body) VALUES('meeting',?,?,?,?)", [rel, title, date, body])
    }

    public func meetings(limit: Int = 100) -> [SearchHit] {
        let rows = (try? db.query("SELECT ref, title, date, substr(body, 1, 200) AS snip FROM fts WHERE kind='meeting' ORDER BY ref DESC LIMIT ?", [limit])) ?? []
        return rows.map { SearchHit(kind: "meeting", ref: $0["ref"] as? String ?? "", title: $0["title"] as? String ?? "",
                                    date: $0["date"] as? String ?? "", snippet: $0["snip"] as? String ?? "") }
    }

    // MARK: Search and read

    public func search(_ text: String, kind: String? = nil, limit: Int = 20) -> [SearchHit] {
        let tokens = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
        var sql = "SELECT kind, ref, title, date, snippet(fts, 4, '[', ']', '…', 24) AS snip FROM fts WHERE fts MATCH ?"
        var params: [Any?] = [match]
        if let kind { sql += " AND kind = ?"; params.append(kind) }
        sql += " ORDER BY rank LIMIT ?"; params.append(limit)
        let rows = (try? db.query(sql, params)) ?? []
        return rows.map { SearchHit(kind: $0["kind"] as? String ?? "", ref: $0["ref"] as? String ?? "",
                                    title: $0["title"] as? String ?? "", date: $0["date"] as? String ?? "",
                                    snippet: $0["snip"] as? String ?? "") }
    }

    /// Reads a note by ref. `Dictations/2026-11-16.md#<id>` returns just that dictation.
    public func read(ref: String) -> String? {
        let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
        if parts.count == 2, let r = dictation(id: parts[1]) {
            return "\(r.context.appName) · \(r.date.formatted(.iso8601))\n\n\(r.best)\n\nRaw transcript:\n\(r.raw)"
        }
        let url = root.appendingPathComponent(parts[0]).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Rebuilds the whole index from the Markdown files.
    @discardableResult
    public func reindex() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try db.exec("DELETE FROM fts"); try db.exec("DELETE FROM dictations")
        var n = 0
        for f in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("Dictations").path)) ?? [] where f.hasSuffix(".md") {
            let text = (try? String(contentsOf: root.appendingPathComponent("Dictations/\(f)"), encoding: .utf8)) ?? ""
            for line in text.components(separatedBy: "\n") where line.hasPrefix("<!-- bi:") && line.hasSuffix(" -->") {
                let json = String(line.dropFirst(8).dropLast(4))
                if let r = try? Self.dec.decode(DictationRecord.self, from: Data(json.utf8)) {
                    try upsert(r, day: String(f.dropLast(3))); n += 1
                }
            }
        }
        for f in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("Meetings").path)) ?? [] where f.hasSuffix(".md") {
            let text = (try? String(contentsOf: root.appendingPathComponent("Meetings/\(f)"), encoding: .utf8)) ?? ""
            let title = text.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? f
            try indexNote(rel: "Meetings/\(f)", title: title, date: String(f.prefix(10)), body: text); n += 1
        }
        return n
    }
}
