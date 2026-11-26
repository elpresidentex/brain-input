import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `BrainInput --demo-video <dir>`: renders the product demo (MP4, GIF and poster stills) frame by frame from
/// SwiftUI. The app windows in it are stand-ins with sample text. `--lang en` renders English captions; the
/// dictated samples are German either way.
@MainActor
enum DemoVideo {
    static var outDir: URL? {
        guard let i = CommandLine.arguments.firstIndex(of: "--demo-video"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1])
    }
    /// `--portrait`: a 9:16 cut (1080 x 1920 px) for phones; writes demo-mobile.mp4 and still-mobile.png only.
    static let portrait = CommandLine.arguments.contains("--portrait")
    static let size = portrait ? NSSize(width: 540, height: 960) : NSSize(width: 960, height: 540), fps = 30

    static func run(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clock = DemoClock()
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua); w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DemoStage(clock: clock).frame(width: size.width, height: size.height))
        w.contentView = host; w.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))

        func frame() async -> CGImage? {
            try? await Task.sleep(for: .milliseconds(12))
            host.layoutSubtreeIfNeeded(); host.display()
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.cgImage
        }

        var frames: [CGImage] = []
        for i in 0..<Int(DemoTimeline.total * Double(fps)) {
            clock.t = Double(i) / Double(fps)
            if let f = await frame() { frames.append(f) }
        }
        func at(_ t: Double) -> CGImage { frames[min(frames.count - 1, max(0, Int(t * Double(fps))))] }
        if portrait {
            writeMP4(frames, to: dir.appendingPathComponent("demo-mobile.mp4"))
            writePNG(at(DemoTimeline.start(of: .scene(0)) + DemoScene.length - 0.5), to: dir.appendingPathComponent("still-mobile.png"))
            for (i, sc) in DemoScene.all.enumerated() { writePNG(at(DemoTimeline.start(of: .scene(i)) + DemoScene.length - 0.5), to: dir.appendingPathComponent("still-mobile-\(sc.id).png")) }
            exit(0)
        }
        writeMP4(frames, to: dir.appendingPathComponent("demo.mp4"))
        // README / website hero: the email scene only, smaller and at 10 fps.
        let first = DemoTimeline.start(of: .scene(0))
        let hero = stride(from: Int(first * Double(fps)), to: Int((first + DemoScene.length) * Double(fps)), by: 3).map { frames[$0] }
        writeGIF(hero, delay: 0.1, width: 800, to: dir.appendingPathComponent("hero.gif"))
        writePNG(at(first + 3.4), to: dir.appendingPathComponent("still-speaking.png"))
        writePNG(at(1.5), to: dir.appendingPathComponent("still-intro.png"))
        writePNG(at(DemoTimeline.total - 0.4), to: dir.appendingPathComponent("still-outro.png"))
        for (i, s) in DemoScene.all.enumerated() {
            writePNG(at(DemoTimeline.start(of: .scene(i)) + DemoScene.length - 0.5), to: dir.appendingPathComponent("still-\(s.id).png"))
            writePNG(at(DemoTimeline.start(of: .card(i)) + 1.2), to: dir.appendingPathComponent("card-\(s.id).png"))
        }
        exit(0)
    }

    static func writePNG(_ img: CGImage, to url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    }

    static func writeGIF(_ frames: [CGImage], delay: Double, width: Int, to url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in frames {
            let h = width * f.height / f.width
            let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(f, in: CGRect(x: 0, y: 0, width: width, height: h))
            CGImageDestinationAddImage(d, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        CGImageDestinationFinalize(d)
    }

    static func writeMP4(_ frames: [CGImage], to url: URL) {
        try? FileManager.default.removeItem(at: url)
        guard let first = frames.first, let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let w = first.width, h = first.height
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for (i, f) in frames.enumerated() {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            ctx?.draw(f, in: CGRect(x: 0, y: 0, width: w, height: h))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
    }
}

final class DemoClock: ObservableObject { @Published var t: Double = 0 }

/// Caption language. The default is German.
enum DemoLang {
    static let english: Bool = {
        guard let i = CommandLine.arguments.firstIndex(of: "--lang"), i + 1 < CommandLine.arguments.count else { return false }
        return CommandLine.arguments[i + 1] == "en"
    }()
}
func L(_ de: String, _ en: String) -> String { DemoLang.english ? en : de }

/// Notion-like palette: white, near-black, warm grey, one blue, pastel tints.
enum DemoInk {
    static let ink = Color(red: 0.05, green: 0.05, blue: 0.05)
    static let grey = Color(red: 0.47, green: 0.47, blue: 0.45)
    static let line = Color.black.opacity(0.09)
    static let warm = Color(red: 0.965, green: 0.961, blue: 0.957)
    static let blue = Color(red: 0, green: 0.459, blue: 0.871)
    static let red = Color(red: 0.83, green: 0.30, blue: 0.28)
}

func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / (b - a))) }
func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

