import AppKit
import Carbon.HIToolbox
import BrainCore
import BrainWhisper
import SwiftUI

enum Phase: Equatable {
    case idle, starting, recording, transcribing, polishing
    case notice(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var phase: Phase = .idle
    @Published var level: Float = 0
    @Published var modelReady = false
    @Published var modelStatus = "Loading speech model…"
    @Published var history: [DictationRecord] = []
    @Published var refreshTick = 0
    @Published var meetingActive = false
    @Published var meetingClock = "00:00"

    let store: NotesStore
    let paster = ClipboardPaster()
    let reader = AXContextReader()
    let mic = MicRecorder()
    let indicator = IndicatorController()
    let modes = ModeStore()
    let dictionary = DictionaryStore()
    let styles = StyleStore()
    var learner: EditLearner?
    lazy var meetings = MeetingController(state: self)
    @Published var styleBusy: String?
    var whisper: (any LocalSpeechModel)?
    @Published var preview = ""
    private var previewTask: Task<Void, Never>?
    var pipeline: DictationPipeline?
    private var loadGeneration = 0
    private var pressedAt: Date?
    private var toggledOn = false
    private var starting = false
    private var releasedEarly = false
    private var stopWhenReady = false
    private var noticeTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var escMonitors: [Any] = []

    private init() {
        Pref.registerDefaults()
        store = try! NotesStore()
        mic.warmSeconds = 15
        mic.onLevel = { [weak self] l in Task { @MainActor in self?.level = l } }
        paster.onNeedsManualPaste = { [weak self] in
            self?.notice("Copied. Press ⌘V (grant Accessibility to paste automatically)", seconds: 4)
        }
    }

    func start() {
        Log.trim()
        indicator.attach(self)
        registerHotkeys()
        installEscapeMonitor()
        loadModel()
        reloadHistory()
        meetings.startWatching()
        if OnboardingController.needed { OnboardingController.shared.show() }
        Log.write("launched; accessibility=\(ClipboardPaster.trusted) mic=\(MicRecorder.permission.rawValue)")
    }

    func registerHotkeys() {
        HotkeyCenter.shared.register(id: 1, shortcut: Pref.dictate, down: { [weak self] in self?.hotkeyDown() },
                                     up: { [weak self] in self?.hotkeyUp() })
        HotkeyCenter.shared.register(id: 2, shortcut: Pref.undo, down: { [weak self] in self?.undoToRaw() })
    }

    func loadModel() {
        modelReady = false
        // The chosen model may have been deleted; fall back to any installed one.
        if !ModelLocator.isInstalled(Pref.whisperModel), let other = ModelLocator.available().first { Pref.d.set(other, forKey: "whisperModel") }
        guard let w = ModelLocator.makeTranscriber(for: Pref.whisperModel) else {
            whisper = nil; pipeline = nil
            modelStatus = "No speech model yet. Download one in the setup guide."; return
        }
        modelStatus = "Loading speech model… (the first time can take a minute or two)"
        let old = whisper
        whisper = w
        loadGeneration += 1
        let gen = loadGeneration
        Self.liveWhisper = w
        Task {
            await old?.unload()
            let t0 = Date()
            do {
                try await w.load()
                _ = try await w.transcribe(samples: [Float](repeating: 0.01, count: 16000), prompt: nil)   // warm-up
                guard gen == loadGeneration else { return }      // another model was chosen while this one loaded
                modelStatus = "Speech model ready (\(ModelLocator.displayName(Pref.whisperModel)))"; modelReady = true
                Log.write("model ready in \(msSince(t0)) ms")
            } catch {
                guard gen == loadGeneration else { return }
                modelStatus = "The speech model could not be loaded. Delete it in Settings and download it again."
                Log.write("model load failed: \(error)")
            }
            buildPipeline()
        }
    }

    /// Rebuilt whenever a setting that feeds the pipeline changes.
    func buildPipeline() {
        guard let whisper else { return }
        var polisher: Polisher?
        if Pref.d.bool(forKey: "cleanupEnabled") {
            let model = Keychain.apiKey().map { key -> ClaudeModel in
                var m = ClaudeModel(apiKey: key, model: Pref.d.string(forKey: "claudeModel") ?? "claude-haiku-5-5")
                m.ledger = .shared; m.purpose = "dictation clean-up"
                return m
            }
            polisher = CleanupPolisher(model: model, modes: modes, timeout: Pref.d.double(forKey: "cleanupTimeout"),
                                       dictionary: { [dictionary] in dictionary.promptLines() },
                                       styleCard: { [styles] in styles.promptText($0) })
        }
        let p = DictationPipeline(transcriber: whisper, inserter: paster, reader: reader, store: store, polisher: polisher,
                                  whisperPrompt: { [dictionary] in dictionary.whisperPrompt() },
                                  rawFixes: { [dictionary] in dictionary.applyKnownFixes(to: $0) },
                                  onInserted: { rec in await AppState.shared.afterInsert(rec) })
        pipeline = p
        learner = EditLearner(reader: reader, dictionary: dictionary) { id, text in await p.setFinalText(text, for: id) }
    }

    /// The slower model configuration, for style cards and meeting summaries.
    var thinkingModel: ClaudeModel? {
        Keychain.apiKey().map { key -> ClaudeModel in
            var m = ClaudeModel(apiKey: key, model: Pref.d.string(forKey: "claudeModel") ?? "claude-haiku-5-5", fast: false)
            m.ledger = .shared; m.purpose = "style & meeting summaries"
            return m
        }
    }

    // MARK: Learning

    private func afterInsert(_ rec: DictationRecord) async {
        guard Pref.d.bool(forKey: "autoLearn") else { return }
        await learner?.track(rec)
        Task {
            try? await Task.sleep(for: .seconds(8))     // time for a quick manual fix
            await learnFromEdits()
        }
        let styleLearner = StyleLearner(store: styles, notes: store)
        if styleBusy == nil, styleLearner.isDue(rec.modeID), let model = thinkingModel {
            regenerateStyle(rec.modeID, model: model)
        }
    }

    func learnFromEdits() async {
        guard Pref.d.bool(forKey: "autoLearn"), let promoted = await learner?.check(), !promoted.isEmpty else { return }
        notice("Learned: \(promoted.map(\.term).joined(separator: ", "))", seconds: 3)
        Log.write("dictionary learned \(promoted.map(\.term))")
    }

    func regenerateStyle(_ modeID: String, model: LanguageModel?, imported: [String] = []) {
        styleBusy = modeID
        Task {
            do { let c = try await StyleLearner(store: styles, notes: store).regenerate(modeID, model: model, imported: imported)
                Log.write("style card \(modeID) v\(c.version) (\(c.source))") }
            catch { Log.write("style card \(modeID) failed: \(error)") }
            styleBusy = nil; refreshTick += 1
        }
    }

    // MARK: Dictation

    private func hotkeyDown() {
        // A press while recording always stops it, whatever mode or state flags say: a lost key-up event must never
        // leave a recording that only Escape can end. The 0.25 s guard ignores a duplicate event for the same press.
        if phase == .recording {
            if let t = pressedAt, Date().timeIntervalSince(t) < 0.25 { return }
            finishDictation()
            return
        }
        if starting { stopWhenReady = true; return }      // second press while the microphone is still starting
        pressedAt = Date()
        toggledOn = false
        Task { await learnFromEdits() }   // second look at the previous dictation, in the field I am returning to
        beginDictation()
    }

    private func hotkeyUp() {
        if starting { releasedEarly = true; return }      // released before the microphone was running
        guard phase == .recording, let pressedAt else { return }
        let held = Date().timeIntervalSince(pressedAt)
        switch Pref.hotkeyMode {
        case "hold": finishDictation()
        case "toggle": toggledOn = true
        default: if held > 0.45 { finishDictation() } else { toggledOn = true }   // hybrid: tap toggles, hold talks
        }
    }

    func toggleDictation() {
        if phase == .recording { finishDictation() } else { toggledOn = true; beginDictation() }
    }

    func beginDictation() {
        guard phase != .recording, !starting else { return }
        guard modelReady else {
            notice(modelStatus, seconds: 3)
            if whisper == nil { OnboardingController.shared.show() }
            return
        }
        starting = true; releasedEarly = false; stopWhenReady = false
        indicator.moveToActiveScreen()
        let warm = mic.isWarm
        if !warm { phase = .starting }     // "Starting microphone…" instead of silently losing the first words
        Task {
            defer { starting = false }
            if MicRecorder.permission != .authorized {
                guard await MicRecorder.requestPermission() else {
                    notice("Microphone access is off. Enable it in System Settings › Privacy & Security › Microphone", seconds: 5); return
                }
            }
            do {
                let mic = self.mic
                try await Task.detached { try mic.start() }.value     // a cold start blocks; keep the main actor free
                // Show "Listening" only once sound really arrives, so I know when it is safe to start talking.
                let t0 = Date()
                while !mic.isReady, Date().timeIntervalSince(t0) < 2, !stopWhenReady { try? await Task.sleep(for: .milliseconds(25)) }
                phase = .recording; startPreview()
                Log.write("mic ready after \(msSince(t0)) ms (warm=\(warm))")
            } catch { notice("Microphone error: \(error.localizedDescription)", seconds: 4); Log.write("mic start failed: \(error)"); return }
            if stopWhenReady { finishDictation(); return }
            if releasedEarly {
                // The key came up while the microphone was starting: a tap. Toggle on, or in hold-only mode discard.
                if Pref.hotkeyMode == "hold" { stopPreview(); mic.stop(); phase = .idle } else { toggledOn = true }
            }
        }
    }

    func finishDictation() {
        guard phase == .recording else { return }
        stopPreview()
        let samples = mic.stop()
        level = 0
        guard samples.count > 4800, let pipeline else { phase = .idle; return }   // under 0.3 s: an accidental tap
        phase = .transcribing
        processingTask = Task {
            let rec = await pipeline.process(samples: samples) { stage in
                Task { @MainActor in if stage == .polishing, AppState.shared.phase == .transcribing { AppState.shared.phase = .polishing } }
            }
            if let rec {
                Log.write("dictation app=\(rec.context.bundleID) mode=\(rec.modeID) audio=\(rec.timings.audioMs)ms transcribe=\(rec.timings.transcribeMs)ms cleanup=\(rec.timings.cleanupMs)ms(\(rec.cleanupStatus)) insert=\(rec.timings.insertMs)ms total=\(rec.timings.totalMs)ms")
                // A new dictation may already be recording; only clear our own progress state.
                if phase == .transcribing || phase == .polishing {
                    phase = .idle
                    // Say what happened to the text: enhanced or not, and (if wanted) what the call cost.
                    var parts: [String] = []
                    if rec.enhanced { parts.append("Enhanced with Claude") }
                    else if rec.cleanupStatus.hasPrefix("skipped") { parts.append("Not enhanced (too short)") }
                    else if rec.cleanupStatus != "disabled" && rec.cleanupStatus != "no-key" { parts.append("Not enhanced · \(CleanupStatusText.reason(rec.cleanupStatus))") }
                    if Pref.d.bool(forKey: "showCostAfterDictation"), let c = rec.costUSD { parts.append(UsageLedger.format(c)) }
                    if !parts.isEmpty { notice(parts.joined(separator: " · "), seconds: 1.8) }
                }
            } else if phase == .transcribing || phase == .polishing { notice("Nothing heard") }
            reloadHistory()
        }
    }

    /// Esc drops a recording, or a transcription in progress, without inserting anything.
    private func installEscapeMonitor() {
        let handler: (NSEvent) -> Void = { e in
            guard e.keyCode == UInt16(kVK_Escape) else { return }
            DispatchQueue.main.async { AppState.shared.cancelDictation() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { escMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in handler(e); return e }) { escMonitors.append(l) }
    }

    func cancelDictation() {
        switch phase {
        case .recording:
            stopPreview(); _ = mic.stop(); level = 0; toggledOn = false
            notice("Cancelled", seconds: 1)
        case .transcribing, .polishing:
            processingTask?.cancel(); processingTask = nil
            notice("Cancelled", seconds: 1)
        default: return
        }
        Log.write("dictation cancelled with Esc")
    }

    // MARK: Live preview
    // While recording, the audio so far is transcribed again every second or so and shown in the indicator, so a
    // wrong microphone or a model that does not understand me shows up after two seconds, not after five minutes.

    private func startPreview() {
        preview = ""
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            var lastCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, !Task.isCancelled, let whisper = self.whisper else { return }
                let samples = self.mic.snapshot()
                guard samples.count > 16_000, samples.count > lastCount + 8_000 else { continue }   // at least 0.5 s of new audio
                lastCount = samples.count
                // Only the last 30 s: the preview must stay cheap however long I talk.
                let window = Array(samples.suffix(480_000))
                if let t = try? await whisper.transcribe(samples: window, prompt: nil), !Task.isCancelled, self.phase == .recording {
                    self.preview = DictationPipeline.tidy(t.text)
                }
            }
        }
    }

