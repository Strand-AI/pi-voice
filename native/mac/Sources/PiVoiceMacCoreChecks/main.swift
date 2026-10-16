import Darwin
import Foundation
import PiVoiceMacCore
import PiVoiceMacSecurity
import Security

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): message } }
}

@MainActor
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure.failed(message) }
    return value
}

private final class CompletionReceiptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLSessionTaskCompletionReceipt] = []

    func append(_ receipt: URLSessionTaskCompletionReceipt) {
        lock.lock()
        stored.append(receipt)
        lock.unlock()
    }

    var receipts: [URLSessionTaskCompletionReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@main
struct CoreChecks {
    @MainActor
    static func main() async throws {
        try wireAndRoutingChecks()
        try voicePreferenceRestartPolicy()
        try lastAgentSelectionContract()
        try boundedCaptionContract()
        try boundedCaptionThreadContract()
        try visualEnvelopeContract()
        try providerClosureRecoveryContract()
        try peerConnectionRecoveryContract()
        try await exactLiaisonStart()
        try await oneShotGreetingReadiness()
        try await exactClosureRecoveryWiring()
        try await manualClosureCheckAfterSleepAndWake()
        try await peerConnectionRecoveryWiring()
        try await savedDeviceReconnectAndLocalForget()
        try await revocationFailsClosed()
        try await continuousMuteAndFocusLifecycle()
        try await captionThreadWiringContract()
        try await pttMuteAuthority()
        try await focusLossCancelsPTTOnly()
        try await hardwareReleaseBeforeAcknowledgement()
        try await playbackResumesBeforeReleaseAcknowledgement()
        try providerClosureReceipts()
        try freshPeerStartupReadiness()
        try await gatewayURLSessionFailureBounds()
        try await automaticAuthorizationRetries()
        try await idleTimeoutAndEndConfirmation()
        try await postEndClosureRecoveryRaces()
        try await pushToTalkGateAndGenerationFence()
        try await fastReleaseNeverReopensCapture()
        try await stopFencesPendingStart()
        try await startupAuthorityRetention()
        try await uncertainReleaseStillStops()
        try await staleRosterStopsPinnedGeneration()
        print("PiVoiceMacCoreChecks: 246 scenarios passed")
    }

    @MainActor
    private static func lastAgentSelectionContract() throws {
        let suite = "PiVoiceMacCoreChecks.LastAgent.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite), "temporary hint store was unavailable")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LastAgentSelectionHintStore(defaults: defaults, key: "hint")
        try store.save(origin: "https://voice.example.test", agentID: "stable-agent")
        try check(store.load(forOrigin: "https://voice.example.test")?.agentID == "stable-agent", "stable ID was not saved for its exact origin")
        try check(store.load(forOrigin: "https://other.example.test") == nil, "stable ID crossed origins")

        let fresh = AgentTarget(id: "stable-agent", endpointEpoch: "fresh-epoch", name: "Agent", cwd: "/tmp")
        var restoration = LastAgentSelectionRestoration()
        restoration.begin(after: 10)
        try check(restoration.candidate(hint: store.load(forOrigin: "https://voice.example.test"), origin: "https://voice.example.test", phase: .ready, rosterConnected: true, rosterRevision: 10, agents: [fresh], selected: nil) == nil, "same roster revision restored stale authority")
        try check(restoration.candidate(hint: store.load(forOrigin: "https://voice.example.test"), origin: "https://voice.example.test", phase: .disconnected, rosterConnected: true, rosterRevision: 11, agents: [fresh], selected: nil) == nil, "disconnected state restored a hint")
        try check(restoration.candidate(hint: store.load(forOrigin: "https://voice.example.test"), origin: "https://voice.example.test", phase: .ready, rosterConnected: true, rosterRevision: 12, agents: [fresh], selected: nil)?.endpointEpoch == "fresh-epoch", "fresh roster did not supply fresh endpoint authority")

        restoration.begin(after: 12)
        let sameName = AgentTarget(id: "replacement", endpointEpoch: "other", name: "Agent", cwd: "/tmp")
        try check(restoration.candidate(hint: store.load(forOrigin: "https://voice.example.test"), origin: "https://voice.example.test", phase: .ready, rosterConnected: true, rosterRevision: 13, agents: [sameName], selected: nil) == nil, "same-name replacement inherited stable-ID authority")
        restoration.begin(after: 13); restoration.cancel()
        try check(restoration.candidate(hint: store.load(forOrigin: "https://voice.example.test"), origin: "https://voice.example.test", phase: .ready, rosterConnected: true, rosterRevision: 14, agents: [fresh], selected: nil) == nil, "manual cancellation did not cancel restoration")
        store.clear(forOrigin: "https://voice.example.test")
        try check(store.load(forOrigin: "https://voice.example.test") == nil, "exact-origin hint was not cleared")
    }

    @MainActor
    private static func boundedCaptionContract() throws {
        var caption = BoundedCaption(characterLimit: 5, utf8ByteLimit: 32)
        caption.append("ab"); caption.append("cdef")
        try check(caption.text == "bcdef", "caption exceeded its recent-character window")
        caption.append("👨‍👩‍👧‍👦🙂🙃😉😊😇")
        try check(caption.text == "🙂🙃😉😊😇" && caption.text.count == 5, "caption split a grapheme cluster")
        try check(caption.text.utf8.count <= 32, "caption exceeded its byte bound")
        caption.replace(with: "0123456789")
        try check(caption.text == "56789", "caption replacement was not bounded")
        var giant = BoundedCaption(characterLimit: 500, utf8ByteLimit: 64)
        giant.append("kept"); giant.append("a" + String(repeating: "\u{0301}", count: 10_000))
        try check(giant.text == "kept", "oversized grapheme was retained or split")
        giant.append("z"); for _ in 0..<1_000 { giant.append("\u{0301}") }
        try check(giant.text.utf8.count <= 64 && giant.text.count <= 500, "cross-delta marks escaped caption bounds")
        giant.append("🙂🙃")
        try check(giant.text.hasSuffix("🙂🙃") && giant.text.utf8.count <= 64, "bounded emoji suffix was lost")
        giant.clear()
        try check(giant.text.isEmpty, "caption clear retained text")
    }

    @MainActor
    private static func boundedCaptionThreadContract() throws {
        var thread = BoundedCaptionThread(segmentLimit: 3, speakerCharacterLimit: 5, speakerUTF8ByteLimit: 32)
        thread.accept(generation: "g1", speaker: .user, delta: "ab", groupID: "u1")
        thread.accept(generation: "g1", speaker: .user, delta: "cd", groupID: "u1")
        try check(thread.segments.map(\.text) == ["abcd"], "same-speaker same-group tail did not append")
        thread.accept(generation: "g1", speaker: .agent, delta: "Pi", groupID: "a1")
        thread.accept(generation: "g1", speaker: .user, delta: "ef", groupID: "u1")
        try check(thread.segments.map(\.text) == ["bcd", "Pi", "ef"], "interleaving did not create a new ordered tail or enforce aggregate speaker bound")
        try check(thread.segments.map(\.isCurrent) == [false, false, true], "only the newest streaming tail was current")
        thread.accept(generation: "g1", speaker: .agent, delta: "reply", groupID: "a2")
        try check(thread.segments.map(\.text) == ["bcd", "ef", "reply"], "segment or per-speaker bound exceeded the approved window")
        try check(thread.markStable(generation: "g1", speaker: .agent, groupID: "a2"), "exact stable group was not found")
        try check(thread.segments.last?.isCurrent == false, "exact stable group remained current")
        try check(!thread.markStable(generation: "g2", speaker: .agent, groupID: "a2"), "foreign generation stabilized current captions")
        thread.accept(generation: "g1", speaker: .user, delta: "old", groupID: nil)
        thread.accept(generation: "g1", speaker: .user, delta: "fresh", groupID: nil)
        try check(thread.segments.last?.text == "fresh" && thread.segments.last?.isCurrent == false, "nil-group snapshot appended or became current")
        thread.clear()
        try check(thread.segments.isEmpty, "caption thread clear retained history")
    }

    @MainActor
    private static func visualEnvelopeContract() throws {
        var channel = VisualEnvelopeChannel()
        channel.retarget(to: 1, at: 10, attackDuration: 0.14, releaseDuration: 0.28)
        let attackMidpoint = channel.value(at: 10.07)
        try check(attackMidpoint > 0 && attackMidpoint < 1, "140 ms attack jumped or failed to advance")
        channel.retarget(to: 0, at: 10.07, attackDuration: 0.14, releaseDuration: 0.28)
        try check(abs(channel.value(at: 10.07) - attackMidpoint) < 0.000_001, "retargeting jumped from the visible monotonic sample")
        try check(channel.value(at: 10.35) == 0, "280 ms release did not settle")
        channel.retarget(to: .infinity, at: 20, attackDuration: 0.14, releaseDuration: 0.3)
        try check(channel.value(at: 20) == 0, "nonfinite visual level escaped fail-zero normalization")
        channel.retarget(to: 1, at: 21, attackDuration: 0.14, releaseDuration: 0.3)
        channel.reset(at: 21.01)
        try check(channel.value(at: 21.01) == 0, "privacy reset interpolated instead of reaching zero immediately")

        let allowed = VisualEnvelopeRenderSelection.select(
            isRunning: true,
            levelGeneration: "g1",
            envelopeGeneration: "g1",
            outgoingAuthorized: true,
            playbackAuthorized: true,
            outgoingSample: 0.7,
            playbackSample: 0.8
        )
        try check(allowed == .init(outgoing: 0.7, playback: 0.8), "exact visible authorized envelope was suppressed")
        for gated in [
            VisualEnvelopeRenderSelection.select(isRunning: false, levelGeneration: "g1", envelopeGeneration: "g1", outgoingAuthorized: true, playbackAuthorized: true, outgoingSample: 0.7, playbackSample: 0.8),
            VisualEnvelopeRenderSelection.select(isRunning: true, levelGeneration: "g2", envelopeGeneration: "g1", outgoingAuthorized: true, playbackAuthorized: true, outgoingSample: 0.7, playbackSample: 0.8),
            VisualEnvelopeRenderSelection.select(isRunning: true, levelGeneration: nil, envelopeGeneration: "g1", outgoingAuthorized: true, playbackAuthorized: true, outgoingSample: 0.7, playbackSample: 0.8),
        ] {
            try check(gated == .zero, "hidden, Unknown, or replacement generation rendered retained activity")
        }
        let channelGated = VisualEnvelopeRenderSelection.select(
            isRunning: true,
            levelGeneration: "g1",
            envelopeGeneration: "g1",
            outgoingAuthorized: false,
            playbackAuthorized: true,
            outgoingSample: 0.7,
            playbackSample: 0.8
        )
        try check(channelGated == .init(outgoing: 0, playback: 0.8), "per-channel authorization did not fail zero")
    }

    @MainActor
    private static func providerClosureRecoveryContract() throws {
        var fence = ProviderClosureRecoveryFence()
        let epoch = try require(fence.begin(origin: "https://voice.example.test", generation: "abcdefghijklmnopqrstuv"), "valid retained scope was rejected")
        try check(fence.begin(origin: "https://voice.example.test", generation: "") == nil, "empty generation opened recovery scope")
        let request = try require(fence.beginRequest(epoch: epoch), "exact epoch could not open a receipt request")
        try check(fence.beginRequest(epoch: epoch) == nil, "concurrent request reused one epoch")
        try check(fence.owns(request), "exact request fence was not owned")
        try check(fence.finish(request), "exact request could not finish")
        try check(!fence.owns(request), "finished request retained authority")
        let replacementEpoch = try require(fence.begin(origin: "https://voice.example.test", generation: "abcdefghijklmnopqrstu2"), "replacement scope was rejected")
        try check(replacementEpoch != epoch && !fence.owns(request), "old request crossed recovery epochs")

        var budget = ProviderClosureRecoveryBudget()
        try check(budget.claimDeadlineOffsetSeconds(epoch: replacementEpoch) == 0, "first recovery deadline was not immediate")
        try check(budget.claimDeadlineOffsetSeconds(epoch: replacementEpoch) == 5, "second recovery deadline was not campaign +5 seconds")
        try check(budget.claimDeadlineOffsetSeconds(epoch: replacementEpoch) == 15, "third recovery deadline was not campaign +15 seconds")
        try check(budget.claimDeadlineOffsetSeconds(epoch: replacementEpoch) == nil, "recovery exceeded its three-attempt budget")
        try check(budget.claimDeadlineOffsetSeconds(epoch: replacementEpoch + 1) == 0 && budget.attempts == 1, "new loss epoch did not receive a fresh budget")
    }

    @MainActor
    private static func peerConnectionRecoveryContract() throws {
        let first = PeerConnectionAuthority(revision: 1, peerIdentifier: "peer-one")
        let replacement = PeerConnectionAuthority(revision: 2, peerIdentifier: "peer-two")
        var policy = PeerConnectionRecoveryPolicy()
        policy.begin(first)
        try check(policy.bind(generation: "generation-1", to: first), "exact peer could not bind generation")
        try check(!policy.bind(generation: "stale", to: replacement), "replacement peer rebound generation")
        try check(policy.observe(.disconnected, authority: first, nowMilliseconds: 1_000, mediaBeforeDisconnect: .continuous) == .gateMediaAndArmGrace(graceSequence: 1, deadlineMilliseconds: 6_000), "disconnect did not gate and arm five-second grace")
        try check(policy.observe(.disconnected, authority: first, nowMilliseconds: 5_000, mediaBeforeDisconnect: .continuous) == .none, "repeated disconnect extended grace")
        try check(policy.observe(.connected, authority: replacement, nowMilliseconds: 5_000, mediaBeforeDisconnect: .continuous) == .none, "stale peer recovered media")
        try check(policy.observe(.connected, authority: first, nowMilliseconds: 5_000, mediaBeforeDisconnect: .gated) == .restoreContinuousSameSession, "same peer did not restore captured continuous state")

        policy.begin(first); _ = policy.bind(generation: "generation-2", to: first)
        try check(policy.observe(.disconnected, authority: first, nowMilliseconds: 5_000, mediaBeforeDisconnect: .pttHeld) == .gateMediaAndArmGrace(graceSequence: 1, deadlineMilliseconds: 10_000), "PTT disconnect did not gate")
        try check(policy.observe(.completed, authority: first, nowMilliseconds: 6_000, mediaBeforeDisconnect: .pttHeld) == .cancelPTTHoldBeforePlayback(generation: "generation-2"), "PTT recovery revived a held gesture")

        policy.begin(replacement); _ = policy.bind(generation: "generation-3", to: replacement)
        _ = policy.observe(.disconnected, authority: replacement, nowMilliseconds: 10_000, mediaBeforeDisconnect: .pttIdle)
        try check(policy.graceExpired(authority: first, graceSequence: 1, nowMilliseconds: 15_000) == .none, "stale peer expired current grace")
        try check(policy.graceExpired(authority: replacement, graceSequence: 2, nowMilliseconds: 15_000) == .none, "stale timer expired current grace")
        try check(policy.graceExpired(authority: replacement, graceSequence: 1, nowMilliseconds: 15_000) == .retainUnknown(generation: "generation-3"), "grace expiry discarded retained generation")
        try check(policy.observe(.connected, authority: replacement, nowMilliseconds: 15_000, mediaBeforeDisconnect: .continuous) == .none, "late recovery revived terminal peer")

        policy.begin(first)
        try check(policy.observe(.failed, authority: first, nowMilliseconds: 20_000, mediaBeforeDisconnect: .gated) == .retainUnknown(generation: nil), "pre-generation peer failure invented authority")
        try check(policy.observe(.connected, authority: first, nowMilliseconds: 20_001, mediaBeforeDisconnect: .continuous) == .none, "invalidated failed peer recovered")
    }

    @MainActor
    private static func voicePreferenceRestartPolicy() throws {
        let suiteName = "PiVoiceMacCoreChecks.preferences.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suiteName), "temporary preference store was unavailable")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        VoicePreferencePolicy.save(mode: .continuous, to: defaults)
        VoicePreferencePolicy.save(voice: .quartz, to: defaults)
        try check(
            VoicePreferencePolicy.restore(from: defaults) == .init(mode: .continuous, voice: .quartz),
            "valid mode and voice were not restored"
        )

        let restarted = try require(UserDefaults(suiteName: suiteName), "restart preference store was unavailable")
        try check(
            VoicePreferencePolicy.restore(from: restarted) == .init(mode: .continuous, voice: .quartz),
            "mode and voice did not survive a new preference-store instance"
        )

        restarted.set("unsupported-mode", forKey: VoicePreferencePolicy.modeKey)
        restarted.set(42, forKey: VoicePreferencePolicy.voiceKey)
        try check(
            VoicePreferencePolicy.restore(from: restarted) == .init(mode: .ptt, voice: .marin) &&
                restarted.string(forKey: VoicePreferencePolicy.modeKey) == VoiceMode.ptt.rawValue &&
                restarted.string(forKey: VoicePreferencePolicy.voiceKey) == VoiceName.marin.rawValue,
            "corrupt preferences were not repaired to validated defaults"
        )

        for mode in VoiceMode.allCases {
            VoicePreferencePolicy.save(mode: mode, to: restarted)
            try check(VoicePreferencePolicy.restore(from: restarted).mode == mode, "supported mode did not round-trip")
        }
        for voice in VoiceName.allCases {
            VoicePreferencePolicy.save(voice: voice, to: restarted)
            try check(VoicePreferencePolicy.restore(from: restarted).voice == voice, "supported voice did not round-trip")
        }
    }

    @MainActor
    private static func wireAndRoutingChecks() throws {
        let connectionID = "abcdefghijklmnopqrstuv"
        try check(
            VoiceConnectionAnnouncement.decode(Data("{\"type\":\"voice_connection\",\"connectionId\":\"\(connectionID)\"}".utf8)) ==
                .valid(connectionID: connectionID),
            "valid voice connection authority was not decoded"
        )
        try check(
            VoiceConnectionAnnouncement.decode(Data("{\"type\":\"voice_connection\",\"connectionId\":\"short\"}".utf8)) == .invalid &&
                !isOpaqueVoiceConnectionID("abcdefghijklmnopqrstu!"),
            "malformed voice connection authority was accepted"
        )
        try check(
            VoiceConnectionAnnouncement.decode(Data("{\"type\":\"relay_roster\"}".utf8)) == .notAnnouncement,
            "an unrelated event was consumed as voice connection authority"
        )
        var connectionFence = VoiceConnectionFence()
        let oldSocket = connectionFence.beginSocket()
        try check(
            connectionFence.connectionID(for: oldSocket) == nil,
            "Start-without-connection-ID did not fail closed"
        )
        try check(
            !connectionFence.acceptFirst(.notAnnouncement, revision: oldSocket),
            "a non-authority first socket event was accepted"
        )
        _ = connectionFence.acceptFirst(.valid(connectionID: connectionID), revision: oldSocket)
        let newSocket = connectionFence.beginSocket()
        try check(
            !connectionFence.bind(connectionID: connectionID, revision: oldSocket) &&
                connectionFence.connectionID(for: newSocket) == nil,
            "stale old socket rebound a replacement connection"
        )
        let replacementID = "0123456789ABCDEFGHIJKL"
        _ = connectionFence.bind(connectionID: replacementID, revision: newSocket)
        connectionFence.clear(revision: oldSocket)
        try check(
            connectionFence.connectionID(for: newSocket) == replacementID,
            "stale old-socket cleanup cleared new connection authority"
        )
        connectionFence.invalidate()
        try check(
            connectionFence.connectionID(for: newSocket) == nil &&
                !connectionFence.bind(connectionID: connectionID, revision: newSocket),
            "terminal task-completion grace retained Start authority or allowed stale rebinding"
        )

        try check(
            !PairingFormPolicy.buttonDisabled(isBusy: false),
            "idle Pair button was disabled before the secure field committed"
        )
        try check(
            !PairingFormPolicy.buttonDisabled(isBusy: false) &&
                PairingFormPolicy.normalizedToken("  nonempty-token\n") == "nonempty-token",
            "nonempty secure-field state did not remain submittable"
        )
        try check(
            PairingFormPolicy.buttonDisabled(isBusy: true),
            "busy Pair button remained enabled"
        )
        try check(
            PairingFormPolicy.normalizedToken(" \n\t") == nil,
            "empty pairing token passed submission validation"
        )

        try check(
            ProviderEventTypeCounts.isValidType("response.audio.delta") &&
                ProviderEventTypeCounts.isValidType("input_audio_buffer.speech_started") &&
                !ProviderEventTypeCounts.isValidType("") &&
                !ProviderEventTypeCounts.isValidType("bad/type") &&
                !ProviderEventTypeCounts.isValidType("évent"),
            "provider event type validation accepted content-bearing or non-contract characters"
        )
        var providerTypeCounts = ProviderEventTypeCounts()
        _ = providerTypeCounts.observe(type: "response.audio.delta")
        _ = providerTypeCounts.observe(type: "response.audio.delta")
        try check(
            providerTypeCounts.snapshot.observations == [
                .init(type: "response.audio.delta", count: 2),
            ] && providerTypeCounts.revision == 2,
            "provider event type counts were not cumulative"
        )
        for index in 0..<31 { _ = providerTypeCounts.observe(type: "type_\(index)") }
        _ = providerTypeCounts.observe(type: "overflow_a")
        _ = providerTypeCounts.observe(type: "overflow_b")
        try check(
            providerTypeCounts.snapshot.observations.count == 32 &&
                providerTypeCounts.snapshot.overflow == 2,
            "provider event diagnostics exceeded 32 unique types or lost overflow counts"
        )
        let boundedRevision = providerTypeCounts.revision
        try check(
            !providerTypeCounts.observe(type: "invalid type") &&
                providerTypeCounts.revision == boundedRevision,
            "invalid provider event type changed the bounded diagnostic snapshot"
        )
        try check(
            providerTypeCounts.observeUnparsedFrame() &&
                providerTypeCounts.snapshot.overflow == 3 &&
                providerTypeCounts.revision == boundedRevision + 1,
            "an unparsed provider frame did not produce bounded packet-presence metadata"
        )

        var audioGate = AudioLevelPublicationGate()
        try check(audioGate.recordEmission() == nil, "disabled audio meter gate admitted a sample")
        audioGate.setEnabled(true)
        let firstAudioPublication = try require(audioGate.recordEmission(), "enabled meter did not issue a publication token")
        audioGate.setEnabled(false)
        audioGate.setEnabled(true)
        let reopenedAudioPublication = try require(audioGate.recordEmission(), "reopened meter did not issue a publication token")
        try check(
            !audioGate.permits(firstAudioPublication) && audioGate.permits(reopenedAudioPublication),
            "a queued audio sample survived an off-to-on gate cycle"
        )
        let positiveAudioPublication = try require(audioGate.recordEmission(), "meter did not advance its publication sequence")
        let expiredZeroPublication = try require(audioGate.expire(positiveAudioPublication), "current meter sample could not expire")
        let expiryOrderingWasValid = !audioGate.permits(positiveAudioPublication) && audioGate.permits(expiredZeroPublication)
        let nextAudioPublication = try require(audioGate.recordEmission(), "meter did not accept a frame after expiry")
        try check(
            !audioGate.permits(reopenedAudioPublication) &&
                expiryOrderingWasValid &&
                !audioGate.permits(expiredZeroPublication) &&
                audioGate.permits(nextAudioPublication),
            "a queued positive sample or stale-zero survived expiry and a newer audio frame"
        )

        let silentRMS = [Int16](repeating: 0, count: 8).withUnsafeBufferPointer(normalizedInt16RMS)
        try check(silentRMS == 0, "silent PCM produced a nonzero audio level")
        let fullScaleRMS = [Int16.min].withUnsafeBufferPointer(normalizedInt16RMS)
        try check(fullScaleRMS == 1, "Int16 minimum did not normalize safely to full scale")
        let halfScaleRMS = [Int16(16_384), Int16(-16_384)].withUnsafeBufferPointer(normalizedInt16RMS)
        try check(abs(halfScaleRMS - 0.5) < 0.000_001, "signed half-scale PCM RMS was incorrect")

        var receipt = GlobalRightOptionReceipt()
        receipt.observe(keyCode: 58, isGlobal: true)
        try check(!receipt.observed, "Left Option created a global Right Option receipt")
        receipt.observe(keyCode: 61, isGlobal: false)
        try check(!receipt.observed, "app-local Right Option was misreported as global")
        receipt.observe(keyCode: 61, isGlobal: true)
        try check(receipt.observed, "global hardware key code 61 was not receipted")

        try check(
            resolvePhysicalOptionState(deviceModifierFlags: 0x40, leftOptionMask: 0x20, rightOptionMask: 0x40) == .init(rightDown: true, leftDown: false) &&
                resolvePhysicalOptionState(deviceModifierFlags: 0x20, leftOptionMask: 0x20, rightOptionMask: 0x40) == .init(rightDown: false, leftDown: true) &&
                resolvePhysicalOptionState(deviceModifierFlags: 1 << 19, leftOptionMask: 0x20, rightOptionMask: 0x40) == .init(rightDown: false, leftDown: false),
            "device-specific flags did not distinguish physical Option sides from the aggregate Option flag"
        )
        try check(
            resolvePhysicalOptionState(deviceModifierFlags: 0x60, leftOptionMask: 0x20, rightOptionMask: 0x40) == .init(rightDown: true, leftDown: true),
            "simultaneous physical Option keys were not detected as a chord"
        )
        var twinOptionGesture = GlobalOptionGesture()
        try check(
            twinOptionGesture.accept(.modifiers(optionDown: true, hasOtherModifiers: false), activeGeneration: "twins") == .begin(generation: "twins") &&
                twinOptionGesture.accept(.modifiers(optionDown: true, hasOtherModifiers: true), activeGeneration: "twins") == .end(generation: "twins", cancel: true) &&
                twinOptionGesture.accept(.modifiers(optionDown: true, hasOtherModifiers: false), activeGeneration: "twins") == nil &&
                twinOptionGesture.accept(.modifiers(optionDown: false, hasOtherModifiers: false), activeGeneration: "twins") == nil &&
                twinOptionGesture.accept(.modifiers(optionDown: true, hasOtherModifiers: false), activeGeneration: "twins") == .begin(generation: "twins"),
            "a twin-Option chord resumed implicitly before full release or blocked a later fresh hold"
        )

        var gesture = GlobalOptionGesture()
        try check(
            gesture.accept(.modifiers(optionDown: true, hasOtherModifiers: false), activeGeneration: "g1") == .begin(generation: "g1"),
            "modifier-only Right Option did not begin exact-generation PTT"
        )
        try check(
            gesture.accept(.nonModifierKeyDown, activeGeneration: "g1") == .end(generation: "g1", cancel: true),
            "an Option chord did not cancel the held PTT turn"
        )
        try check(
            gesture.accept(.modifiers(optionDown: false, hasOtherModifiers: false), activeGeneration: "g1") == nil,
            "a cancelled chord dispatched again on Option release"
        )
        try check(
            gesture.accept(.modifiers(optionDown: true, hasOtherModifiers: true), activeGeneration: "g1") == nil,
            "Right Option with another modifier began PTT"
        )
        _ = gesture.accept(.modifiers(optionDown: false, hasOtherModifiers: false), activeGeneration: "g1")
        try check(
            gesture.accept(.modifiers(optionDown: true, hasOtherModifiers: false), activeGeneration: "g1") == .begin(generation: "g1") &&
                gesture.accept(.modifiers(optionDown: true, hasOtherModifiers: true), activeGeneration: "g1") == .end(generation: "g1", cancel: true),
            "adding a modifier did not cancel the held PTT turn"
        )
        _ = gesture.accept(.modifiers(optionDown: false, hasOtherModifiers: false), activeGeneration: "g1")

        var unavailableGesture = GlobalOptionGesture()
        try check(
            unavailableGesture.accept(.modifiers(optionDown: true, hasOtherModifiers: false), activeGeneration: nil) == nil &&
                unavailableGesture.accept(.modifiers(optionDown: true, hasOtherModifiers: false), activeGeneration: "late") == nil &&
                unavailableGesture.accept(.modifiers(optionDown: false, hasOtherModifiers: false), activeGeneration: "late") == nil,
            "an Option hold that began before session authority auto-started late PTT"
        )
        try check(
            shouldRegisterGlobalNSEventMonitor(accessibilityTrusted: true),
            "Accessibility-trusted AppKit monitor was incorrectly blocked by a separate Core Graphics gate"
        )
        try check(
            !shouldRegisterGlobalNSEventMonitor(accessibilityTrusted: false),
            "global AppKit key monitor was allowed without Accessibility trust"
        )
        try check(
            !shouldWatchGlobalAccessibility(activeHold: true, globalMonitorReady: false),
            "focused local Right Option hold incorrectly required global permissions"
        )
        try check(
            shouldCancelOptionHoldOnApplicationResign(globalMonitorReady: false),
            "focused local Right Option hold did not fail closed on application resign"
        )
        try check(
            shouldWatchGlobalAccessibility(activeHold: true, globalMonitorReady: true) &&
                !shouldCancelOptionHoldOnApplicationResign(globalMonitorReady: true),
            "registered global Right Option hold did not preserve focus and watch Accessibility loss"
        )

        try check(
            gesture.accept(.modifiers(optionDown: true, hasOtherModifiers: false), activeGeneration: "old") == .begin(generation: "old"),
            "fresh modifier-only gesture did not begin"
        )
        try check(
            gesture.accept(.modifiers(optionDown: false, hasOtherModifiers: false), activeGeneration: "new") == nil,
            "a stale Option release affected a replacement generation"
        )

        var holds = PhysicalHoldAuthority()
        let pointer = holds.press(.pointer, generation: "g1")
        try check(pointer.action == .begin(generation: "g1"), "first pointer hold did not begin PTT")
        let option = holds.press(.rightOption, generation: "g1")
        try check(option.action == nil, "second physical source began duplicate PTT")
        try check(holds.release(option.token) == nil, "Option release ended a still-held pointer turn")
        try check(holds.release(pointer.token) == .end(generation: "g1", cancel: false), "last matching pointer release did not end PTT")

        let optionFirst = holds.press(.rightOption, generation: "g2")
        let pointerSecond = holds.press(.pointer, generation: "g2")
        try check(holds.release(pointerSecond.token) == nil, "pointer release ended a still-held Option turn")
        try check(holds.release(optionFirst.token) == .end(generation: "g2", cancel: false), "last matching Option release did not end PTT")

        let stalePointer = holds.press(.pointer, generation: "g3").token
        _ = holds.press(.rightOption, generation: "g3")
        try check(holds.cancelAll(generation: "g3") == .end(generation: "g3", cancel: true), "chord cancellation did not revoke all physical holds")
        let freshOption = holds.press(.rightOption, generation: "g3")
        try check(holds.release(stalePointer) == nil, "stale pointer-up ended a fresh Option hold")
        try check(holds.release(freshOption.token) == .end(generation: "g3", cancel: false), "fresh Option hold did not retain authority")

        let pointerForBlur = holds.press(.pointer, generation: "blur").token
        let optionAcrossBlur = holds.press(.rightOption, generation: "blur").token
        try check(holds.cancel(pointerForBlur) == nil, "pointer blur cancelled a simultaneous global Option hold")
        try check(holds.release(optionAcrossBlur) == .end(generation: "blur", cancel: false), "global Option hold did not survive application blur")
        let pointerOnly = holds.press(.pointer, generation: "pointer-only").token
        try check(holds.cancel(pointerOnly) == .end(generation: "pointer-only", cancel: true), "pointer-only blur did not cancel the turn")

        let staleOption = holds.press(.rightOption, generation: "g4").token
        _ = holds.cancelAll(generation: "g4")
        let freshPointer = holds.press(.pointer, generation: "g4")
        try check(holds.release(staleOption) == nil, "stale Option-up after blur ended a fresh pointer hold")
        try check(holds.release(freshPointer.token) == .end(generation: "g4", cancel: false), "fresh pointer hold did not survive stale Option-up")

        var mediaFence = MediaOwnershipFence()
        let oldMedia = mediaFence.begin()
        mediaFence.invalidate()
        let newMedia = mediaFence.begin()
        try check(!mediaFence.owns(oldMedia) && mediaFence.owns(newMedia), "stale media cleanup retained ownership of a newer peer")

        let now = Date(timeIntervalSince1970: 1_000)
        let alpha = AgentTarget(id: "agent-alpha-id", endpointEpoch: "epoch-a", name: "alpha", cwd: "/a")
        let replacement = AgentTarget(id: alpha.id, endpointEpoch: "epoch-b", name: "alpha", cwd: "/a")
        let duplicate = AgentTarget(id: "agent-other-id", endpointEpoch: "epoch-c", name: "alpha", cwd: "/b")
        let roster = RosterSnapshot(targets: [alpha], receivedAt: now)

        var router = TurnRouter()
        let focus = HerdrClientFocus(clientID: "mba-client", machineID: "mbp", paneID: "w5:p1", targetID: alpha.id, observedAt: now)
        let pinned = try router.begin(selection: .focused(focus), roster: roster, now: now)
        try check(pinned.target.id == alpha.id && pinned.target.endpointEpoch == "epoch-a", "turn did not pin exact target")
        do {
            _ = try router.finish(using: RosterSnapshot(targets: [replacement], receivedAt: now))
            throw CheckFailure.failed("replacement generation was accepted")
        } catch RoutingFailure.targetGenerationChanged {}

        let staleFocus = HerdrClientFocus(
            clientID: "mba-client", machineID: "mbp", paneID: "w5:p1", targetID: alpha.id,
            observedAt: now.addingTimeInterval(-TurnRouter.maximumFocusAge - 0.001)
        )
        do {
            _ = try router.begin(selection: .focused(staleFocus), roster: roster, now: now)
            throw CheckFailure.failed("stale focus was accepted")
        } catch RoutingFailure.focusEvidenceExpired {}

        let ambiguous = resolveDisplayName("alpha", in: RosterSnapshot(targets: [alpha, duplicate], receivedAt: now))
        guard case .ambiguous(let matches) = ambiguous else { throw CheckFailure.failed("duplicate display name resolved implicitly") }
        try check(matches.map(\.id) == [alpha.id, duplicate.id], "ambiguous identities changed")

        let gateway = try GatewayConfiguration(baseURL: URL(string: "https://voice.example.test")!)
        try check(gateway.origin == "https://voice.example.test", "origin mismatch")
        try check(gateway.webSocketURL.absoluteString == "wss://voice.example.test/ws", "websocket URL mismatch")
        try check(gateway.httpURL(path: "/api/browser-session/pair").absoluteString == "https://voice.example.test/api/browser-session/pair", "pairing path mismatch")

        let pairing = try BrowserPairingRequest(
            pairingToken: "abcdEFGH0123_-abcdEFGH0123_-abcd",
            deviceName: "  Pi Voice\n Mac  "
        )
        let pairingObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pairing)) as? [String: String]
        try check(pairingObject == [
            "pairingToken": "abcdEFGH0123_-abcdEFGH0123_-abcd",
            "deviceName": "Pi Voice Mac",
        ], "pairing body mismatch")
        do {
            _ = try BrowserPairingRequest(pairingToken: "operator-root-secret", deviceName: "Pi Voice Mac")
            throw CheckFailure.failed("invalid pairing token was accepted")
        } catch GatewayWireError.invalidPairingToken {}
        do {
            _ = try BrowserPairingRequest(pairingToken: String(repeating: "a", count: 32), deviceName: "")
            throw CheckFailure.failed("empty device name was accepted")
        } catch GatewayWireError.invalidDeviceName {}
        do {
            _ = try GatewayConfiguration(baseURL: URL(string: "https://secret@voice.example.test/path")!)
            throw CheckFailure.failed("unsafe gateway URL was accepted")
        } catch GatewayWireError.invalidBaseURL {}

        let rosterWire = Data(#"{"type":"relay_roster","sessions":[{"id":"id-1","endpointEpoch":"epoch-1","name":"alpha","cwd":"/tmp","kind":"agent","lastActivity":12}]}"#.utf8)
        guard case .roster(let decoded) = try GatewayEventDecoder.decode(rosterWire) else { throw CheckFailure.failed("roster event did not decode") }
        try check(decoded.first?.id == "id-1" && decoded.first?.endpointEpoch == "epoch-1", "exact roster identity lost")

        let pttWire = Data(#"{"type":"voice_ptt_ready","generation":"generation-1"}"#.utf8)
        try check(VoiceGatewayEventDecoder.decode(pttWire) == .pttReady(generation: "generation-1"), "voice wire generation was lost")
        let captionWire = Data(#"{"type":"voice_caption","generation":"generation-1","speaker":"user","delta":"hello","groupId":"user-7"}"#.utf8)
        try check(VoiceGatewayEventDecoder.decode(captionWire) == .caption(generation: "generation-1", speaker: "user", delta: "hello", groupID: "user-7"), "caption wire lost typed group identity")
        let stableWire = Data(#"{"type":"voice_caption_stable","generation":"generation-1","speaker":"user","groupId":"user-7"}"#.utf8)
        try check(VoiceGatewayEventDecoder.decode(stableWire) == .captionStable(generation: "generation-1", speaker: "user", groupID: "user-7"), "caption stability wire lost exact group identity")

        let authEndpoint = URL(string: "https://voice.example.test/api/browser-session/renew")!
        try check(RejectingRedirectDelegate.rejectsAllRedirects, "auth URLSession did not declare redirect rejection")
        try check(exactResponseURL(authEndpoint, matches: authEndpoint), "exact auth response URL was rejected")
        try check(
            !exactResponseURL(URL(string: "https://voice.example.test:444/api/browser-session/renew"), matches: authEndpoint) &&
                !exactResponseURL(URL(string: "https://voice.example.test/other"), matches: authEndpoint),
            "redirected auth response URL was accepted"
        )

        let credential = try DeviceCredential(
            origin: "https://voice.example.test",
            value: String(repeating: "A", count: 43)
        )
        try check(credential.origin == "https://voice.example.test", "device credential lost exact origin")
        do {
            _ = try DeviceCredential(origin: "https://voice.example.test/path", value: credential.value)
            throw CheckFailure.failed("non-origin Keychain account was accepted")
        } catch DeviceCredentialStoreError.invalidOrigin {}
        let keychainPolicy = try KeychainDeviceCredentialStore().policyAttributes(origin: credential.origin)
        try check(
            (keychainPolicy[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue == false,
            "device credential was not explicitly excluded from Keychain synchronization"
        )
        try check(
            keychainPolicy[kSecAttrAccount as String] as? String == credential.origin &&
                keychainPolicy[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            "Keychain policy lost exact-origin or this-device-only scope"
        )
        let failingStore = FailingCredentialStore()
        let vault = DeviceCredentialVault(store: failingStore)
        do {
            try vault.persist(value: credential.value, echoedOrigin: credential.origin, expectedOrigin: credential.origin)
            throw CheckFailure.failed("Keychain adapter failure was swallowed")
        } catch CredentialTestFailure.writeFailed {}
        try check(failingStore.saveAttempts == [credential], "Keychain adapter did not receive the exact-origin credential")
        do {
            try vault.persist(value: credential.value, echoedOrigin: "https://other.example.test", expectedOrigin: credential.origin)
            throw CheckFailure.failed("mismatched echoed origin reached Keychain")
        } catch DeviceCredentialVaultError.originMismatch {}
        try check(failingStore.saveAttempts == [credential], "origin mismatch mutated Keychain")

        var authAuthority = AsyncOperationAuthority()
        let stalePair = authAuthority.begin()
        authAuthority.invalidate()
        let memoryStore = MemoryCredentialStore()
        let memoryVault = DeviceCredentialVault(store: memoryStore)
        if authAuthority.owns(stalePair) {
            try memoryVault.persist(value: credential.value, echoedOrigin: credential.origin, expectedOrigin: credential.origin)
        }
        try check(memoryStore.value == nil, "late pair success recreated a forgotten Keychain credential")
        let currentPair = authAuthority.begin()
        try check(authAuthority.owns(currentPair), "current auth operation lost ownership")
        try memoryVault.persist(value: credential.value, echoedOrigin: credential.origin, expectedOrigin: credential.origin)
        if authAuthority.owns(stalePair) { try memoryVault.delete(origin: credential.origin) }
        try check(memoryStore.value == credential, "stale renew failure erased a newer paired credential")
        let replacementCredential = try DeviceCredential(origin: credential.origin, value: String(repeating: "B", count: 43))
        try memoryVault.persist(value: replacementCredential.value, echoedOrigin: replacementCredential.origin, expectedOrigin: replacementCredential.origin)
        try memoryVault.deleteIfUnchanged(credential)
        try check(memoryStore.value == replacementCredential, "late definitive 401 erased a newer credential")
        try memoryVault.deleteIfUnchanged(replacementCredential)
        try check(memoryStore.value == nil, "current definitive 401 did not delete its exact credential snapshot")
        let staleSocket = authAuthority.current
        _ = authAuthority.begin()
        var staleSocketYielded = false
        if authAuthority.owns(staleSocket) { staleSocketYielded = true }
        try check(!staleSocketYielded, "stale WebSocket success published an event after reconnect")

        try check(
            deviceCredentialFailureDisposition(httpStatus: 401, code: "invalid_device") == .deleteSavedCredential &&
                deviceCredentialFailureDisposition(httpStatus: 401, code: "expired_device") == .deleteSavedCredential &&
                deviceCredentialFailureDisposition(httpStatus: 401, code: "revoked_device") == .deleteSavedCredential &&
                deviceCredentialFailureDisposition(httpStatus: 401, code: "wrong_origin") == .retainSavedCredential &&
                deviceCredentialFailureDisposition(httpStatus: 503, code: "revoked_device") == .retainSavedCredential,
            "renewal failure policy could erase a valid credential"
        )

        let delivery = RelayDelivery(delivered: false, delivery: "unknown", retryable: false, outcomeKnown: false)
        do {
            try delivery.requireKnownDelivery()
            throw CheckFailure.failed("unknown delivery was accepted")
        } catch GatewayWireError.deliveryUnknown {}
    }

    @MainActor
    private static func gatewayURLSessionFailureBounds() async throws {
        let production = GatewayConnectionPolicy.makeEphemeralConfiguration()
        try check(
            !production.waitsForConnectivity &&
                production.timeoutIntervalForRequest == 20 &&
                production.timeoutIntervalForResource == 20,
            "production gateway URLSession lost its bounded offline policy"
        )

        let isolatedCookies = try require(
            URLSessionConfiguration.ephemeral.httpCookieStorage,
            "ephemeral WebSocket cookie store was unavailable"
        )
        let webSocketConfiguration = GatewayConnectionPolicy.makeWebSocketConfiguration(
            cookieStorage: isolatedCookies
        )
        try check(
            webSocketConfiguration.timeoutIntervalForRequest == 20 &&
                webSocketConfiguration.timeoutIntervalForResource == 65 * 60 &&
                webSocketConfiguration.httpCookieStorage === isolatedCookies &&
                webSocketConfiguration.httpCookieStorage !== HTTPCookieStorage.shared,
            "event WebSocket lost its bounded handshake/lifetime or exact ephemeral cookie jar"
        )

        let timeoutServer = try SilentLoopbackHTTPServer()
        let timeoutConfiguration = GatewayConnectionPolicy.makeEphemeralConfiguration(
            requestTimeout: 0.2,
            resourceTimeout: 0.2
        )
        let timeoutSession = URLSession(
            configuration: timeoutConfiguration,
            delegate: RejectingRedirectDelegate(),
            delegateQueue: nil
        )
        let timeoutStart = ContinuousClock.now
        do {
            _ = try await timeoutSession.data(from: timeoutServer.url)
            throw CheckFailure.failed("a silent gateway fixture did not time out")
        } catch let error as URLError {
            try check(error.code == .timedOut, "silent gateway fixture failed for a reason other than timeout")
        }
        try check(
            timeoutStart.duration(to: .now) < .seconds(2),
            "gateway request timeout did not bound a silent offline fixture"
        )
        timeoutSession.invalidateAndCancel()
        timeoutServer.stop()

        let completionRecorder = CompletionReceiptRecorder()
        let completionDelegate = RejectingRedirectDelegate { completionRecorder.append($0) }
        let completionSession = URLSession(
            configuration: production,
            delegate: completionDelegate,
            delegateQueue: nil
        )
        let completionTask = completionSession.dataTask(with: URL(string: "https://voice.example.test/completion")!)
        completionDelegate.urlSession(completionSession, task: completionTask, didCompleteWithError: nil)
        let taskReceipt = try require(completionRecorder.receipts.last, "task completion delegate emitted no identity receipt")
        try check(
            taskReceipt.kind == .taskCompleted && taskReceipt.matches(session: completionSession, task: completionTask),
            "task completion receipt lost its exact session/task identity"
        )
        let replacementSession = URLSession(configuration: production)
        let replacementTask = replacementSession.dataTask(with: URL(string: "https://voice.example.test/replacement")!)
        try check(
            !taskReceipt.matches(session: replacementSession, task: completionTask) &&
                !taskReceipt.matches(session: completionSession, task: replacementTask),
            "stale completion receipt matched a replacement session or task"
        )
        let webSocketTask = completionSession.webSocketTask(with: URL(string: "wss://voice.example.test/events")!)
        completionDelegate.urlSession(
            completionSession,
            webSocketTask: webSocketTask,
            didCloseWith: .normalClosure,
            reason: nil
        )
        let closeReceipt = try require(completionRecorder.receipts.last, "WebSocket close delegate emitted no identity receipt")
        try check(
            closeReceipt.kind == .webSocketClosed && closeReceipt.webSocketCloseCode == 1000 &&
                closeReceipt.matches(session: completionSession, task: webSocketTask),
            "WebSocket close receipt lost its exact session/task/code identity"
        )
        completionSession.invalidateAndCancel()
        replacementSession.invalidateAndCancel()

        let cancellationServer = try SilentLoopbackHTTPServer()
        let cancellationSession = URLSession(
            configuration: production,
            delegate: RejectingRedirectDelegate(),
            delegateQueue: nil
        )
        let request = Task { try await cancellationSession.data(from: cancellationServer.url) }
        try await Task.sleep(for: .milliseconds(50))
        let cancellationStart = ContinuousClock.now
        request.cancel()
        do {
            _ = try await request.value
            throw CheckFailure.failed("cancelled gateway request returned success")
        } catch is CancellationError {
            // Expected from URLSession's async bridge.
        } catch let error as URLError {
            try check(error.code == .cancelled, "cancelled gateway request returned a non-cancellation error")
        }
        try check(
            cancellationStart.duration(to: .now) < .seconds(1),
            "gateway request cancellation waited for the resource timeout"
        )
        cancellationSession.invalidateAndCancel()
        cancellationServer.stop()
    }

    @MainActor
    private static func automaticAuthorizationRetries() async throws {
        let fake = FakeTransport()
        fake.renewFailuresRemaining = 3
        let coordinator = VoiceSessionCoordinator(transport: fake)
        let origin = URL(string: "https://voice.example.test")!
        var visibleFailures: [String] = []
        var requestedDelays: [Duration] = []
        let connected = await AutomaticConnectionRetry.run(
            shouldContinue: { coordinator.phase == .disconnected },
            reconnect: { try await coordinator.reconnectSavedDevice(origin: origin) },
            shouldRetry: { _ in true },
            reportFailure: { visibleFailures.append($0.localizedDescription) },
            sleep: { requestedDelays.append($0) }
        )
        try check(
            !connected && fake.renewedOrigins.count == 3 &&
                requestedDelays == [.seconds(1), .seconds(2)] && visibleFailures.count == 3,
            "automatic authorization did not stop after three transient attempts with a visible failure"
        )
        try check(
            coordinator.phase == .disconnected && fake.startedTargets.isEmpty &&
                !fake.microphone && !fake.playback,
            "automatic authorization started voice, microphone, playback, or provider work"
        )

        fake.renewFailuresRemaining = 1
        var allowRetry = true
        var cancelledAttempts = 0
        let cancelled = await AutomaticConnectionRetry.run(
            shouldContinue: { allowRetry },
            reconnect: {
                cancelledAttempts += 1
                try await coordinator.reconnectSavedDevice(origin: origin)
            },
            shouldRetry: { _ in true },
            reportFailure: { _ in allowRetry = false },
            sleep: { _ in throw CancellationError() }
        )
        try check(
            !cancelled && cancelledAttempts == 1 && fake.startedTargets.isEmpty &&
                coordinator.phase == .disconnected,
            "cancelled automatic authorization retried or created a voice session"
        )
    }

    @MainActor
    private static func connected(
        _ fake: FakeTransport,
        peerRecoveryPolicy: PeerConnectionRecoveryPolicy = PeerConnectionRecoveryPolicy()
    ) async throws -> (VoiceSessionCoordinator, AgentTarget) {
        let coordinator = VoiceSessionCoordinator(transport: fake, peerRecoveryPolicy: peerRecoveryPolicy)
        try check(fake.playbackGain == 1, "default per-track playback gain was not unity")
        coordinator.setOutputGain(0.6)
        try check(fake.playbackGain == 0.6, "60 percent per-track reply volume was not applied")
        coordinator.setOutputGain(99)
        try check(fake.playbackGain == 1, "reply volume exceeded 100 percent")
        coordinator.setOutputGain(0)
        try check(fake.playbackGain == 0, "zero percent reply volume did not mute")
        coordinator.setOutputGain(-1)
        try check(fake.playbackGain == 0, "negative volume was not clamped")
        coordinator.setOutputGain(.nan)
        try check(fake.playbackGain == 1, "nonfinite volume was not made safe")
        let target = AgentTarget(id: "agent", endpointEpoch: "epoch-live", name: "Research", cwd: "/repo")
        try await coordinator.connect(
            origin: URL(string: "https://voice.example.test")!,
            pairingToken: String(repeating: "a", count: 32),
            deviceName: "Pi Voice test"
        )
        fake.emit(.roster(connected: true, agents: [target]))
        try await Task.sleep(for: .milliseconds(10))
        return (coordinator, target)
    }

    @MainActor
    private static func activePTT(_ fake: FakeTransport) async throws -> VoiceSessionCoordinator {
        let (coordinator, target) = try await connected(fake)
        try coordinator.select(target)
        try await coordinator.start(mode: .ptt, voice: .marin)
        return coordinator
    }

    @MainActor
    private static func exactLiaisonStart() async throws {
        let fake = FakeTransport()
        let (coordinator, target) = try await connected(fake)
        let stale = AgentTarget(id: target.id, endpointEpoch: "old", name: target.name, cwd: target.cwd)
        do { try coordinator.select(stale); throw CheckFailure.failed("stale epoch was accepted") }
        catch VoiceFailure.staleTarget {}
        try coordinator.select(target)
        try await coordinator.start(mode: .continuous, voice: .marin)
        try check(fake.startedTargets == [target], "start did not preserve exact target")
        try check(fake.startedRoutings == [.liaison], "native voice did not request central liaison routing")
        let connectionID = "abcdefghijklmnopqrstuv"
        let body = LiveSessionRequest(target: target, mode: .continuous, voice: .marin).gatewayBody(
            sdp: "offer",
            connectionID: connectionID
        )
        try check(
            body.routingMode == "liaison" && body.targetEpoch == target.endpointEpoch &&
                body.connectionId == connectionID && body.idleTimeoutMinutes == 5,
            "gateway body lost target or exact WebSocket authority"
        )
        try check(fake.microphone && fake.playback, "continuous liaison media gates are wrong")
        try await Task.sleep(for: .milliseconds(10))
        try check(fake.mediaReady == ["generation-1"], "exact ready generation did not announce media readiness")
    }

    @MainActor
    private static func oneShotGreetingReadiness() async throws {
        let fake = FakeTransport()
        fake.failMediaReady = true
        let (coordinator, target) = try await connected(fake)
        try coordinator.select(target)
        try await coordinator.start(mode: .continuous, voice: .marin)
        try await Task.sleep(for: .milliseconds(10))
        try check(fake.mediaReady == ["generation-1"], "unknown media-ready outcome was retried or omitted")
        try coordinator.setContinuousMicrophoneMuted(true)
        try coordinator.setContinuousMicrophoneMuted(false)
        try await Task.sleep(for: .milliseconds(10))
        try check(fake.mediaReady == ["generation-1"], "mute toggles repeated media readiness")
        fake.failMediaReady = false
        await coordinator.stop()
        try await coordinator.start(mode: .continuous, voice: .marin)
        try await Task.sleep(for: .milliseconds(10))
        try check(fake.mediaReady == ["generation-1", "generation-2"], "fresh explicit Start did not receive fresh greeting authority")
    }

    @MainActor
    private static func exactClosureRecoveryWiring() async throws {
        let fake = FakeTransport()
        let (coordinator, target) = try await connected(fake)
        try coordinator.select(target)
        try await coordinator.start(mode: .continuous, voice: .marin)
        fake.emit(.sessionEnded(message: "socket lost"))
        try await Task.sleep(for: .milliseconds(5))
        guard let firstEpoch = coordinator.closureRecoveryEpoch else { throw CheckFailure.failed("socket loss did not create recovery epoch") }
        coordinator.retainAuthorityAfterConnectionLoss("duplicate sleep notification")
        try check(coordinator.closureRecoveryEpoch == firstEpoch, "duplicate loss notification reset the bounded recovery epoch")
        try check(coordinator.mayCheckProviderClosure(epoch: firstEpoch), "exact retained scope could not query closure")
        fake.closureReceiptResult = .unconfirmed
        let unconfirmed = try await coordinator.checkProviderClosure(epoch: firstEpoch)
        try check(!unconfirmed, "unconfirmed receipt released authority")
        try check(coordinator.activeGeneration == "generation-1" && coordinator.hasProviderClosureRecoveryScope(epoch: firstEpoch), "unconfirmed receipt mutated retained scope")

        fake.closureReceiptDelay = .milliseconds(40)
        fake.closureReceiptIgnoresCancellation = true
        fake.closureReceiptThrowsDefinitive = true
        let canceledSameEpoch = Task { try? await coordinator.checkProviderClosure(epoch: firstEpoch) }
        try await Task.sleep(for: .milliseconds(5))
        canceledSameEpoch.cancel()
        coordinator.cancelProviderClosureCheck(epoch: firstEpoch)
        _ = await canceledSameEpoch.value
        try check(fake.closureReceiptMutationChecks.last == false, "canceled same-epoch late 401 retained credential mutation authority")
        try check(coordinator.mayCheckProviderClosure(epoch: firstEpoch), "canceled same-epoch request blocked a fresh bounded attempt")
        fake.closureReceiptIgnoresCancellation = false
        fake.closureReceiptThrowsDefinitive = false

        fake.closureReceiptResult = .providerClosed
        let oldRequest = Task { try await coordinator.checkProviderClosure(epoch: firstEpoch) }
        try await Task.sleep(for: .milliseconds(5))
        fake.emit(.voiceState(generation: "generation-1", state: "closed", reason: "provider_closed"))
        try await Task.sleep(for: .milliseconds(5))
        await coordinator.disconnect()
        try await coordinator.reconnectSavedDevice(origin: URL(string: "https://voice.example.test")!)
        fake.emit(.roster(connected: true, agents: [target])); try await Task.sleep(for: .milliseconds(5))
        try coordinator.select(target)
        try await coordinator.start(mode: .continuous, voice: .marin)
        fake.emit(.sessionEnded(message: "replacement socket lost")); try await Task.sleep(for: .milliseconds(5))
        guard let secondEpoch = coordinator.closureRecoveryEpoch else { throw CheckFailure.failed("replacement loss lacked recovery epoch") }
        try check(secondEpoch != firstEpoch, "replacement generation reused recovery epoch")
        let oldConfirmed = try await oldRequest.value
        try check(!oldConfirmed && coordinator.activeGeneration == "generation-2", "late old receipt released replacement authority")
        try check(fake.closureReceiptMutationChecks.last == false, "canceled same-snapshot receipt retained credential-mutation authority")
        try check(coordinator.hasProviderClosureRecoveryScope(epoch: secondEpoch), "late old receipt cleared replacement recovery scope")
        try check(fake.closureReceiptQueries.map(\.1).contains("generation-1"), "receipt query lost exact generation")

        fake.closureReceiptThrowsDefinitive = true
        let lateRejection = Task { try? await coordinator.checkProviderClosure(epoch: secondEpoch) }
        try await Task.sleep(for: .milliseconds(5))
        fake.emit(.voiceState(generation: "generation-2", state: "closed", reason: "provider_closed"))
        try await Task.sleep(for: .milliseconds(5))
        _ = await lateRejection.value
        try check(fake.closureReceiptMutationChecks.last == false, "late definitive 401 retained same-snapshot credential mutation authority after epoch cancellation")
    }

    @MainActor
    private static func manualClosureCheckAfterSleepAndWake() async throws {
        let fake = FakeTransport()
        let (coordinator, target) = try await connected(fake)
        try coordinator.select(target)
        try await coordinator.start(mode: .continuous, voice: .marin)
        try coordinator.setContinuousMicrophoneMuted(true)
        let startedBeforeSleep = fake.startedTargets

        coordinator.retainAuthorityAfterConnectionLoss("simulated system sleep")
        guard let epoch = coordinator.closureRecoveryEpoch else {
            throw CheckFailure.failed("simulated sleep did not retain an exact closure epoch")
        }
        try check(
            coordinator.activeGeneration == "generation-1" && !fake.microphone && !fake.playback && coordinator.continuousMicrophoneMuted,
            "simulated sleep discarded exact authority, reopened media, or cleared Mute"
        )

        fake.closureReceiptResult = .unconfirmed
        for _ in 0..<2 {
            let confirmed = try await coordinator.checkProviderClosure(epoch: epoch)
            try check(!confirmed, "manual status check invented provider closure")
            try check(
                coordinator.activeGeneration == "generation-1" && coordinator.hasProviderClosureRecoveryScope(epoch: epoch) &&
                    !fake.microphone && !fake.playback && coordinator.continuousMicrophoneMuted,
                "unconfirmed manual status check mutated authority, media, or Mute"
            )
        }
        try check(fake.startedTargets == startedBeforeSleep, "manual status check started or replayed voice")
        try check(fake.closureReceiptQueries.suffix(2).allSatisfy { $0.1 == "generation-1" }, "manual status check queried a non-exact generation")
        do {
            try await coordinator.reconnectSavedDevice(origin: URL(string: "https://voice.example.test")!)
            throw CheckFailure.failed("manual status path allowed authorization reconnect across retained authority")
        } catch VoiceFailure.callAlreadyActive {}

        fake.closureReceiptThrowsDefinitive = true
        var statusCheckFailed = false
        do { _ = try await coordinator.checkProviderClosure(epoch: epoch) }
        catch { statusCheckFailed = true }
        try check(statusCheckFailed, "failed manual status check was accepted")
        try check(
            coordinator.activeGeneration == "generation-1" && coordinator.hasProviderClosureRecoveryScope(epoch: epoch) &&
                !fake.microphone && !fake.playback,
            "failed manual status check erased authority or reopened media"
        )

        try check(coordinator.lastError == "simulated system sleep", "manual recovery fixture did not retain the pre-closure warning")
        fake.closureReceiptThrowsDefinitive = false
        fake.closureReceiptResult = .providerClosed
        let closureConfirmed = try await coordinator.checkProviderClosure(epoch: epoch)
        try check(closureConfirmed, "exact manual status check did not accept provider closure")
        try check(
            coordinator.activeGeneration == nil && coordinator.lastEndConfirmed && coordinator.lastEndGeneration == "generation-1" &&
                coordinator.lastError == nil && fake.startedTargets == startedBeforeSleep && !fake.microphone && !fake.playback,
            "confirmed manual status check restarted voice or failed to release exact closed authority"
        )
    }

    @MainActor
    private static func peerConnectionRecoveryWiring() async throws {
        let fake = FakeTransport()
        let (coordinator, target) = try await connected(fake)
        try coordinator.select(target)
        try await coordinator.start(mode: .continuous, voice: .marin)
        let peer = PeerConnectionAuthority(revision: 1, peerIdentifier: "peer-1")
        fake.emit(.peerConnectionState(authority: peer, state: .disconnected))
        try await Task.sleep(for: .milliseconds(5))
        try check(coordinator.mediaConnectionState == .reconnecting && !fake.microphone && !fake.playback, "ICE disconnect did not gate both media directions immediately")
        try check(coordinator.activeGeneration == "generation-1", "ICE disconnect discarded exact generation authority")
        fake.emit(.peerConnectionState(authority: .init(revision: 99, peerIdentifier: "replacement"), state: .connected))
        try await Task.sleep(for: .milliseconds(5))
        try check(coordinator.mediaConnectionState == .reconnecting && !fake.microphone, "replacement peer recovered current media")
        fake.emit(.peerConnectionState(authority: peer, state: .connected))
        try await Task.sleep(for: .milliseconds(5))
        try check(coordinator.mediaConnectionState == .connected && fake.microphone && fake.playback, "same peer did not restore continuous media")
        try coordinator.setContinuousMicrophoneMuted(true)
        fake.emit(.peerConnectionState(authority: peer, state: .disconnected))
        fake.emit(.peerConnectionState(authority: peer, state: .connected))
        try await Task.sleep(for: .milliseconds(5))
        try check(!fake.microphone && fake.playback, "same-peer recovery bypassed current mute")

        let pttFake = FakeTransport()
        let ptt = try await activePTT(pttFake)
        try ptt.beginPushToTalkFromHardwareEvent()
        try await Task.sleep(for: .milliseconds(5))
        let pttPeer = PeerConnectionAuthority(revision: 1, peerIdentifier: "peer-1")
        pttFake.emit(.peerConnectionState(authority: pttPeer, state: .disconnected))
        try await Task.sleep(for: .milliseconds(5))
        try check(!pttFake.microphone && !pttFake.playback, "held PTT disconnect did not gate media")
        pttFake.emit(.peerConnectionState(authority: pttPeer, state: .completed))
        try await Task.sleep(for: .milliseconds(10))
        try check(pttFake.ptt.last?.held == false && pttFake.ptt.last?.cancel == true, "PTT recovery did not cancel the old hold")
        try check(!pttFake.microphone && pttFake.playback, "PTT recovery restored capture or failed to restore idle playback")

        let expiringFake = FakeTransport()
        let (expiring, expiringTarget) = try await connected(
            expiringFake,
            peerRecoveryPolicy: PeerConnectionRecoveryPolicy(graceMilliseconds: 20)
        )
        try expiring.select(expiringTarget)
        try await expiring.start(mode: .continuous, voice: .marin)
        expiringFake.emit(.peerConnectionState(authority: peer, state: .disconnected))
        try await Task.sleep(for: .milliseconds(40))
        guard case .uncertain = expiring.phase else { throw CheckFailure.failed("ICE grace expiry did not enter retained Unknown") }
        try check(expiring.activeGeneration == "generation-1" && !expiringFake.microphone && !expiringFake.playback, "ICE expiry discarded authority or retained media")
        expiringFake.emit(.peerConnectionState(authority: peer, state: .connected))
        try await Task.sleep(for: .milliseconds(5))
        guard case .uncertain = expiring.phase else { throw CheckFailure.failed("late peer callback revived Unknown") }

        let ackFake = FakeTransport()
        ackFake.delayReleaseAcknowledgement = true
        let held = try await activePTT(ackFake)
        try await held.beginPushToTalk()
        let heldPeer = PeerConnectionAuthority(revision: 1, peerIdentifier: "peer-1")
        ackFake.emit(.peerConnectionState(authority: heldPeer, state: .disconnected)); try await Task.sleep(for: .milliseconds(5))
        ackFake.emit(.peerConnectionState(authority: heldPeer, state: .connected)); try await Task.sleep(for: .milliseconds(5))
        ackFake.emit(.peerConnectionState(authority: heldPeer, state: .disconnected)); try await Task.sleep(for: .milliseconds(60))
        try check(held.mediaConnectionState == .reconnecting && !ackFake.microphone && !ackFake.playback, "stale PTT-cancel ACK reopened media during a newer peer grace")
        ackFake.emit(.peerConnectionState(authority: heldPeer, state: .connected)); try await Task.sleep(for: .milliseconds(5))
        guard case .uncertain = held.phase else { throw CheckFailure.failed("superseded PTT cancellation recovered without exact outcome proof") }
    }

    @MainActor
    private static func savedDeviceReconnectAndLocalForget() async throws {
        let fake = FakeTransport()
        let coordinator = VoiceSessionCoordinator(transport: fake)
        let origin = URL(string: "https://voice.example.test")!
        let hasSavedDevice = try coordinator.hasSavedDevice(origin: origin)
        try check(hasSavedDevice, "saved-device availability was not exposed")
        try await coordinator.reconnectSavedDevice(origin: origin)
        try check(fake.renewedOrigins == [origin] && coordinator.phase == .ready, "restart reconnect did not renew one short session")
        fake.emit(.sessionEnded(message: "Reconnect explicitly"))
        try await Task.sleep(for: .milliseconds(5))
        try check(
            coordinator.phase == .disconnected && coordinator.explicitReconnectRequired,
            "dead event transport retained Ready or permitted implicit reconnect"
        )
        try await coordinator.reconnectSavedDevice(origin: origin)
        try check(
            fake.renewedOrigins == [origin, origin] && coordinator.phase == .ready &&
                !coordinator.explicitReconnectRequired,
            "explicit Reconnect did not supersede the dead socket with fresh readiness"
        )
        try await coordinator.forgetSavedDevice(origin: origin)
        try check(fake.forgottenOrigins == [origin], "Forget did not delete only the exact-origin credential")
        try check(coordinator.phase == .disconnected, "Forget retained the in-memory gateway session")
    }

    @MainActor
    private static func revocationFailsClosed() async throws {
        let fake = FakeTransport()
        let (coordinator, target) = try await connected(fake)
        try coordinator.select(target)
        try await coordinator.start(mode: .continuous, voice: .marin)
        fake.emit(.deviceRevoked(credentialCleared: true))
        try await Task.sleep(for: .milliseconds(10))
        guard case .uncertain = coordinator.phase else { throw CheckFailure.failed("revocation discarded unconfirmed provider authority") }
        try check(coordinator.activeGeneration == "generation-1", "revocation lost exact generation authority")
        try check(!fake.microphone && !fake.playback && fake.disconnectCount == 1, "revocation did not synchronously stop media and the socket")
        try check(coordinator.lastError?.contains("deleted") == true, "revocation did not report exact Keychain deletion")

        let transientFake = FakeTransport()
        let (transient, transientTarget) = try await connected(transientFake)
        try transient.select(transientTarget)
        try await transient.start(mode: .continuous, voice: .marin)
        transientFake.emit(.sessionEnded(message: "Reconnect explicitly"))
        try await Task.sleep(for: .milliseconds(10))
        guard case .uncertain = transient.phase, let recoveryEpoch = transient.closureRecoveryEpoch else {
            throw CheckFailure.failed("active socket loss did not retain Unknown recovery scope")
        }
        try check(transient.activeGeneration == "generation-1" && !transientFake.microphone && !transientFake.playback, "active socket loss discarded authority or retained media")
        transientFake.closureReceiptResult = .providerClosed
        let confirmed = try await transient.checkProviderClosure(epoch: recoveryEpoch)
        try check(confirmed, "exact provider-closed receipt did not release retained authority")
        try check(transient.phase == .disconnected && transient.activeGeneration == nil, "receipt proof did not return to disconnected authorization state")
        try await transient.reconnectSavedDevice(origin: URL(string: "https://voice.example.test")!)
        try check(
            transient.phase == .ready && transient.lastError == nil,
            "successful durable reconnect retained the expired-session error"
        )
        try await Task.sleep(for: .milliseconds(1))
        transientFake.emit(.roster(connected: true, agents: [transientTarget]))
        try await Task.sleep(for: .milliseconds(10))
        try check(
            transient.agents == [transientTarget],
            "fresh roster did not repopulate after durable reconnect"
        )

        transientFake.emit(.sessionEnded(message: "Expired again"))
        try await Task.sleep(for: .milliseconds(10))
        transientFake.delayConnect = true
        let staleReconnect = Task { try await transient.reconnectSavedDevice(origin: URL(string: "https://voice.example.test")!) }
        try await Task.sleep(for: .milliseconds(10))
        transientFake.emit(.sessionEnded(message: "Newer connection failure"))
        try? await staleReconnect.value
        try check(
            transient.phase == .disconnected && transient.lastError == "Newer connection failure",
            "a stale reconnect completion cleared a newer connection error"
        )
    }

    @MainActor
    private static func continuousMuteAndFocusLifecycle() async throws {
        let fake = FakeTransport()
        let (coordinator, target) = try await connected(fake)
        try coordinator.select(target)
        try await coordinator.start(mode: .continuous, voice: .marin)

        try coordinator.setContinuousMicrophoneMuted(true)
        try check(coordinator.continuousMicrophoneMuted && !fake.microphone && fake.playback, "continuous Mute did not preserve reply playback")
        await coordinator.suspendForFocusLoss()
        try check(!fake.microphone && fake.playback, "focus loss changed a muted continuous conversation")
        fake.emit(.caption(generation: "generation-1", speaker: "assistant", delta: "working", groupID: "assistant-1"))
        try await Task.sleep(for: .milliseconds(10))
        try check(!fake.microphone && fake.playback, "a reply silently unmuted continuous input")

        try coordinator.setContinuousMicrophoneMuted(false)
        await coordinator.suspendForFocusLoss()
        try check(fake.microphone && fake.playback, "focus loss silenced an explicit continuous conversation")

        let refreshed = AgentTarget(
            id: target.id,
            endpointEpoch: target.endpointEpoch,
            name: "Research",
            cwd: "/repo/task",
            status: "busy"
        )
        fake.emit(.roster(connected: true, agents: [refreshed]))
        try await Task.sleep(for: .milliseconds(10))
        try check(coordinator.activeTarget == refreshed, "verified task status did not refresh for the pinned endpoint")
        try check(fake.closed.isEmpty, "same-authority task refresh stopped the conversation")
    }

    @MainActor
    private static func captionThreadWiringContract() async throws {
        let fake = FakeTransport()
        let (coordinator, target) = try await connected(fake)
        try coordinator.select(target)
        try await coordinator.start(mode: .continuous, voice: .marin)
        fake.emit(.caption(generation: "generation-1", speaker: "user", delta: "User A ", groupID: "user-1"))
        fake.emit(.caption(generation: "generation-1", speaker: "assistant", delta: "Huh.", groupID: "assistant-1"))
        fake.emit(.caption(generation: "generation-1", speaker: "user", delta: "User B", groupID: "user-1"))
        try await Task.sleep(for: .milliseconds(5))
        try check(
            coordinator.captionThread == [
                .init(generation: "generation-1", speaker: .user, text: "User A ", isCurrent: false),
                .init(generation: "generation-1", speaker: .agent, text: "Huh.", isCurrent: false),
                .init(generation: "generation-1", speaker: .user, text: "User B", isCurrent: true),
            ],
            "interleaved captions did not preserve exact arrival order in three segments"
        )
        try coordinator.setContinuousMicrophoneMuted(true)
        try check(coordinator.captionThread.allSatisfy { !$0.isCurrent }, "muted user retained a current marker")
        try coordinator.setContinuousMicrophoneMuted(false)
        try check(coordinator.captionThread.last?.speaker == .user && coordinator.captionThread.last?.isCurrent == true, "unmuted authorized user currentness was not restored")
        fake.emit(.captionStable(generation: "generation-1", speaker: "user", groupID: "stale")); try await Task.sleep(for: .milliseconds(2))
        try check(coordinator.captionThread.last?.speaker == .user && coordinator.captionThread.last?.isCurrent == true, "mismatched stable event ended current user group")
        fake.emit(.captionStable(generation: "generation-1", speaker: "user", groupID: "user-1")); try await Task.sleep(for: .milliseconds(2))
        try check(coordinator.captionThread.allSatisfy { !$0.isCurrent }, "exact stable user group did not clear currentness")
        fake.emit(.caption(generation: "generation-1", speaker: "assistant", delta: "Reply ", groupID: "assistant-2"))
        fake.emit(.playbackActivity(generation: "generation-1", active: true)); try await Task.sleep(for: .milliseconds(2))
        try check(coordinator.captionThread.last?.speaker == .agent && coordinator.captionThread.last?.isCurrent == true, "fresh playback did not mark the newest agent caption current")
        fake.emit(.captionStable(generation: "generation-1", speaker: "assistant", groupID: "assistant-2")); try await Task.sleep(for: .milliseconds(2))
        try check(coordinator.captionThread.last?.isCurrent == true, "caption stability hid authoritative active playback")
        fake.emit(.playbackActivity(generation: "generation-1", active: false)); try await Task.sleep(for: .milliseconds(2))
        try check(coordinator.captionThread.allSatisfy { !$0.isCurrent }, "inactive playback retained an agent current marker")
        fake.emit(.playbackActivity(generation: "generation-1", active: true)); try await Task.sleep(for: .milliseconds(2))
        fake.emit(.caption(generation: "generation-1", speaker: "assistant", delta: String(repeating: "x", count: 600), groupID: "assistant-2")); try await Task.sleep(for: .milliseconds(2))
        try check(coordinator.piCaption.count == 500, "agent caption aggregate exceeded the character bound")
        fake.emit(.caption(generation: "generation-1", speaker: "assistant", delta: "legacy", groupID: nil)); try await Task.sleep(for: .milliseconds(2))
        try check(coordinator.captionThread.last == .init(generation: "generation-1", speaker: .agent, text: "legacy", isCurrent: true), "authoritative playback activity did not apply to a group-less newest agent caption")
        fake.emit(.utterance(generation: "generation-1", text: "must not display")); try await Task.sleep(for: .milliseconds(2))
        try check(coordinator.captionThread.last?.text == "legacy", "task-routing utterance created a second caption path")
        fake.emit(.sessionEnded(message: "socket lost")); try await Task.sleep(for: .milliseconds(5))
        try check(coordinator.captionThread.isEmpty, "Unknown retained caption text")
        fake.emit(.caption(generation: "generation-1", speaker: "user", delta: "late", groupID: "late"))
        fake.emit(.captionStable(generation: "generation-1", speaker: "user", groupID: "late"))
        fake.emit(.playbackActivity(generation: "generation-1", active: true)); try await Task.sleep(for: .milliseconds(5))
        try check(coordinator.captionThread.isEmpty && coordinator.userCaption.isEmpty && coordinator.piCaption.isEmpty, "late Unknown caption events repopulated cleared buffers")

        let stoppingFake = FakeTransport(); stoppingFake.delayClose = true
        let (stopping, stoppingTarget) = try await connected(stoppingFake)
        try stopping.select(stoppingTarget); try await stopping.start(mode: .continuous, voice: .marin)
        stoppingFake.emit(.caption(generation: "generation-1", speaker: "user", delta: "before", groupID: "before")); try await Task.sleep(for: .milliseconds(2))
        let stopTask = Task { await stopping.stop() }; try await Task.sleep(for: .milliseconds(5))
        stoppingFake.emit(.caption(generation: "generation-1", speaker: "user", delta: "late", groupID: "late")); try await Task.sleep(for: .milliseconds(2))
        try check(stopping.captionThread.isEmpty && stopping.userCaption.isEmpty, "Stopping retained or accepted caption text after synchronous media teardown")
        await stopTask.value

        let pttFake = FakeTransport()
        let ptt = try await activePTT(pttFake)
        pttFake.emit(.caption(generation: "generation-1", speaker: "assistant", delta: "Speaking", groupID: "agent-ptt"))
        pttFake.emit(.playbackActivity(generation: "generation-1", active: true)); try await Task.sleep(for: .milliseconds(2))
        try check(ptt.captionThread.last?.isCurrent == true, "authorized PTT-idle playback lacked a current marker")
        try await ptt.beginPushToTalk()
        try check(ptt.captionThread.allSatisfy { !$0.isCurrent }, "PTT hold retained stale playback currentness")
        try await ptt.endPushToTalk()
        try check(ptt.captionThread.last?.isCurrent == true, "PTT release failed to restore still-current authorized playback")
        pttFake.emit(.peerConnectionState(
            authority: .init(revision: 1, peerIdentifier: "peer-1"),
            state: .disconnected
        )); try await Task.sleep(for: .milliseconds(2))
        try check(ptt.captionThread.allSatisfy { !$0.isCurrent }, "reconnecting media retained stale playback currentness")
    }

    @MainActor
    private static func pttMuteAuthority() async throws {
        let fake = FakeTransport()
        let coordinator = try await activePTT(fake)
        try coordinator.setUserMuted(true)
        try coordinator.beginPushToTalkFromHardwareEvent()
        try await Task.sleep(for: .milliseconds(5))
        try check(coordinator.pttHeld && coordinator.userMuted && !fake.microphone, "muted acknowledged PTT hold opened capture")
        try coordinator.setUserMuted(false)
        try check(fake.microphone, "unmuting an exact acknowledged hold did not apply the centralized gate")
        try coordinator.setUserMuted(true)
        try check(!fake.microphone && !fake.playback, "PTT mute failed to close only outbound capture during hold")
        try coordinator.endPushToTalkFromHardwareEvent(cancel: false)
        try await Task.sleep(for: .milliseconds(5))
        try check(!fake.microphone && fake.playback && fake.ptt.map(\.sequence) == [1, 2], "muted PTT release changed ACK order or reply playback")
        await coordinator.stop()
        try await coordinator.start(mode: .ptt, voice: .marin)
        try check(!coordinator.userMuted, "fresh Start persisted mute")
        try coordinator.beginPushToTalkFromHardwareEvent(); try await Task.sleep(for: .milliseconds(5))
        try check(fake.microphone, "fresh unmuted PTT Start failed its ACKed-hold gate")
    }

    @MainActor
    private static func focusLossCancelsPTTOnly() async throws {
        let fake = FakeTransport()
        let coordinator = try await activePTT(fake)
        try await coordinator.beginPushToTalk()
        await coordinator.suspendForFocusLoss()
        try check(!coordinator.pttHeld && !fake.microphone, "focus loss did not safely cancel the held PTT turn")
        try await Task.sleep(for: .milliseconds(20))
        try check(fake.playback, "focus-loss cancellation did not restore reply playback")
        try check(fake.ptt.last?.held == false && fake.ptt.last?.cancel == true, "focus loss sent the held PTT turn instead of cancelling it")
        try check(fake.closed.isEmpty, "focus loss terminated the active conversation")
    }

    @MainActor
    private static func freshPeerStartupReadiness() throws {
        var fence = MediaOwnershipFence(), readiness = PeerStartupReadiness()
        var counts = ProviderEventTypeCounts()
        let first = fence.begin()
        readiness.begin(first)
        readiness.observe(type: "session.started", revision: first)
        try check(!readiness.ready(first), "primary startup bypassed ICE gathering")
        readiness.iceGathered(first)
        try check(readiness.ready(first), "first fresh peer did not become ready")
        _ = counts.observe(type: "session.started")
        try check(counts.snapshot.observations.first?.type == "session.started", "primary startup report was missing before readiness")
        readiness.invalidate(); fence.invalidate()
        let second = fence.begin()
        readiness.begin(second); counts = ProviderEventTypeCounts()
        readiness.iceGathered(first); readiness.observe(type: "session.started", revision: first)
        try check(!readiness.ready(second) && !readiness.ready(first) && !fence.owns(first), "old peer callbacks activated the second conversation")
        readiness.iceGathered(second)
        readiness.observe(type: "session.output_transcript.delta", revision: second)
        try check(!readiness.ready(second) && counts.snapshot.observations.isEmpty, "ICE or old counters bypassed fresh primary startup")
        readiness.observe(type: "session.started", revision: second)
        _ = counts.observe(type: "session.started")
        try check(readiness.ready(second) && counts.snapshot.observations.first?.count == 1, "second peer reused startup counts")
        for cancelledStage in 0..<3 { // Before ICE, before primary, and after both: timeout/End/revocation.
            let revision = fence.begin(); readiness.begin(revision)
            if cancelledStage > 0 { readiness.iceGathered(revision) }
            if cancelledStage > 1 { readiness.observe(type: "session.started", revision: revision) }
            readiness.invalidate(); fence.invalidate()
            readiness.iceGathered(revision); readiness.observe(type: "session.started", revision: revision)
            try check(!readiness.ready(revision) && !fence.owns(revision), "late startup revived a cancelled peer")
        }
    }

    @MainActor
    private static func providerClosureReceipts() throws {
        func receipt(_ generation: String, active: Bool, state: String, count: Int) throws -> ProviderClosureDiagnostic {
            let data = try JSONSerialization.data(withJSONObject: ["current": ["generation": generation, "active": active, "control": ["state": state, "events": ["sessionClosed": count]]]])
            return try JSONDecoder().decode(ProviderClosureDiagnostic.self, from: data)
        }
        let confirmed = try receipt("g1", active: false, state: "closed", count: 1)
        try check(confirmed.confirmsClosure("g1"), "provider closure receipt was ignored")
        for value in [try receipt("g2", active: false, state: "closed", count: 1), try receipt("g1", active: true, state: "closing", count: 0), try receipt("g1", active: false, state: "closed", count: 0)] {
            try check(!value.confirmsClosure("g1"), "foreign, pending, or unknown closure allowed a handoff")
        }
    }

    @MainActor
    private static func idleTimeoutAndEndConfirmation() async throws {
        let fake = FakeTransport()
        let (coordinator, target) = try await connected(fake)
        coordinator.setIdleTimeoutMinutes(0)
        try check(coordinator.idleTimeoutMinutes == 1, "idle timeout minimum was not enforced")
        coordinator.setIdleTimeoutMinutes(99)
        try check(coordinator.idleTimeoutMinutes == 30, "idle timeout exceeded the hard session maximum")
        coordinator.setIdleTimeoutMinutes(7)
        try coordinator.select(target)
        try await coordinator.start(mode: .ptt, voice: .marin)
        try check(fake.startedIdleTimeouts == [7], "configured idle timeout did not reach the transport")
        let body = LiveSessionRequest(target: target, mode: .ptt, voice: .marin, idleTimeoutMinutes: 7).gatewayBody(sdp: "offer", connectionID: "abcdefghijklmnopqrstuv")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        try check(encoded?["idleTimeoutMinutes"] as? Int == 7, "idle timeout was not encoded as an integer")
        await coordinator.stop()
        try check(coordinator.lastEndConfirmed, "confirmed End did not permit fresh handoff")
        try await coordinator.start(mode: .ptt, voice: .marin)
        try coordinator.setUserMuted(true)
        fake.failClose = true
        let oldGeneration = coordinator.activeGeneration
        await coordinator.stop()
        guard let recoveryEpoch = coordinator.closureRecoveryEpoch else {
            throw CheckFailure.failed("unknown End did not retain exact closure-recovery scope")
        }
        try check(
            !coordinator.lastEndConfirmed && coordinator.lastEndGeneration == oldGeneration &&
                coordinator.activeGeneration == oldGeneration && coordinator.selected == target &&
                coordinator.continuousMicrophoneMuted && !fake.microphone && !fake.playback,
            "unknown End lost authority or selection, cleared Mute, or reopened media"
        )
        fake.closureReceiptResult = .providerClosed
        let closureConfirmed = try await coordinator.checkProviderClosure(epoch: recoveryEpoch)
        try check(closureConfirmed, "exact post-End closure proof was not accepted")
        try check(
            coordinator.phase == .ready && coordinator.lastEndConfirmed && coordinator.activeGeneration == nil &&
                coordinator.rosterConnected && fake.renewedOrigins.isEmpty,
            "exact post-End closure proof did not preserve the existing ready connection"
        )
        try await coordinator.start(mode: .ptt, voice: .marin)
        try check(fake.startedTargets.count == 3, "future explicit Start remained blocked after exact post-End closure proof")
    }

    @MainActor
    private static func postEndClosureRecoveryRaces() async throws {
        let successAfterLossFake = FakeTransport()
        let (successAfterLoss, successAfterLossTarget) = try await connected(successAfterLossFake)
        try successAfterLoss.select(successAfterLossTarget)
        try await successAfterLoss.start(mode: .continuous, voice: .marin)
        successAfterLossFake.delayClose = true
        let delayedSuccessfulEnd = Task { await successAfterLoss.stop() }
        try await Task.sleep(for: .milliseconds(10))
        successAfterLossFake.emit(.roster(connected: false, agents: []))
        await delayedSuccessfulEnd.value
        try await Task.sleep(for: .milliseconds(60)) // Let the roster-triggered exact End finish.
        try check(
            successAfterLoss.phase == .disconnected && !successAfterLoss.rosterConnected &&
                successAfterLoss.lastEndConfirmed && successAfterLoss.activeGeneration == nil &&
                !successAfterLossFake.microphone && !successAfterLossFake.playback,
            "successful End completion bypassed a concurrent roster-loss readiness fence"
        )

        let eventFirstFake = FakeTransport()
        let (eventFirst, eventFirstTarget) = try await connected(eventFirstFake)
        try eventFirst.select(eventFirstTarget)
        try await eventFirst.start(mode: .continuous, voice: .marin)
        eventFirstFake.delayClose = true
        eventFirstFake.failClose = true
        let delayedFailedEnd = Task { await eventFirst.stop() }
        try await Task.sleep(for: .milliseconds(10))
        eventFirstFake.emit(.voiceState(generation: "generation-1", state: "closed", reason: "provider_closed"))
        await delayedFailedEnd.value
        try check(
            eventFirst.phase == .ready && eventFirst.lastEndConfirmed && eventFirst.activeGeneration == nil &&
                eventFirst.closureRecoveryEpoch == nil && !eventFirstFake.microphone && !eventFirstFake.playback,
            "failed End HTTP completion overwrote an earlier exact provider-closed event"
        )

        let lostFake = FakeTransport()
        let (lost, lostTarget) = try await connected(lostFake)
        try lost.select(lostTarget)
        try await lost.start(mode: .continuous, voice: .marin)
        try lost.setContinuousMicrophoneMuted(true)
        lostFake.failClose = true
        await lost.stop()
        guard lost.closureRecoveryEpoch != nil else {
            throw CheckFailure.failed("failed End did not create the connection-loss race fixture")
        }
        lostFake.emit(.sessionEnded(message: "socket ended after failed End"))
        lostFake.emit(.voiceState(generation: "generation-1", state: "closed", reason: "provider_closed"))
        try await Task.sleep(for: .milliseconds(10))
        try check(
            lost.phase == .disconnected && lost.explicitReconnectRequired && lost.lastEndConfirmed &&
                lost.activeGeneration == nil && !lostFake.microphone && !lostFake.playback,
            "queued exact provider-closed event bypassed the connection-loss Reconnect fence or reopened media"
        )

        let rosterFake = FakeTransport()
        let (roster, rosterTarget) = try await connected(rosterFake)
        try roster.select(rosterTarget)
        try await roster.start(mode: .continuous, voice: .marin)
        rosterFake.failClose = true
        await roster.stop()
        let firstEpoch = try require(roster.closureRecoveryEpoch, "failed End lacked its first recovery epoch")
        rosterFake.closureReceiptResult = .providerClosed
        rosterFake.closureReceiptDelay = .milliseconds(50)
        let oldReceipt = Task { try await roster.checkProviderClosure(epoch: firstEpoch) }
        try await Task.sleep(for: .milliseconds(5))
        rosterFake.emit(.roster(connected: false, agents: []))
        try await Task.sleep(for: .milliseconds(10))
        let secondEpoch = try require(roster.closureRecoveryEpoch, "roster-loss End retry lacked a new recovery epoch")
        try check(secondEpoch != firstEpoch, "roster-loss End retry reused the old recovery epoch")
        let oldReceiptConfirmed = try await oldReceipt.value
        try check(
            !oldReceiptConfirmed && roster.activeGeneration == "generation-1" &&
                roster.closureRecoveryEpoch == secondEpoch && !roster.rosterConnected &&
                !rosterFake.microphone && !rosterFake.playback,
            "late old receipt crossed the roster-loss End retry or reopened media"
        )
        rosterFake.closureReceiptDelay = nil
        let currentReceiptConfirmed = try await roster.checkProviderClosure(epoch: secondEpoch)
        try check(
            currentReceiptConfirmed && roster.phase == .disconnected && roster.lastEndConfirmed &&
                roster.activeGeneration == nil && !rosterFake.microphone && !rosterFake.playback,
            "current exact receipt restored Ready after roster loss instead of requiring explicit Reconnect"
        )
    }

    @MainActor
    private static func playbackResumesBeforeReleaseAcknowledgement() async throws {
        let fake = FakeTransport()
        let coordinator = try await activePTT(fake)
        try await coordinator.beginPushToTalk()
        try check(!fake.playback, "playback must remain muted during a physical hold")
        fake.delayReleaseAcknowledgement = true
        try coordinator.endPushToTalkFromHardwareEvent(cancel: false)
        try check(!fake.microphone && fake.playback, "release waited for HTTP acknowledgement before restoring playback")
        try await Task.sleep(for: .milliseconds(70))
        try check(!fake.microphone && fake.playback, "late release acknowledgement changed media gates")
        await coordinator.stop()
    }

    @MainActor
    private static func hardwareReleaseBeforeAcknowledgement() async throws {
        let fake = FakeTransport()
        fake.delayHeldAcknowledgement = true
        let coordinator = try await activePTT(fake)
        try coordinator.beginPushToTalkFromHardwareEvent()
        try coordinator.endPushToTalkFromHardwareEvent(cancel: true)
        try check(!coordinator.pttHeld && !fake.microphone, "hardware release did not close local input synchronously")
        try await Task.sleep(for: .milliseconds(120))
        try check(fake.ptt.map(\.sequence) == [1, 2], "hardware PTT commands crossed or reordered")
        try check(fake.ptt.map(\.held) == [true, false] && fake.ptt.last?.cancel == true, "hardware chord did not finish as a cancelled turn")
        try check(!fake.microphone, "late hardware hold acknowledgement reopened capture")
    }

    @MainActor
    private static func pushToTalkGateAndGenerationFence() async throws {
        let fake = FakeTransport()
        let coordinator = try await activePTT(fake)
        try check(!fake.microphone && fake.playback, "idle PTT gates are wrong")
        try await coordinator.beginPushToTalk()
        try check(fake.microphone && !fake.playback, "capture opened before an accepted hold")
        try await coordinator.endPushToTalk()
        try check(!fake.microphone && fake.playback, "release did not restore liaison playback")
        try check(fake.ptt.map(\.sequence) == [1, 2], "PTT commands were not strictly sequenced")
        fake.emit(.pttReady(generation: "wrong")); try await Task.sleep(for: .milliseconds(10))
        try check(coordinator.pttFinishing, "stale generation changed PTT readiness")
        fake.emit(.pttReady(generation: "generation-1")); try await Task.sleep(for: .milliseconds(10))
        try check(!coordinator.pttFinishing, "matching readiness was ignored")
    }

    @MainActor
    private static func fastReleaseNeverReopensCapture() async throws {
        let fake = FakeTransport()
        fake.delayHeldAcknowledgement = true
        let coordinator = try await activePTT(fake)
        let press = Task { try await coordinator.beginPushToTalk() }
        try await Task.sleep(for: .milliseconds(10))
        try await coordinator.endPushToTalk()
        try await press.value
        try check(!fake.microphone, "fast release reopened capture after hold acknowledgement")
        try check(fake.ptt.map(\.sequence) == [1, 2], "fast release lost command order")
    }

    @MainActor
    private static func stopFencesPendingStart() async throws {
        let fake = FakeTransport()
        fake.delayStart = true
        let (coordinator, target) = try await connected(fake)
        try coordinator.select(target)
        let pending = Task { try await coordinator.start(mode: .ptt, voice: .marin) }
        try await Task.sleep(for: .milliseconds(10))
        await coordinator.stop()
        do { try await pending.value; throw CheckFailure.failed("stopped start became active") }
        catch is CancellationError {}
        try check(coordinator.phase == .ready && !fake.microphone && !fake.playback, "stale start completion clobbered Stop")
        try check(fake.closed == ["generation-1"], "stale started generation was not closed")
    }

    @MainActor
    private static func startupAuthorityRetention() async throws {
        let beforeFake = FakeTransport()
        beforeFake.failStartDefinitively = true
        beforeFake.emitSessionEndedBeforeDefinitiveFailure = true
        let (before, beforeTarget) = try await connected(beforeFake)
        try before.select(beforeTarget)
        do {
            try await before.start(mode: .continuous, voice: .marin)
            throw CheckFailure.failed("definitive stale Start succeeded after prior terminal event")
        } catch is URLError {}
        try check(
            before.phase == .disconnected && before.explicitReconnectRequired &&
                before.activeGeneration == nil && !before.hasUnknownStartAllocation,
            "terminal event before definitive stale failure did not expose explicit Reconnect without authority"
        )

        let afterFake = FakeTransport()
        afterFake.failStartDefinitively = true
        let (after, afterTarget) = try await connected(afterFake)
        try after.select(afterTarget)
        do {
            try await after.start(mode: .continuous, voice: .marin)
            throw CheckFailure.failed("definitive stale Start succeeded before terminal event")
        } catch is URLError {}
        try check(after.phase == .ready, "definitive preallocation failure guessed transport loss before its terminal event")
        afterFake.emit(.sessionEnded(message: "definitive stale connection"))
        try await Task.sleep(for: .milliseconds(5))
        try check(
            after.phase == .disconnected && after.explicitReconnectRequired &&
                after.activeGeneration == nil && !after.hasUnknownStartAllocation,
            "terminal event after definitive stale failure retained Ready or invented authority"
        )

        let allocatedFake = FakeTransport(); allocatedFake.failStartAfterAllocation = true
        let (allocated, target) = try await connected(allocatedFake)
        try allocated.select(target)
        do { try await allocated.start(mode: .continuous, voice: .marin); throw CheckFailure.failed("post-allocation failure was accepted") }
        catch is RetainedVoiceStartAuthority {}
        guard case .uncertain = allocated.phase, let epoch = allocated.closureRecoveryEpoch else {
            throw CheckFailure.failed("post-allocation failure did not retain Unknown authority")
        }
        try check(allocated.activeGeneration == "generation-1" && allocated.hasProviderClosureRecoveryScope(epoch: epoch), "allocated startup generation lost its exact recovery scope")
        allocatedFake.failClose = true
        await allocated.disconnect()
        try check(allocated.activeGeneration == "generation-1" && allocated.phase != .disconnected, "Disconnect erased retained startup authority")
        do {
            try await allocated.forgetSavedDevice(origin: URL(string: "https://voice.example.test")!)
            throw CheckFailure.failed("Forget deleted credentials while startup authority was retained")
        } catch VoiceFailure.callAlreadyActive {}
        try check(allocatedFake.forgottenOrigins.isEmpty, "Forget mutated credentials while authority remained Unknown")

        let canceledFake = FakeTransport(); canceledFake.delayStart = true; canceledFake.failClose = true
        let (canceled, canceledTarget) = try await connected(canceledFake)
        try canceled.select(canceledTarget)
        let pending = Task { try await canceled.start(mode: .continuous, voice: .marin) }
        try await Task.sleep(for: .milliseconds(10)); canceled.interruptPendingStart()
        do { try await pending.value; throw CheckFailure.failed("canceled allocated Start succeeded") }
        catch is RetainedVoiceStartAuthority {}
        guard case .uncertain = canceled.phase else { throw CheckFailure.failed("canceled allocated Start with unconfirmed close did not retain Unknown") }
        try check(canceled.activeGeneration == "generation-1" && !canceledFake.microphone && !canceledFake.playback, "canceled startup discarded authority or retained media")

        let socketFake = FakeTransport(); socketFake.delayStart = true; socketFake.failClose = true
        let (socketRace, socketTarget) = try await connected(socketFake)
        try socketRace.select(socketTarget)
        let racing = Task { try await socketRace.start(mode: .continuous, voice: .marin) }
        try await Task.sleep(for: .milliseconds(10)); socketFake.emit(.sessionEnded(message: "socket lost during Start"))
        do { try await racing.value; throw CheckFailure.failed("socket-loss Start became active") }
        catch is RetainedVoiceStartAuthority {}
        guard case .uncertain = socketRace.phase else { throw CheckFailure.failed("socket-loss allocation did not retain Unknown") }
        try check(
            socketRace.activeGeneration == "generation-1" && socketRace.closureRecoveryEpoch != nil &&
                socketRace.explicitReconnectRequired,
            "socket-loss allocation lost exact closure authority or explicit-reconnect fence"
        )

        let destructiveFake = FakeTransport(); destructiveFake.delayStart = true; destructiveFake.failClose = true
        let (destructive, destructiveTarget) = try await connected(destructiveFake)
        let originalOrigin = URL(string: "https://voice.example.test")!
        try destructive.select(destructiveTarget)
        let delayedAllocation = Task { try await destructive.start(mode: .continuous, voice: .marin) }
        try await Task.sleep(for: .milliseconds(10))
        await destructive.disconnect()
        do { try await destructive.forgetSavedDevice(origin: originalOrigin); throw CheckFailure.failed("Forget crossed a pending Start") }
        catch VoiceFailure.callAlreadyActive {}
        do { try await destructive.reconnectSavedDevice(origin: URL(string: "https://replacement.example.test")!); throw CheckFailure.failed("new auth crossed a pending Start") }
        catch VoiceFailure.callAlreadyActive {}
        do { try await delayedAllocation.value; throw CheckFailure.failed("Disconnect allowed delayed allocation to activate") }
        catch is RetainedVoiceStartAuthority {}
        guard let destructiveEpoch = destructive.closureRecoveryEpoch else { throw CheckFailure.failed("pending Disconnect lost allocated recovery scope") }
        _ = try await destructive.checkProviderClosure(epoch: destructiveEpoch)
        try check(destructiveFake.closureReceiptQueries.last?.0 == originalOrigin, "pending Disconnect rebound allocation to a new or empty origin")
        try check(destructiveFake.forgottenOrigins.isEmpty, "pending Forget deleted saved authorization")

        let unknownFake = FakeTransport(); unknownFake.delayStart = true; unknownFake.failStartWithUnknownAllocation = true
        let (unknown, unknownTarget) = try await connected(unknownFake)
        try unknown.select(unknownTarget)
        let unknownRequest = Task { try await unknown.start(mode: .continuous, voice: .marin) }
        try await Task.sleep(for: .milliseconds(10))
        unknown.interruptPendingStart()
        unknown.abandonLocally() // exact production sleep sequence must not clear original authority scope
        do { try await unknown.reconnectSavedDevice(origin: originalOrigin); throw CheckFailure.failed("wake auth crossed unknown pending Start") }
        catch VoiceFailure.callAlreadyActive {}
        do { try await unknownRequest.value; throw CheckFailure.failed("unknown allocation outcome became Ready") }
        catch is UnknownVoiceStartAllocation {}
        guard case .uncertain = unknown.phase else { throw CheckFailure.failed("unknown allocation outcome did not remain blocked") }
        try check(unknown.hasUnknownStartAllocation && unknown.activeGeneration == nil, "unknown allocation guessed or discarded generation authority")
        await unknown.disconnect()
        do { try await unknown.forgetSavedDevice(origin: originalOrigin); throw CheckFailure.failed("Forget crossed unknown allocation authority") }
        catch VoiceFailure.callAlreadyActive {}
        try check(unknown.hasUnknownStartAllocation && unknownFake.forgottenOrigins.isEmpty, "unknown allocation was destructively cleared")
        unknownFake.emit(.sessionEnded(message: "terminal transport event")); try await Task.sleep(for: .milliseconds(5))
        unknown.abandonLocally()
        try check(unknown.hasUnknownStartAllocation && unknown.activeTarget == unknownTarget && unknown.retainsAuthorityOrigin(originalOrigin), "session-ended then sleep erased unknown startup origin/target")
        do { try await unknown.reconnectSavedDevice(origin: originalOrigin); throw CheckFailure.failed("session-ended unknown authority allowed wake auth") }
        catch VoiceFailure.callAlreadyActive {}
        do { try await unknown.start(mode: .continuous, voice: .marin); throw CheckFailure.failed("session-ended unknown authority allowed Start") }
        catch VoiceFailure.notReady {}
        do { try await unknown.forgetSavedDevice(origin: originalOrigin); throw CheckFailure.failed("session-ended unknown authority allowed Forget") }
        catch VoiceFailure.callAlreadyActive {}

        let revokedFake = FakeTransport(); revokedFake.failStartWithUnknownAllocation = true
        let (revoked, revokedTarget) = try await connected(revokedFake)
        try revoked.select(revokedTarget)
        do { try await revoked.start(mode: .continuous, voice: .marin); throw CheckFailure.failed("revoked fixture did not enter unknown allocation") }
        catch is UnknownVoiceStartAllocation {}
        revokedFake.emit(.deviceRevoked(credentialCleared: true)); try await Task.sleep(for: .milliseconds(5)); revoked.abandonLocally()
        try check(revoked.hasUnknownStartAllocation && revoked.activeTarget == revokedTarget && revoked.retainsAuthorityOrigin(originalOrigin), "device revocation then sleep erased unknown startup authority")
        do { try await revoked.reconnectSavedDevice(origin: originalOrigin); throw CheckFailure.failed("revoked unknown authority allowed wake auth") }
        catch VoiceFailure.callAlreadyActive {}
        do { try await revoked.forgetSavedDevice(origin: originalOrigin); throw CheckFailure.failed("revoked unknown authority allowed Forget") }
        catch VoiceFailure.callAlreadyActive {}

        let rosterFake = FakeTransport(); rosterFake.failStartWithUnknownAllocation = true
        let (rosterLoss, rosterTarget) = try await connected(rosterFake)
        try rosterLoss.select(rosterTarget)
        do { try await rosterLoss.start(mode: .continuous, voice: .marin); throw CheckFailure.failed("roster fixture did not enter unknown allocation") }
        catch is UnknownVoiceStartAllocation {}
        rosterFake.emit(.roster(connected: true, agents: [])); try await Task.sleep(for: .milliseconds(5)); rosterLoss.abandonLocally()
        guard case .uncertain = rosterLoss.phase else { throw CheckFailure.failed("roster loss moved unknown allocation into Stopping") }
        try check(rosterLoss.hasUnknownStartAllocation && rosterLoss.activeTarget == rosterTarget && rosterLoss.retainsAuthorityOrigin(originalOrigin), "roster loss then sleep erased unknown startup authority")
        do { try await rosterLoss.reconnectSavedDevice(origin: originalOrigin); throw CheckFailure.failed("roster-loss unknown authority allowed wake auth") }
        catch VoiceFailure.callAlreadyActive {}
        do { try await rosterLoss.start(mode: .continuous, voice: .marin); throw CheckFailure.failed("roster-loss unknown authority allowed Start") }
        catch VoiceFailure.notReady {}
        do { try await rosterLoss.forgetSavedDevice(origin: originalOrigin); throw CheckFailure.failed("roster-loss unknown authority allowed Forget") }
        catch VoiceFailure.callAlreadyActive {}
    }

    @MainActor
    private static func uncertainReleaseStillStops() async throws {
        let fake = FakeTransport()
        let coordinator = try await activePTT(fake)
        try await coordinator.beginPushToTalk()
        fake.failPTT = true
        do { try await coordinator.endPushToTalk(); throw CheckFailure.failed("release failure was swallowed") }
        catch is URLError {}
        try check(!fake.microphone && !fake.playback, "uncertain release did not fail closed")
        await coordinator.stop()
        try check(
            fake.closed == ["generation-1"] && coordinator.lastEndConfirmed && coordinator.lastError == nil,
            "confirmed Stop lost the active generation or retained a stale uncertainty warning"
        )
    }

    @MainActor
    private static func staleRosterStopsPinnedGeneration() async throws {
        let fake = FakeTransport()
        let coordinator = try await activePTT(fake)
        fake.emit(.roster(connected: true, agents: [
            AgentTarget(id: "agent", endpointEpoch: "replacement", name: "Research", cwd: "/repo"),
        ]))
        try await Task.sleep(for: .milliseconds(30))
        try check(fake.closed == ["generation-1"], "endpoint replacement did not stop the pinned generation")
        try check(coordinator.selected == nil, "endpoint replacement retained stale selection")
    }
}

private enum CredentialTestFailure: Error { case writeFailed }

private final class MemoryCredentialStore: DeviceCredentialStore, @unchecked Sendable {
    var value: DeviceCredential?
    func load(origin: String) throws -> DeviceCredential? { value?.origin == origin ? value : nil }
    func save(_ credential: DeviceCredential) throws { value = credential }
    func delete(origin: String) throws { if value?.origin == origin { value = nil } }
}

private final class FailingCredentialStore: DeviceCredentialStore, @unchecked Sendable {
    var saveAttempts: [DeviceCredential] = []
    func load(origin: String) throws -> DeviceCredential? { nil }
    func save(_ credential: DeviceCredential) throws {
        saveAttempts.append(credential)
        throw CredentialTestFailure.writeFailed
    }
    func delete(origin: String) throws {}
}

@MainActor
private final class FakeTransport: VoiceTransport {
    struct PTT {
        let sequence: Int
        let held: Bool
        let cancel: Bool
    }

    let events: AsyncStream<VoiceGatewayEvent>
    private let continuation: AsyncStream<VoiceGatewayEvent>.Continuation
    var startedTargets: [AgentTarget] = []
    var startedRoutings: [ConversationRouting] = []
    var ptt: [PTT] = []
    var closed: [String] = []
    var mediaReady: [String] = []
    var microphone = false
    var playback = false
    var playbackGain = 1.0
    var delayHeldAcknowledgement = false
    var delayReleaseAcknowledgement = false
    var failClose = false
    var delayClose = false
    var failStartAfterAllocation = false
    var failStartWithUnknownAllocation = false
    var failStartDefinitively = false
    var emitSessionEndedBeforeDefinitiveFailure = false
    var failMediaReady = false
    var startedIdleTimeouts: [Int] = []
    var delayStart = false
    var delayConnect = false
    var failPTT = false
    var renewedOrigins: [URL] = []
    var renewFailuresRemaining = 0
    var forgottenOrigins: [URL] = []
    var closureReceiptResult: ProviderClosureReceiptResult = .unconfirmed
    var closureReceiptDelay: Duration?
    var closureReceiptIgnoresCancellation = false
    var closureReceiptThrowsDefinitive = false
    var closureReceiptQueries: [(URL, String)] = []
    var closureReceiptMutationChecks: [Bool] = []
    var disconnectCount = 0

    init() {
        let pair = AsyncStream<VoiceGatewayEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func emit(_ event: VoiceGatewayEvent) { continuation.yield(event) }
    func pair(origin: URL, token: String, deviceName: String) async throws {}
    func renew(origin: URL) async throws {
        renewedOrigins.append(origin)
        if renewFailuresRemaining > 0 {
            renewFailuresRemaining -= 1
            throw URLError(.cannotConnectToHost)
        }
    }
    func hasSavedDevice(origin: URL) throws -> Bool { true }
    func forgetSavedDevice(origin: URL) throws { forgottenOrigins.append(origin) }
    func providerClosureReceipt(
        origin: URL,
        generation: String,
        mayMutateCredential: @escaping @MainActor () -> Bool
    ) async throws -> ProviderClosureReceiptResult {
        closureReceiptQueries.append((origin, generation))
        if let closureReceiptDelay {
            do { try await Task.sleep(for: closureReceiptDelay) }
            catch where closureReceiptIgnoresCancellation { }
        }
        closureReceiptMutationChecks.append(mayMutateCredential())
        if closureReceiptThrowsDefinitive { throw CheckFailure.failed("definitive credential rejection") }
        return closureReceiptResult
    }
    func connectEvents(origin: URL) async throws {
        if delayConnect { try await Task.sleep(for: .milliseconds(50)) }
    }
    func disconnectEvents() { disconnectCount += 1 }
    func start(target: AgentTarget, mode: VoiceMode, voice: VoiceName, routing: ConversationRouting, idleTimeoutMinutes: Int) async throws -> SessionAuthority {
        startedTargets.append(target)
        startedIdleTimeouts.append(idleTimeoutMinutes)
        startedRoutings.append(routing)
        if delayStart { try await Task.sleep(for: .milliseconds(50)) }
        if failStartDefinitively {
            if emitSessionEndedBeforeDefinitiveFailure {
                continuation.yield(.sessionEnded(message: "definitive stale connection"))
                try await Task.sleep(for: .milliseconds(5))
            }
            throw URLError(.cannotConnectToHost)
        }
        if failStartWithUnknownAllocation {
            throw UnknownVoiceStartAllocation(message: "fake unknown startup allocation")
        }
        let allocated = SessionAuthority(
            generation: "generation-\(startedTargets.count)",
            idleDeadline: .now.addingTimeInterval(300),
            hardDeadline: .now.addingTimeInterval(7_200),
            peerAuthority: .init(revision: startedTargets.count, peerIdentifier: "peer-\(startedTargets.count)"),
            initialPeerState: .connected
        )
        if failStartAfterAllocation {
            throw RetainedVoiceStartAuthority(
                authority: allocated,
                message: "fake post-allocation startup failure"
            )
        }
        return allocated
    }
    func announceMediaReady(generation: String) async throws {
        mediaReady.append(generation)
        if failMediaReady { throw URLError(.networkConnectionLost) }
    }
    func sendPushToTalk(generation: String, held: Bool, cancel: Bool, commandSequence: Int) async throws {
        ptt.append(.init(sequence: commandSequence, held: held, cancel: cancel))
        if held, delayHeldAcknowledgement { try await Task.sleep(for: .milliseconds(50)) }
        if !held, delayReleaseAcknowledgement { try await Task.sleep(for: .milliseconds(50)) }
        if failPTT { throw URLError(.networkConnectionLost) }
    }
    func close(generation: String) async throws {
        closed.append(generation)
        if delayClose { try await Task.sleep(for: .milliseconds(50)) }
        if failClose { throw CheckFailure.failed("Provider closure unconfirmed") }
    }
    func setMicrophoneEnabled(_ enabled: Bool) { microphone = enabled }
    func setPlaybackEnabled(_ enabled: Bool) { playback = enabled }
    func setPlaybackGain(_ gain: Double) { playbackGain = gain }
    func teardownMedia() { microphone = false; playback = false }
}

private final class SilentLoopbackHTTPServer: @unchecked Sendable {
    let url: URL
    private let listener: Int32
    private let lock = NSLock()
    private var client: Int32 = -1
    private var stopped = false

    init() throws {
        let listenerFD = socket(AF_INET, SOCK_STREAM, 0)
        listener = listenerFD
        guard listenerFD >= 0 else { throw CheckFailure.failed("could not create loopback timeout fixture") }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listenerFD, 1) == 0 else {
            Darwin.close(listenerFD)
            throw CheckFailure.failed("could not bind loopback timeout fixture")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenerFD, $0, &length)
            }
        }
        guard nameResult == 0,
              let url = URL(string: "http://127.0.0.1:\(Int(UInt16(bigEndian: bound.sin_port)))/renew") else {
            Darwin.close(listenerFD)
            throw CheckFailure.failed("could not address loopback timeout fixture")
        }
        self.url = url

        DispatchQueue.global(qos: .utility).async { [self] in
            let accepted = Darwin.accept(listener, nil, nil)
            lock.lock()
            if stopped {
                lock.unlock()
                if accepted >= 0 { Darwin.close(accepted) }
                return
            }
            client = accepted
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let accepted = client
        client = -1
        lock.unlock()
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        if accepted >= 0 {
            Darwin.shutdown(accepted, SHUT_RDWR)
            Darwin.close(accepted)
        }
    }

    deinit { stop() }
}
