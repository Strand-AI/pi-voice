import CoreAudio
import Foundation

struct AudioRouteSnapshot: Equatable {
    struct Device: Equatable {
        let name: String
        let sampleRate: Double
        let isBluetooth: Bool
    }

    let input: Device?
    let output: Device?

    var summary: String {
        let inputText = input.map { "\($0.name) · \(Int($0.sampleRate.rounded())) Hz" } ?? "Input unavailable"
        let outputText = output.map { "\($0.name) · \(Int($0.sampleRate.rounded())) Hz" } ?? "Output unavailable"
        return "Input: \(inputText)\nOutput: \(outputText)"
    }

    var isLowRateBluetoothDuplex: Bool {
        input?.isBluetooth == true && output?.isBluetooth == true &&
            (output?.sampleRate ?? 48_000) < 44_100
    }
}

enum AudioRouteInspector {
    static func current() -> AudioRouteSnapshot {
        AudioRouteSnapshot(
            input: defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice),
            output: defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        )
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioRouteSnapshot.Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr,
              size == UInt32(MemoryLayout<AudioDeviceID>.size), deviceID != 0 else { return nil }

        guard let name = stringProperty(kAudioObjectPropertyName, deviceID: deviceID),
              let sampleRate = scalarProperty(kAudioDevicePropertyNominalSampleRate, deviceID: deviceID),
              let transport = uint32Property(kAudioDevicePropertyTransportType, deviceID: deviceID) else {
            return nil
        }
        return AudioRouteSnapshot.Device(
            name: name,
            sampleRate: sampleRate,
            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
        )
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              size == UInt32(MemoryLayout<Unmanaged<CFString>?>.size), let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func scalarProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              size == UInt32(MemoryLayout<Float64>.size), value.isFinite,
              (1...384_000).contains(value) else { return nil }
        return value
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              size == UInt32(MemoryLayout<UInt32>.size) else { return nil }
        return value
    }
}