    private func stopPreview() { previewTask?.cancel(); previewTask = nil; preview = "" }

    func undoToRaw() {
        Task {
            let ok = await pipeline?.undoToRaw() ?? false
            notice(ok ? "Swapped in the raw transcript" : "Nothing to undo")
            reloadHistory()
        }
    }

    func notice(_ text: String, seconds: Double = 2) {
        phase = .notice(text)
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled, case .notice = phase { phase = .idle }
        }
    }

    /// Reachable without hopping to the main actor, which is blocked while the app terminates.
    nonisolated(unsafe) static var liveWhisper: (any LocalSpeechModel)?
    nonisolated static func shutdown() async { await liveWhisper?.unload() }

    func reloadHistory() { history = store.dictations(limit: 300); refreshTick += 1 }
}

// MARK: - Floating indicator

final class IndicatorController {
    private var panel: NSPanel?
    private var observer: Any?

    @MainActor func attach(_ state: AppState) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 110), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .statusBar; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: IndicatorView().environmentObject(state))
        if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.minY + 28))
        }
        p.orderFrontRegardless()
        panel = p
    }

    /// Follows the screen the pointer is on, so the pill shows where I am working.
    @MainActor func moveToActiveScreen() {
        let mouse = NSEvent.mouseLocation
        guard let panel, let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.minY + 28))
    }
}

