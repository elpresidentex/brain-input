import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `BrainInput --demo-video <dir>`: renders the product demo (MP4, GIF and poster stills) frame by frame from
/// SwiftUI. The app windows in it are stand-ins with sample text; the recording pill uses the app's own look.
@MainActor
enum DemoVideo {
    static var outDir: URL? {
        guard let i = CommandLine.arguments.firstIndex(of: "--demo-video"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1])
    }
    static let size = NSSize(width: 960, height: 540), fps = 30

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

        let total = Double(DemoScene.all.count) * DemoScene.length
        var frames: [CGImage] = []
        for i in 0..<Int(total * Double(fps)) {
            clock.t = Double(i) / Double(fps)
            if let f = await frame() { frames.append(f) }
        }
        writeMP4(frames, to: dir.appendingPathComponent("demo.mp4"))
        // README / website hero: the email scene only, smaller and at 10 fps.
        let hero = stride(from: 0, to: Int(DemoScene.length * Double(fps)), by: 3).map { frames[$0] }
        writeGIF(hero, delay: 0.1, width: 800, to: dir.appendingPathComponent("hero.gif"))
        writePNG(frames[Int(3.4 * Double(fps))], to: dir.appendingPathComponent("still-speaking.png"))
        for (i, s) in DemoScene.all.enumerated() {
            let idx = min(frames.count - 1, Int((Double(i) * DemoScene.length + DemoScene.length - 0.5) * Double(fps)))
            writePNG(frames[idx], to: dir.appendingPathComponent("still-\(s.id).png"))
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

/// One nine-second scene: speak (raw words stream into the pill), process, clean text lands in the app.
struct DemoScene: Identifiable {
    var id: String
    var app: String            // window title
    var kind: Kind
    var raw: String
    var clean: String
    var notes: [String]
    enum Kind { case mail, chat, code }
    static let length = 9.0

    static let all: [DemoScene] = [
        DemoScene(id: "email", app: "New Message", kind: .mail,
                  raw: "hi jonas um thanks for sending the draft over i read it this morning and i think the pricing section is uh too long can we cut it to three points no wait two points and move the table to the appendix lets talk thursday best mira",
                  clean: "Hi Jonas,\n\nThanks for sending the draft over. I read it this morning and I think the pricing section is too long. Can we cut it to two points and move the table to the appendix?\n\nLet's talk Thursday.\n\nBest,\nMira",
                  notes: ["“um”, “uh” removed", "“three… no wait, two” → two", "Greeting, paragraphs, sign-off"]),
        DemoScene(id: "chat", app: "# launch", kind: .chat,
                  raw: "so the three things for launch week are first fix the onboarding copy second record the demo and third um send the invite to the beta list",
                  clean: "three things for launch week:\n1. fix the onboarding copy\n2. record the demo\n3. send the invite to the beta list",
                  notes: ["Spoken list → numbered list", "Casual, like a chat message"]),
        DemoScene(id: "code", app: "Pipeline.swift — brain-input", kind: .code,
                  raw: "in pipeline dot swift rename the function process samples to transcribe and insert and update the two call sites in app state dot swift",
                  clean: "In Pipeline.swift, rename the function processSamples to transcribeAndInsert and update the two call sites in AppState.swift.",
                  notes: ["File names spelled as on screen", "A prompt for your coding agent"]),
    ]
}

struct DemoStage: View {
    @ObservedObject var clock: DemoClock
    private let ink = Color(red: 0.07, green: 0.08, blue: 0.13)

    var body: some View {
        let index = min(DemoScene.all.count - 1, Int(clock.t / DemoScene.length))
        let scene = DemoScene.all[index]
        let t = clock.t - Double(index) * DemoScene.length
        // 0.6-5.2 s speaking, 5.2-5.9 transcribing, 5.9-6.5 polishing, 6.5 text lands
        let speaking = t >= 0.6 && t < 5.2
        let landed = t >= 6.5
        let words = scene.raw.split(separator: " ")
        let spoken = speaking ? words.prefix(Int(Double(words.count) * min(1, (t - 0.6) / 4.4))).joined(separator: " ") : ""
        ZStack {
            LinearGradient(colors: [ink, Color(red: 0.13, green: 0.12, blue: 0.20)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0)], center: UnitPoint(x: 0.85, y: 0.95), startRadius: 0, endRadius: 520)
            VStack(spacing: 0) {
                Text(landed ? "…get it the way you'd write it." : "Say it the way you think it…")
                    .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .padding(.top, 26)
                Text(landed ? scene.notes.joined(separator: "   ·   ") : (t < 0.6 ? "Hold a key and talk. In any app." : " "))
                    .font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Theme.accent).padding(.top, 8)
                DemoWindow(scene: scene, text: landed ? scene.clean : "", caret: !landed)
                    .frame(width: 640, height: 318).padding(.top, 18)
                Spacer(minLength: 0)
                DemoPill(t: t, preview: spoken).padding(.bottom, 16)
            }
            HStack(spacing: 6) {
                ForEach(DemoScene.all.indices, id: \.self) { i in Capsule().fill(.white.opacity(i == index ? 0.9 : 0.25)).frame(width: i == index ? 18 : 6, height: 6) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(22)
            Text("Sample text").font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(22)
        }
    }
}

struct DemoPill: View {
    var t: Double
    var preview: String
    var body: some View {
        HStack(spacing: 10) {
            if t < 0.6 { Image(systemName: "keyboard").foregroundStyle(Theme.accent); Text("⌃⌥Space") }
            else if t < 5.2 {
                LevelBars(level: Float(0.03 + 0.03 * abs(sin(t * 9)) + 0.02 * abs(sin(t * 23))))
                if preview.isEmpty { Text("Listening") }
                else { Text(preview).lineLimit(2).truncationMode(.head).multilineTextAlignment(.leading).frame(maxWidth: 380, alignment: .leading) }
            }
            else if t < 5.9 { Spinner(t: t); Text("Transcribing") }
            else if t < 6.5 { Spinner(t: t); Text("Polishing") }
            else if t < 8.2 { Image(systemName: "sparkles").foregroundStyle(Theme.accent); Text("Enhanced with Claude") }
            else { Image(systemName: "checkmark").foregroundStyle(Theme.accent); Text("Done") }
        }
        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Capsule().fill(Color(red: 0.09, green: 0.10, blue: 0.16)))
        .overlay(Capsule().stroke(Theme.accent.opacity(0.7), lineWidth: 1))
        .padding(4)
        .frame(height: 60)
    }
}

