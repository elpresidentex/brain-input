import AppKit
import BrainCore
import BrainWhisper
import EventKit
import SwiftUI

/// Meeting recording. Starts only from an explicit click (the offer panel or the menu), never on its own.
@MainActor
final class MeetingController {
    private unowned let state: AppState
    private var session: MeetingSession?
    private let mic = MicRecorder()
    private let tap = SystemAudioTap()
    private var startedAt = Date()
    private var clock: Timer?
    private var watcher: Timer?
    private var callApp: String?          // call app currently holding the microphone
    private var declinedApp: String?
    private var recordingFor: String?
    private var missing = 0
    private var offerPanel: NSPanel?
    private var themHeard = false

    init(state: AppState) { self.state = state }

    func startWatching() {
        Task { let n = await MeetingNotes.recoverAll(store: state.store, model: state.thinkingModel)
            if n > 0 { Log.write("recovered \(n) meeting note(s) from an earlier crash"); state.refreshTick += 1 } }
        watcher = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
    }

    private func poll() {
        let app = CallDetector.match(micUsers: MicUsage.current().filter { $0 != Bundle.main.bundleIdentifier })
        if state.meetingActive {
            // The call app let go of the microphone: the call is over.
            if let recordingFor, app != recordingFor { missing += 1; if missing >= 3 { stop() } } else { missing = 0 }
            return
        }
        if app == nil { declinedApp = nil }
        if let app, app != callApp, app != declinedApp, UserDefaults.standard.bool(forKey: "offerMeetings") { offer(app) }
        callApp = app
    }

    /// The one-click prompt. Shown on detection and when started from the menu.
    func offer(_ app: String?) {
        offerPanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150), styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: OfferView(app: app, record: { [weak self] in self?.offerPanel?.close(); self?.start(app: app) },
                                                              dismiss: { [weak self] in self?.declinedApp = app; self?.offerPanel?.close() }))
        if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 380, y: screen.visibleFrame.maxY - 170)) }
        panel.orderFrontRegardless()
        offerPanel = panel
    }

    func start(app: String?) {
        guard !state.meetingActive else { return }
        guard let whisper = state.whisper, state.modelReady else { state.notice(state.modelStatus); return }
        Task {
            guard await MicRecorder.requestPermission() else { state.notice("Microphone access is off", seconds: 4); return }
            let event = await Self.currentEvent()
            let info = MeetingInfo(title: event?.title ?? "", startedAt: Date(), participants: event?.people ?? [], app: app ?? "")
            let session = MeetingSession(info: info, transcriber: whisper, journalDir: state.store.root.appendingPathComponent("Meetings"),
                                         whisperPrompt: state.dictionary.whisperPrompt())
            themHeard = false
            do {
                try tap.start { [weak self] s in
                    if AudioMath.rms(s) > 0.001 { Task { @MainActor in self?.themHeard = true } }
                    Task { await session.feed(s, speaker: "Them") }
                }
            } catch { state.notice("System audio: \(error)", seconds: 6); Log.write("tap failed: \(error)") }   // still record my side
            mic.onSamples = { s in Task { await session.feed(s, speaker: "Me") } }
            do { try mic.start() } catch { tap.stop(); state.notice("Microphone error: \(error.localizedDescription)", seconds: 4); return }
            self.session = session; startedAt = info.startedAt; recordingFor = app; missing = 0
            state.meetingActive = true; state.meetingClock = "00:00"
            clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            Log.write("meeting started app=\(app ?? "manual") event=\(event?.title ?? "-")")
        }
    }

    private func tick() {
        let s = Int(Date().timeIntervalSince(startedAt))
        state.meetingClock = String(format: "%02d:%02d", s / 60, s % 60)
        if s == 30, !themHeard { state.notice("No call audio heard yet. Check Screen & System Audio Recording in System Settings", seconds: 6) }
    }

    func stop() {
        guard state.meetingActive, let session else { return }
        mic.stop(); tap.stop(); clock?.invalidate()
        state.meetingActive = false; self.session = nil; recordingFor = nil
        state.notice("Writing meeting notes…", seconds: 60)
        Task {
            let segments = await session.finish()
            do {
                let url = try await MeetingNotes.write(info: session.info, segments: segments, model: state.thinkingModel, store: state.store)
                try? FileManager.default.removeItem(at: session.journal)
                state.notice("Meeting notes saved: \(url.lastPathComponent)", seconds: 5)
                Log.write("meeting saved \(url.lastPathComponent) segments=\(segments.count)")
            } catch { state.notice("Could not write the note: \(error)", seconds: 6); Log.write("meeting note failed: \(error)") }
            state.refreshTick += 1
        }
    }

    /// The calendar event happening now, if Calendar access was granted.
    static func currentEvent() async -> (title: String, people: [String])? {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        let now = Date()
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-300), end: now.addingTimeInterval(300), calendars: nil))
            .filter { !$0.isAllDay }
        guard let e = events.first(where: { ($0.attendees?.count ?? 0) > 0 }) ?? events.first else { return nil }
        return (e.title ?? "", (e.attendees ?? []).compactMap(\.name))
    }
}

