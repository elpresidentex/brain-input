import AppKit
import Carbon.HIToolbox
import BrainCore
import BrainWhisper
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            if let dir = Snapshots.outDir { await Snapshots.run(to: dir) }
            else if let dir = DemoVideo.outDir { await DemoVideo.run(to: dir) }
            else { AppState.shared.start() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        // whisper's Metal backend asserts if the context is still alive at exit.
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await AppState.shutdown(); sem.signal() }
        _ = sem.wait(timeout: .now() + 3)
    }
}

/// The one-colour "Text Brain" glyph (Assets/MenuBarIcon*.png), drawn as a template so the menu bar tints it.
enum MenuBarIcon {
    static let image: NSImage? = {
        guard let img = Bundle.main.image(forResource: "MenuBarIcon") else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }()
}

@main
struct BrainInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared

    init() {
        let d = UserDefaults.standard
        // Someone who used the app before the setup guide existed and has a model does not need the guide.
        if d.bool(forKey: "launchedBefore"), d.object(forKey: "onboardingDone") == nil, !ModelLocator.available().isEmpty {
            d.set(true, forKey: "onboardingDone")
        }
        // On a first run the setup guide opens instead of the main window.
        if !d.bool(forKey: "onboardingDone") { d.set(true, forKey: "launchedBefore") }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(state)
        } label: {
            if state.meetingActive || state.phase == .recording {
                Image(systemName: state.meetingActive ? "record.circle.fill" : "waveform.circle.fill")
            } else if let icon = MenuBarIcon.image {
                Image(nsImage: icon)
            } else {
                Image(systemName: "brain.head.profile")
            }
        }
        Window("Brain Input", id: "main") {
            MainWindow().environmentObject(state).tint(Theme.accent)
        }
        .defaultSize(width: 980, height: 660)
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "launchedBefore") ? .suppressed : .presented)
    }
}

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.modelReady ? "Ready · hold \(Pref.dictate.display) to dictate" : state.modelStatus)
        Divider()
        Button(state.phase == .recording ? "Stop Dictation" : "Start Dictation") { state.toggleDictation() }
        Button("Swap Last Dictation for Raw (\(Pref.undo.display))") { state.undoToRaw() }
        Divider()
        MeetingMenuItems()
        Divider()
        Button("Open Brain Input…") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Setup Guide…") { OnboardingController.shared.show() }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

enum Section: String, CaseIterable, Identifiable {
    case history = "Dictations", meetings = "Meetings", search = "Search", dictionary = "Dictionary", modes = "Modes",
         style = "Style", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .history: "text.bubble"; case .meetings: "person.2.wave.2"; case .search: "magnifyingglass"
        case .dictionary: "character.book.closed"; case .modes: "square.stack.3d.up"; case .style: "signature"; case .settings: "gearshape"
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var state: AppState
    @State private var section: Section?
    init(initial: Section = .history) { _section = State(initialValue: initial) }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in Label(s.rawValue, systemImage: s.icon).tag(s) }
                .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch section ?? .history {
            case .history: HistoryView()
            case .meetings: MeetingsView()
            case .search: SearchView()
            case .dictionary: DictionaryView()
            case .modes: ModesView()
            case .style: StyleView()
            case .settings: SettingsView()
            }
        }
        .onAppear { UserDefaults.standard.set(true, forKey: "launchedBefore"); state.reloadHistory() }
    }
}

struct HistoryView: View {
    @EnvironmentObject var state: AppState
    @State private var filter = ""
    @State private var showRaw: Set<String> = []

