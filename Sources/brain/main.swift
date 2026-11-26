import BrainCore
import BrainWhisper
import Foundation

// `brain`: read and search notes from the shell, run benchmarks and fixtures, serve MCP over stdio.

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { args.contains(name) }
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }
let valueOptions: Set<String> = ["--model", "--kind", "--prompt", "--fixtures", "--claude-model", "--seconds", "--speed", "--preview-every", "--preview-step", "-parakeetEncoder"]
let positional: [String] = {
    var out: [String] = []; var skip = false
    for a in args.dropFirst() {
        if skip { skip = false; continue }
        if valueOptions.contains(a) { skip = true; continue }
        if !a.hasPrefix("--") { out.append(a) }
    }
    return out
}()

let usage = """
brain: Brain Input notes from the shell
  brain search <query> [--kind meeting|dictation|transcript] [--json]
  brain read <ref>                 ref as printed by search, e.g. Meetings/2026-11-16-1400-sync.md
  brain last-meeting
  brain meetings
  brain history [n]
  brain mic-users                  apps capturing the microphone now, and whether that counts as a call
  brain timing [n]                 where dictation time goes, and how transcribe time correlates with message length (last n, default all)
  brain reindex                    rebuild the index from the Markdown files
  brain transcribe <audio or video file> [--model name.bin] [--timestamps] [--save]
                                   any format macOS decodes; --save keeps it as a note in Transcripts/
  brain bench <audio file>... [--model name.bin]     load and transcription latency, memory
  brain live-bench <audio file>... [--model name] [--seconds 300] [--speed 1] [--preview-every ms]
                                   [--old-preview] [--chunk-preview] [--words]
                                   wait after release, one pass vs live chunks; files are looped with 1 s gaps
                                   up to --seconds and fed at --speed times real time
  brain eval-cleanup [--yes] [--live] [--claude-model id] [--fixtures path]
                                   run Fixtures/cleanup.json against the real model (paid; prints the cost first,
                                   does nothing without --yes; Batch API unless --live)
  brain models                     speech models and whether they are installed
  brain download <model id>        download a speech model (as the app's setup guide does)
  brain mcp                        MCP server over stdio
"""

/// Whisper when it is installed (it takes a prompt and reports the language), else whatever is.
let defaultModelID = ModelLocator.isInstalled(ModelLocator.defaultModel) ? ModelLocator.defaultModel : (ModelLocator.available().first ?? ModelLocator.defaultModel)
func store() -> NotesStore { do { return try NotesStore() } catch { fail("cannot open notes: \(error)") } }
func transcriber() -> any LocalSpeechModel {
    guard let t = ModelLocator.makeTranscriber(for: option("--model") ?? defaultModelID) else { fail("speech model not installed; run `brain models`") }
    return t
}
func residentMB() -> Int {
    var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return Int(info.phys_footprint / 1_048_576)
}

