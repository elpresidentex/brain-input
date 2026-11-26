import Foundation

// Fine-grained timing of one dictation, from key release to inserted text. The coarse numbers stay in `Timings`;
// everything here exists to answer "where did the time go?" when a transcription is slow.

/// What the speech engine reports about one call. Filled inside the engine, so the time it spent waiting for its own
/// turn (actors serialise calls) can be told apart from time spent working.
public struct TranscribeStats: Sendable, Codable, Equatable {
    public var engine = ""
    /// When the engine body began running. Caller's call time to this instant is the queue wait.
    public var startedAt: Date?
    /// Model load that happened inside this call (cold or unloaded model); 0 when it was already resident.
    public var loadMs = 0
    /// Pure model run (whisper_full / Parakeet transcribe).
    public var inferenceMs = 0
    /// Samples the engine actually ran on (after padding to the model's minimum).
    public var samples = 0
    /// True when the energy gate decided there was no speech and the model never ran.
    public var silenceGated = false
    public init() {}
}

/// Network side of one Messages API call, from URLSessionTaskMetrics.
public struct NetTiming: Sendable, Codable, Equatable {
    /// DNS + TCP connect + TLS. 0 on a reused connection.
    public var connectMs = 0
    /// Request fully sent to first response byte: the model's own latency (queue + prefill + first token).
    public var ttfbMs = 0
    /// First byte to last byte.
    public var downloadMs = 0
    public var reusedConnection = false
    public var proto = ""
    public init() {}
}

/// Breakdown of the clean-up step.
public struct CleanupDetail: Sendable, Codable, Equatable {
    public var screenReadMs = 0
    public var promptMs = 0
    /// Whole model call as seen by the app.
    public var apiMs = 0
    public var net: NetTiming?
    public var inputChars = 0
    public var outputChars = 0
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var model = ""
    public init() {}
}

/// What the app knew about the moment of release; passed in because the pipeline cannot see it.
public struct TraceSeed: Sendable {
    /// Hotkey release (or toggle off) to the pipeline starting: stopping the microphone and spinning up the task.
    public var stopMs = 0
    /// A live-preview transcription was still running when the key came up. It holds the engine, so the real one waits.
    public var previewInFlight = false
    public var previewRuns = 0
    /// Total time the preview spent in the engine during this recording.
    public var previewEngineMs = 0
    public var meetingActive = false
    public init(stopMs: Int = 0, previewInFlight: Bool = false, previewRuns: Int = 0, previewEngineMs: Int = 0, meetingActive: Bool = false) {
        self.stopMs = stopMs; self.previewInFlight = previewInFlight; self.previewRuns = previewRuns
        self.previewEngineMs = previewEngineMs; self.meetingActive = meetingActive
    }
}

public struct TimingDetail: Sendable, Codable, Equatable {
    // Before the pipeline
    public var stopMs = 0
    public var previewInFlight = false
    public var previewRuns = 0
    public var previewEngineMs = 0
    public var meetingActive = false
    // Transcription phase
    public var engine = ""
    public var promptMs = 0           // building the whisper prompt (dictionary)
    public var queueWaitMs = 0        // waiting for the engine to become free
    public var loadMs = 0             // model (re)load inside the call
    public var inferenceMs = 0        // model run
    public var silenceGated = false
    public var contextMs = 0          // frontmost-app / window reading (runs concurrently)
    public var contextWaitMs = 0      // extra wait for it after the transcript was ready
    public var samples = 0
    // Environment
    public var thermal = ""
    public var lowPower = false
    // Clean-up phase
    public var cleanup: CleanupDetail?
    // Live (chunked) transcription. All optional: nil on records from before it existed and on one-shot dictations.
    /// Chunks the recording was transcribed in.
    public var chunks: Int?
    /// Release to the last chunk's text: the transcription wait that is left after release.
    public var tailMs: Int?
    /// Part of the tail spent on chunks that were queued before release.
    public var backlogMs: Int?
    /// Engine time for all chunks, during and after recording.
    public var liveEngineMs: Int?
    /// True when live transcription gave up and the whole recording was transcribed in one pass.
    public var liveFallback: Bool?
    public init() {}

    /// Time inside the transcribe phase not explained by queue, load or inference. Should be near 0.
    public func transcribeResidualMs(transcribeMs: Int) -> Int { transcribeMs - queueWaitMs - loadMs - inferenceMs }

    public static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s { case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "?" }
    }
}

// MARK: - Analysis

public struct Fit: Sendable {
    public var n = 0
    public var pearson = Double.nan
    public var spearman = Double.nan
    public var slope = Double.nan
    public var intercept = Double.nan
    public var r2: Double { pearson * pearson }
}

public struct PhaseStat: Sendable {
    public var name: String
    public var n: Int, median: Double, p90: Double, max: Double
}

