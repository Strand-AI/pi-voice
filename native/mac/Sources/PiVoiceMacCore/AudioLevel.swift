import Foundation

public struct AudioLevelPublicationToken: Equatable, Sendable {
    public let gateEpoch: UInt64
    public let emissionSequence: UInt64

    public init(gateEpoch: UInt64, emissionSequence: UInt64) {
        self.gateEpoch = gateEpoch
        self.emissionSequence = emissionSequence
    }
}

public struct AudioLevelPublicationGate: Equatable, Sendable {
    public private(set) var enabled = false
    private var gateEpoch: UInt64 = 0
    private var emissionSequence: UInt64 = 0

    public init() {}

    public mutating func setEnabled(_ enabled: Bool) {
        if self.enabled != enabled {
            gateEpoch &+= 1
            emissionSequence &+= 1
        }
        self.enabled = enabled
    }

    public mutating func recordEmission() -> AudioLevelPublicationToken? {
        guard enabled else { return nil }
        emissionSequence &+= 1
        return AudioLevelPublicationToken(
            gateEpoch: gateEpoch,
            emissionSequence: emissionSequence
        )
    }

    public func permits(_ token: AudioLevelPublicationToken) -> Bool {
        enabled && token.gateEpoch == gateEpoch && token.emissionSequence == emissionSequence
    }

    public mutating func expire(_ token: AudioLevelPublicationToken) -> AudioLevelPublicationToken? {
        guard permits(token) else { return nil }
        return recordEmission()
    }
}

/// Normalized RMS for signed 16-bit PCM. The caller owns the sample storage;
/// this function neither copies nor retains it.
public func normalizedInt16RMS(_ samples: UnsafeBufferPointer<Int16>) -> Double {
    guard !samples.isEmpty else { return 0 }
    var squareSum = 0.0
    for value in samples {
        let normalized = Double(value) / 32_768.0
        squareSum += normalized * normalized
    }
    let result = sqrt(squareSum / Double(samples.count))
    return result.isFinite ? min(1, max(0, result)) : 0
}
