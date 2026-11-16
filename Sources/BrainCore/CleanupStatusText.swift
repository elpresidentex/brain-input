import Foundation

/// Short, user-facing wording for the clean-up status stored with each dictation.
/// The stored status keeps the raw detail for the log; only what users see goes through here.
public enum CleanupStatusText {
    /// A short reason, used in history chips ("raw · timed out") and notices ("Not enhanced · timed out").
    public static func reason(_ status: String) -> String {
        switch status {
        case "ok": return "enhanced"
        case "timeout": return "timed out"
        case "cancelled": return "cancelled"
        case "no-key": return "no API key"
        case "disabled": return "clean-up off"
        case "error: rejected output": return "unexpected answer"
        default:
            if status.hasPrefix("skipped") { return "too short" }
            if status.contains("HTTP 401") || status.contains("HTTP 403") { return "API key rejected" }
            if status.contains("HTTP 429") { return "rate limit reached" }
            if status.contains("HTTP 529") || status.contains("HTTP 5") { return "Claude is busy" }
            if status.hasPrefix("error") { return "clean-up failed" }
            return "not enhanced"
        }
    }
}
