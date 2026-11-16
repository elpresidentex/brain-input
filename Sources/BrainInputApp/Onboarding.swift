import AppKit
import AVFoundation
import BrainCore
import BrainWhisper
import ServiceManagement
import SwiftUI

// MARK: - Model downloads (shared by the setup guide and Settings)

@MainActor
final class ModelDownloads: ObservableObject {
    static let shared = ModelDownloads()
    @Published var progress: [String: Double] = [:]     // model id -> 0...1 while downloading
    @Published var errors: [String: String] = [:]
    @Published var tick = 0                              // bumps when the installed set changes

    func isDownloading(_ id: String) -> Bool { progress[id] != nil }

    func download(_ model: SpeechModel) {
        guard progress[model.id] == nil else { return }
        progress[model.id] = 0; errors[model.id] = nil
        Log.write("model download started: \(model.id)")
        Task {
            do {
                try await ModelLocator.download(model) { p in Task { @MainActor in
                    if let old = ModelDownloads.shared.progress[model.id], p > old { ModelDownloads.shared.progress[model.id] = p } } }
                progress[model.id] = nil; tick += 1
                Log.write("model download finished: \(model.id)")
                // The first model to arrive becomes the active one.
                if !AppState.shared.modelReady { Pref.d.set(model.id, forKey: "whisperModel"); AppState.shared.loadModel() }
            } catch {
                progress[model.id] = nil
                errors[model.id] = "Download failed: \(error.localizedDescription) Check your connection and try again."
                Log.write("model download failed: \(model.id): \(error)")
            }
        }
    }

    func remove(_ id: String) {
        ModelLocator.remove(id); tick += 1
        if Pref.whisperModel == id {
            Pref.d.set(ModelLocator.available().first ?? ModelLocator.preferredModel, forKey: "whisperModel")
            AppState.shared.loadModel()
        }
    }
}

struct ModelCard: View {
    var model: SpeechModel
    @ObservedObject var downloads = ModelDownloads.shared
    @EnvironmentObject var state: AppState
    @AppStorage("whisperModel") private var active = ModelLocator.preferredModel

