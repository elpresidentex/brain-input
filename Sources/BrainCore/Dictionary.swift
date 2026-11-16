import Foundation

public struct DictEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String { term }
    public var term: String
    public var source: String          // manual | learned
    public var heardAs: [String] = []  // what whisper wrote instead
    public var added = Date()
}

public struct Correction: Codable, Hashable, Sendable {
    public var from: String, to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

/// Personal vocabulary. Feeds whisper's initial prompt and the clean-up prompt, and grows from my edits:
/// a word I fix more than once becomes an entry.
public final class DictionaryStore: @unchecked Sendable {
    struct File: Codable { var entries: [DictEntry] = []; var candidates: [String: Int] = [:] }
    private let url: URL
    private let lock = NSLock()
    private var file: File
    public static let promoteAfter = 2

    public init(url: URL = BrainPaths.supportDir.appendingPathComponent("dictionary.json")) {
        self.url = url
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        file = (try? dec.decode(File.self, from: Data(contentsOf: url))) ?? File()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(file).write(to: url, options: .atomic)
    }

    public var entries: [DictEntry] { lock.withLock { file.entries.sorted { $0.added > $1.added } } }
    /// Corrections seen once, waiting for a second sighting.
    public var candidates: [(Correction, Int)] {
        lock.withLock { file.candidates.compactMap { k, v in Self.split(k).map { ($0, v) } }.sorted { $0.0.to < $1.0.to } }
    }
    static func key(_ c: Correction) -> String { "\(c.from.lowercased())\u{1F}\(c.to)" }
    static func split(_ k: String) -> Correction? {
        let p = k.components(separatedBy: "\u{1F}"); return p.count == 2 ? Correction(from: p[0], to: p[1]) : nil
    }

    public func add(_ term: String, source: String = "manual", heardAs: [String] = []) {
        let term = term.trimmed
        guard !term.isEmpty else { return }
        lock.withLock {
            if let i = file.entries.firstIndex(where: { $0.term == term }) {
                file.entries[i].heardAs = Array(Set(file.entries[i].heardAs + heardAs)).sorted()
            } else { file.entries.append(DictEntry(term: term, source: source, heardAs: heardAs)) }
        }
        persist()
    }

    public func remove(_ term: String) {
        lock.withLock {
            file.entries.removeAll { $0.term == term }
            file.candidates = file.candidates.filter { Self.split($0.key)?.to != term }
        }
        persist()
    }

    /// Counts corrections; returns the entries that crossed the threshold with this call.
    @discardableResult
    public func record(_ corrections: [Correction]) -> [DictEntry] {
        var promoted: [DictEntry] = []
        for c in corrections {
            let n: Int = lock.withLock { file.candidates[Self.key(c), default: 0] += 1; return file.candidates[Self.key(c)]! }
            if n >= Self.promoteAfter {
                lock.withLock { file.candidates[Self.key(c)] = nil }
                add(c.to, source: "learned", heardAs: [c.from.lowercased()])
                if let e = entries.first(where: { $0.term == c.to }) { promoted.append(e) }
            }
        }
        persist()
        return promoted
    }

    /// Whisper's initial prompt biases spelling. It holds roughly 220 tokens, so newest terms win.
    public func whisperPrompt() -> String? {
        var terms: [String] = []; var chars = 0
        for e in entries { if chars + e.term.count > 560 { break }; terms.append(e.term); chars += e.term.count + 2 }
        return terms.isEmpty ? nil : terms.joined(separator: ", ") + "."
    }

    public func promptLines() -> [String] {
        entries.prefix(300).map { $0.heardAs.isEmpty ? $0.term : "\($0.term) (sometimes transcribed as: \($0.heardAs.joined(separator: ", ")))" }
    }

    /// Deterministic fix for known mishearings of names and technical terms, so it also works with no model.
    /// Limited to targets that look like proper nouns or identifiers, to keep ordinary words untouched.
    public func applyKnownFixes(to text: String) -> String {
        var out = text
        for e in entries where e.term.contains(where: { $0.isUppercase || $0.isNumber }) {
            for wrong in e.heardAs where wrong.count >= 3 {
                let pattern = "(?i)(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: wrong))(?![\\p{L}\\p{N}])"
                out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: e.term), options: .regularExpression)
            }
        }
        return out
    }
}