/// One feature: a title card, then the scene (speak, transcribe, clean up, text lands in the app).
struct DemoScene: Identifiable {
    var id: String
    var number: String
    var title: String
    var line: String
    var symbol: String
    var tint: Color            // pastel background of the card and chip
    var deep: Color            // readable colour on that tint
    var app: String            // window title
    var kind: Kind
    var raw: String            // words in [brackets] are what clean-up drops
    var clean: String
    var notes: [String]
    enum Kind { case mail, chat, code }
    static let length = 8.4
    static let cardLength = 1.9

    static let all: [DemoScene] = [
        DemoScene(id: "email", number: "01", title: L("E-Mail", "Email"), line: L("Drauflosreden. Fertige Mail bekommen.", "Ramble. Get a finished email."),
                  symbol: "envelope", tint: Color(red: 0.984, green: 0.953, blue: 0.859), deep: Color(red: 0.70, green: 0.47, blue: 0.10),
                  app: L("Neue Nachricht", "New Message"), kind: .mail,
                  raw: "hallo jonas [ähm] danke für den entwurf ich hab ihn heute morgen in der u-bahn gelesen und ich finde der preisteil ist [äh] zu lang können wir den [auf drei punkte nee warte] auf zwei punkte kürzen und die tabelle in den anhang schieben lass uns donnerstag sprechen kaffee am mehringdamm viele grüße mira",
                  clean: "Hallo Jonas,\n\ndanke für den Entwurf. Ich hab ihn heute Morgen in der U-Bahn gelesen und ich finde, der Preisteil ist zu lang. Können wir den auf zwei Punkte kürzen und die Tabelle in den Anhang schieben?\n\nLass uns Donnerstag sprechen. Kaffee am Mehringdamm?\n\nViele Grüße\nMira",
                  notes: [L("„ähm“ und „äh“ raus", "“ähm”, “äh” removed"), L("„drei … nee warte, zwei“ → zwei", "“three … no wait, two” → two"), L("Anrede, Absätze, Gruß", "Greeting, paragraphs, sign-off")]),
        DemoScene(id: "chat", number: "02", title: "Chat", line: L("Eine Liste sagen. Eine Liste bekommen.", "Say a list. Get a list."),
                  symbol: "bubble.left.and.bubble.right", tint: Color(red: 0.906, green: 0.953, blue: 0.973), deep: Color(red: 0.16, green: 0.44, blue: 0.62),
                  app: "# launch", kind: .chat,
                  raw: "[also] die drei sachen für die launch woche sind erstens den onboarding text fixen zweitens das demo video aufnehmen und drittens [ähm] die einladung an die beta liste schicken",
                  clean: "drei Sachen für die Launch-Woche:\n1. Onboarding-Text fixen\n2. Demo-Video aufnehmen\n3. Einladung an die Beta-Liste schicken",
                  notes: [L("Aufzählung wird zur Liste", "Spoken list → numbered list"), L("Locker, wie im Chat", "Casual, like a chat message")]),
        DemoScene(id: "code", number: "03", title: "Code", line: L("Den Prompt sprechen statt tippen.", "Speak the prompt instead of typing it."),
                  symbol: "chevron.left.forwardslash.chevron.right", tint: Color(red: 0.929, green: 0.953, blue: 0.925), deep: Color(red: 0.22, green: 0.46, blue: 0.33),
                  app: "Pipeline.swift — brain-input", kind: .code,
                  raw: "[ähm] in pipeline punkt swift benenne die funktion process samples um in transcribe and insert und pass die zwei aufrufe in app state punkt swift an",
                  clean: "In Pipeline.swift: Benenne die Funktion processSamples um in transcribeAndInsert und pass die zwei Aufrufe in AppState.swift an.",
                  notes: [L("Dateinamen wie auf dem Bildschirm", "File names spelled as on screen"), L("Ein Prompt für deinen Coding-Agenten", "A prompt for your coding agent")]),
    ]

