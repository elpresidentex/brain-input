import Foundation

public struct ClaudeError: Error, CustomStringConvertible { public let description: String }

/// Collects the transport timing of one request.
final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value: NetTiming?
    var timing: NetTiming? { lock.withLock { value } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let m = metrics.transactionMetrics.last else { return }
        func ms(_ a: Date?, _ b: Date?) -> Int { a.flatMap { a in b.map { Int($0.timeIntervalSince(a) * 1000) } } ?? 0 }
        var t = NetTiming()
        t.reusedConnection = m.isReusedConnection
        t.connectMs = m.isReusedConnection ? 0 : ms(m.domainLookupStartDate ?? m.connectStartDate, m.secureConnectionEndDate ?? m.connectEndDate)
        t.ttfbMs = ms(m.requestEndDate, m.responseStartDate)
        t.downloadMs = ms(m.responseStartDate, m.responseEndDate)
        t.proto = m.networkProtocolName ?? ""
        lock.withLock { value = t }
    }
}

/// Claude Messages API over URLSession (there is no official Swift SDK). Only text is ever sent.
public struct ClaudeModel: LanguageModel {
    public var apiKey: String
    public var model: String
    /// true: thinking off and low effort, for the latency-critical clean-up call.
    /// false: the model's default adaptive thinking, for style cards and meeting summaries.
    public var fast: Bool
    /// When set, every successful call is recorded here (the app sets it; the CLI and tests leave it nil).
    public var ledger: UsageLedger?
    public var purpose = "cleanup"
    static let base = URL(string: "https://api.anthropic.com/v1/")!

    public init(apiKey: String, model: String = "claude-haiku-5-5", fast: Bool = true) {
        self.apiKey = apiKey; self.model = model; self.fast = fast
    }

    public func body(system: String, user: String, maxTokens: Int) -> [String: Any] {
        var b: [String: Any] = [
            "model": model,
            "max_tokens": fast ? maxTokens : max(maxTokens, 4096),
            // The system prompt is identical for every dictation in a mode, so mark it cacheable.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
        ]
        if fast { b["thinking"] = ["type": "disabled"]; b["output_config"] = ["effort": "low"] }
        return b
    }

