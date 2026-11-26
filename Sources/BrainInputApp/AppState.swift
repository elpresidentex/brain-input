import AppKit
import Carbon.HIToolbox
import BrainCore
import BrainWhisper
import SwiftUI

enum Phase: Equatable {
    case idle, starting, recording, transcribing, polishing
    case notice(String)
    /// A dictation is under way and Esc can cancel it.
    var isActive: Bool { self == .recording || self == .transcribing || self == .polishing }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var phase: Phase = .idle {
        // A first Esc only counts for the dictation it was pressed in.
        didSet { if !phase.isActive { escDeadline = nil } }
    }
    /// Which page the main window shows; the menu's History and Settings items set it.
    @Published var mainSection: Section? = .history
    /// Set by a first Esc while recording or processing: a second Esc before this moment cancels.
    @Published var escDeadline: Date?
    static let escWindow: TimeInterval = 3
    @Published var level: Float = 0
    @Published var modelReady = false
    @Published var modelStatus = "Loading speech model…"
    @Published var history: [DictationRecord] = []
    @Published var refreshTick = 0
    @Published var meetingActive = false
    /// A dropped file is being transcribed: it holds the speech engine, so a dictation waits behind it.
    @Published var fileTranscribing = false
    @Published var meetingClock = "00:00"

    let store: NotesStore
    let paster = ClipboardPaster()
    let reader = AXContextReader()
    let mic = MicRecorder()