struct IndicatorView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            if state.meetingActive {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text("Meeting · \(state.meetingClock)").monospacedDigit()
                if state.phase != .idle { Divider().frame(height: 14) }
            }
            switch state.phase {
            case .idle: EmptyView()
            case .starting: ProgressView().controlSize(.small); Text("Starting microphone…")
            case .recording:
                LevelBars(level: state.level)
                if state.preview.isEmpty { Text("Listening") }
                else { Text(state.preview).lineLimit(3).truncationMode(.head).multilineTextAlignment(.leading).frame(maxWidth: 340, alignment: .leading) }
            case .transcribing: ProgressView().controlSize(.small); Text("Transcribing")
            case .polishing: ProgressView().controlSize(.small); Text("Polishing")
            case .notice(let text): Text(text).lineLimit(2)
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(Color(white: 0.06))
        .environment(\.colorScheme, .light)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .padding(.bottom, 14).padding(.horizontal, 16)
        .opacity(state.phase == .idle && !state.meetingActive ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: state.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

struct LevelBars: View {
    var level: Float
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                let h = 4 + CGFloat(min(1, level * 14)) * CGFloat([8, 14, 18, 12, 7][i])
                Capsule().fill(Theme.accent).frame(width: 3, height: h)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.08), value: level)
    }
}

enum Theme {
    static let accent = Color(red: 0, green: 0.459, blue: 0.871)   // the one blue; everything else is black, white and grey
}
