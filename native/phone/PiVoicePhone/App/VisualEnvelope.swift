import Foundation

struct VisualEnvelopeRenderSelection: Equatable {
    let outgoing: Double
    let playback: Double

    static let zero = VisualEnvelopeRenderSelection(outgoing: 0, playback: 0)

    static func select(
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

/// A deterministic, frame-sampled presentation envelope.
///
/// Retargeting begins at the value currently visible at `time`, so fresh meter
/// samples never jump the rendered geometry. Authority loss uses `reset()` and
/// bypasses interpolation.
struct VisualEnvelopeChannel: Equatable {
    private var startValue: Double = 0
    private var targetValue: Double = 0
    private var startTime: TimeInterval = 0
    private var duration: TimeInterval = 0

    func value(at time: TimeInterval) -> Double {
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

    mutating func retarget(
        to rawTarget: Double,
        at time: TimeInterval,
        attackDuration: TimeInterval,
        releaseDuration: TimeInterval
    ) {
        let currentValue = value(at: time)
        let target = min(max(rawTarget, 0), 1)
        startValue = currentValue
        targetValue = target
        startTime = time
        duration = target > currentValue ? attackDuration : releaseDuration
    }

    mutating func reset(at time: TimeInterval) {
        startValue = 0
        targetValue = 0
        startTime = time
        duration = 0
    }
}