    /// The microphone choice changed (or the chosen one went away): rebuild the warm engine on the next dictation.
    func micDeviceChanged(onlyIfSelectedGone: Bool = false) {
        if onlyIfSelectedGone && MicDevices.selectedDeviceID != nil { return }
        mic.resetDevice()
    }
    let indicator = IndicatorController()
    let modes = ModeStore()
    let dictionary = DictionaryStore()
    let styles = StyleStore()
    var learner: EditLearner?
    lazy var meetings = MeetingController(state: self)
    lazy var files = FileTranscriptionController(state: self)
    @Published var styleBusy: String?
    var whisper: (any LocalSpeechModel)?
    @Published var preview = ""
    private var previewTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    /// Transcribes the current recording chunk by chunk while I talk; nil when not recording.
    private var live: IncrementalTranscriber?
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
        reinstallMonitorsWhenTrusted()
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
        let tRelease = Date()
        // Taken before stopPreview() resets them: a preview transcription still running holds the speech engine,
        // and the real transcription queues behind it.
        let previewAtRelease = (inFlight: previewInFlight, runs: previewRuns, engineMs: previewEngineMs)
        let live = self.live
        stopPreview()
        let samples = mic.stop()
        level = 0
        guard samples.count > 4800, let pipeline else {     // under 0.3 s: an accidental tap
            if let live { Task { await live.cancel() } }
            phase = .idle; return
        }
        phase = .transcribing
        processingTask = Task {
            let seed = TraceSeed(stopMs: msSince(tRelease), previewInFlight: previewAtRelease.inFlight, previewRuns: previewAtRelease.runs,
                                 previewEngineMs: previewAtRelease.engineMs, meetingActive: AppState.shared.meetingActive)
            let rec = await pipeline.process(samples: samples, live: live, seed: seed) { stage in
                Task { @MainActor in if stage == .polishing, AppState.shared.phase == .transcribing { AppState.shared.phase = .polishing } }
            }
            if let rec {
                Log.write("dictation app=\(rec.context.bundleID) mode=\(rec.modeID) audio=\(rec.timings.audioMs)ms transcribe=\(rec.timings.transcribeMs)ms\(Self.detailLog(rec)) cleanup=\(rec.timings.cleanupMs)ms(\(rec.cleanupStatus)) insert=\(rec.timings.insertMs)ms total=\(rec.timings.totalMs)ms")
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

    /// Esc twice drops a recording, or a transcription in progress, without inserting anything. The first press
    /// only arms it and shows "Press Esc again to cancel" with a countdown, so a stray Esc meant for the app in
    /// front no longer throws away a long dictation. (Same idea as VoiceInk's double-press Escape.)
    private func installEscapeMonitor() {
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors = []
        let handler: (NSEvent) -> Void = { e in
            guard e.keyCode == UInt16(kVK_Escape) else { return }
            DispatchQueue.main.async { AppState.shared.escapePressed() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { escMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in handler(e); return e }) { escMonitors.append(l) }
    }

    /// A global key monitor added before Accessibility was granted stays deaf after the grant, so Esc (and a
    /// modifier-only shortcut) only worked in other apps after a relaunch. Until trust arrives, check every 2 s,
    /// then add the monitors again.
    private func reinstallMonitorsWhenTrusted() {
        guard !ClipboardPaster.trusted else { return }
        Task { @MainActor in
            while !ClipboardPaster.trusted { try? await Task.sleep(for: .seconds(2)) }
            installEscapeMonitor()
            HotkeyCenter.shared.accessibilityGranted()
            Log.write("accessibility granted; key monitors reinstalled")
        }
    }

    func escapePressed() {
        guard phase.isActive else { return }
        if let d = escDeadline, d > Date() { escDeadline = nil; cancelDictation(); return }
        let deadline = Date().addingTimeInterval(Self.escWindow)
        escDeadline = deadline
        Task {
            try? await Task.sleep(for: .seconds(Self.escWindow))
            if escDeadline == deadline { escDeadline = nil }
        }
    }

    func copyLastTranscription() {
        guard let last = store.dictations(limit: 1).first else { notice("Nothing to copy yet"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.best, forType: .string)
        notice("Copied last transcription", seconds: 1.5)
    }

    func cancelDictation() {
        switch phase {
        case .recording:
            if let live { Task { await live.cancel() } }
            stopPreview(); _ = mic.stop(); level = 0; toggledOn = false
            notice("Cancelled", seconds: 1)
        case .transcribing, .polishing:
            processingTask?.cancel(); processingTask = nil
            if let pendingLive { Task { await pendingLive.cancel() } }
            notice("Cancelled", seconds: 1)
        default: return
        }
        Log.write("dictation cancelled with Esc")
    }

    // MARK: Live transcription and preview
    // While recording, finished chunks of speech are transcribed once each (IncrementalTranscriber), and the indicator
    // shows their text plus a preview of the chunk still open, so a wrong microphone or a model that does not
    // understand me shows up after two seconds, not after five minutes. Before, the last 30 s were transcribed again
    // every second, and the whole recording once more after release.

    private var previewInFlight = false
    private var previewRuns = 0
    private var previewEngineMs = 0
    /// The live transcriber of the dictation being processed, so Esc can stop its remaining chunks.
    private var pendingLive: IncrementalTranscriber?
    /// Held while recording: BrainInput is a background app then, and App Nap may stretch its timers (the feed and
    /// preview loops sleep 50 ms) far beyond what the bench measures.
    private var recordingActivity: NSObjectProtocol?

    private func startPreview() {
        preview = ""
        previewInFlight = false; previewRuns = 0; previewEngineMs = 0
        previewTask?.cancel(); feedTask?.cancel()
        guard let pipeline else { return }
        if recordingActivity == nil {
            recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                      reason: "Live dictation preview")
        }
        let mic = self.mic
        let box = LiveBox()
        // Feeding runs on its own task so a preview call that waits for the engine never delays it; one task, so
        // samples arrive in order.
        feedTask = Task.detached {
            let live = await pipeline.makeLive()
            let current = await MainActor.run { () -> Bool in
                guard !Task.isCancelled else { return false }      // released before setup finished: one-shot path
                box.live = live; AppState.shared.live = live; AppState.shared.pendingLive = live
                return true
            }
            guard current else { return }
            var offset = 0
            while !Task.isCancelled {
                let new = mic.samples(since: offset)
                if !new.isEmpty { await live.feed(new, from: offset); offset += new.count }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        // Asks every 50 ms; live.preview() itself decides when enough new audio arrived and the engine is free, so on
        // Parakeet previews run back to back and the text trails speech by about 0.4 s (0.7 s with the old 300 ms
        // poll and 0.5 s step).
        previewTask = Task { [weak self] in
            // How long the 50 ms sleep really takes, and how often the shown text changes: logged per dictation, so a
            // preview that feels slow in the app can be told apart from one that is slow in the engine.
            var slept: [Int] = [], updates = 0
            let t0 = Date()
            while !Task.isCancelled {
                let ts = Date()
                try? await Task.sleep(for: .milliseconds(50))
                slept.append(msSince(ts))
                guard let self, !Task.isCancelled, let live = box.live else { continue }
                self.previewInFlight = true
                let text = await live.preview()
                self.previewInFlight = false
                if !Task.isCancelled, self.phase == .recording, text != self.preview { self.preview = text; updates += 1 }
            }
            let s = slept.sorted()
            if s.count > 10 {
                Log.write("preview loop: sleep 50 ms took median \(s[s.count / 2]) p90 \(s[s.count * 9 / 10]) max \(s.last!) ms; text changed \(updates)x in \(msSince(t0)) ms")
            }
        }
    }

    /// One-line timing breakdown for the log, e.g. " [queue=2100 load=0 infer=900 ctx=3 preview=live]".
    static func detailLog(_ r: DictationRecord) -> String {
        guard let d = r.timings.detail else { return "" }
        var s = " [stop=\(d.stopMs) queue=\(d.queueWaitMs) load=\(d.loadMs) infer=\(d.inferenceMs) ctx=\(d.contextMs)/\(d.contextWaitMs) engine=\(d.engine) preview=\(d.previewInFlight ? "live" : "idle")x\(d.previewRuns) thermal=\(d.thermal)"
        if d.meetingActive { s += " meeting" }
        if let c = d.cleanup {
            s += " | cleanup screen=\(c.screenReadMs) api=\(c.apiMs)"
            if let n = c.net { s += " connect=\(n.connectMs) ttfb=\(n.ttfbMs) dl=\(n.downloadMs)\(n.reusedConnection ? " reused" : "")" }
            if let o = c.outputTokens { s += " outTok=\(o)" }
        }
        return s + "]"
    }

    /// Stops the preview and the live feed. The live transcriber itself keeps its chunks for finishDictation().
    private func stopPreview() {
        previewTask?.cancel(); previewTask = nil; feedTask?.cancel(); feedTask = nil
        live = nil; preview = ""
        if let a = recordingActivity { ProcessInfo.processInfo.endActivity(a); recordingActivity = nil }
    }

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

/// Hands the live transcriber from the feed task to the preview task.
@MainActor private final class LiveBox { var live: IncrementalTranscriber? }

// MARK: - Floating indicator

final class IndicatorController {
    private var panel: NSPanel?
    private var observer: Any?
    /// The meeting counter has its own panel up top, so it never covers a call app's controls at the bottom.
    private let badge = MeetingBadgeController()

    @MainActor func attach(_ state: AppState) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150), styleMask: [.borderless, .nonactivatingPanel],
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
        badge.attach(state)
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
        VStack(spacing: 8) {
            if let deadline = state.escDeadline, state.phase.isActive { EscHint(deadline: deadline) }
            pill
        }
        .animation(.easeOut(duration: 0.15), value: state.escDeadline)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            switch state.phase {
            case .idle: EmptyView()
            case .starting: ProgressView().controlSize(.small); Text("Starting microphone…")
            case .recording:
                LevelBars(level: state.level)
                if state.preview.isEmpty { Text("Listening") }
                else { Text(state.preview).lineLimit(3).truncationMode(.head).multilineTextAlignment(.leading).frame(maxWidth: 340, alignment: .leading) }
            case .transcribing: ProgressView().controlSize(.small); Text(state.fileTranscribing ? "Waiting for file transcription…" : "Transcribing")
            case .polishing: ProgressView().controlSize(.small); Text("Polishing")
            case .notice(let text): Text(text).lineLimit(2)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)   // the dark pill needs light spinners, not black ones
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 22).fill(Theme.ink.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.mint.opacity(0.55), lineWidth: 1))
        .opacity(state.phase == .idle ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: state.phase)
    }
}

/// "Press Esc again to cancel", with a ring and a number counting down the seconds left to do it.
struct EscHint: View {
    var deadline: Date

    var body: some View {
        TimelineView(.animation) { ctx in
            let left = max(0, deadline.timeIntervalSince(ctx.date))
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Theme.mint.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: left / AppState.escWindow).rotation(.degrees(-90))
                        .stroke(Theme.mint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    Text("\(Int(left.rounded(.up)))").font(.system(size: 9, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 18, height: 18)
                Text("Press Esc again to cancel")
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Theme.ink.opacity(0.94)))
        .overlay(Capsule().strokeBorder(Theme.mint.opacity(0.35), lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct LevelBars: View {
    var level: Float
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                let h = 4 + CGFloat(min(1, level * 14)) * CGFloat([8, 14, 18, 12, 7][i])
                Capsule().fill(Theme.mint).frame(width: 3, height: h)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.08), value: level)
    }
}

/// Colours taken from the app icon (Assets/AppIcon-1024.png): the green tile, the mint cursor, a deep green ink.
enum Theme {
    static let accent = Color(red: 0.13, green: 0.53, blue: 0.37)   // icon tile green, #22875E
    static let mint = Color(red: 0.49, green: 0.94, blue: 0.71)     // icon cursor, #7CF0B6: accents on dark
    static let ink = Color(red: 0.04, green: 0.11, blue: 0.08)      // near-black green behind the indicator
}