    /// Raw words with a flag for the ones clean-up drops.
    var words: [(text: String, dropped: Bool)] {
        var out: [(String, Bool)] = [], inside = false
        for w in raw.split(separator: " ") {
            var s = String(w)
            if s.hasPrefix("[") { inside = true; s.removeFirst() }
            let closes = s.hasSuffix("]")
            if closes { s.removeLast() }
            out.append((s, inside))
            if closes { inside = false }
        }
        return out
    }
}

/// Intro, then card + scene per feature, then the outro.
enum DemoTimeline {
    enum Part: Equatable { case intro, card(Int), scene(Int), outro }
    static let introLength = 2.0, outroLength = 3.8
    static let parts: [(part: Part, start: Double, length: Double)] = {
        var out: [(Part, Double, Double)] = [(.intro, 0, introLength)], t = introLength
        for i in DemoScene.all.indices {
            out.append((.card(i), t, DemoScene.cardLength)); t += DemoScene.cardLength
            out.append((.scene(i), t, DemoScene.length)); t += DemoScene.length
        }
        out.append((.outro, t, outroLength))
        return out
    }()
    static let total = parts.last!.start + parts.last!.length
    static func start(of p: Part) -> Double { parts.first { $0.part == p }!.start }
    static func current(_ t: Double) -> (part: Part, t: Double, length: Double) {
        let p = parts.last { $0.start <= t } ?? parts[0]
        return (p.part, t - p.start, p.length)
    }
}

struct DemoStage: View {
    @ObservedObject var clock: DemoClock

    var body: some View {
        let now = DemoTimeline.current(clock.t)
        // Every part fades in from white and, except the last, out to white.
        let fade = min(ramp(now.t, 0, 0.22), now.part == .outro ? 1 : 1 - ramp(now.t, now.length - 0.18, now.length))
        ZStack {
            Color.white
            Group {
                switch now.part {
                case .intro: DemoIntro(t: now.t)
                case .card(let i): DemoCard(scene: DemoScene.all[i], t: now.t)
                case .scene(let i): DemoSceneView(scene: DemoScene.all[i], t: now.t)
                case .outro: DemoOutro(t: now.t)
                }
            }.opacity(fade)
        }
    }
}

private func headline(_ s: String, _ size: CGFloat) -> Text {
    Text(s).font(.system(size: size, weight: .semibold)).tracking(-size * 0.04).foregroundStyle(DemoInk.ink)
}

struct DemoIntro: View {
    var t: Double
    var body: some View {
        VStack(spacing: 18) {
            if let icon = NSImage(contentsOfFile: "Assets/AppIcon-1024.png") {
                Image(nsImage: icon).resizable().frame(width: 84, height: 84).opacity(ramp(t, 0.05, 0.4))
            }
            Text(L("Brain Input · Diktieren auf dem Mac, in jeder App", "Brain Input · dictation for Mac, in any app"))
                .font(.system(size: DemoVideo.portrait ? 20 : 22)).foregroundStyle(DemoInk.grey).opacity(ramp(t, 0.3, 0.6))
                .multilineTextAlignment(.center).padding(.horizontal, DemoVideo.portrait ? 40 : 0)
        }
    }
}

