import Foundation

// MARK: - Edges of the pipeline. Everything behind these protocols is testable without permissions.

public struct Transcript: Sendable, Equatable {
    public var text: String
    public var language: String?
    /// Timing from inside the engine; nil for engines that do not report it.
    public var stats: TranscribeStats?
    /// Word pieces with their times in seconds from the start of the samples, for engines that report them
    /// (Parakeet). Joined in order they give `text`, up to surrounding whitespace.
    public var tokens: [TimedToken]?
    public init(text: String, language: String? = nil, stats: TranscribeStats? = nil, tokens: [TimedToken]? = nil) {
        self.text = text; self.language = language; self.stats = stats; self.tokens = tokens
    }
}

public struct TimedToken: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// Speech to text. Samples are 16 kHz mono Float32.
public protocol Transcriber: Sendable {
    func transcribe(samples: [Float], prompt: String?) async throws -> Transcript
    /// Same, with the language fixed (ISO code such as "de"); engines without language selection ignore it.
    /// Used for the second and later chunks of a dictation, so a short chunk cannot flip to another language.
    func transcribe(samples: [Float], prompt: String?, language: String?) async throws -> Transcript
}

extension Transcriber {
    public func transcribe(samples: [Float], prompt: String?, language: String?) async throws -> Transcript {
        try await transcribe(samples: samples, prompt: prompt)
    }
}

public struct AppContext: Sendable, Codable, Equatable {
    public var bundleID: String
    public var appName: String
    public var windowTitle: String
    public var url: String?
    public init(bundleID: String = "", appName: String = "", windowTitle: String = "", url: String? = nil) {
        self.bundleID = bundleID; self.appName = appName; self.windowTitle = windowTitle; self.url = url
    }
}

/// Reads the frontmost app, its window, and (where Accessibility allows) text on screen.
public protocol ContextReader: Sendable {
    func currentContext() async -> AppContext
    /// Text visible in the focused window; used by modes that read the screen.
    func visibleText(maxChars: Int) async -> String?
    /// Full value of the focused text field, or nil if the app does not expose it.
    func focusedFieldText() async -> String?
}

public protocol TextInserter: Sendable {
    /// Inserts at the cursor. Returns false if the text could not be delivered.
    func insert(_ text: String) async -> Bool
    /// Swaps the previously inserted text for another version.
    func replaceLast(_ old: String, with new: String) async -> Bool
}

/// The clean-up model. Claude today; a local model can implement this later.
public protocol LanguageModel: Sendable {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
    /// Same call, plus token usage and cost when the provider reports them.
    func completeDetailed(system: String, user: String, maxTokens: Int) async throws -> Completion
}

extension LanguageModel {
    public func completeDetailed(system: String, user: String, maxTokens: Int) async throws -> Completion {
        Completion(text: try await complete(system: system, user: user, maxTokens: maxTokens))
    }
}

public struct PolishResult: Sendable {
    public var text: String?      // nil means: use the raw transcript
    public var modeID: String
    public var status: String     // ok | no-key | timeout | error: … | disabled
    public var ms: Int
    public var costUSD: Double?
    public var detail: CleanupDetail?
    public init(text: String?, modeID: String, status: String, ms: Int, costUSD: Double? = nil, detail: CleanupDetail? = nil) {
        self.text = text; self.modeID = modeID; self.status = status; self.ms = ms; self.costUSD = costUSD; self.detail = detail
    }
}

public protocol Polisher: Sendable {
    func polish(raw: String, language: String?, context: AppContext, reader: ContextReader) async -> PolishResult
}

// MARK: - Records

public struct Timings: Sendable, Codable, Equatable {
    public var audioMs = 0, transcribeMs = 0, cleanupMs = 0, insertMs = 0, totalMs = 0
    /// Fine-grained breakdown; nil for dictations recorded before it existed.
    public var detail: TimingDetail?
    public init() {}
}

public struct DictationRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: String = UUID().uuidString
    public var date = Date()
    public var context = AppContext()
    public var modeID = "default"
    public var language: String?
    public var raw = ""
    public var cleaned: String?
    public var inserted = ""
    /// Text found in the field after my own edits; the best evidence of what I wanted.
    public var finalText: String?
    public var cleanupStatus = "disabled"
    public var revertedToRaw = false
    /// API cost of this dictation's clean-up call; nil when no call was made or the model is unpriced.
    public var costUSD: Double?
    public var timings = Timings()
    public init() {}
    /// True when the inserted text is the model's clean-up rather than the raw transcript.
    public var enhanced: Bool { cleaned != nil && !revertedToRaw }
    public var best: String { finalText ?? inserted }
}

public enum BrainPaths {
    /// Markdown notes. Override with BRAININPUT_HOME (tests, experiments).
    public static var notesRoot: URL {
        if let p = ProcessInfo.processInfo.environment["BRAININPUT_HOME"] { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BrainInput")
    }
    public static var supportDir: URL {
        if let p = ProcessInfo.processInfo.environment["BRAININPUT_SUPPORT"] { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrainInput")
    }
}

public func msSince(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
