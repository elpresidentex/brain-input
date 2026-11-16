import Foundation

/// A set of clean-up instructions tied to apps and websites.
public struct Mode: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var instructions: String
    /// Bundle identifiers; an entry ending in "." matches as a prefix (e.g. "com.jetbrains.").
    public var bundleIDs: [String]
    /// Substrings matched against the page URL (or the window title when no URL is readable).
    public var urlPatterns: [String]
    /// Read the visible text of the focused window so on-screen names are spelled as shown.
    public var readsScreen: Bool
    public var builtIn: Bool

    public init(id: String, name: String, instructions: String, bundleIDs: [String] = [], urlPatterns: [String] = [],
                readsScreen: Bool = false, builtIn: Bool = false) {
        self.id = id; self.name = name; self.instructions = instructions; self.bundleIDs = bundleIDs
        self.urlPatterns = urlPatterns; self.readsScreen = readsScreen; self.builtIn = builtIn
    }

    public static let defaults: [Mode] = [
        Mode(id: "coding", name: "Coding", instructions: """
            The text is a prompt for a coding assistant, or a note typed in a code editor or terminal. Write it the way a developer \
            types an instruction: direct and precise, no pleasantries. Spell file names, identifiers, commands and technical terms \
            exactly as they appear in <screen> and <dictionary>: spoken "pipeline dot swift" becomes Pipeline.swift, "user underscore \
            id" becomes user_id, and casing follows what is on screen. Do not write code the speaker did not dictate, and do not \
            carry out or answer the prompt; the output is the prompt itself.
            """,
             bundleIDs: ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.apple.Terminal",
                         "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.zed.Zed", "com.mitchellh.ghostty",
                         "com.anthropic.claudefordesktop", "com.exafunction.windsurf", "com.openai.chat", "com.jetbrains."],
             urlPatterns: ["github.com", "gitlab.com", "claude.ai", "chatgpt.com", "localhost"], readsScreen: true, builtIn: true),
        Mode(id: "chat", name: "Chat", instructions: """
            A casual chat message. Keep it short and relaxed, the way people type in a messenger. A message of one sentence has no \
            full stop at the end. No greeting and no sign-off unless spoken. Keep it as informal as it was said.
            """,
             bundleIDs: ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
                         "com.hnc.Discord", "org.whispersystems.signal-desktop", "com.microsoft.teams2"],
             urlPatterns: ["slack.com", "web.whatsapp.com", "discord.com", "teams.microsoft.com", "messenger.com", "web.telegram.org"], builtIn: true),
        Mode(id: "email", name: "Email", instructions: """
            The body of an email. Use paragraphs; put a spoken greeting and a spoken sign-off on their own lines. If the dictation is \
            a whole email (it opens by addressing someone) and <style> states the speaker's usual sign-off for this language, end with \
            that sign-off. Otherwise add no greeting, sign-off or name that was not spoken. Keep the level of formality as spoken.
            """,
             bundleIDs: ["com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron", "com.readdle.SparkDesktop", "com.mimestream.Mimestream"],
             urlPatterns: ["mail.google.com", "outlook.live.com", "outlook.office.com", "mail.proton.me", "- Gmail"], builtIn: true),
        Mode(id: "notes", name: "Notes", instructions: """
            Notes the speaker writes for themselves. Keep the terse phrasing; fragments are fine. Use lists when the speaker lists \
            things and a short heading line only when the speaker names a topic. No pleasantries.
            """,
             bundleIDs: ["com.apple.Notes", "md.obsidian", "notion.id", "net.shinyfrog.bear", "com.apple.TextEdit", "com.lukilabs.lukiapp",
                         "com.apple.iWork.Pages", "com.microsoft.Word", "com.apple.reminders"],
             urlPatterns: ["notion.so", "docs.google.com", "keep.google.com"], builtIn: true),
        Mode(id: "default", name: "Default", instructions: "Clean prose in the speaker's own register.", builtIn: true),
    ]
}

public final class ModeStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var modes: [Mode]

    public init(url: URL = BrainPaths.supportDir.appendingPathComponent("modes.json")) {
        self.url = url
        if let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([Mode].self, from: d), !m.isEmpty { modes = m }
        else { modes = Mode.defaults }
        if !modes.contains(where: { $0.id == "default" }) { modes.append(Mode.defaults.last!) }
    }

    public var all: [Mode] { lock.withLock { modes } }

    public func save(_ new: [Mode]) {
        lock.withLock { modes = new }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(new).write(to: url, options: .atomic)
    }

    public func mode(id: String) -> Mode? { all.first { $0.id == id } }

    /// Website first (a browser shows many kinds of page), then the app itself, then the default.
    public func resolve(_ ctx: AppContext) -> Mode {
        let all = self.all
        let page = (ctx.url ?? "").lowercased(), title = ctx.windowTitle.lowercased()
        if !page.isEmpty || Self.isBrowser(ctx.bundleID) {
            let haystack = page.isEmpty ? title : page
            for m in all { if m.urlPatterns.contains(where: { !$0.isEmpty && haystack.contains($0.lowercased()) }) { return m } }
        }
        for m in all {
            if m.bundleIDs.contains(where: { $0.hasSuffix(".") ? ctx.bundleID.hasPrefix($0) : $0 == ctx.bundleID }) { return m }
        }
        return all.first { $0.id == "default" } ?? Mode.defaults.last!
    }

    static func isBrowser(_ id: String) -> Bool {
        ["safari", "chrome", "browser", "firefox", "edgemac", "vivaldi", "zen", "arc", "dia", "atlas"].contains { id.lowercased().contains($0) }
    }
}