switch args.first {
case "models":
    for m in ModelLocator.catalog { print("\(ModelLocator.isInstalled(m.id) ? "installed" : "missing  ")  \(m.id)  (\(m.name), \(m.sizeMB) MB)") }
case "download":
    guard let m = ModelLocator.catalog.first(where: { $0.id == positional.first }) else { fail("unknown model; run `brain models`") }
    nonisolated(unsafe) var last = -1
    try await ModelLocator.download(m) { p in let pct = Int(p * 100); if pct >= last + 10 { last = pct; print("\(pct) %") } }
    print("installed \(m.id)")
case "search":
    let hits = store().search(positional.joined(separator: " "), kind: option("--kind"))
    if flag("--json") { print(String(data: try JSONEncoder().encode(hits), encoding: .utf8)!) }
    else if hits.isEmpty { print("no matches") }
    else { for h in hits { print("\(h.date)  \(h.title)\n  \(h.ref)\n  \(h.snippet.replacingOccurrences(of: "\n", with: " "))\n") } }
case "read":
    guard let ref = positional.first, let text = store().read(ref: ref) else { fail("not found") }
    print(text)
case "last-meeting":
    let s = store()
    guard let m = s.meetings(limit: 1).first, let text = s.read(ref: m.ref) else { fail("no meeting notes yet") }
    print(text)
case "meetings":
    for m in store().meetings() { print("\(m.date)  \(m.title)\n  \(m.ref)") }
case "history":
    for r in store().dictations(limit: Int(positional.first ?? "") ?? 10) {
        print("\(r.date.formatted(date: .abbreviated, time: .standard)) · \(r.context.appName) · \(r.modeID) · \(r.timings.totalMs) ms\n  \(r.best)\n")
    }
case "mcp":
    MCPServer(store: store()).run()
case "mic-users":
    let users = MicUsage.current()
    print(users.isEmpty ? "no app is capturing the microphone" : users.joined(separator: "\n"))
    print("call detected: \(CallDetector.match(micUsers: users) ?? "none")")
case "timing":
    let n = Int(positional.first ?? "") ?? 100_000
    print(TimingReport.render(store().dictations(limit: n)))
case "reindex":
    print("indexed \(try store().reindex()) items")
case "transcribe":
    guard let f = positional.first else { fail(usage) }
    let url = URL(fileURLWithPath: f)
    let samples: [Float]
    do { samples = try await AudioLoader.loadAny16kMono(url) } catch { fail("cannot read \(f): \(error.localizedDescription)") }
    let w = transcriber()
    let modelName = option("--model") ?? ModelLocator.defaultModel
    let r = try await FileTranscription.run(samples: samples, transcriber: w, prompt: option("--prompt")) { p in
        FileHandle.standardError.write(Data(String(format: "\r%3.0f%%", p * 100).utf8))
    }
    FileHandle.standardError.write(Data("\r".utf8))
    print(flag("--timestamps") ? r.paragraphs().map { p in (p.start.map { "[\(FileTranscription.timestamp($0))] " } ?? "") + p.text }.joined(separator: "\n\n") : r.text)
    if flag("--save") {
        let ref = try FileTranscription.save(r, sourceName: url.lastPathComponent, model: modelName, store: store())
        FileHandle.standardError.write(Data("saved \(ref)\n".utf8))
    }
    await w.unload()
case "bench":
    let w = transcriber()
    var t0 = Date(); try await w.load()
    print("model \(option("--model") ?? defaultModelID): load \(msSince(t0)) ms, footprint \(residentMB()) MB")
    _ = try await w.transcribe(samples: [Float](repeating: 0.01, count: 16000), prompt: nil)   // warm-up
    for f in positional {
        let s = try AudioLoader.load16kMono(URL(fileURLWithPath: f))
        t0 = Date(); let t = try await w.transcribe(samples: s, prompt: nil)
        print(String(format: "%@: audio %.1f s, transcribe %d ms, lang %@, footprint %d MB\n  %@", (f as NSString).lastPathComponent,
                     Double(s.count) / 16000, msSince(t0), t.language ?? "?", residentMB(), t.text))
    }
    await w.unload()
case "live-bench":
    guard !positional.isEmpty else { fail(usage) }
    let w = transcriber()
    try await w.load()
    _ = try await w.transcribe(samples: [Float](repeating: 0.01, count: 16000), prompt: nil)   // warm-up
    var clips: [[Float]] = []
    for p in positional { clips.append(try await AudioLoader.loadAny16kMono(URL(fileURLWithPath: p))) }
    let target = Int((Double(option("--seconds") ?? "") ?? 0) * 16000)
    let speed = Double(option("--speed") ?? "") ?? 1
    var audio: [Float] = []
    let gap = [Float](repeating: 0, count: 16000)
    repeat { for c in clips { audio += c + gap } } while audio.count < target
    print(String(format: "audio %.1f s (%@), model %@, fed at %.0fx real time", Double(audio.count) / 16000,
                 positional.map { ($0 as NSString).lastPathComponent }.joined(separator: " + "), option("--model") ?? ModelLocator.defaultModel, speed))
    var t0 = Date()
    let one = try await w.transcribe(samples: audio, prompt: nil)
    let oneMs = msSince(t0)
    print("one pass after release: \(oneMs) ms")
    let live = IncrementalTranscriber(transcriber: w, prompt: nil)
    if args.contains("--chunk-preview") { await live.setWindowPreview(false) }
    let step = 800                                   // 50 ms, as the app feeds
    let tFeed = Date()
    func now() -> Double { Date().timeIntervalSince(tFeed) * speed }      // seconds of audio since the start
    // With --preview-every, a preview loop runs as in the app; every snapshot of the shown text is kept, and each
    // spoken word's lag is the time from its end (one-pass token timings) to the first snapshot that shows it.
    final class Snaps: @unchecked Sendable { var list: [(t: Double, text: String)] = []; var samples = 0; var runs = 0 }
    let snaps = Snaps()
    let fedSoFar = Snaps()
    let previewEvery = Int(option("--preview-every") ?? "")
    if let st = Double(option("--preview-step") ?? "") { await live.setMinPreviewStep(Int(st * 16000)) }
    let previewLoop: Task<Void, Never>? = previewEvery.map { ms in
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(ms))
                let text = await live.preview()
                if text != snaps.list.last?.text { snaps.list.append((now(), text)) }
            }
        }
    }
    var lags: [Double] = []
    // --old-preview: the preview before live chunks, the last 30 s transcribed again every 900 ms, for comparison.
    let oldLoop: Task<Void, Never>? = args.contains("--old-preview") ? Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(900))
            let n = fedSoFar.samples
            guard n > 16_000 else { continue }
            guard let t = try? await w.transcribe(samples: Array(audio[max(0, n - 480_000)..<n]), prompt: nil) else { continue }
            snaps.list.append((now(), DictationPipeline.tidy(t.text))); snaps.samples = n; snaps.runs += 1
        }
    } : nil
    var oldLags: [Double] = []
    for i in stride(from: 0, to: audio.count, by: step) {
        await live.feed(Array(audio[i..<min(i + step, audio.count)]), from: i)
        fedSoFar.samples = min(i + step, audio.count)
        if oldLoop != nil, i >= 3 * 16000 { oldLags.append(Double(i + step - snaps.samples) / 16000) }
        if previewLoop != nil, i >= 3 * 16000 { lags.append(Double(i + step - (await live.previewCovers)) / 16000) }
        let due = Double(i + step) / 16000 / speed
        let wait = due - Date().timeIntervalSince(tFeed)
        if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
    }
    previewLoop?.cancel(); oldLoop?.cancel()
    _ = await previewLoop?.value; _ = await oldLoop?.value
    if !oldLags.isEmpty {
        let l = oldLags.sorted()
        print(String(format: "old preview (last 30 s every 900 ms): audio covered trails speech by median %.2f s, p90 %.2f s; %d runs",
                     l[l.count / 2], l[l.count * 9 / 10], snaps.runs))
    }
    if let ms = previewEvery, !lags.isEmpty {
        let l = lags.sorted()
        print(String(format: "preview every %d ms: audio covered trails speech by median %.2f s, p90 %.2f s; %d preview runs, %d ms engine",
                     ms, l[l.count / 2], l[l.count * 9 / 10], await live.previewRuns, await live.previewEngineMs))
    }
    if !snaps.list.isEmpty {
        if let tokens = one.tokens, !tokens.isEmpty {
            let ref = PreviewLag.words(from: tokens)
            let shown = PreviewLag.firstShown(reference: ref, snapshots: snaps.list)
            print(PreviewLag.summary(reference: ref, shown: shown))
            if args.contains("--words") {
                for (w, s) in zip(ref, shown) { print(String(format: "  %7.2f  %@  %@", w.end, s.map { String(format: "+%.2f", $0 - w.end) } ?? "never", w.text)) }
            }
        } else { print("word lag: the model gives no token timings") }
    }
    let queued = await live.chunksQueued, finishedBefore = await live.chunksDone
    t0 = Date()
    guard let r = await live.finish(all: audio) else { fail("live transcription fell back to one pass") }
    let wer = WordDiff.rate(r.transcript.text, reference: one.text)
    print("live chunks after release: \(msSince(t0)) ms (tail \(r.tailMs), backlog \(r.backlogMs)); \(r.chunks) chunks, \(finishedBefore)/\(queued) done at release, engine \(r.engineMs) ms in all")
    print(String(format: "word difference vs one pass: %d of %d words (%.1f%%)", WordDiff.distance(one.text, r.transcript.text),
                 WordDiff.words(one.text).count, wer * 100))
    if args.contains("--chunks") { for (i, c) in await live.chunkLog.enumerated() { print(String(format: "  chunk %2d  %5.1f s  %@", i, Double(c.samples) / 16000, c.text)) } }
    if args.contains("--print") { print("ONE PASS: \(one.text)\nLIVE:     \(r.transcript.text)") }
    await w.unload()
