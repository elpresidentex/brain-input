import Foundation

/// The only thing the app reports about itself: one "installed" event on the very first launch and one "opened"
/// event per launch, so the author can see whether anyone uses it. Each event carries the app version and the
/// macOS major version and a throwaway random id that is never stored, so launches cannot be linked to each
/// other or to a person. Nothing about dictations, files or settings. Off with one switch in Settings.
enum Telemetry {
    static let host = URL(string: "https://us.i.posthog.com/i/v0/e/")!
    static let projectKey = "phc_kGBs2Ae5MnJH3yZgDVbXenZY6ZP2SFCjs4iNSVsnkq3p"   // public write-only key
    static let enabledKey = "anonymousPing"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func appOpened() {
        // Not from development builds, tests or sandboxed renders.
        guard enabled, AppInfo.version != "dev", ProcessInfo.processInfo.environment["BRAININPUT_SUPPORT"] == nil else { return }
        let d = UserDefaults.standard
        if !d.bool(forKey: "installPingSent") { d.set(true, forKey: "installPingSent"); send("app_installed") }
        send("app_opened")
    }

    private static func send(_ event: String) {
        let body: [String: Any] = [
            "api_key": projectKey, "event": event, "distinct_id": "anon-" + UUID().uuidString,
            "properties": ["app": "brain-input", "app_version": AppInfo.version,
                           "macos": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                           "$process_person_profile": false, "$geoip_disable": true],
        ]
        var req = URLRequest(url: host)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req).resume()
    }
}
