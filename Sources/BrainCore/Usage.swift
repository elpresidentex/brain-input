import Foundation

/// Token counts exactly as the Messages API reports them in `usage`.
public struct TokenUsage: Codable, Sendable, Equatable {
    public var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
    /// `input_tokens` excludes cached tokens; `output_tokens` includes thinking.
    public init?(response: [String: Any]) {
        guard let u = response["usage"] as? [String: Any], u["input_tokens"] != nil || u["output_tokens"] != nil else { return nil }
        self.init(input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
                  cacheRead: u["cache_read_input_tokens"] as? Int ?? 0, cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0)
    }
    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

/// USD per million tokens. Rates are the published ones as of 2026-11-03 (standard, non-batch, prompts under 100K tokens).
/// Cache writes (5 min) cost 1.25x input. Cache-read rates differ per model; where the published figure was not at hand
/// the table uses 0.1x input, which can only overstate. A model missing from the table is reported as unpriced, never guessed.
public enum Pricing {
    public struct Rate: Sendable { public var input, output, cacheRead: Double }
    static let table: [String: Rate] = [
        "claude-haiku-5-5": Rate(input: 0.10, output: 0.50, cacheRead: 0.01),
        "claude-sonnet-5-5": Rate(input: 2.00, output: 10.00, cacheRead: 0.10),
        "claude-sonnet-5": Rate(input: 2.00, output: 10.00, cacheRead: 0.20),
        "claude-opus-5-5": Rate(input: 4.00, output: 20.00, cacheRead: 0.20),
        "claude-opus-5": Rate(input: 5.00, output: 25.00, cacheRead: 0.50),
        "claude-fable-5-2": Rate(input: 8.00, output: 40.00, cacheRead: 0.20),
        "claude-haiku-4-5": Rate(input: 1.00, output: 5.00, cacheRead: 0.10),
        "claude-sonnet-4-6": Rate(input: 3.00, output: 15.00, cacheRead: 0.30),
    ]
    /// nil when the model is not in the table.
    public static func cost(model: String, usage u: TokenUsage) -> Double? {
        guard let r = table[model] else { return nil }
        return (Double(u.input) * r.input + Double(u.output) * r.output
                + Double(u.cacheRead) * r.cacheRead + Double(u.cacheWrite) * r.input * 1.25) / 1_000_000
    }
}

public struct Completion: Sendable {
    public var text: String
    public var usage: TokenUsage?
    public var costUSD: Double?
    public init(text: String, usage: TokenUsage? = nil, costUSD: Double? = nil) { self.text = text; self.usage = usage; self.costUSD = costUSD }
}

public struct UsageEntry: Codable, Sendable {
    public var date: Date
    public var model: String
    public var purpose: String
    public var usage: TokenUsage
    /// nil: the model has no entry in the price table.
    public var costUSD: Double?
}

public struct UsageSummary: Sendable {
    public var calls = 0
    public var tokens = TokenUsage()
    public var costUSD = 0.0
    public var unpricedCalls = 0
}

/// Append-only log of every billed API call the app made (usage.jsonl in the support folder).
public final class UsageLedger: @unchecked Sendable {
    public static let shared = UsageLedger()
    private let lock = NSLock()
    private let url: URL

    public init(url: URL = BrainPaths.supportDir.appendingPathComponent("usage.jsonl")) { self.url = url }

    public func record(model: String, purpose: String, usage: TokenUsage) -> Double? {
        let cost = Pricing.cost(model: model, usage: usage)
        let entry = UsageEntry(date: Date(), model: model, purpose: purpose, usage: usage, costUSD: cost)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(entry) else { return cost }
        line.append(10)
        lock.withLock {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: line) }
            else { try? line.write(to: url) }
        }
        return cost
    }

    public func entries() -> [UsageEntry] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let data = lock.withLock { try? Data(contentsOf: url) } ?? Data()
        return data.split(separator: 10).compactMap { try? dec.decode(UsageEntry.self, from: Data($0)) }
    }

    public static func summarize(_ entries: [UsageEntry], since: Date? = nil) -> UsageSummary {
        var s = UsageSummary()
        for e in entries where since.map({ e.date >= $0 }) ?? true {
            s.calls += 1; s.tokens = s.tokens + e.usage
            if let c = e.costUSD { s.costUSD += c } else { s.unpricedCalls += 1 }
        }
        return s
    }

    public static func format(_ usd: Double) -> String {
        usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
    }
}
