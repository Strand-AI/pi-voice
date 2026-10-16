import AVFoundation
import Foundation
import PiVoiceMacAudioMeter

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@main
private struct MeterChecks {
    static func main() throws {
        try standardFloat32MonoPublishes()
        try standardFloat32StereoUsesEveryChannel()
        try interleavedInt16Publishes()
        try unsupportedBufferDoesNotConsumeThrottle()
        print("PiVoiceMacMeterChecks: 4 scenarios passed")
    }

    private static func standardFloat32MonoPublishes() throws {
        let buffer = try standardFloatBuffer(channels: 1, values: [0.5])
        let values = renderOnce(buffer, revision: 1)
        try check(values.count == 1 && abs(values[0] - 0.5) < 0.0001,
                  "standard Float32 mono did not publish its RMS")
    }

    private static func standardFloat32StereoUsesEveryChannel() throws {
        let buffer = try standardFloatBuffer(channels: 2, values: [0.25, 0.75])
        let expected = sqrt((0.25 * 0.25 + 0.75 * 0.75) / 2)
        let values = renderOnce(buffer, revision: 2)
        try check(values.count == 1 && abs(values[0] - expected) < 0.0001,
                  "standard Float32 stereo did not include every planar channel")
    }

    private static func interleavedInt16Publishes() throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480),
        let samples = buffer.int16ChannelData?[0]
        else { throw CheckFailure(description: "could not make Int16 control buffer") }
        buffer.frameLength = 480
        for frame in 0..<480 { samples[frame] = 16_384 }
        let values = renderOnce(buffer, revision: 3)
        try check(values.count == 1 && abs(values[0] - 0.5) < 0.0001,
                  "interleaved Int16 control did not publish its RMS")
    }

    private static func unsupportedBufferDoesNotConsumeThrottle() throws {
        guard let unsupportedFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let unsupported = AVAudioPCMBuffer(
            pcmFormat: unsupportedFormat,
            frameCapacity: 480
        ) else { throw CheckFailure(description: "could not make unsupported buffer") }
        unsupported.frameLength = 480

        let collector = Collector()
        let meter = AudioLevelMeter(revision: 4) { level, _, _ in collector.append(level) }
        meter.setEnabled(true)
        meter.render(pcmBuffer: unsupported)
        meter.render(pcmBuffer: try standardFloatBuffer(channels: 1, values: [0.5]))
        try check(collector.snapshot.count == 1 && abs(collector.snapshot[0] - 0.5) < 0.0001,
                  "unsupported buffer consumed the next valid publication")
    }

    private static func standardFloatBuffer(
        channels: AVAudioChannelCount,
        values: [Float]
    ) throws -> AVAudioPCMBuffer {
        guard values.count == Int(channels),
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: 48_000,
                  channels: channels
              ), format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480),
              let channelData = buffer.floatChannelData
        else { throw CheckFailure(description: "could not make standard Float32 buffer") }
        buffer.frameLength = 480
        for channel in 0..<Int(channels) {
            for frame in 0..<480 { channelData[channel][frame] = values[channel] }
        }
        return buffer
    }

    private static func renderOnce(
        _ buffer: AVAudioPCMBuffer,
        revision: Int
    ) -> [Double] {
        let collector = Collector()
        let meter = AudioLevelMeter(revision: revision) { level, _, _ in collector.append(level) }
        meter.setEnabled(true)
        meter.render(pcmBuffer: buffer)
        return collector.snapshot
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(description: message) }
    }
}
