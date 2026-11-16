import AVFoundation
import BrainCore
import BrainWhisper
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("hotkeyMode") private var hotkeyMode = "hybrid"
    @AppStorage("whisperModel") private var whisperModel = ModelLocator.preferredModel
    @AppStorage("cleanupEnabled") private var cleanupEnabled = true
    @AppStorage("claudeModel") private var claudeModel = "claude-haiku-5-5"
    @AppStorage("cleanupTimeout") private var cleanupTimeout = 3.0
    @AppStorage("autoLearn") private var autoLearn = true
    @AppStorage("offerMeetings") private var offerMeetings = true
    @AppStorage("showCostAfterDictation") private var showCost = false
    @State private var usage: [UsageEntry] = UsageLedger.shared.entries()
    @State private var apiKey = ""
    @State private var keyNote = ""
    @State private var launchAtLogin = LoginItem.enabled
    @State private var anonymousPing = Telemetry.enabled
    @State private var keyStored = false
    @State private var axTrusted = ClipboardPaster.trusted
    @State private var mic = MicRecorder.permission

    var body: some View {
        Form {
            SwiftUI.Section("General") {
                Toggle("Start Brain Input when I log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.set(launchAtLogin); launchAtLogin = LoginItem.enabled }
                Button("Open the setup guide…") { OnboardingController.shared.show() }
                Toggle("Count app opens anonymously", isOn: $anonymousPing).onChange(of: anonymousPing) { Telemetry.enabled = anonymousPing }
                Text("Sends \"opened\" with the app and macOS version when the app starts, so I can see whether anyone uses it. No ID, nothing about what you dictate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Shortcuts") {
                ShortcutField(title: "Dictate", get: { Pref.dictate }, set: { Pref.dictate = $0 })
                ShortcutField(title: "Swap last dictation for raw", get: { Pref.undo }, set: { Pref.undo = $0 })
                if !HotkeyCenter.shared.failed.isEmpty {
                    Label("macOS could not register a shortcut, most likely because another app uses it. Pick a different one.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("Dictate key behaviour", selection: $hotkeyMode) {
                    Text("Hold to talk, tap to toggle").tag("hybrid")
                    Text("Hold to talk").tag("hold")
                    Text("Press to toggle").tag("toggle")
                }
            }
            SwiftUI.Section("Speech to text (on this Mac)") {
                ForEach(ModelLocator.catalog) { ModelCard(model: $0) }
                let extra = ModelLocator.available().filter { id in !ModelLocator.catalog.contains { $0.id == id } }
                if !extra.isEmpty {
                    Picker("Other models in the models folder", selection: $whisperModel) {
                        ForEach(ModelLocator.available(), id: \.self) { Text(ModelLocator.displayName($0)).tag($0) }
                    }.onChange(of: whisperModel) { state.loadModel() }
                }
                Text(state.modelStatus).font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Clean-up (Claude API)") {
                Toggle("Clean up dictations", isOn: $cleanupEnabled).onChange(of: cleanupEnabled) { state.buildPipeline() }
                LabeledContent("API key") {
                    HStack {
                        SecureField(keyStored ? "Stored in Keychain" : "sk-ant-…", text: $apiKey).frame(width: 260)
                        Button("Save") {
                            let key = apiKey
                            Keychain.setAPIKey(key); apiKey = ""; keyStored = Keychain.apiKey() != nil; state.buildPipeline()
                            Task { keyNote = await ClaudeModel.validate(apiKey: key) == .invalid ? "Anthropic rejected this key. Check that you copied all of it." : "" }
                        }.disabled(apiKey.isEmpty)
                        if keyStored { Button("Remove") { Keychain.setAPIKey(nil); keyStored = false; state.buildPipeline() } }
                    }
                }
                if !keyNote.isEmpty { Text(keyNote).font(.caption).foregroundStyle(.red) }
                TextField("Model ID", text: $claudeModel).onSubmit { state.buildPipeline() }
                LabeledContent("Give up and paste raw after") {
                    HStack { Slider(value: $cleanupTimeout, in: 1...8, step: 0.5).frame(width: 180); Text("\(cleanupTimeout, specifier: "%.1f") s").monospacedDigit() }
                }.onChange(of: cleanupTimeout) { state.buildPipeline() }
                Text("Only the transcript, app name, window title, your style card and dictionary are sent. Audio never leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("API usage and cost") {
                UsageRow(title: "Today", s: UsageLedger.summarize(usage, since: Calendar.current.startOfDay(for: Date())))
                UsageRow(title: "Last 30 days", s: UsageLedger.summarize(usage, since: Date().addingTimeInterval(-30 * 86400)))
                UsageRow(title: "All time", s: UsageLedger.summarize(usage))
                Toggle("Show the cost after each dictation", isOn: $showCost)
                Text("Computed from the token counts the API returns, at the published rates, for calls this app made (clean-up, style cards, meeting summaries). A call that timed out or was cancelled mid-flight may still be billed but is not counted; check the Anthropic Console for the authoritative total. Batch eval runs from the command line are not included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Learning") {
                Toggle("Learn vocabulary and tone from my edits", isOn: $autoLearn)
            }
            SwiftUI.Section("Meetings") {
                Toggle("Offer to record when a call is detected", isOn: $offerMeetings)
            }
            SwiftUI.Section("Permissions") {
                LabeledContent("Microphone") {
                    HStack {
                        StatusDot(ok: mic == .authorized)
                        Button(mic == .authorized ? "Granted" : "Request") { Task { _ = await MicRecorder.requestPermission(); mic = MicRecorder.permission } }
                            .disabled(mic == .authorized)
                    }
                }
                LabeledContent("Accessibility (paste, read context, learn from edits)") {
                    HStack {
                        StatusDot(ok: axTrusted)
                        Button(axTrusted ? "Granted" : "Open prompt") {
                            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                        }.disabled(axTrusted)
                    }
                }
                Text("System audio for meetings is requested the first time you start a meeting recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("About") {
                LabeledContent("Version", value: AppInfo.version)
                Link("Check for a newer version", destination: AppInfo.releases)
                Link("Report a problem or suggest something", destination: AppInfo.issues)
                Link("Source code and licences (GPL-3.0)", destination: AppInfo.repo)
                Link("Privacy", destination: AppInfo.privacy)
                Text("Free software, provided without warranty. Speech recognition by NVIDIA Parakeet (via FluidAudio) and OpenAI Whisper (via whisper.cpp). Parts are adapted from VoiceInk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { keyStored = Keychain.apiKey() != nil }
        .task { while !Task.isCancelled { axTrusted = ClipboardPaster.trusted; mic = MicRecorder.permission; usage = UsageLedger.shared.entries(); try? await Task.sleep(for: .seconds(2)) } }
    }
}

struct StatusDot: View {
    var ok: Bool
    var body: some View { Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8) }
}

struct UsageRow: View {
    var title: String
    var s: UsageSummary
    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(UsageLedger.format(s.costUSD)).monospacedDigit().bold()
                Text("\(s.calls) calls · \(s.tokens.input + s.tokens.cacheRead + s.tokens.cacheWrite) in · \(s.tokens.output) out")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if s.unpricedCalls > 0 { Text("\(s.unpricedCalls) calls on an unpriced model are not in the total").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

/// Where the project lives. One place to change when the name or home changes.
enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let repo = URL(string: "https://github.com/elpresidentex/brain-input")!
    static let releases = URL(string: "https://github.com/elpresidentex/brain-input/releases/latest")!
    static let issues = URL(string: "https://github.com/elpresidentex/brain-input/issues")!
    static let privacy = URL(string: "https://brain-input.vercel.app/privacy.html")!
}