case "eval-cleanup":
    let path = option("--fixtures") ?? "Fixtures/cleanup.json"
    guard let fixtures = try? CleanupFixture.load(URL(fileURLWithPath: path)) else { fail("cannot read \(path); run from the repository root or pass --fixtures") }
    let modes = ModeStore()
    let modelID = option("--claude-model") ?? UserDefaults(suiteName: "com.arminbognar.BrainInput")?.string(forKey: "claudeModel") ?? "claude-haiku-5-5"
    let prompts = fixtures.map { ($0, $0.prompts(modes: modes)) }
    // Rough token estimate: 3 characters per token for input, the ideal answer for output.
    let inTok = prompts.reduce(0) { $0 + ($1.1.system.count + $1.1.user.count) / 3 }
    let outTok = fixtures.reduce(0) { $0 + $1.ideal.count / 3 + 20 }
    let live = flag("--live")
    let price = (Double(inTok) * 0.10 + Double(outTok) * 0.50) / 1_000_000 * (live ? 1 : 0.5)
    print("\(fixtures.count) fixtures, about \(inTok) input and \(outTok) output tokens on \(modelID)")
    print(String(format: "estimated cost at Haiku 5.5 list prices ($0.10 / $0.50 per million tokens)%@: $%.4f", live ? "" : ", Batch API half price", price))
    guard flag("--yes") else { print("nothing sent. Add --yes to run\(live ? "" : " (Batch API: results in minutes; add --live for immediate, full-price calls)")."); break }
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? Keychain.apiKey() else { fail("no API key: set ANTHROPIC_API_KEY or save one in the app's Settings") }
    let claude = ClaudeModel(apiKey: key, model: modelID)
    var outputs: [String: Result<String, Error>] = [:]
    if live {
        for (f, p) in prompts {
            let t0 = Date()
            do { let o = try await claude.complete(system: p.system, user: p.user, maxTokens: 1024); outputs[f.id] = .success(o); print("  \(f.id): \(msSince(t0)) ms") }
            catch { outputs[f.id] = .failure(error) }
        }
    } else {
        outputs = try await claude.runBatch(prompts.map { (id: $0.0.id, system: $0.1.system, user: $0.1.user) }) { print("  \($0)") }
    }
    var passed = 0
    for f in fixtures {
        switch outputs[f.id] {
        case .success(let raw):
            let out = CleanupPrompt.sanitize(raw, raw: f.raw) ?? ""
            let problems = out.isEmpty ? ["rejected by sanitizer (would fall back to raw)"] : f.grade(out)
            if problems.isEmpty { passed += 1 }
            print("\(problems.isEmpty ? "PASS" : "FAIL") \(f.id) (\(f.note))\n  in : \(f.raw)\n  out: \(raw.replacingOccurrences(of: "\n", with: "⏎"))" + (problems.isEmpty ? "" : "\n  why: \(problems.joined(separator: "; "))"))
        case .failure(let e): print("FAIL \(f.id): \(e)")
        case nil: print("FAIL \(f.id): no result")
        }
    }
    print("\(passed)/\(fixtures.count) passed")
default:
    print(usage)
}
