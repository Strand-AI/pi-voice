import Foundation

@main
struct VisualEnvelopeChecks {
    static func main() {
        var checks = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else {
                fputs("VisualEnvelopeChecks failed: \(message)\n", stderr)
                exit(1)
            }
        }

        func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.000_001) -> Bool {
            abs(lhs - rhs) <= tolerance
        }

        var channel = VisualEnvelopeChannel()
        channel.retarget(to: 1, at: 10, attackDuration: 0.14, releaseDuration: 0.28)
        expect(approximatelyEqual(channel.value(at: 10), 0), "attack must begin at the visible value")
        let attackMidpoint = channel.value(at: 10.07)
        expect(attackMidpoint > 0 && attackMidpoint < 1, "attack must expose an intermediate frame value")
        expect(approximatelyEqual(channel.value(at: 10.14), 1), "attack must reach its target")

        var prior = channel.value(at: 10)
        for step in 1 ... 14 {
            let sample = channel.value(at: 10 + Double(step) * 0.01)
            expect(sample >= prior, "attack must be monotonic")
            prior = sample
        }

        let visibleAtRetarget = channel.value(at: 10.07)
        channel.retarget(to: 0.2, at: 10.07, attackDuration: 0.14, releaseDuration: 0.28)
        expect(
            approximatelyEqual(channel.value(at: 10.07), visibleAtRetarget),
            "retargeting must preserve the currently visible value"
        )
        let releaseMidpoint = channel.value(at: 10.21)
        expect(releaseMidpoint < visibleAtRetarget && releaseMidpoint > 0.2, "release must expose an intermediate frame value")
        expect(approximatelyEqual(channel.value(at: 10.35), 0.2), "release must reach its target")

        channel.reset(at: 10.22)
        expect(approximatelyEqual(channel.value(at: 10.22), 0), "authority reset must clear immediately")
        expect(approximatelyEqual(channel.value(at: 99), 0), "authority reset must not retain a stale tail")

        let visible = VisualEnvelopeRenderSelection.select(
            isRunning: true,
            levelGeneration: "generation-a",
            envelopeGeneration: "generation-a",
            outgoingAuthorized: true,
            playbackAuthorized: true,
            outgoingSample: 0.7,
            playbackSample: 0.6
        )
        expect(visible == VisualEnvelopeRenderSelection(outgoing: 0.7, playback: 0.6), "matching live authority may render")

        let inactive = VisualEnvelopeRenderSelection.select(
            isRunning: false,
            levelGeneration: "generation-a",
            envelopeGeneration: "generation-a",
            outgoingAuthorized: true,
            playbackAuthorized: true,
            outgoingSample: 0.7,
            playbackSample: 0.6
        )
        expect(inactive == .zero, "inactive presentation must synchronously hide saved envelope values")

        let replaced = VisualEnvelopeRenderSelection.select(
            isRunning: true,
            levelGeneration: "generation-b",
            envelopeGeneration: "generation-a",
            outgoingAuthorized: true,
            playbackAuthorized: true,
            outgoingSample: 0.7,
            playbackSample: 0.6
        )
        expect(replaced == .zero, "generation replacement must synchronously hide the old envelope")

        let gated = VisualEnvelopeRenderSelection.select(
            isRunning: true,
            levelGeneration: "generation-a",
            envelopeGeneration: "generation-a",
            outgoingAuthorized: false,
            playbackAuthorized: true,
            outgoingSample: 0.7,
            playbackSample: 0.6
        )
        expect(gated == VisualEnvelopeRenderSelection(outgoing: 0, playback: 0.6), "channel authority must gate the rendered sample")

        print("VisualEnvelopeChecks: \(checks) passed")
    }
}
