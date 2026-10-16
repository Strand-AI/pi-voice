import Foundation
import PiVoiceMacCore

/// Offline executable transport. It opens no network, microphone, WebRTC peer, or paid session.
@MainActor
final class SimulatorVoiceTransport: VoiceTransport {
    let events: AsyncStream<VoiceGatewayEvent>
    private let continuation: AsyncStream<VoiceGatewayEvent>.Continuation
    private(set) var microphoneEnabled = false
    private(set) var playbackEnabled = false
    private(set) var playbackGain = 1.0

    init() {
        let pair = AsyncStream<VoiceGatewayEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        events = pair.stream
        continuation = pair.continuation
    }

    func pair(origin: URL, token: String, deviceName: String) async throws {}
    func renew(origin: URL) async throws {}
    func hasSavedDevice(origin: URL) throws -> Bool { true }
    func forgetSavedDevice(origin: URL) throws {}
    func providerClosureReceipt(origin: URL, generation: String, mayMutateCredential: @escaping @MainActor () -> Bool) async throws -> ProviderClosureReceiptResult {
        _ = mayMutateCredential
        return ProcessInfo.processInfo.arguments.contains("--fake-provider-closed-receipt") ? .providerClosed : .unconfirmed
    }

    func connectEvents(origin: URL) async throws {
        continuation.yield(.roster(connected: true, agents: [
            AgentTarget(
                id: "simulated-pi-session",
                endpointEpoch: "simulated-endpoint-epoch",
                name: "Simulator Pi",
                cwd: "/private/fake",
                model: "fake",
                status: "available",
                location: "offline"
            ),
        ]))
    }

    func disconnectEvents() {}

    func start(target: AgentTarget, mode: VoiceMode, voice: VoiceName, routing: ConversationRouting, idleTimeoutMinutes: Int) async throws -> SessionAuthority {
        SessionAuthority(
            generation: "simulated-generation",
            idleDeadline: .now.addingTimeInterval(300),
            hardDeadline: .now.addingTimeInterval(7_200),
            peerAuthority: .init(revision: 1, peerIdentifier: "simulated-peer"),
            initialPeerState: .connected
        )
    }

    func announceMediaReady(generation: String) async throws {}

    func sendPushToTalk(generation: String, held: Bool, cancel: Bool, commandSequence: Int) async throws {
        if !held {
            continuation.yield(.utterance(
                generation: generation,
                text: cancel ? "Cancelled offline hold" : "Simulated held utterance"
            ))
            try? await Task.sleep(for: .milliseconds(100))
            continuation.yield(.pttReady(generation: generation))
            if !cancel {
                continuation.yield(.caption(
                    generation: generation,
                    speaker: "assistant",
                    delta: "Fake liaison reply — no audio, network, or model was used.",
                    groupID: "assistant-offline-1"
                ))
            }
        }
    }

    func close(generation: String) async throws {
        continuation.yield(.voiceState(generation: generation, state: "closed", reason: "Offline session stopped"))
    }

    func setMicrophoneEnabled(_ enabled: Bool) { microphoneEnabled = enabled }
    func setPlaybackEnabled(_ enabled: Bool) { playbackEnabled = enabled }
    func setPlaybackGain(_ gain: Double) { playbackGain = gain }
    func teardownMedia() { microphoneEnabled = false; playbackEnabled = false }
}
