import AppKit
import AVFoundation
import BrainCore
import BrainWhisper
import Carbon.HIToolbox

// MARK: - Log

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BrainInput.log")
    private static let queue = DispatchQueue(label: "log")
    /// Keeps the log from growing without bound: past 2 MB the older half is dropped. Called once at launch.
    static func trim() {
        queue.async {
            guard let d = try? Data(contentsOf: url), d.count > 2_000_000 else { return }
            let tail = d.suffix(1_000_000)
            let cut = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
            try? Data(tail[cut...]).write(to: url, options: .atomic)
        }
    }
    static func write(_ msg: String) {
        let line = "\(Date().formatted(.iso8601)) \(msg)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}

// MARK: - Preferences

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon flags

    /// Marks a shortcut made of modifiers alone (⌘, ⌥⌃ …). Carbon cannot register those, see ModifierWatcher.
    static let modifierOnlyCode: UInt32 = 0xFFFF
    var isModifierOnly: Bool { keyCode == Shortcut.modifierOnlyCode }

    /// Extra bit in `modifiers` (Carbon has no right ⌘): the shortcut is the right ⌘ key only.
    static let rightCmdBit: UInt32 = 1 << 16
    var rightCmdOnly: Bool { modifiers & Shortcut.rightCmdBit != 0 }
    static let deviceLeftCmd: UInt = 0x08, deviceRightCmd: UInt = 0x10   // NX_DEVICE[LR]CMDKEYMASK

    static func modifierSymbols(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    var display: String {
        if isModifierOnly { return (rightCmdOnly ? "Right " : "") + Shortcut.modifierSymbols(modifiers) }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
                                      kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                      kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
                                      kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19"]
        if let s = special[Int(code)] { return s }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "key \(code)" }
        let data = unsafeBitCast(ptr, to: CFData.self) as Data
        var dead: UInt32 = 0; var len = 0; var chars = [UniChar](repeating: 0, count: 4)
        data.withUnsafeBytes { raw in
            _ = UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                               UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }

    static func carbonFlags(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

enum Pref {
    static let d = UserDefaults.standard
    static func registerDefaults() {
        d.register(defaults: [
            "dictateKey": kVK_Space, "dictateMods": controlKey | optionKey,
            "undoKey": kVK_ANSI_Z, "undoMods": controlKey | optionKey,
            "hotkeyMode": "hybrid", "whisperModel": ModelLocator.preferredModel,
            "cleanupEnabled": true, "claudeModel": "claude-haiku-5-5", "cleanupTimeout": 3.0,
            "autoLearn": true, "offerMeetings": true,
        ])
    }
    static var dictate: Shortcut {
        get { Shortcut(keyCode: UInt32(d.integer(forKey: "dictateKey")), modifiers: UInt32(d.integer(forKey: "dictateMods"))) }
        set { d.set(Int(newValue.keyCode), forKey: "dictateKey"); d.set(Int(newValue.modifiers), forKey: "dictateMods") }
    }
    static var undo: Shortcut {
        get { Shortcut(keyCode: UInt32(d.integer(forKey: "undoKey")), modifiers: UInt32(d.integer(forKey: "undoMods"))) }
        set { d.set(Int(newValue.keyCode), forKey: "undoKey"); d.set(Int(newValue.modifiers), forKey: "undoMods") }
    }
    static var hotkeyMode: String { d.string(forKey: "hotkeyMode") ?? "hybrid" }
    static var whisperModel: String { d.string(forKey: "whisperModel") ?? ModelLocator.preferredModel }
}

// MARK: - Global shortcuts (Carbon hot keys: press and release, no permission needed)
// Approach follows VoiceInk's shortcut handling in spirit; the code is new.

final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private var handlers: [UInt32: (down: () -> Void, up: () -> Void)] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false
    /// Shortcuts macOS refused to register, usually because another app holds them. Shown in Settings.
    private(set) var failed: Set<UInt32> = []

    private let modifierWatcher = ModifierWatcher()

    func register(id: UInt32, shortcut: Shortcut, down: @escaping () -> Void, up: @escaping () -> Void = {}) {
        install()
        if let old = refs[id] { UnregisterEventHotKey(old); refs[id] = nil }
        failed.remove(id)
        modifierWatcher.remove(id)
        if shortcut.isModifierOnly {
            modifierWatcher.add(id: id, modifiers: shortcut.modifiers, down: down, up: up)
            return
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4252_4E49, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[id] = ref; handlers[id] = (down, up) }
        else { failed.insert(id); Log.write("hotkey \(id) (\(shortcut.display)) could not be registered: \(status)") }
    }

    fileprivate func dispatch(_ id: UInt32, pressed: Bool) {
        guard let h = handlers[id] else { return }
        pressed ? h.down() : h.up()
    }

    private func install() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { HotkeyCenter.shared.dispatch(id.id, pressed: pressed) }
            return noErr
        }, 2, &specs, nil, nil)
    }
}

