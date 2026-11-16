import AppKit
import BrainCore
import SwiftUI

/// `BrainInput --snapshots <dir>`: renders the real windows with sample data to PNG files (website and README
/// pictures). Runs only with BRAININPUT_HOME and BRAININPUT_SUPPORT pointing at throwaway folders, so the sample
/// data can never land in real notes.
@MainActor
enum Snapshots {
    static var outDir: URL? {
        guard let i = CommandLine.arguments.firstIndex(of: "--snapshots"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1])
    }

    static func run(to dir: URL) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BRAININPUT_HOME"] != nil, env["BRAININPUT_SUPPORT"] != nil else {
            FileHandle.standardError.write(Data("--snapshots needs BRAININPUT_HOME and BRAININPUT_SUPPORT set to throwaway folders\n".utf8)); exit(1)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = AppState.shared
        seed(state)
        state.modelReady = true; state.modelStatus = "Speech model ready (Parakeet v3)"
        state.reloadHistory()
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            for step in 0..<5 {
                await shot(OnboardingView(close: {}, initialStep: step), size: NSSize(width: 600, height: 560), dark: dark,
                           to: dir.appendingPathComponent("onboarding-\(step + 1)\(suffix).png"))
            }
            for s in [Section.history, .meetings, .dictionary, .modes, .settings] {
                await shot(SnapshotMain(section: s), size: NSSize(width: 980, height: 660), dark: dark,
                           to: dir.appendingPathComponent("main-\(s.rawValue.lowercased())\(suffix).png"))
            }
        }
        exit(0)
    }

    private static func shot<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) async {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view.environmentObject(AppState.shared).tint(Theme.accent).frame(width: size.width, height: size.height))
        w.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))
        w.toolbar = nil
        try? await Task.sleep(for: .milliseconds(300))
        if let frame = w.contentView?.superview,
           let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.bounds.width) * 2, pixelsHigh: Int(frame.bounds.height) * 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = frame.bounds.size
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        w.close()
    }

    /// Invented sample content. No real person, company or message.
    private static func seed(_ state: AppState) {
        func rec(_ minutesAgo: Double, app: String, bundle: String, mode: String, raw: String, cleaned: String?, ms: Int, cost: Double?) {
            var r = DictationRecord()
            r.date = Date().addingTimeInterval(-minutesAgo * 60)
            r.context = AppContext(bundleID: bundle, appName: app, windowTitle: "")
            r.modeID = mode; r.raw = raw; r.cleaned = cleaned; r.inserted = cleaned ?? raw
            r.cleanupStatus = cleaned == nil ? "skipped: too short" : "ok"; r.costUSD = cost
            r.timings.totalMs = ms; r.timings.transcribeMs = ms / 3; r.timings.cleanupMs = cleaned == nil ? 0 : ms / 2; r.timings.audioMs = raw.count * 60
            try? state.store.saveDictation(r)
        }
        rec(3, app: "Mail", bundle: "com.apple.mail", mode: "email",
            raw: "hi jonas um thanks for sending the draft over i read it this morning and i think the pricing section is uh too long can we cut it to three points no wait two points and move the table to the appendix lets talk thursday best mira",
            cleaned: "Hi Jonas,\n\nThanks for sending the draft over. I read it this morning and I think the pricing section is too long. Can we cut it to two points and move the table to the appendix?\n\nLet's talk Thursday.\n\nBest,\nMira", ms: 1420, cost: 0.0002)
        rec(26, app: "Slack", bundle: "com.tinyspeck.slackmacgap", mode: "chat",
            raw: "so the three things for launch week are first fix the onboarding copy second record the demo and third um send the invite to the beta list",
            cleaned: "three things for launch week:\n1. fix the onboarding copy\n2. record the demo\n3. send the invite to the beta list", ms: 1180, cost: 0.0001)
        rec(58, app: "Cursor", bundle: "com.todesktop.230313mzl4w4u92", mode: "coding",
            raw: "in pipeline dot swift rename the function process samples to transcribe and insert and update the two call sites in app state dot swift",
            cleaned: "In Pipeline.swift, rename the function processSamples to transcribeAndInsert and update the two call sites in AppState.swift.", ms: 1310, cost: 0.0002)
        rec(95, app: "Notes", bundle: "com.apple.Notes", mode: "notes", raw: "Call the landlord about the heating.", cleaned: nil, ms: 420, cost: nil)
        rec(190, app: "Messages", bundle: "com.apple.MobileSMS", mode: "chat",
            raw: "ich bin in äh zehn minuten da nein warte in fünfzehn minuten soll ich noch was vom bäcker mitbringen",
            cleaned: "bin in fünfzehn Minuten da, soll ich noch was vom Bäcker mitbringen?", ms: 1090, cost: 0.0001)
        for (term, heard) in [("Kubernetes", ["cooper netties"]), ("Mira Lindqvist", ["mira lindquist"]), ("EÜR", ["e ü r"]), ("PostHog", ["post hog"])] {
            state.dictionary.add(term, source: heard.first == "post hog" ? "manual" : "learned", heardAs: heard)
        }
        let start = Date().addingTimeInterval(-26 * 3600)
        let md = """
        # Launch week sync

        - Date: \(start.formatted(.iso8601.year().month().day())) 10:00 (24 min)
        - Call app: Zoom
        - Participants: Mira Lindqvist, Jonas Weber
        - Recorded locally by Brain Input; "Me" is the microphone, "Them" is the call audio.

        ## Summary

        The beta goes out on Thursday to the first 40 people on the list. The onboarding copy is the last open item; the demo video is recorded and needs one cut.

        ## Decisions

        - Launch on Thursday, not Tuesday, so the download page can be tested on a second Mac first.
        - The pricing table moves to the appendix of the deck.

        ## Action items

        - **Me**: finish the onboarding copy by Wednesday noon.
        - **Jonas**: cut the demo video to under 40 seconds.
        - **Jonas**: send the invite to the beta list on Thursday morning.

        ## Transcript

        **Me** (00:04): Morning. I only have two things, the launch date and the demo.

        **Them** (00:11): Sure. On the date, I would rather take Thursday. We have not tried the download on a clean machine yet.

        **Me** (00:24): Agreed, Thursday. I will finish the onboarding copy by Wednesday noon so you can read it once.

        **Them** (00:36): Good. The demo is recorded, it just runs a minute ten. I will cut it to under forty seconds.
        """
        _ = try? state.store.saveNote(folder: "Meetings", filename: "sample-launch-week-sync.md", title: "Launch week sync", date: start, markdown: md)
    }
}

/// The main window for pictures: the real detail views beside a plain sidebar. The live window's split view
/// uses system materials that an offscreen render cannot draw.
struct SnapshotMain: View {
    var section: Section
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { s in
                    Label(s.rawValue, systemImage: s.icon)
                        .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(s == section ? Theme.accent.opacity(0.22) : .clear))
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 48).frame(width: 190)
            .background(Color.primary.opacity(0.05))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(section.rawValue).font(.title2).bold().padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                Group {
                    switch section {
                    case .history: HistoryView()
                    case .meetings: MeetingsView()
                    case .search: SearchView()
                    case .dictionary: DictionaryView()
                    case .modes: ModesView()
                    case .style: StyleView()
                    case .settings: SettingsView()
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