    func request(_ path: String, method: String = "POST", json: [String: Any]? = nil) throws -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: Self.base)!)
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        if let json { r.httpBody = try JSONSerialization.data(withJSONObject: json) }
        r.timeoutInterval = fast ? 15 : 120
        return r
    }

    func send(_ r: URLRequest) async throws -> Data { try await sendTimed(r).0 }

    /// Same, plus connection / first-byte / download timing from URLSessionTaskMetrics.
    func sendTimed(_ r: URLRequest) async throws -> (Data, NetTiming?) {
        let collector = MetricsCollector()
        let (data, resp) = try await URLSession.shared.data(for: r, delegate: collector)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ClaudeError(description: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
        }
        return (data, collector.timing)
    }

    public enum KeyCheck: Sendable { case valid, invalid, unknown }

    /// Asks the free model-list endpoint whether the key is accepted. No tokens are used. `unknown`: no answer (offline).
    public static func validate(apiKey: String) async -> KeyCheck {
        var r = URLRequest(url: URL(string: "models?limit=1", relativeTo: base)!)
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.timeoutInterval = 8
        guard let (_, resp) = try? await URLSession.shared.data(for: r), let http = resp as? HTTPURLResponse else { return .unknown }
        switch http.statusCode {
        case 200: return .valid
        case 401, 403: return .invalid
        default: return .unknown
        }
    }

    /// Text of a Messages response. Blocks are read by type: thinking blocks may come first.
    public static func text(of message: [String: Any]) throws -> String {
        let stop = message["stop_reason"] as? String
        guard stop != "refusal", stop != "max_tokens" else { throw ClaudeError(description: "stopped: \(stop ?? "")") }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await completeDetailed(system: system, user: user, maxTokens: maxTokens).text
    }

    public func completeDetailed(system: String, user: String, maxTokens: Int) async throws -> Completion {
        let (data, net) = try await sendTimed(try request("messages", json: body(system: system, user: user, maxTokens: maxTokens)))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeError(description: "bad response") }
        // Billed even if the text is then rejected (refusal, max_tokens), so record before reading it.
        let usage = TokenUsage(response: obj)
        let cost = usage.flatMap { ledger?.record(model: model, purpose: purpose, usage: $0) ?? Pricing.cost(model: model, usage: $0) }
        return Completion(text: try Self.text(of: obj), usage: usage, costUSD: cost, net: net)
    }

    /// Message Batches API: half price, asynchronous. Used for fixture and eval runs, never for dictation.
    public func runBatch(_ items: [(id: String, system: String, user: String)], maxTokens: Int = 1024,
                         progress: (String) -> Void = { _ in }) async throws -> [String: Result<String, Error>] {
        let reqs = items.map { ["custom_id": $0.id, "params": body(system: $0.system, user: $0.user, maxTokens: maxTokens)] as [String: Any] }
        var obj = try JSONSerialization.jsonObject(with: try await send(try request("messages/batches", json: ["requests": reqs]))) as? [String: Any] ?? [:]
        guard let id = obj["id"] as? String else { throw ClaudeError(description: "no batch id") }
        progress("batch \(id) submitted")
        while obj["processing_status"] as? String != "ended" {
            try await Task.sleep(for: .seconds(10))
            obj = try JSONSerialization.jsonObject(with: try await send(try request("messages/batches/\(id)", method: "GET"))) as? [String: Any] ?? [:]
            progress("status: \(obj["processing_status"] as? String ?? "?")")
        }
        guard let resultsURL = (obj["results_url"] as? String).flatMap(URL.init(string:)) else { throw ClaudeError(description: "no results_url") }
        var r = try request("messages", method: "GET"); r.url = resultsURL
        var out: [String: Result<String, Error>] = [:]
        for line in String(data: try await send(r), encoding: .utf8)?.split(separator: "\n") ?? [] {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let cid = row["custom_id"] as? String else { continue }
            let result = row["result"] as? [String: Any] ?? [:]
            if result["type"] as? String == "succeeded", let msg = result["message"] as? [String: Any] { out[cid] = Result { try Self.text(of: msg) } }
            else { out[cid] = .failure(ClaudeError(description: "batch result: \(result["type"] as? String ?? "?")")) }
        }
        return out
    }
}

// MARK: - Clean-up fixtures (Fixtures/cleanup.json)

public struct CleanupFixture: Codable, Sendable {
    public var id: String
    public var mode: String
    public var app: String
    public var language: String
    public var raw: String
    public var screen: String?
    public var dictionary: [String]?
    public var style: String?
    /// A hand-written acceptable answer; the mock provider returns it, which keeps the checks honest.
    public var ideal: String
    public var must: [String]
    public var mustNot: [String]
    public var note: String

    public static func load(_ url: URL) throws -> [CleanupFixture] { try JSONDecoder().decode([CleanupFixture].self, from: Data(contentsOf: url)) }

    public func prompts(modes: ModeStore) -> (system: String, user: String) {
        let m = modes.mode(id: mode) ?? Mode.defaults.last!
        return (CleanupPrompt.system(mode: m, styleCard: style, dictionary: dictionary ?? []),
                CleanupPrompt.user(raw: raw, language: language, context: AppContext(appName: app, windowTitle: ""), screen: screen))
    }

    /// Reasons this output fails; empty means pass. Substring checks ignore case.
    public func grade(_ output: String) -> [String] {
        var problems: [String] = []
        let o = output.lowercased()
        for m in must where !o.contains(m.lowercased()) { problems.append("missing \"\(m)\"") }
        for m in mustNot where o.contains(m.lowercased()) { problems.append("contains \"\(m)\"") }
        if output.count > raw.count * 3 / 2 + 60 { problems.append("too long (\(output.count) vs \(raw.count) chars): added content?") }
        if output.trimmed.isEmpty { problems.append("empty") }
        return problems
    }
}
