import AppKit
import BrainCore
import BrainWhisper
import SwiftUI
import UniformTypeIdentifiers

/// Transcribes audio (or video) files the user drops in or picks, one after another, with the loaded speech model.
/// Each result is saved as a note in Transcripts/. The whole file is one engine call (see FileTranscription), so a
/// dictation finished meanwhile waits for it; `AppState.fileTranscribing` lets the indicator say so.
@MainActor
final class FileTranscriptionController: ObservableObject {
    struct Job: Identifiable, Equatable {
        enum Status: Equatable { case queued, loading, transcribing(Double), done(String), failed(String), cancelled }
        let id = UUID()
        let url: URL
        var status: Status = .queued
        var name: String { url.lastPathComponent }
    }

    @Published var jobs: [Job] = [] { didSet { state.fileTranscribing = busy } }
    /// Ref of the newest finished transcript, for the list to select it.
    @Published var lastSaved: String?
    private var worker: Task<Void, Never>?
    private unowned let state: AppState

    static let types: [UTType] = [.audio, .audiovisualContent, .movie]

    init(state: AppState) { self.state = state }

    var busy: Bool { jobs.contains { if case .queued = $0.status { true } else if case .loading = $0.status { true } else if case .transcribing = $0.status { true } else { false } } }

    func add(_ urls: [URL]) {
        jobs.removeAll { if case .done = $0.status { true } else if case .cancelled = $0.status { true } else { false } }
        jobs += urls.map { Job(url: $0) }
        if worker == nil { worker = Task { await runQueue(); worker = nil } }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = true
        panel.message = "Choose audio or video files to transcribe"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func cancelAll() {
        worker?.cancel()
        for i in jobs.indices where jobs[i].isPending { jobs[i].status = .cancelled }
    }

    func clearFinished() { jobs.removeAll { !$0.isPending } }

    private func runQueue() async {
        while let i = jobs.firstIndex(where: { $0.status == .queued }), !Task.isCancelled {
            await run(i)
        }
    }

    private func set(_ id: UUID, _ s: Job.Status) { if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].status = s } }

    private func run(_ index: Int) async {
        let job = jobs[index]
        guard let engine = state.whisper, state.modelReady else { set(job.id, .failed(state.modelStatus)); return }
        set(job.id, .loading)
        let access = job.url.startAccessingSecurityScopedResource()
        defer { if access { job.url.stopAccessingSecurityScopedResource() } }
        let t0 = Date()
        do {
            let samples = try await Task.detached(priority: .userInitiated) { try await AudioLoader.loadAny16kMono(job.url) }.value
            set(job.id, .transcribing(0))
            let id = job.id
            let r = try await FileTranscription.run(samples: samples, transcriber: engine, prompt: state.dictionary.whisperPrompt()) { p in
                await MainActor.run { self.set(id, .transcribing(p)) }
            }
            let ref = try FileTranscription.save(r, sourceName: job.name, model: Pref.whisperModel, store: state.store)
            set(job.id, .done(ref)); lastSaved = ref; state.refreshTick += 1
            Log.write(String(format: "file transcribed: audio %.0f s in %d ms, %d segments", r.audioSeconds, msSince(t0), r.segments.count))
        } catch is CancellationError {
            set(job.id, .cancelled)
        } catch {
            set(job.id, .failed(error.localizedDescription)); Log.write("file transcription failed: \(error)")
        }
    }
}

extension FileTranscriptionController.Job {
    var isPending: Bool {
        switch status { case .queued, .loading, .transcribing: true; default: false }
    }
}

struct TranscribeView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var files = AppState.shared.files
    @State private var notes: [SearchHit] = []
    @State private var selected: String?
    @State private var targeted = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                dropZone.padding(12)
                if !files.jobs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) { ForEach(files.jobs) { JobRow(job: $0) } }
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
                Divider()
                List(notes, id: \.ref, selection: $selected) { n in
                    VStack(alignment: .leading) { Text(n.title).bold().lineLimit(1); Text(n.date).font(.caption).foregroundStyle(.secondary) }.tag(n.ref)
                }
                .overlay { if notes.isEmpty { ContentUnavailableView("No transcripts yet", systemImage: "waveform") } }
            }.frame(minWidth: 260, maxWidth: 340)
            TranscriptReader(ref: selected)
        }
        .navigationTitle("Transcribe")
        .toolbar {
            if files.busy { Button("Cancel") { files.cancelAll() } }
            else if !files.jobs.isEmpty { Button("Clear list") { files.clearFinished() } }
            Button("Choose Files…") { files.choose() }
        }
        .onAppear(perform: reload)
        .onChange(of: state.refreshTick) { reload() }
        .onChange(of: files.lastSaved) { if let r = files.lastSaved { selected = r } }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 28)).foregroundStyle(Theme.accent)
            Text("Drop audio or video files here").font(.headline)
            Text("m4a, mp3, wav, aiff, flac, mp4, mov… Runs on this Mac with \(Pref.whisperModel).")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose Files…") { files.choose() }.buttonStyle(.link).font(.caption)
            if !state.modelReady { Text(state.modelStatus).font(.caption).foregroundStyle(.orange) }
        }
        .frame(maxWidth: .infinity).padding(16)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(targeted ? Theme.accent : .secondary.opacity(0.5)))
        .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? Theme.accent.opacity(0.08) : .clear))
        .dropDestination(for: URL.self) { urls, _ in
            let ok = urls.filter { $0.isFileURL }
            guard !ok.isEmpty else { return false }
            files.add(ok); return true
        } isTargeted: { targeted = $0 }
    }

    private func reload() { notes = state.store.transcripts(); if selected == nil { selected = notes.first?.ref } }
}

private struct JobRow: View {
    let job: FileTranscriptionController.Job
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.name).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(label).font(.caption2).foregroundStyle(color)
            }
            if case .transcribing = job.status { ProgressView().progressViewStyle(.linear).controlSize(.small) }
            else if case .loading = job.status { ProgressView().progressViewStyle(.linear).controlSize(.small) }
        }
    }
    private var label: String {
        switch job.status {
        case .queued: "waiting"
        case .loading: "reading…"
        case .transcribing: "transcribing…"
        case .done: "saved"
        case .failed(let m): m
        case .cancelled: "cancelled"
        }
    }
    private var color: Color {
        switch job.status { case .failed: .red; case .done: .green; default: .secondary }
    }
}

/// The note, plus a one-click copy of the plain transcript without the header and timestamps.
private struct TranscriptReader: View {
    @EnvironmentObject var state: AppState
    var ref: String?
    var body: some View {
        NoteReader(ref: ref)
            .toolbar {
                if let ref, let text = state.store.read(ref: ref) {
                    Button("Copy Transcript") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Self.plain(text), forType: .string)
                        state.notice("Transcript copied")
                    }
                }
            }
    }

    /// The text under "## Transcript" with the "**[mm:ss]**" markers removed.
    static func plain(_ md: String) -> String {
        let body = md.components(separatedBy: "\n## Transcript\n").last ?? md
        return body.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: #"^\*\*\[[0-9:]+\]\*\* "#, with: "", options: .regularExpression)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