    var rows: [DictationRecord] {
        filter.isEmpty ? state.history : state.history.filter { $0.best.localizedCaseInsensitiveContains(filter) || $0.raw.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        List(rows) { r in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(r.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    Text(r.context.appName).bold()
                    Chip(r.modeID)
                    if r.enhanced { Chip("enhanced") } else if r.cleaned == nil { Chip("raw · \(CleanupStatusText.reason(r.cleanupStatus))") }
                    if let c = r.costUSD { Chip(UsageLedger.format(c)) }
                    if r.revertedToRaw { Chip("reverted") }
                    Spacer()
                    Text("\(r.timings.totalMs) ms").foregroundStyle(.secondary).monospacedDigit()
                        .help("audio \(r.timings.audioMs) ms · transcribe \(r.timings.transcribeMs) · clean-up \(r.timings.cleanupMs) · insert \(r.timings.insertMs)")
                }.font(.caption)
                Text(showRaw.contains(r.id) ? r.raw : r.best).textSelection(.enabled)
                HStack {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.best, forType: .string) }
                    if r.raw != r.best {
                        Button(showRaw.contains(r.id) ? "Show final" : "Show raw") { showRaw.formSymmetricDifference([r.id]) }
                    }
                }.buttonStyle(.link).font(.caption)
            }.padding(.vertical, 4)
        }
        .searchable(text: $filter, prompt: "Filter dictations")
        .overlay { if state.history.isEmpty { ContentUnavailableView("No dictations yet", systemImage: "text.bubble", description: Text("Hold \(Pref.dictate.display) in any app and speak.")) } }
        .navigationTitle("Dictations")
    }
}

struct Chip: View {
    var text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.accent.opacity(0.18)))
    }
}

/// Records a shortcut and shows what it hears while it hears it: held modifiers appear immediately, and the
/// final combination replaces them the moment a key (or, for a modifier-only shortcut, the release) completes it.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published var recording = false
    @Published var live = ""         // modifiers currently held
    @Published var shown = ""
    private var monitor: Any?
    private var maxMods: UInt32 = 0
    private var sawLeftCmd = false, sawRightCmd = false
    private var keyPressed = false
    private let get: () -> Shortcut
    private let set: (Shortcut) -> Void

    init(get: @escaping () -> Shortcut, set: @escaping (Shortcut) -> Void) {
        self.get = get; self.set = set; shown = get().display
    }

    func toggle() { recording ? stop() : start() }

    func start() {
        recording = true; live = ""; maxMods = 0; keyPressed = false; sawLeftCmd = false; sawRightCmd = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            self?.handle(e); return nil
        }
    }

    func stop() {
        recording = false; live = ""
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func commit(_ s: Shortcut) {
        set(s); shown = get().display
        AppState.shared.registerHotkeys(); stop()
    }

    private func handle(_ e: NSEvent) {
        let mods = Shortcut.carbonFlags(e.modifierFlags.intersection(.deviceIndependentFlagsMask))
        if e.type == .keyDown {
            if e.keyCode == 53 { stop(); return }                          // Esc cancels
            guard mods != 0 || (96...122).contains(Int(e.keyCode)) else { return }
            keyPressed = true
            commit(Shortcut(keyCode: UInt32(e.keyCode), modifiers: mods))
        } else {
            live = Shortcut.modifierSymbols(mods)
            maxMods |= mods
            let raw = e.modifierFlags.rawValue
            if raw & Shortcut.deviceLeftCmd != 0 { sawLeftCmd = true }
            if raw & Shortcut.deviceRightCmd != 0 { sawRightCmd = true }
            // Everything let go without any other key: the modifiers on their own are the shortcut.
            if mods == 0, maxMods != 0, !keyPressed {
                // ⌘ alone and only the right one: remember the side.
                let right = maxMods == UInt32(cmdKey) && sawRightCmd && !sawLeftCmd
                commit(Shortcut(keyCode: Shortcut.modifierOnlyCode, modifiers: maxMods | (right ? Shortcut.rightCmdBit : 0)))
            }
        }
    }
}

struct ShortcutField: View {
    var title: String
    @StateObject private var recorder: ShortcutRecorder

    init(title: String, get: @escaping () -> Shortcut, set: @escaping (Shortcut) -> Void) {
        self.title = title
        _recorder = StateObject(wrappedValue: ShortcutRecorder(get: get, set: set))
    }

    var body: some View {
        LabeledContent(title) {
            Button(recorder.recording ? (recorder.live.isEmpty ? "Press keys…" : recorder.live + "…") : recorder.shown) { recorder.toggle() }
                .monospacedDigit()
        }
        .onDisappear { if recorder.recording { recorder.stop() } }
    }
}
