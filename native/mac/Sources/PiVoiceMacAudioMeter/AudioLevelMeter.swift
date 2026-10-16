import AVFoundation
import Dispatch
import Foundation
import PiVoiceMacCore
@preconcurrency import LiveKitWebRTC

/// A read-only renderer sink for an existing WebRTC audio track.
/// It retains no PCM and publishes at most 12 scalar RMS samples per second.
public final class AudioLevelMeter: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
    public typealias Observation = @Sendable (
        _ level: Double,
        _ revision: Int,
        _ publication: AudioLevelPublicationToken
    ) -> Void

    private let lock = NSLock()
    private let observation: Observation
    private let revision: Int
    private var publicationGate = AudioLevelPublicationGate()
    private var lastEmissionNanoseconds: UInt64 = 0
    private let minimumEmissionIntervalNanoseconds: UInt64 = 83_333_333
    private let staleIntervalNanoseconds: UInt64 = 350_000_000

    public init(revision: Int, observation: @escaping Observation) {
        self.revision = revision
        self.observation = observation
    }

    public func setEnabled(_ enabled: Bool) {
        lock.lock()
        publicationGate.setEnabled(enabled)
        if !enabled { lastEmissionNanoseconds = 0 }
        lock.unlock()
    }

    public func permitsObservation(_ publication: AudioLevelPublicationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return publicationGate.permits(publication)
    }

    public func render(pcmBuffer: AVAudioPCMBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let mayEmit = publicationGate.enabled &&
            now &- lastEmissionNanoseconds >= minimumEmissionIntervalNanoseconds
        lock.unlock()
        guard mayEmit, let level = Self.normalizedRMS(pcmBuffer) else { return }

        lock.lock()
        guard publicationGate.enabled,
              now &- lastEmissionNanoseconds >= minimumEmissionIntervalNanoseconds,
              let publication = publicationGate.recordEmission()
        else {
            lock.unlock()
            return
        }
        lastEmissionNanoseconds = now
        let capturedRevision = revision
        lock.unlock()

        observation(level, capturedRevision, publication)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .nanoseconds(Int(staleIntervalNanoseconds))
        ) { [weak self] in
            guard let self else { return }
            lock.lock()
            let expiredPublication: AudioLevelPublicationToken?
            if DispatchTime.now().uptimeNanoseconds &- lastEmissionNanoseconds >= staleIntervalNanoseconds {
                expiredPublication = publicationGate.expire(publication)
            } else {
                expiredPublication = nil
            }
            lock.unlock()
            if let expiredPublication { observation(0, capturedRevision, expiredPublication) }
        }
    }

    private static func normalizedRMS(_ buffer: AVAudioPCMBuffer) -> Double? {
        let format = buffer.format
        let channelCount = Int(format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let sampleCount = channelCount * frameCount
        guard (1...2).contains(channelCount),
              sampleCount > 0,
              sampleCount <= 192_000
        else { return nil }

        var squareSum = 0.0
        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return nil }
            if format.isInterleaved {
                for index in 0..<sampleCount {
                    let sample = Double(channels[0][index])
                    squareSum += sample * sample
                }
            } else {
                for channel in 0..<channelCount {
                    for frame in 0..<frameCount {
                        let sample = Double(channels[channel][frame])
                        squareSum += sample * sample
                    }
                }
            }
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { return nil }
            if format.isInterleaved {
                for index in 0..<sampleCount {
                    let sample = Double(channels[0][index]) / 32_768.0
                    squareSum += sample * sample
                }
            } else {
                for channel in 0..<channelCount {
                    for frame in 0..<frameCount {
                        let sample = Double(channels[channel][frame]) / 32_768.0
                        squareSum += sample * sample
                    }
                }
            }
        default:
            return nil
        }

        let result = sqrt(squareSum / Double(sampleCount))
        return result.isFinite ? min(1, max(0, result)) : nil
    }
}
