import Foundation

public struct VisualEnvelopeRenderSelection: Equatable, Sendable {
    public let outgoing: Double
    public let playback: Double

    public init(outgoing: Double, playback: Double) {
        self.outgoing = outgoing
        self.playback = playback
    }

    public static let zero = VisualEnvelopeRenderSelection(outgoing: 0, playback: 0)

    /// Final render boundary. No interpolated value crosses visibility,
    /// generation, or per-channel authorization loss.
    public static func select(
        isRunning: Bool,
        levelGeneration: String?,
        envelopeGeneration: String?,
        outgoingAuthorized: Bool,
        playbackAuthorized: Bool,
        outgoingSample: Double,
        playbackSample: Double
    ) -> VisualEnvelopeRenderSelection {
        guard isRunning,
              let levelGeneration,
              levelGeneration == envelopeGeneration else {
            return .zero
        }
        return VisualEnvelopeRenderSelection(
            outgoing: outgoingAuthorized ? outgoingSample : 0,
            playback: playbackAuthorized ? playbackSample : 0
        )
    }
}

/// A deterministic, monotonic-clock, frame-sampled presentation envelope.
/// Retargeting begins at the value visible at `time`; authority loss uses
/// `reset(at:)` and bypasses interpolation.
public struct VisualEnvelopeChannel: Equatable, Sendable {
    private var startValue: Double = 0
    private var targetValue: Double = 0
    private var startTime: TimeInterval = 0
    private var duration: TimeInterval = 0

    public init() {}

    public func value(at time: TimeInterval) -> Double {
        guard duration > 0 else { return targetValue }
        let progress = min(max((time - startTime) / duration, 0), 1)
        let eased: Double
        if targetValue >= startValue {
            eased = 1 - pow(1 - progress, 3)
        } else {
            eased = progress * progress * (3 - 2 * progress)
        }
        return startValue + (targetValue - startValue) * eased
    }

    public mutating func retarget(
        to rawTarget: Double,
        at time: TimeInterval,
        attackDuration: TimeInterval,
        releaseDuration: TimeInterval
    ) {
        let currentValue = value(at: time)
        let target = rawTarget.isFinite ? min(max(rawTarget, 0), 1) : 0
        startValue = currentValue
        targetValue = target
        startTime = time
        duration = target > currentValue ? attackDuration : releaseDuration
    }

    public mutating func reset(at time: TimeInterval) {
        startValue = 0
        targetValue = 0
        startTime = time
        duration = 0
    }
}