// MARK: - Modifier-only shortcuts (⌘ alone)
// Carbon hot keys need a real key, so a bare modifier is detected from flagsChanged events instead. The global
// monitor needs Accessibility (or Input Monitoring) permission; without it the shortcut only works while this app is in front.
// A bare ⌘ is also the start of every ⌘C, so the press only counts when no other key follows within 150 ms.

final class ModifierWatcher {
    private struct Entry { var modifiers: UInt32; var down: () -> Void; var up: () -> Void; var pending: DispatchWorkItem?; var active = false }
    private var entries: [UInt32: Entry] = [:]
    private var monitors: [Any] = []

    func add(id: UInt32, modifiers: UInt32, down: @escaping () -> Void, up: @escaping () -> Void) {
        entries[id] = Entry(modifiers: modifiers, down: down, up: up)
        installIfNeeded()
        if !AXIsProcessTrusted() { Log.write("modifier-only shortcut needs Accessibility to work outside this app") }
    }

    func remove(_ id: UInt32) { entries[id]?.pending?.cancel(); entries[id] = nil }

    private func installIfNeeded() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in
            DispatchQueue.main.async { self?.handle(e) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { e in handler(e); return e }) { monitors.append(l) }
    }

    private func handle(_ e: NSEvent) {
        let current = Shortcut.carbonFlags(e.modifierFlags.intersection(.deviceIndependentFlagsMask))
        let raw = e.modifierFlags.rawValue
        let rightOnly = raw & Shortcut.deviceRightCmd != 0 && raw & Shortcut.deviceLeftCmd == 0
        for id in Array(entries.keys) {
            guard var en = entries[id] else { continue }
            let wanted = en.modifiers & ~Shortcut.rightCmdBit
            let matches = current == wanted && (en.modifiers & Shortcut.rightCmdBit == 0 || rightOnly)
            if e.type == .keyDown {
                en.pending?.cancel(); en.pending = nil      // a chord such as ⌘C, not a bare modifier
            } else if matches, !en.active, en.pending == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard var en = self?.entries[id] else { return }
                    en.pending = nil; en.active = true; self?.entries[id] = en
                    en.down()
                }
                en.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            } else if !matches {
                if en.pending != nil, current == 0 {
                    // Released within the debounce window with no other key: a quick tap. Count it as press and release,
                    // otherwise a fast second tap never stops a recording.
                    en.pending?.cancel(); en.pending = nil; en.active = false; entries[id] = en
                    en.down(); en.up(); continue
                }
                en.pending?.cancel(); en.pending = nil
                if en.active { en.active = false; entries[id] = en; en.up(); continue }
            }
            entries[id] = en
        }
    }
}

// MARK: - Microphone
// Starting an audio engine cold takes 100-500 ms (more with Bluetooth), which used to eat the first words. With
// `warmSeconds` > 0 the engine stays running for a while after a recording and keeps the last 0.3 s as pre-roll, so the
// next dictation starts instantly and also catches speech that began just before the key press. The system microphone
// indicator stays on during that window; meetings use warmSeconds = 0 and release the microphone at once.

