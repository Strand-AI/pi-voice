import Foundation
import PiVoiceCore

/// Offline simulator/demo transport. It never opens a microphone, network socket, or paid session.
@MainActor
final class SimulatorVoiceTransport: VoiceTransport {
    var mediaLevelsDidChange: ((VoiceMediaLevelSample) -> Void)?
    let events: AsyncStream<GatewayEvent>
    private let continuation: AsyncStream<GatewayEvent>.Continuation
    private var microphone = false
    private var mediaObservationEnabled = true

    init() {
        let pair = AsyncStream<GatewayEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        events = pair.stream
        continuation = pair.continuation
    }

    func authenticate(origin: URL, pairingToken: String?, deviceName: String) async throws {}
    func forgetDevice(origin: URL) throws {}
    func connectEvents(origin: URL) async throws {
        continuation.yield(.roster(connected: true, agents: [
            AgentEndpoint(id: "simulated-pi", endpointEpoch: "simulator-epoch", name: "Simulator Pi", model: "fake", status: "available")
        ]))
    }
    func disconnectEvents() {}
    func providerClosureReceipt(origin: URL, generation: String) async throws -> ProviderClosureReceiptResult {
        ProcessInfo.processInfo.arguments.contains("--fake-provider-closed-receipt") ? .providerClosed : .unconfirmed
    }
    func start(target: AgentEndpoint, mode: VoiceMode, voice: VoiceName, routing: ConversationRouting) async throws -> SessionAuthority {
        if ProcessInfo.processInfo.arguments.contains("--fake-control-loss") {
            Task { @MainActor [continuation] in
                try? await Task.sleep(for: .milliseconds(300))
                continuation.yield(.peerConnectionState(
                    authority: PeerConnectionAuthority(revision: 1, peerIdentifier: "simulated-peer"),
                    state: .disconnected
                ))
                continuation.yield(.sessionEnded(code: "websocket_closed", message: "simulated interface loss"))
            }
        } else if ProcessInfo.processInfo.arguments.contains("--fake-ice-disconnect") {
            Task { @MainActor [continuation] in
                try? await Task.sleep(for: .milliseconds(300))
                continuation.yield(.peerConnectionState(
                    authority: PeerConnectionAuthority(revision: 1, peerIdentifier: "simulated-peer"),
                    state: .disconnected
                ))
                if ProcessInfo.processInfo.arguments.contains("--fake-ice-recover") {
                    try? await Task.sleep(for: .milliseconds(4_000))
                    continuation.yield(.peerConnectionState(
                        authority: PeerConnectionAuthority(revision: 1, peerIdentifier: "simulated-peer"),
                        state: .connected
                    ))
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--fake-long-caption") {
            Task { @MainActor [continuation] in
                try? await Task.sleep(for: .milliseconds(100))
                continuation.yield(.caption(
                    generation: "simulated-generation",
                    speaker: "assistant",
                    delta: String(repeating: "x", count: 600) + "🙂",
                    groupID: "assistant-fake-long"
                ))
            }
        }
        let authority = PeerConnectionAuthority(revision: 1, peerIdentifier: "simulated-peer")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.mediaObservationEnabled else { return }
            self.mediaLevelsDidChange?(VoiceMediaLevelSample(
                generation: "simulated-generation",
                peerAuthority: authority,
                observedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                outgoingLevel: 0.58,
                playbackLevel: 0.42,
                speakerActive: true
            ))
        }
        return SessionAuthority(
            generation: "simulated-generation",
            idleDeadline: .now.addingTimeInterval(300),
            hardDeadline: .now.addingTimeInterval(7_200),
            peerAuthority: authority
        )
    }
    func announceMediaReady(generation: String) async throws {}
    func sendPushToTalk(generation: String, held: Bool, cancel: Bool, commandSequence: Int) async throws {
        if !held {
            continuation.yield(.utterance(generation: generation, text: cancel ? "Cancelled simulator hold" : "Simulated held utterance"))
            try? await Task.sleep(for: .milliseconds(250))
            continuation.yield(.pttReady(generation: generation))
            continuation.yield(.replyWindow(generation: generation, durationMilliseconds: 900))
            continuation.yield(.caption(
                generation: generation,
                speaker: "assistant",
                delta: "Fake provider reply — no audio or network was used.",
                groupID: "assistant-fake-reply"
            ))
        }
    }
    func close(generation: String) async throws { continuation.yield(.voiceState(generation: generation, state: "closed", reason: "Simulator stopped")) }
    func setMicrophoneEnabled(_ enabled: Bool) { microphone = enabled }
    func setPlaybackEnabled(_ enabled: Bool) {}
    func setMediaObservationEnabled(_ enabled: Bool) { mediaObservationEnabled = enabled }
    func teardownMedia() { microphone = false }
}