struct DemoCard: View {
    var scene: DemoScene
    var t: Double
    var body: some View {
        let rise = ease(ramp(t, 0.05, 0.5))
        ZStack {
            scene.tint
            (DemoVideo.portrait ? AnyLayout(VStackLayout(spacing: 56)) : AnyLayout(HStackLayout(spacing: 40))) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(scene.number).font(.system(size: 22, weight: .semibold, design: .monospaced)).foregroundStyle(scene.deep)
                    headline(scene.title, DemoVideo.portrait ? 84 : 104)
                    Text(scene.line).font(.system(size: DemoVideo.portrait ? 28 : 27, weight: .medium)).fixedSize(horizontal: false, vertical: true).foregroundStyle(DemoInk.ink.opacity(0.72))
                        .opacity(ramp(t, 0.35, 0.7))
                }.offset(y: 18 * (1 - rise))
                if !DemoVideo.portrait { Spacer(minLength: 0) }
                Image(systemName: scene.symbol).font(.system(size: 78, weight: .regular)).foregroundStyle(DemoInk.ink)
                    .frame(width: 190, height: 190)
                    .background(RoundedRectangle(cornerRadius: 36).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 36).strokeBorder(DemoInk.line))
                    .shadow(color: .black.opacity(0.07), radius: 22, y: 10)
                    .rotationEffect(.degrees(4 - 4 * rise)).scaleEffect(0.92 + 0.08 * rise)
            }.padding(.horizontal, DemoVideo.portrait ? 48 : 84).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DemoOutro: View {
    var t: Double
    var body: some View {
        VStack(spacing: 16) {
            headline(L("Kostenlos. Open Source.", "Free. Open source."), DemoVideo.portrait ? 54 : 72).multilineTextAlignment(.center).offset(y: 14 * (1 - ease(ramp(t, 0.1, 0.5))))
            Text(L("Die Spracherkennung läuft lokal auf deinem Mac.", "Speech recognition runs locally on your Mac."))
                .font(.system(size: 23)).foregroundStyle(DemoInk.grey).opacity(ramp(t, 0.5, 0.8)).multilineTextAlignment(.center)
                .padding(.horizontal, DemoVideo.portrait ? 40 : 0)
            Text("brain-input.vercel.app").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 24).padding(.vertical, 12).background(RoundedRectangle(cornerRadius: 12).fill(DemoInk.blue))
                .padding(.top, 14).opacity(ramp(t, 0.9, 1.2)).scaleEffect(0.96 + 0.04 * ease(ramp(t, 0.9, 1.3)))
        }
    }
}

/// 0.5-4.3 s speaking, 4.3-4.9 transcribing, 4.9-5.5 cleaning up, 5.5-6.5 the text is typed, then the notes.
struct DemoSceneView: View {
    var scene: DemoScene
    var t: Double
    static let speak = (from: 0.5, to: 4.3), cleanAt = 4.9, typeAt = 5.5, doneAt = 6.5

