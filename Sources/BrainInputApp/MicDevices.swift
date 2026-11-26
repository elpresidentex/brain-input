import AudioToolbox
import CoreAudio
import Foundation

/// The microphones the Mac currently offers, and which one Brain Input records from.
/// `nil` selection means "follow the system default input".
struct MicDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

@MainActor
final class MicDevices: ObservableObject {
    static let shared = MicDevices()
    nonisolated static let prefKey = "micDeviceUID"

    @Published private(set) var devices: [MicDevice] = []
    @Published private(set) var defaultUID: String?
    @Published var selectedUID: String? = UserDefaults.standard.string(forKey: MicDevices.prefKey)

    private var listening = false

    init() { refresh(); listen() }

    /// The device recording will use right now, or nil when the system default applies.
    nonisolated static var selectedDeviceID: AudioDeviceID? {
        guard let uid = UserDefaults.standard.string(forKey: prefKey) else { return nil }
        return input(forUID: uid)?.id
    }

    /// What the menu shows: the chosen device if it is plugged in, else the system default.
    var activeName: String {
        if let uid = selectedUID, let d = devices.first(where: { $0.uid == uid }) { return d.name }
        if let d = devices.first(where: { $0.uid == defaultUID }) { return d.name }
        return "System Default"
    }

    var selectedIsMissing: Bool { selectedUID != nil && !devices.contains { $0.uid == selectedUID } }

    func select(_ uid: String?) {
        selectedUID = uid
        if let uid { UserDefaults.standard.set(uid, forKey: Self.prefKey) } else { UserDefaults.standard.removeObject(forKey: Self.prefKey) }
        AppState.shared.micDeviceChanged()
    }

    func refresh() {
        devices = Self.allInputs()
        defaultUID = Self.defaultInputID().flatMap { id in devices.first { $0.id == id }?.uid }
    }

    // MARK: CoreAudio

    private func listen() {
        guard !listening else { return }
        listening = true
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
                Task { @MainActor in self?.refresh(); AppState.shared.micDeviceChanged(onlyIfSelectedGone: true) }
            }
        }
    }

    nonisolated static func input(forUID uid: String) -> MicDevice? { allInputs().first { $0.uid == uid } }

    nonisolated static func defaultInputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    nonisolated static func allInputs() -> [MicDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            // Skip the aggregate devices apps like Zoom create behind the scenes.
            if uid.hasPrefix("CADefaultDeviceAggregate") { return nil }
            return MicDevice(id: id, uid: uid, name: name)
        }
    }

    private nonisolated static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private nonisolated static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }
}
