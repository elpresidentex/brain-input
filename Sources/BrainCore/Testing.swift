import Foundation

// Stand-ins for the edges, used by the test suite and by `brain` when no permission or key exists.

public final class MockInserter: TextInserter, @unchecked Sendable {
    public private(set) var field = ""
    public var succeed = true
    public init() {}
    public func insert(_ text: String) async -> Bool { if succeed { field += text }; return succeed }
    public func replaceLast(_ old: String, with new: String) async -> Bool {
        guard let r = field.range(of: old, options: .backwards) else { return false }
        field.replaceSubrange(r, with: new); return true
    }
    public func setField(_ s: String) { field = s }
}

public final class MockContextReader: ContextReader, @unchecked Sendable {
    public var context: AppContext
    public var visible: String?
    public var field: String?
    public init(context: AppContext = AppContext(bundleID: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled"),
                visible: String? = nil, field: String? = nil) {
        self.context = context; self.visible = visible; self.field = field
    }
    public func currentContext() async -> AppContext { context }
    public func visibleText(maxChars: Int) async -> String? { visible.map { String($0.prefix(maxChars)) } }
    public func focusedFieldText() async -> String? { field }
}

public final class MockTranscriber: Transcriber, @unchecked Sendable {
    public var result: Transcript
    public private(set) var prompts: [String?] = []
    public init(_ text: String, language: String? = "en") { result = Transcript(text: text, language: language) }
    public func transcribe(samples: [Float], prompt: String?) async throws -> Transcript { prompts.append(prompt); return result }
}

public final class MockLanguageModel: LanguageModel, @unchecked Sendable {
    public var reply: @Sendable (_ system: String, _ user: String) async throws -> String
    public private(set) var calls: [(system: String, user: String)] = []
    private let lock = NSLock()
    public init(reply: @escaping @Sendable (String, String) async throws -> String) { self.reply = reply }
    public convenience init(_ fixed: String) { self.init { _, _ in fixed } }
    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        lock.withLock { calls.append((system, user)) }
        return try await reply(system, user)
    }
}
