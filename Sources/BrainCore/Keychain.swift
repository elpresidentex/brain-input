import Foundation
import Security

/// The Claude API key lives in the login keychain, never in a file or in UserDefaults.
public enum Keychain {
    static let service = "BrainInput", account = "anthropic-api-key"
    private static var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }

    /// A sandboxed run (BRAININPUT_SUPPORT set: tests, snapshots, a trial of the setup guide) never touches the real keychain.
    static var sandboxed: Bool { ProcessInfo.processInfo.environment["BRAININPUT_SUPPORT"] != nil }

    public static func setAPIKey(_ key: String?) {
        guard !sandboxed else { return }
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmed, !key.isEmpty else { return }
        var q = base; q[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    public static func apiKey() -> String? {
        guard !sandboxed else { return nil }
        var q = base; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