final class MicRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var preRoll: [Float] = []
    private var recording = false
    private var heard = false
    private let lock = NSLock()
    private let resampler = StreamResampler()
    private var cooldown: DispatchWorkItem?
    var warmSeconds: Double = 0
    var onLevel: ((Float) -> Void)?
    /// When set, samples are handed over in chunks instead of being kept (meetings).
    var onSamples: (([Float]) -> Void)?

    static func requestPermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// True once the input device has delivered real (non-silent) audio since start(). Some devices, Bluetooth above all,
    /// report the engine as running well before they deliver sound.
    var isReady: Bool { lock.withLock { heard } }

    /// True when start() will return immediately.
    var isWarm: Bool { lock.withLock { engine?.isRunning == true } }

    /// Safe to call off the main thread; the cold path blocks until the input device is running.
    func start() throws {
        cancelCooldown()
        if let e = lock.withLock({ engine }), !e.isRunning { teardown() }   // device change stopped it
        let wasWarm = lock.withLock { engine != nil }
        if !wasWarm { try buildEngine() }
        lock.withLock { samples = preRoll; preRoll = []; recording = true; heard = wasWarm }
    }

    private func buildEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "BrainInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            let s = self.resampler.convert(buf)
            guard !s.isEmpty else { return }
            let live: Bool = self.lock.withLock {
                if self.recording {
                    if self.onSamples == nil { self.samples += s }
                    if !self.heard, AudioMath.rms(s) > 1e-5 { self.heard = true }
                    return true
                }
                self.preRoll += s
                if self.preRoll.count > 4800 { self.preRoll.removeFirst(self.preRoll.count - 4800) }
                return false
            }
            guard live else { return }
            self.onSamples?(s)
            self.onLevel?(AudioMath.rms(s))
        }
        engine.prepare()
        try engine.start()
        lock.withLock { self.engine = engine }
    }

    /// The audio recorded so far, without stopping.
    func snapshot() -> [Float] { lock.withLock { samples } }

    @discardableResult
    func stop() -> [Float] {
        let out: [Float] = lock.withLock { recording = false; preRoll = []; let s = samples; samples = []; return s }
        if warmSeconds > 0 {
            let work = DispatchWorkItem { [weak self] in self?.teardown() }
            lock.withLock { cooldown = work }
            DispatchQueue.main.asyncAfter(deadline: .now() + warmSeconds, execute: work)
        } else { teardown() }
        return out
    }

    private func cancelCooldown() { lock.withLock { cooldown?.cancel(); cooldown = nil } }

    private func teardown() {
        let e: AVAudioEngine? = lock.withLock { let e = engine; engine = nil; preRoll = []; return e }
        e?.inputNode.removeTap(onBus: 0)
        e?.stop()
    }
}

// MARK: - Insert at cursor
// Clipboard handling (transient pasteboard markers, snapshot and restore, ⌘V via CGEvent) is adapted
// from VoiceInk (GPL-3.0): Infrastructure/SystemIntegration/Paste/CursorPaster.swift and ClipboardManager.swift.

final class ClipboardPaster: TextInserter, @unchecked Sendable {
    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]
    private var saved: Snapshot?
    private var ourChangeCount = -1
    private var restoreTask: Task<Void, Never>?
    /// Set when text could not be pasted and was left on the clipboard instead.
    var onNeedsManualPaste: (() -> Void)?

    static var trusted: Bool { AXIsProcessTrusted() }

    func insert(_ text: String) async -> Bool {
        let canPaste = Self.trusted
        await MainActor.run {
            let pb = NSPasteboard.general
            restoreTask?.cancel()
            // A restore still pending means the clipboard holds our own text: keep the older snapshot.
            if saved == nil || pb.changeCount != ourChangeCount {
                saved = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
            }
            pb.clearContents()
            pb.setString(text, forType: .string)
            if canPaste {
                pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
            }
            ourChangeCount = pb.changeCount
        }
        guard canPaste else {
            // Without Accessibility the text stays on the clipboard so nothing is lost.
            await MainActor.run { saved = nil; onNeedsManualPaste?() }
            return false
        }
        try? await Task.sleep(for: .milliseconds(80))
        Self.post(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        restoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, let saved = self.saved else { return }
            let pb = NSPasteboard.general
            if pb.changeCount == self.ourChangeCount {
                pb.clearContents()
                let items = saved.map { entries -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (t, d) in entries { item.setData(d, forType: t) }
                    return item
                }
                if !items.isEmpty { pb.writeObjects(items) }
            }
            self.saved = nil
        }
        return true
    }

    func replaceLast(_ old: String, with new: String) async -> Bool {
        guard Self.trusted else { return false }
        if !AX.selectInFocusedField(old) {
            // Fall back to the app's own undo, which removes the paste as one step in most apps.
            Self.post(key: CGKeyCode(kVK_ANSI_Z), flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(150))
        }
        return await insert(new)
    }

    static func post(key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Accessibility: frontmost app, window, URL, text on screen, focused field

enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.4)
        return element(sys, kAXFocusedUIElementAttribute)
    }

    static func focusedFieldText() -> String? {
        guard AXIsProcessTrusted(), let el = focusedElement() else { return nil }
        return string(el, kAXValueAttribute)
    }

    static func selectInFocusedField(_ text: String) -> Bool {
        guard let el = focusedElement(), let value = string(el, kAXValueAttribute) else { return false }
        let r = (value as NSString).range(of: text, options: .backwards)
        guard r.location != NSNotFound else { return false }
        var range = CFRange(location: r.location, length: r.length)
        guard let v = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Breadth-first walk with hard limits so a huge or slow tree cannot stall dictation.
    static func walk(_ root: AXUIElement, maxNodes: Int, deadline: Date, visit: (AXUIElement) -> Bool) {
        var queue = [root]; var seen = 0; var i = 0
        while i < queue.count, seen < maxNodes, Date() < deadline {
            let el = queue[i]; i += 1; seen += 1
            if !visit(el) { return }
            queue.append(contentsOf: children(el))
        }
    }
}

