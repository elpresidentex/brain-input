import BrainCore
import BrainWhisper
import Foundation

// `brain`: read and search notes from the shell, run benchmarks and fixtures, serve MCP over stdio.

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { args.contains(name) }
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }
let valueOptions: Set<String> = ["--model", "--kind", "--prompt", "--fixtures", "--claude-model"]
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
  brain search <query> [--kind meeting|dictation] [--json]
  brain read <ref>                 ref as printed by search, e.g. Meetings/2026-11-16-1400-sync.md
  brain last-meeting
  brain meetings
  brain history [n]
  brain mic-users                  apps capturing the microphone now, and whether that counts as a call
  brain reindex                    rebuild the index from the Markdown files
  brain transcribe <audio file> [--model name.bin]
  brain bench <audio file>... [--model name.bin]     load and transcription latency, memory
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
case "reindex":
    print("indexed \(try store().reindex()) items")
case "transcribe":
    guard let f = positional.first else { fail(usage) }
    let w = transcriber()
    let t = try await w.transcribe(samples: try AudioLoader.load16kMono(URL(fileURLWithPath: f)), prompt: option("--prompt"))
    print(t.text)
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