    var body: some View {
        let typed = ramp(t, Self.typeAt, Self.doneAt)
        if DemoVideo.portrait { portraitBody(typed) } else {
        VStack(spacing: 0) {
            HStack {
                Text("\(scene.number) · \(scene.title)").font(.system(size: 14, weight: .semibold)).foregroundStyle(scene.deep)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 8).fill(scene.tint))
                Spacer()
                Text("Brain Input").font(.system(size: 14, weight: .semibold)).foregroundStyle(DemoInk.grey)
            }.padding(.top, 22)
            HStack(alignment: .top, spacing: 20) {
                spoken.frame(width: 306)
                DemoWindow(scene: scene, text: String(scene.clean.prefix(Int(Double(scene.clean.count) * typed))), caret: typed < 1)
            }.frame(height: 384).padding(.top, 16)
            HStack(spacing: 8) {
                Text(L("Beispieltext", "Sample text")).font(.system(size: 11)).foregroundStyle(DemoInk.grey.opacity(0.8)).frame(width: 306, alignment: .leading)
                    .padding(.trailing, 12)
                ForEach(Array(scene.notes.enumerated()), id: \.offset) { i, n in
                    let a = ramp(t, Self.doneAt + 0.1 + 0.35 * Double(i), Self.doneAt + 0.35 + 0.35 * Double(i))
                    HStack(spacing: 5) { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)); Text(n) }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(scene.deep).lineLimit(1).fixedSize()
                        .padding(.horizontal, 9).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 7).fill(scene.tint))
                        .opacity(a).offset(y: 6 * (1 - ease(a)))
                }
                Spacer(minLength: 0)
            }.frame(width: 900).padding(.top, 16)
            Spacer(minLength: 0)
        }.frame(width: 900)
        }
    }

    /// Phone cut: tag, the spoken words, the app window, then the notes, stacked at 500 pt wide with larger type.
    private func portraitBody(_ typed: Double) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(scene.number) · \(scene.title)").font(.system(size: 17, weight: .semibold)).foregroundStyle(scene.deep)
                    .padding(.horizontal, 13).padding(.vertical, 7).background(RoundedRectangle(cornerRadius: 9).fill(scene.tint))
                Spacer()
                Text("Brain Input").font(.system(size: 17, weight: .semibold)).foregroundStyle(DemoInk.grey)
            }.padding(.top, 28)
            spoken.frame(height: scene.kind == .mail ? 290 : 200).padding(.top, 14)
            Image(systemName: "arrow.down").font(.system(size: 18, weight: .semibold)).foregroundStyle(DemoInk.grey).frame(height: 30)
            DemoWindow(scene: scene, text: String(scene.clean.prefix(Int(Double(scene.clean.count) * typed))), caret: typed < 1)
                .frame(height: scene.kind == .mail ? 405 : 420)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(scene.notes.enumerated()), id: \.offset) { i, n in
                    let a = ramp(t, Self.doneAt + 0.1 + 0.35 * Double(i), Self.doneAt + 0.35 + 0.35 * Double(i))
                    HStack(spacing: 6) { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)); Text(n) }
                        .font(.system(size: 14.5, weight: .medium)).foregroundStyle(scene.deep).lineLimit(1).fixedSize()
                        .padding(.horizontal, 11).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 9).fill(scene.tint))
                        .opacity(a).offset(y: 6 * (1 - ease(a)))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
            Spacer(minLength: 0)
            Text(L("Beispieltext", "Sample text")).font(.system(size: 12)).foregroundStyle(DemoInk.grey.opacity(0.8)).padding(.bottom, 14)
        }.frame(width: 484)
    }

    /// The left pane: every word fades in as it is spoken; clean-up then strikes what it drops.
    private var spoken: some View {
        let words = scene.words
        let struck = ramp(t, Self.cleanAt, Self.cleanAt + 0.4)
        let text = words.enumerated().reduce(Text("")) { acc, w in
            let at = Self.speak.from + (Self.speak.to - Self.speak.from - 0.2) * Double(w.offset) / Double(max(1, words.count - 1))
            let seen = ramp(t, at, at + 0.18)
            let newest = t < Self.speak.to && seen > 0 && t < at + 0.45
            let base: Color = w.element.dropped && struck > 0 ? DemoInk.red : (newest ? DemoInk.blue : DemoInk.ink.opacity(struck > 0 ? 0.55 : 0.9))
            return acc + Text(w.element.text).foregroundStyle(base.opacity(seen)).strikethrough(w.element.dropped && struck > 0.5, color: DemoInk.red) + Text(" ")
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 12)).foregroundStyle(.white).frame(width: 26, height: 26)
                    .background(Circle().fill(t >= Self.speak.from && t < Self.speak.to ? DemoInk.red : DemoInk.ink))
                Text(L("Du sagst", "You say")).font(.system(size: 14, weight: .semibold)).foregroundStyle(DemoInk.ink)
                Spacer()
            }
            text.font(.system(size: DemoVideo.portrait ? 18 : 15.5)).lineSpacing(DemoVideo.portrait ? 6 : 5).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
            Spacer(minLength: 0)
            DemoPill(t: t)
        }
        .padding(16).frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(DemoInk.warm))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DemoInk.line))
    }
}

struct DemoPill: View {
    var t: Double
    var body: some View {
        HStack(spacing: 9) {
            if t < DemoSceneView.speak.from { Image(systemName: "keyboard"); Text(L("⌃⌥Leertaste halten", "Hold ⌃⌥Space")) }
            else if t < DemoSceneView.speak.to {
                HStack(spacing: 2.5) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule().fill(DemoInk.red).frame(width: 3, height: 5 + 13 * abs(sin(t * (7 + Double(i) * 1.7) + Double(i))))
                    }
                }.frame(height: 20)
                Text(L("Hört zu", "Listening"))
            }
            else if t < DemoSceneView.cleanAt { Spinner(t: t); Text(L("Transkribiert lokal auf dem Mac", "Transcribing on your Mac")) }
            else if t < DemoSceneView.typeAt { Spinner(t: t); Text(L("Claude räumt auf", "Claude cleans up")) }
            else if t < DemoSceneView.doneAt { Image(systemName: "sparkles").foregroundStyle(DemoInk.blue); Text(L("Schreibt in die App", "Typing into the app")) }
            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.2, green: 0.6, blue: 0.4)); Text(L("Fertig", "Done")) }
            Spacer(minLength: 0)
        }
        .font(.system(size: DemoVideo.portrait ? 15 : 13, weight: .medium)).foregroundStyle(DemoInk.ink)
        .padding(.horizontal, 12).frame(height: DemoVideo.portrait ? 42 : 38)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DemoInk.line))
    }
}