final class AXContextReader: ContextReader, @unchecked Sendable {
    static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
                                        "com.microsoft.edgemac", "org.mozilla.firefox", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
                                        "company.thebrowser.dia", "com.openai.atlas"]

    /// Browsers plus "Add to Dock" web apps (Safari `.WebApp.<uuid>`, Chrome `.app.<id>`), which expose the page URL the same way.
    static func readsURL(_ id: String) -> Bool {
        browsers.contains(id) || browsers.contains { id.hasPrefix($0 + ".WebApp.") || id.hasPrefix($0 + ".app.") }
    }

    private func frontWindow() -> (NSRunningApplication, AXUIElement, AXUIElement?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.4)
        return (app, el, AX.element(el, kAXFocusedWindowAttribute))
    }

    func currentContext() async -> AppContext {
        await Task.detached { [self] in
            guard let (app, _, window) = frontWindow() else { return AppContext() }
            var ctx = AppContext(bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "")
            guard AXIsProcessTrusted(), let window else { return ctx }
            ctx.windowTitle = AX.string(window, kAXTitleAttribute) ?? ""
            if Self.readsURL(ctx.bundleID) {
                if let doc = AX.string(window, kAXDocumentAttribute), doc.hasPrefix("http") { ctx.url = doc }
                else {
                    AX.walk(window, maxNodes: 600, deadline: Date().addingTimeInterval(0.25)) { el in
                        guard AX.string(el, kAXRoleAttribute) == "AXWebArea", let u = AX.attr(el, kAXURLAttribute) as? URL else { return true }
                        ctx.url = u.absoluteString; return false
                    }
                }
            }
            return ctx
        }.value
    }

    func visibleText(maxChars: Int) async -> String? {
        await Task.detached { [self] in
            guard AXIsProcessTrusted(), let (_, appEl, window) = frontWindow() else { return nil }
            // Electron apps (Cursor, VS Code, Slack) only build their accessibility tree when asked.
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            guard let window else { return nil }
            var parts: [String] = []; var total = 0; var seen = Set<String>()
            AX.walk(window, maxNodes: 2500, deadline: Date().addingTimeInterval(0.35)) { el in
                for name in [kAXValueAttribute, kAXTitleAttribute] {
                    if let s = AX.string(el, name)?.trimmed, s.count > 1, !seen.contains(s) {
                        seen.insert(s); parts.append(String(s.prefix(1500))); total += min(s.count, 1500)
                    }
                }
                return total < maxChars
            }
            return parts.isEmpty ? nil : String(parts.joined(separator: "\n").prefix(maxChars))
        }.value
    }

    func focusedFieldText() async -> String? { await Task.detached { AX.focusedFieldText() }.value }
}