/// Correlation and attribution over stored dictations.
public enum TimingReport {
    public static func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    public static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count > 2 else { return .nan }
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) { sxy += (a - mx) * (b - my); sxx += (a - mx) * (a - mx); syy += (b - my) * (b - my) }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : .nan
    }

    static func ranks(_ v: [Double]) -> [Double] {
        let order = v.indices.sorted { v[$0] < v[$1] }
        var r = [Double](repeating: 0, count: v.count); var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, v[order[j + 1]] == v[order[i]] { j += 1 }
            for k in i...j { r[order[k]] = Double(i + j) / 2 }
            i = j + 1
        }
        return r
    }

    public static func fit(_ x: [Double], _ y: [Double]) -> Fit {
        var f = Fit(); f.n = x.count
        guard x.count > 2 else { return f }
        f.pearson = pearson(x, y); f.spearman = pearson(ranks(x), ranks(y))
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        if sxx > 0 {
            f.slope = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
            f.intercept = my - f.slope * mx
        }
        return f
    }

    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let i = Int((Double(sorted.count) * q).rounded(.up)) - 1
        return sorted[max(0, min(sorted.count - 1, i))]
    }

    public static func stat(_ name: String, _ v: [Int]) -> PhaseStat {
        let s = v.map(Double.init).sorted()
        let med = s.isEmpty ? Double.nan : (s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
        return PhaseStat(name: name, n: s.count, median: med, p90: quantile(s, 0.9), max: s.last ?? .nan)
    }

    /// Why a slow transcription was slow, from the detail when it exists.
    public static func cause(_ r: DictationRecord) -> String {
        guard let d = r.timings.detail else { return "no detail (recorded before timing detail existed)" }
        let t = r.timings.transcribeMs
        let parts: [(String, Int)] = [("waited for engine" + (d.previewInFlight ? " (live preview was running)" : ""), d.queueWaitMs),
                                      ("model load", d.loadMs), ("inference", d.inferenceMs), ("context read (after transcript)", d.contextWaitMs),
                                      ("other", max(0, d.transcribeResidualMs(transcribeMs: t)))]
        let top = parts.max { $0.1 < $1.1 }!
        return "\(top.0) \(top.1) ms of \(t)"
    }

    /// Live (chunked) against one-shot dictations: does the wait after release still grow with recording length?
    static func liveSection(_ rs: [DictationRecord]) -> String {
        func f(_ x: Double, _ digits: Int = 2) -> String { x.isNaN ? "n/a" : String(format: "%.\(digits)f", x) }
        let live = rs.filter { $0.timings.detail?.chunks != nil }
        guard !live.isEmpty else { return "" }
        let fallback = rs.filter { $0.timings.detail?.liveFallback == true }
        let oneShot = rs.filter { $0.timings.detail?.chunks == nil }
        var out = "\nLIVE TRANSCRIPTION (\(live.count) chunked, \(fallback.count) fell back to one pass, \(oneShot.count) one-shot)\n"
        out += "  group                  n   median transcribe ms   p90   ms per audio s   pearson vs audio\n"
        for (name, g) in [("chunked", live), ("one-shot (incl. fallback)", oneShot)] where !g.isEmpty {
            let s = stat(name, g.map { $0.timings.transcribeMs })
            let fit = fit(g.map { Double($0.timings.audioMs) }, g.map { Double($0.timings.transcribeMs) })
            out += "  " + name.padding(toLength: 22, withPad: " ", startingAt: 0)
                + String(format: "%3d %14.0f %9.0f %12@ %14@\n", s.n, s.median, s.p90, f(fit.slope * 1000, 1) as NSString, f(fit.pearson) as NSString)
        }
        let tails = live.compactMap { $0.timings.detail?.tailMs }, backlog = live.compactMap { $0.timings.detail?.backlogMs }
        let chunks = live.compactMap { $0.timings.detail?.chunks }
        let t = stat("tail", tails), b = stat("backlog", backlog), c = stat("chunks", chunks)
        out += String(format: "  tail after release: median %.0f ms, p90 %.0f, max %.0f (of which backlog median %.0f ms); chunks median %.0f, max %.0f\n",
                      t.median, t.p90, t.max, b.median, c.median, c.max)
        return out
    }

    public static func render(_ records: [DictationRecord]) -> String {
        var out = ""
        func f(_ x: Double, _ digits: Int = 2) -> String { x.isNaN ? "n/a" : String(format: "%.\(digits)f", x) }
        let rs = records.filter { $0.timings.transcribeMs > 0 && !$0.raw.isEmpty }
        out += "\(records.count) dictations, \(rs.count) with a transcription time, \(rs.filter { $0.timings.detail != nil }.count) with detailed timing\n\n"
        guard !rs.isEmpty else { return out + "nothing to analyse yet\n" }

        out += "WHERE THE TIME GOES (ms)            n   median      p90      max\n"
        let stops = rs.compactMap { $0.timings.detail?.stopMs }
        var phases = [stat("transcribe", rs.map { $0.timings.transcribeMs }),
                      stat("clean-up (called)", rs.filter { $0.timings.cleanupMs > 0 }.map { $0.timings.cleanupMs }),
                      stat("insert", rs.map { $0.timings.insertMs }), stat("total in pipeline", rs.map { $0.timings.totalMs })]
        if !stops.isEmpty { phases.insert(stat("stop mic → pipeline", stops), at: 0) }
        for p in phases { out += "  " + p.name.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "%4d %8.0f %8.0f %8.0f\n", p.n, p.median, p.p90, p.max) }

        out += "\nTRANSCRIBE TIME VS LENGTH OF THE MESSAGE\n"
        out += "  predictor        n  pearson spearman    R²   ms per unit  fixed ms\n"
        let y = rs.map { Double($0.timings.transcribeMs) }
        var audioFit = Fit()
        for (name, x) in [("words", rs.map { Double(words($0.raw)) }), ("characters", rs.map { Double($0.raw.count) }),
                          ("audio ms", rs.map { Double($0.timings.audioMs) })] {
            let fit = fit(x, y)
            if name == "audio ms" { audioFit = fit }
            out += "  " + name.padding(toLength: 14, withPad: " ", startingAt: 0)
                + String(format: "%4d %8@ %8@ %6@ %12@ %9.0f\n", fit.n, f(fit.pearson) as NSString, f(fit.spearman) as NSString, f(fit.r2) as NSString,
                         f(fit.slope, 3) as NSString, fit.intercept.isNaN ? 0 : fit.intercept)
        }

        // Outliers: slower than the line through the data by more than 1.5 s and 2x the prediction.
        if !audioFit.slope.isNaN {
            let slow = rs.filter { r in
                let predicted = audioFit.intercept + audioFit.slope * Double(r.timings.audioMs)
                let actual = Double(r.timings.transcribeMs)
                return actual - predicted > 1500 && actual > 2 * max(predicted, 1)
            }.sorted { $0.timings.transcribeMs > $1.timings.transcribeMs }
            out += "\nSLOWER THAN LENGTH EXPLAINS (\(slow.count) of \(rs.count))\n"
            for r in slow.prefix(15) {
                out += "  \(r.date.formatted(date: .numeric, time: .standard))  audio \(r.timings.audioMs / 1000)s  \(words(r.raw)) words  transcribe \(r.timings.transcribeMs) ms  → \(cause(r))\n"
            }
        }

        let detailed = rs.compactMap { r in r.timings.detail.map { (r, $0) } }
        if !detailed.isEmpty {
            out += "\nTRANSCRIBE PHASE, ATTRIBUTED (median ms, \(detailed.count) dictations)\n"
            for (name, v) in [("engine queue wait", detailed.map { $0.1.queueWaitMs }), ("model load", detailed.map { $0.1.loadMs }),
                              ("inference", detailed.map { $0.1.inferenceMs }), ("context read wait", detailed.map { $0.1.contextWaitMs }),
                              ("whisper prompt build", detailed.map { $0.1.promptMs })] {
                let s = stat(name, v); out += "  " + name.padding(toLength: 24, withPad: " ", startingAt: 0) + String(format: "median %6.0f  p90 %6.0f  max %6.0f\n", s.median, s.p90, s.max)
            }
            let withPreview = detailed.filter { $0.1.previewInFlight }, without = detailed.filter { !$0.1.previewInFlight }
            if !withPreview.isEmpty && !without.isEmpty {
                func med(_ a: [(DictationRecord, TimingDetail)]) -> Double { stat("", a.map { $0.0.timings.transcribeMs }).median }
                out += String(format: "\n  preview still running at release: %d dictations, median transcribe %.0f ms; otherwise %d, %.0f ms\n",
                              withPreview.count, med(withPreview), without.count, med(without))
            }
            let inf = fit(detailed.map { Double($0.0.timings.audioMs) }, detailed.map { Double($0.1.inferenceMs) })
            out += "  inference alone vs audio length: pearson \(f(inf.pearson)), \(f(inf.slope * 1000, 0)) ms per audio second\n"
        }

        out += liveSection(rs)

        let cl = rs.filter { $0.cleanupStatus == "ok" && $0.timings.cleanupMs > 0 }
        if cl.count > 2 {
            out += "\nCLEAN-UP\n"
            let a = fit(cl.map { Double(words($0.raw)) }, cl.map { Double($0.timings.cleanupMs) })
            out += "  call time vs words: pearson \(f(a.pearson)), \(f(a.slope, 1)) ms per word, fixed \(f(a.intercept, 0)) ms  (n=\(cl.count))\n"
            let det = cl.compactMap { $0.timings.detail?.cleanup }
            if !det.isEmpty {
                let net = det.compactMap { $0.net }
                for (name, v) in [("screen read", det.map { $0.screenReadMs }), ("api call total", det.map { $0.apiMs }),
                                  ("connect (dns+tls)", net.map { $0.connectMs }), ("time to first byte", net.map { $0.ttfbMs }),
                                  ("download", net.map { $0.downloadMs })] where !v.isEmpty {
                    let s = stat(name, v); out += "  " + name.padding(toLength: 20, withPad: " ", startingAt: 0) + String(format: "median %6.0f  p90 %6.0f  max %6.0f\n", s.median, s.p90, s.max)
                }
            }
        }
        return out
    }
}
