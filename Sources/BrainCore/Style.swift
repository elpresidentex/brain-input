import Foundation

/// How I write in one mode: a plain-language description plus a few real examples.
/// Stored as Markdown in ~/BrainInput/Style/<mode>.md; earlier versions in Style/history/.
public struct StyleCard: Equatable, Sendable {
    public var modeID: String
    public var version = 1
    public var updated = Date()
    public var source = "generated"      // generated | edited | imported
    public var description = ""
    public var examples: [String] = []
    public init(modeID: String) { self.modeID = modeID }

    public var markdown: String {
        var md = "---\nmode: \(modeID)\nversion: \(version)\nupdated: \(updated.formatted(.iso8601))\nsource: \(source)\n---\n"
        md += "# How I write: \(modeID)\n\n\(description.trimmed)\n\n## Examples\n"
        for e in examples { md += "\n" + e.trimmed.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n" }
        return md
    }

    public static func parse(_ md: String, modeID: String) -> StyleCard {
        var card = StyleCard(modeID: modeID)
        var body = md
        if md.hasPrefix("---\n"), let end = md.range(of: "\n---\n") {
            for line in md[md.index(md.startIndex, offsetBy: 4)..<end.lowerBound].components(separatedBy: "\n") {
                let kv = line.split(separator: ":", maxSplits: 1).map { String($0).trimmed }
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "version": card.version = Int(kv[1]) ?? 1
                case "updated": card.updated = (try? Date(kv[1], strategy: .iso8601)) ?? Date()
                case "source": card.source = kv[1]
                default: break
                }
            }
            body = String(md[end.upperBound...])
        }
        let parts = body.components(separatedBy: "\n## Examples")
        card.description = parts[0].components(separatedBy: "\n").filter { !$0.hasPrefix("# ") }.joined(separator: "\n").trimmed
        if parts.count > 1 {
            var cur: [String] = []
            for line in parts[1].components(separatedBy: "\n") + [""] {
                if line.hasPrefix(">") { cur.append(String(line.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: " "))) }
                else if !cur.isEmpty { card.examples.append(cur.joined(separator: "\n")); cur = [] }
            }
        }
        return card
    }

    /// The text placed in the clean-up prompt.
    public var promptText: String {
        var s = description.trimmed
        if !examples.isEmpty { s += "\n\nExamples of the speaker's own writing:\n" + examples.prefix(5).map { "<example>\n\($0)\n</example>" }.joined(separator: "\n") }
        return s
    }
}

public final class StyleStore: @unchecked Sendable {
    public let dir: URL
    private let fm = FileManager.default
    public init(dir: URL = BrainPaths.notesRoot.appendingPathComponent("Style")) {
        self.dir = dir
        try? fm.createDirectory(at: dir.appendingPathComponent("history"), withIntermediateDirectories: true)
    }

    public func current(_ modeID: String) -> StyleCard? {
        (try? String(contentsOf: dir.appendingPathComponent("\(modeID).md"), encoding: .utf8)).map { StyleCard.parse($0, modeID: modeID) }
    }

    /// Saves as the next version and keeps the previous one in history/.
    @discardableResult
    public func save(_ card: StyleCard) -> StyleCard {
        var c = card
        if let old = current(card.modeID) {
            try? old.markdown.write(to: dir.appendingPathComponent("history/\(old.modeID)-v\(old.version).md"), atomically: true, encoding: .utf8)
            c.version = old.version + 1
        } else { c.version = 1 }
        c.updated = Date()
        try? c.markdown.write(to: dir.appendingPathComponent("\(c.modeID).md"), atomically: true, encoding: .utf8)
        return c
    }

    public func history(_ modeID: String) -> [StyleCard] {
        let files = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("history").path)) ?? []
        return files.filter { $0.hasPrefix("\(modeID)-v") }.compactMap { f in
            (try? String(contentsOf: dir.appendingPathComponent("history/\(f)"), encoding: .utf8)).map { StyleCard.parse($0, modeID: modeID) }
        }.sorted { $0.version > $1.version }
    }

    public func promptText(_ modeID: String) -> String? {
        guard let c = current(modeID), !(c.description.isEmpty && c.examples.isEmpty) else { return nil }
        return c.promptText
    }
}

public struct StyleLearner: Sendable {
    public let store: StyleStore
    public let notes: NotesStore
    public var threshold = 12
    public init(store: StyleStore, notes: NotesStore) { self.store = store; self.notes = notes }

    static let system = """
    You maintain a style card: a short description of how one person writes in one context, used to make dictated text sound like \
    them. You get their previous card (if any) and recent samples of their final text in that context.

    Write the card in plain language, at most 150 words, as direct statements about their writing. Cover what the samples actually \
    show: typical sentence and message length, formality, greetings and sign-offs (quote them exactly, per language), punctuation \
    and capitalisation habits, emoji use, and which language they use with whom. Describe only what you can see in the samples; \
    where the samples show nothing about a point, leave it out. Revise the previous card rather than starting over, and keep \
    statements the new samples do not contradict.

    Then write a line containing only EXAMPLES: followed by three to five of the samples that best show their style, copied \
    character for character, separated by lines containing only ---. Write nothing else.
    """

    /// Final text of dictations in this mode since the card was last written (after my edits where known).
    public func newSamples(_ modeID: String) -> [String] {
        let since = store.current(modeID)?.updated ?? .distantPast
        return notes.dictations(limit: 400).filter { $0.modeID == modeID && $0.date > since && $0.best.count >= 25 }.prefix(40).map(\.best)
    }

    public func isDue(_ modeID: String) -> Bool { newSamples(modeID).count >= threshold }

    /// Regenerates the card from new dictations plus optional pasted samples. Without a model the card is
    /// seeded with examples only, so imports work before an API key exists.
    @discardableResult
    public func regenerate(_ modeID: String, model: LanguageModel?, imported: [String] = []) async throws -> StyleCard {
        let samples = (imported + newSamples(modeID)).map(\.trimmed).filter { !$0.isEmpty }
        var card = store.current(modeID) ?? StyleCard(modeID: modeID)
        guard !samples.isEmpty else { return card }
        card.source = imported.isEmpty ? "generated" : "imported"
        guard let model else {
            card.examples = Array((imported + card.examples).prefix(5))
            if card.description.isEmpty { card.description = "(No description yet. Add an API key and regenerate, or write one here.)" }
            return store.save(card)
        }
        var user = "Context: \(modeID)\n\n"
        if !card.description.isEmpty { user += "<previous_card>\n\(card.description)\n</previous_card>\n\n" }
        user += samples.map { "<sample>\n\($0.prefix(1200))\n</sample>" }.joined(separator: "\n")
        let out = try await model.complete(system: Self.system, user: user, maxTokens: 2000)
        let parts = out.components(separatedBy: "EXAMPLES:")
        let description = parts[0].trimmed
        guard !description.isEmpty else { throw ClaudeError(description: "empty style card") }
        // Keep only examples that really are my text; fall back to my own samples rather than invented ones.
        var examples = parts.count > 1 ? parts[1].components(separatedBy: "\n---").map(\.trimmed).filter { e in !e.isEmpty && samples.contains { $0.contains(e) } } : []
        if examples.isEmpty { examples = Array(samples.sorted { abs($0.count - 200) < abs($1.count - 200) }.prefix(4)) }
        card.description = description; card.examples = Array(examples.prefix(5))
        return store.save(card)
    }
}