    var body: some View {
        let _ = downloads.tick
        let installed = ModelLocator.isInstalled(model.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.name).font(.headline)
                if model.recommended { Chip("Recommended") }
                Spacer()
                Text("\(model.sizeMB) MB").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(model.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let p = downloads.progress[model.id] {
                    ProgressView(value: p).frame(maxWidth: .infinity)
                    Text(p >= 0.995 ? "Preparing…" : "\(Int(p * 100)) %").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else if installed {
                    Label(active == model.id ? "Installed · in use" : "Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    Spacer()
                    if active != model.id { Button("Use") { active = model.id; state.loadModel() } }
                    Button("Delete") { downloads.remove(model.id) }.disabled(state.meetingActive)
                } else {
                    Button("Download") { downloads.download(model) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    Spacer()
                }
            }
            if let e = downloads.errors[model.id] { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(model.recommended ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.1)))
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { Log.write("launch at login (\(on)) failed: \(error.localizedDescription)") }
    }
}

// MARK: - Setup guide window

@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()
    private var window: NSWindow?

    /// First run: no model on this Mac, or the guide was never finished.
    static var needed: Bool { !Pref.d.bool(forKey: "onboardingDone") }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false; w.delegate = self
        w.contentView = NSHostingView(rootView: OnboardingView(close: { [weak self] in self?.finish() })
            .environmentObject(AppState.shared).tint(Theme.accent))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func finish() {
        Pref.d.set(true, forKey: "onboardingDone")
        window?.close()
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct OnboardingView: View {
    var close: () -> Void
    @EnvironmentObject var state: AppState
    @ObservedObject var downloads = ModelDownloads.shared
    @State private var step: Int
    @State private var mic = MicRecorder.permission
    @State private var axTrusted = ClipboardPaster.trusted
    @State private var apiKey = ""
    @State private var keyStored = Keychain.apiKey() != nil
    @State private var keyStatus = ""
    @State private var checkingKey = false
    @State private var tryText = ""
    @State private var launchAtLogin = true

    init(close: @escaping () -> Void, initialStep: Int = 0) { self.close = close; _step = State(initialValue: initialStep) }

    private let titles = ["Welcome", "Speech model", "Permissions", "Clean-up", "Try it"]
    private var hasModel: Bool { let _ = downloads.tick; return !ModelLocator.available().isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { i in
                    Capsule().fill(i <= step ? Theme.accent : Color.primary.opacity(0.12)).frame(height: 4)
                }
            }.padding(.horizontal, 28).padding(.top, 36)
            Group {
                switch step {
                case 0: welcome
                case 1: model
                case 2: permissions
                case 3: cleanup
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28).padding(.top, 22)
            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Text("Step \(step + 1) of \(titles.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if step == 1 && !hasModel {
                    Button("Continue") {}.disabled(true).help("Download a speech model first")
                } else if step < titles.count - 1 {
                    Button(step == 3 && !keyStored ? "Skip for now" : "Continue") { step += 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish") { LoginItem.set(launchAtLogin); close() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(16)
        }
        .frame(width: 600, height: 560)
        .task { while !Task.isCancelled { axTrusted = ClipboardPaster.trusted; mic = MicRecorder.permission; try? await Task.sleep(for: .seconds(1)) } }
    }

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 28, weight: .semibold)).tracking(-0.8)
            Text(sub).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 14)
    }

    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.primary).frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage { Image(nsImage: icon).resizable().frame(width: 64, height: 64) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Talk. It types.").font(.system(size: 34, weight: .semibold)).tracking(-1.2)
                    Text("Brain Input turns what you say into clean text, in any app.").font(.title3).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 8)
            point("keyboard", "Hold a key, speak, release", "The text lands at your cursor, formatted for the app you are in: an email reads like an email, a chat message like a chat message.")
            point("lock.laptopcomputer", "Speech recognition stays on this Mac", "Your audio is never uploaded. Only if you add your own Claude API key is the transcript text sent for clean-up.")
            point("character.book.closed", "It learns your words", "Correct a name twice and it remembers. Meetings become Me / Them notes with a summary.")
            Spacer()
            Text("Free and open source. Setup takes about two minutes. The app counts that it was opened, anonymously; you can switch that off in Settings.").font(.callout).foregroundStyle(.secondary).padding(.bottom, 10)
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Download a speech model", "The model does the listening, on your Mac. This one download is all it needs from the internet.")
            ForEach(ModelLocator.catalog) { ModelCard(model: $0) }
            if hasModel { Label(state.modelReady ? "Ready to listen." : state.modelStatus, systemImage: state.modelReady ? "checkmark.circle" : "hourglass")
                .font(.callout).foregroundStyle(.secondary) }
            else { Text("Not sure? Take Parakeet. You can switch or add the other one later in Settings.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func permissionRow(_ title: String, _ why: String, ok: Bool, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").font(.title2).foregroundStyle(ok ? .green : .secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(ok ? "Granted" : button, action: action).disabled(ok)
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Two permissions", "macOS asks you to allow each one. You can change them any time in System Settings.")
            permissionRow("Microphone", "To hear you while you hold the dictation key. Nothing is recorded otherwise.", ok: mic == .authorized,
                          button: mic == .denied ? "Open Settings" : "Allow") {
                if mic == .denied { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
                else { Task { _ = await MicRecorder.requestPermission(); mic = MicRecorder.permission } }
            }
            permissionRow("Accessibility", "To paste the text at your cursor, see which app you are in, and learn from your corrections. Without it, text is copied to the clipboard and you paste it yourself.",
                          ok: axTrusted, button: "Open prompt") {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            Text("After you switch on Accessibility in System Settings, this page updates by itself.").font(.callout).foregroundStyle(.secondary)
            Text("Meeting recording asks for System Audio the first time you use it.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var cleanup: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Clean-up with Claude (optional)", "Without a key you get exactly what you said. With your own Claude API key, filler words and self-corrections disappear and the text is formatted for the app.")
            HStack {
                SecureField(keyStored ? "Key stored in your Keychain" : "sk-ant-…", text: $apiKey).textFieldStyle(.roundedBorder)
                Button(checkingKey ? "Checking…" : "Save") { saveKey() }.disabled(apiKey.trimmed.isEmpty || checkingKey)
                if keyStored { Button("Remove") { Keychain.setAPIKey(nil); keyStored = false; keyStatus = ""; state.buildPipeline() } }
            }
            if !keyStatus.isEmpty { Text(keyStatus).font(.callout).foregroundStyle(keyStored ? .green : .red) }
            Link("Create a key in the Claude Console", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            VStack(alignment: .leading, spacing: 6) {
                Label("You pay Anthropic directly for what you use. A dictation costs a fraction of a cent, and Settings shows your running total.", systemImage: "eurosign.circle")
                Label("Sent to Claude: the transcript, the app name and window title, your word list and style notes. Never audio.", systemImage: "arrow.up.right.circle")
                Label("The key is stored in your macOS Keychain.", systemImage: "key")
            }.font(.callout).foregroundStyle(.secondary).padding(.top, 6)
        }
    }

    private func saveKey() {
        let key = apiKey.trimmed
        checkingKey = true; keyStatus = ""
        Task {
            let result = await ClaudeModel.validate(apiKey: key)
            checkingKey = false
            switch result {
            case .valid, .unknown:
                Keychain.setAPIKey(key); apiKey = ""; keyStored = Keychain.apiKey() != nil; state.buildPipeline()
                keyStatus = result == .valid ? "Key works and is saved." : "Saved. Could not reach Anthropic to check it."
            case .invalid:
                keyStatus = "Anthropic rejected this key. Check that you copied all of it."
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Try it", "Click into the box, hold \(Pref.dictate.display), say a sentence, and let go.")
            TextEditor(text: $tryText).font(.title3).frame(height: 120).padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                .overlay(alignment: .topLeading) {
                    if tryText.isEmpty { Text("Your words appear here…").font(.title3).foregroundStyle(.tertiary).padding(12).allowsHitTesting(false) }
                }
            Label(state.modelReady ? "Speech model ready" : state.modelStatus, systemImage: state.modelReady ? "checkmark.circle.fill" : "hourglass")
                .font(.callout).foregroundStyle(state.modelReady ? .green : .secondary)
            Form {
                ShortcutField(title: "Dictation key", get: { Pref.dictate }, set: { Pref.dictate = $0 })
                Toggle("Start Brain Input when I log in", isOn: $launchAtLogin)
            }.formStyle(.columns)
            Spacer()
            Text("Brain Input lives in the menu bar. A short tap starts and stops; Esc cancels. Everything else is under the menu bar icon › Open Brain Input.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
        }
    }
}