struct Spinner: View {
    var t: Double
    var body: some View {
        Circle().trim(from: 0, to: 0.7).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 13, height: 13).rotationEffect(.degrees(t * 540))
    }
}

struct DemoWindow: View {
    var scene: DemoScene
    var text: String
    var caret: Bool
    private var dark: Bool { scene.kind != .mail }
    private var bg: Color { dark ? Color(red: 0.11, green: 0.12, blue: 0.15) : .white }
    private var fg: Color { dark ? .white.opacity(0.92) : Color(red: 0.12, green: 0.13, blue: 0.16) }
    private var dim: Color { dark ? .white.opacity(0.45) : .black.opacity(0.45) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 11, height: 11) }
                Spacer(); Text(scene.app).font(.system(size: 12, weight: .semibold)).foregroundStyle(dim); Spacer()
                Color.clear.frame(width: 47, height: 1)
            }.padding(.horizontal, 14).frame(height: 36).background(dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
            Group {
                switch scene.kind {
                case .mail: mail
                case .chat: chat
                case .code: code
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(bg).clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }

    private func body(_ size: CGFloat) -> some View {
        (Text(text) + Text(caret ? "▏" : "").foregroundStyle(Theme.accent))
            .font(.system(size: size)).foregroundStyle(fg).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([("To:", "Jonas Weber"), ("Subject:", "Your draft")], id: \.0) { k, v in
                HStack { Text(k).foregroundStyle(dim); Text(v).foregroundStyle(fg) }.font(.system(size: 13)).padding(.horizontal, 18).frame(height: 30)
                Divider()
            }
            body(13.5).padding(18)
        }
    }

    private var chat: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Channels").font(.system(size: 11, weight: .semibold)).foregroundStyle(dim)
                ForEach(["# general", "# launch", "# design"], id: \.self) { c in
                    Text(c).font(.system(size: 13, weight: c == "# launch" ? .bold : .regular)).foregroundStyle(c == "# launch" ? fg : dim)
                }
                Spacer()
            }.padding(14).frame(width: 150, alignment: .leading).background(Color.white.opacity(0.04))
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.36, green: 0.55, blue: 0.85)).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jonas  ").font(.system(size: 13, weight: .bold)).foregroundStyle(fg) + Text("10:04").font(.system(size: 11)).foregroundStyle(dim)
                        Text("what's left before we ship on Thursday?").font(.system(size: 13)).foregroundStyle(fg)
                    }
                }
                Spacer()
                body(13).padding(12).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.22)))
            }.padding(16)
        }
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(["public actor DictationPipeline {", "    public func processSamples(_ samples: [Float]) async -> DictationRecord? {",
                               "        let transcript = try await transcriber.transcribe(samples: samples)", "        …", "    }", "}"].enumerated()), id: \.offset) { i, l in
                    HStack(spacing: 12) { Text("\(i + 27)").foregroundStyle(dim.opacity(0.6)).frame(width: 22, alignment: .trailing); Text(l).foregroundStyle(fg.opacity(0.8)) }
                        .font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                }
            }.padding(14)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Text("Ask the agent").font(.system(size: 11, weight: .semibold)).foregroundStyle(dim)
                body(13)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.5))).padding(14)
        }
    }
}
