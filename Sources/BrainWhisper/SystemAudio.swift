import AVFoundation
import CoreAudio
import Foundation

enum CA {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = address(selector); var size = UInt32(MemoryLayout<T>.size); var v = initial
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector); var size = UInt32(MemoryLayout<CFString?>.size); var v: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
    }
}

/// Which apps are capturing microphone input right now (Core Audio process objects; needs no permission).
public enum MicUsage {
    public static func current() -> [String] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = CA.address(kAudioHardwarePropertyProcessObjectList); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard CA.value(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1 else { return nil }
            return CA.string(id, kAudioProcessPropertyBundleID)
        }
    }
}

public struct TapError: Error, CustomStringConvertible { public let description: String }

/// Captures everything the Mac plays (the other side of a call) with a Core Audio process tap:
/// no virtual audio driver, no bot in the call. macOS asks for "System Audio Recording" on first use.
public final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "braininput.tap")
    private let resampler = StreamResampler()
    public init() {}

    public func start(onSamples: @escaping ([Float]) -> Void) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "Brain Input meeting tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { throw TapError(description: "could not create the system audio tap (\(err)); check System Settings › Privacy & Security › Screen & System Audio Recording") }
        tapID = tap
        guard var format = CA.value(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()) else { stop(); throw TapError(description: "tap has no format") }
        let output = CA.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0)) ?? 0
        guard let outputUID = CA.string(output, kAudioDevicePropertyDeviceUID) else { stop(); throw TapError(description: "no output device") }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Brain Input Tap", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID, kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
        guard err == noErr else { stop(); throw TapError(description: "could not create the aggregate device (\(err))") }
        guard let avFormat = AVAudioFormat(streamDescription: &format) else { stop(); throw TapError(description: "unsupported tap format") }
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [resampler] _, input, _, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil) else { return }
            let s = resampler.convert(buf)
            if !s.isEmpty { onSamples(s) }
        }
        guard err == noErr else { stop(); throw TapError(description: "could not attach to the tap (\(err))") }
        err = AudioDeviceStart(deviceID, procID)
        guard err == noErr else { stop(); throw TapError(description: "could not start the tap (\(err))") }
    }

    public func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID { AudioDeviceStop(deviceID, procID); AudioDeviceDestroyIOProcID(deviceID, procID) }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; deviceID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