struct Spinner: View {
    var t: Double
    var body: some View {
        Circle().trim(from: 0, to: 0.7).stroke(DemoInk.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 13, height: 13).rotationEffect(.degrees(t * 540))
    }
}

struct DemoWindow: View {
    var scene: DemoScene
    var text: String
    var caret: Bool
    private let fg = DemoInk.ink.opacity(0.92), dim = DemoInk.grey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 11, height: 11) }
                Spacer(); Text(scene.app).font(.system(size: 12, weight: .semibold)).foregroundStyle(dim); Spacer()
                Color.clear.frame(width: 47, height: 1)
            }.padding(.horizontal, 14).frame(height: 36).background(DemoInk.warm)
            Rectangle().fill(DemoInk.line).frame(height: 1)
            Group {
                switch scene.kind {
                case .mail: mail
                case .chat: chat
                case .code: code
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DemoInk.line))
        .shadow(color: .black.opacity(0.09), radius: 26, y: 12)
    }

    private func body(_ size: CGFloat) -> some View {
        (Text(text) + Text(caret ? "▏" : "").foregroundStyle(DemoInk.blue))
            .font(.system(size: DemoVideo.portrait ? size + 1.5 : size)).foregroundStyle(fg).lineSpacing(3.5).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([(L("An:", "To:"), "Jonas Weber"), (L("Betreff:", "Subject:"), L("Dein Entwurf", "Your draft"))], id: \.0) { k, v in
                HStack { Text(k).foregroundStyle(dim); Text(v).foregroundStyle(fg) }.font(.system(size: 13.5)).padding(.horizontal, 20).frame(height: 32)
                Rectangle().fill(DemoInk.line).frame(height: 1)
            }
            body(15).padding(20)
        }
    }

    private var chat: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Kanäle", "Channels")).font(.system(size: 11, weight: .semibold)).foregroundStyle(dim)
                ForEach(["# allgemein", "# launch", "# design"], id: \.self) { c in
                    Text(c).font(.system(size: 13.5, weight: c == "# launch" ? .semibold : .regular)).foregroundStyle(c == "# launch" ? fg : dim)
                }
                Spacer()
            }.padding(16).frame(width: DemoVideo.portrait ? 104 : 150, alignment: .leading).background(DemoInk.warm.opacity(0.7))
            Rectangle().fill(DemoInk.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("J").font(.system(size: 14, weight: .semibold)).foregroundStyle(scene.deep).frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(scene.tint))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jonas  ").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(fg) + Text("10:04").font(.system(size: 11)).foregroundStyle(dim)
                        Text("Was fehlt noch, bevor wir Donnerstag live gehen?").font(.system(size: 14)).foregroundStyle(fg)
                    }
                }
                Spacer()
                body(14.5).padding(13).frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.black.opacity(0.18)))
            }.padding(DemoVideo.portrait ? 14 : 18)
        }
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array((DemoVideo.portrait
                    ? ["public actor DictationPipeline {", "  func processSamples(_ s: [Float]) async {", "    let t = try await transcribe(s)", "    …", "  }", "}"]
                    : ["public actor DictationPipeline {", "    public func processSamples(_ samples: [Float]) async -> DictationRecord? {",
                       "        let transcript = try await transcriber.transcribe(samples: samples)", "        …", "    }", "}"]).enumerated()), id: \.offset) { i, l in
                    HStack(spacing: 12) { Text("\(i + 27)").foregroundStyle(dim.opacity(0.6)).frame(width: 22, alignment: .trailing); Text(l).foregroundStyle(fg.opacity(0.8)) }
                        .font(.system(size: DemoVideo.portrait ? 12.5 : 11.5, design: .monospaced)).lineLimit(1)
                }
            }.padding(16)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 7) {
                Text(L("Frag den Agenten", "Ask the agent")).font(.system(size: 11, weight: .semibold)).foregroundStyle(dim)
                body(14.5)
            }.padding(14).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(DemoInk.warm))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DemoInk.blue.opacity(0.55))).padding(16)
        }
    }
}