struct OfferView: View {
    var app: String?
    var record: () -> Void
    var dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(app.map { "\($0) is on a call" } ?? "Record a meeting", systemImage: "person.2.wave.2").font(.headline)
            Text("Record both sides locally and write notes when it ends? No bot joins the call.").font(.callout)
            Text("Tell the other people that you are recording.").font(.callout).bold().foregroundStyle(Theme.accent)
            HStack { Spacer(); Button("Not now", action: dismiss); Button("Record", action: record).buttonStyle(.borderedProminent).tint(Theme.accent) }
        }.padding(16).frame(width: 360)
    }
}

struct MeetingMenuItems: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if state.meetingActive { Button("Stop Meeting Recording (\(state.meetingClock))") { state.meetings.stop() } }
        else { Button("Record a Meeting…") { state.meetings.offer(nil) } }
    }
}

struct MeetingsView: View {
    @EnvironmentObject var state: AppState
    @State private var notes: [SearchHit] = []
    @State private var selected: String?

    var body: some View {
        HSplitView {
            List(notes, id: \.ref, selection: $selected) { n in
                VStack(alignment: .leading) { Text(n.title).bold(); Text(n.date).font(.caption).foregroundStyle(.secondary) }.tag(n.ref)
            }.frame(minWidth: 220, maxWidth: 300)
            NoteReader(ref: selected)
        }
        .navigationTitle("Meetings")
        .toolbar {
            if state.meetingActive { Button("Stop recording (\(state.meetingClock))") { state.meetings.stop() } }
            else { Button("Record a meeting…") { state.meetings.offer(nil) } }
        }
        .onAppear(perform: reload).onChange(of: state.refreshTick) { reload() }
    }
    private func reload() { notes = state.store.meetings(); if selected == nil { selected = notes.first?.ref } }
}

/// Shows a Markdown note with a way to open the file itself.
struct NoteReader: View {
    @EnvironmentObject var state: AppState
    var ref: String?
    var body: some View {
        if let ref, let text = state.store.read(ref: ref) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        if line.hasPrefix("# ") { Text(line.dropFirst(2)).font(.title2).bold() }
                        else if line.hasPrefix("## ") { Text(line.dropFirst(3)).font(.headline).padding(.top, 6) }
                        else if !line.hasPrefix("<!--") && !line.isEmpty { Text((try? AttributedString(markdown: line)) ?? AttributedString(line)).textSelection(.enabled) }
                    }
                    if !ref.contains("#") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.store.root.appendingPathComponent(ref)]) }.padding(.top, 8)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        } else { ContentUnavailableView("No note selected", systemImage: "doc.text") }
    }
}