// MARK: - Learning from edits

public enum EditDiff {
    struct Token { let text: String; let norm: String; let range: Range<String.Index> }

    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            let start = i
            while i < s.endIndex, !s[i].isWhitespace { i = s.index(after: i) }
            if start < i {
                let word = String(s[start..<i]).trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                out.append(Token(text: word, norm: word.lowercased(), range: start..<i))
            }
        }
        return out
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Finds what became of `inserted` inside the field's current value.
    /// Returns nil when the text is gone or unrecognisable (sent, deleted, another field).
    public static func compare(inserted: String, field: String) -> (finalText: String, corrections: [Correction])? {
        let a = tokens(inserted), b = tokens(field)
        guard !a.isEmpty, !b.isEmpty, b.count <= 6000 else { return nil }
        // Longest common subsequence over normalised words.
        var dp = [[Int32]](repeating: [Int32](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i].norm == b[j].norm && !a[i].norm.isEmpty ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i].norm == b[j].norm, !a[i].norm.isEmpty { pairs.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        guard let first = pairs.first, let last = pairs.last, Double(pairs.count) >= Double(a.count) * 0.6 else { return nil }
        let start = max(0, first.1 - first.0), end = min(b.count - 1, last.1 + (a.count - 1 - last.0))
        let finalText = String(field[b[start].range.lowerBound..<b[end].range.upperBound])

        var corrections: [Correction] = []
        // Words replaced between two anchors: a vocabulary fix if short and similar-sounding (not a rephrase).
        let anchors = [(-1, start - 1)] + pairs + [(a.count, end + 1)]
        for (p, q) in zip(anchors, anchors.dropFirst()) {
            let from = (p.0 + 1..<q.0).map { a[$0].text }, to = (p.1 + 1..<q.1).map { b[$0].text }
            guard (1...2).contains(from.count), (1...2).contains(to.count) else { continue }
            let f = from.joined(separator: " "), t = to.joined(separator: " ")
            let dist = levenshtein(f.lowercased(), t.lowercased())
            if !f.isEmpty, !t.isEmpty, dist > 0, Double(dist) <= Double(max(f.count, t.count)) * 0.6 { corrections.append(Correction(from: f, to: t)) }
        }
        // Same word, new casing: learn brand-style capitals (GitHub, iOS, API), ignore sentence starts.
        for (x, y) in pairs where a[x].text != b[y].text {
            let t = b[y].text
            if t.dropFirst().contains(where: \.isUppercase) { corrections.append(Correction(from: a[x].text, to: t)) }
        }
        return (finalText, corrections)
    }
}

/// Watches what happens to an insertion: a few seconds later, and again at the next dictation.
public actor EditLearner {
    private let reader: ContextReader
    private let dictionary: DictionaryStore
    private let setFinal: @Sendable (String, String) async -> Void
    private var pending: DictationRecord?
    private var counted = Set<Correction>()

    public init(reader: ContextReader, dictionary: DictionaryStore, setFinal: @escaping @Sendable (String, String) async -> Void) {
        self.reader = reader; self.dictionary = dictionary; self.setFinal = setFinal
    }

    public func track(_ rec: DictationRecord) { pending = rec; counted = [] }

    /// Reads the focused field back and learns from the difference. Returns newly promoted entries.
    @discardableResult
    public func check() async -> [DictEntry] {
        guard let rec = pending else { return [] }
        let ctx = await reader.currentContext()
        guard ctx.bundleID == rec.context.bundleID, let field = await reader.focusedFieldText(),
              let diff = EditDiff.compare(inserted: rec.inserted, field: field) else { return [] }
        if diff.finalText != rec.inserted { await setFinal(rec.id, diff.finalText) }
        let fresh = diff.corrections.filter { !counted.contains($0) }   // one vote per dictation
        counted.formUnion(fresh)
        return dictionary.record(fresh)
    }
}
