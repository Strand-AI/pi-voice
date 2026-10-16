import Foundation
import PiVoiceCore

private enum CheckFailure: Error, CustomStringConvertible, LocalizedError {
    case failed(String)
    var description: String { switch self { case let .failed(message): message } }
    var errorDescription: String? { description }
}

@MainActor
private final class TestMonotonicClock {
    var now: UInt64
    init(now: UInt64) { self.now = now }
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

@main
struct CoreChecks {
    @MainActor
    static func main() async throws {
        try durableCredentialContract()
        try lastAgentSelectionContract()
        try voiceNavigationRouteContract()
        try liveActivityControlAuthorityContract()
        try deferredStartupReconnectContract()
        try boundedCaptionContract()
        try boundedCaptionThreadContract()
        try liveActivityReconciliationContract()
        try callKitAttemptPolicyContract()
        try callKitMuteIntentLedgerContract()
        try await automaticConnectionRetryContract()
        try startupReadinessContract()
        try peerConnectionRecoveryContract()
        try await gatewayDeviceAuthenticatorContract()
        try await staleConnectFencing()
        try await sessionEndedAllowsReconnect()
        try await exactProviderClosureRecovery()
        try providerClosureRecoveryBudget()
        try await automaticNetworkRecoveryEligibility()
        try await peerConnectionRecoveryWiring()
        try await oneShotGreetingReadiness()
        try await externalAudioAuthorizationContract()
        try await durableReconnectAndRevocation()
        try await exactEpochAndContinuousStart()
        try await pttReleaseHasNoClientFlush()
        try await fastReleaseNeverOpensCaptureAfterAcknowledgement()
        try await stopFencesPendingStart()
        try await startupAllocationRetentionContract()
        try await uncertainReleaseCanStillClose()
        try await backgroundLifecyclePolicy()
        try await audioInterruptionAndRouteSafety()
        try await userMuteAuthority()
        try await mediaAndCaptionPresentationContract()
        print("PiVoiceCoreChecks: 32 passed")
    }

    @MainActor
    private static func lastAgentSelectionContract() throws {
        let suite = "PiVoiceCoreChecks.LastAgent.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure.failed("could not create isolated defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LastAgentSelectionHintStore(defaults: defaults, key: "hint")
        try store.save(origin: "https://voice.example.test", agentID: "stable-agent")
        try require(store.load(forOrigin: "https://voice.example.test")?.agentID == "stable-agent", "exact-origin stable ID was not saved")
        try require(store.load(forOrigin: "https://other.example.test") == nil, "selection hint crossed origins")

        let fresh = AgentEndpoint(id: "stable-agent", endpointEpoch: "fresh-epoch", name: "Agent")
        var restoration = LastAgentSelectionRestoration()
        restoration.begin(after: 10)
        try require(restoration.candidate(hint: store.load(forOrigin: "https://voice.example.test"), origin: "https://voice.example.test", phase: .ready, rosterConnected: true, rosterRevision: 10, agents: [fresh], selected: nil) == nil, "same roster revision restored stale endpoint authority")
        try require(restoration.candidate(hint: store.load(forOrigin: "https://voice.example.test"), origin: "https://voice.example.test", phase: .disconnected, rosterConnected: true, rosterRevision: 11, agents: [fresh], selected: nil) == nil, "disconnected state restored a selection")
        try require(restoration.candidate(hint: store.load(forOrigin: "https://voice.example.test"), origin: "https://voice.example.test", phase: .ready, rosterConnected: true, rosterRevision: 12, agents: [fresh], selected: nil)?.identityKey == fresh.identityKey, "fresh roster did not bind the new endpoint epoch")

        restoration.begin(after: 12)
        let sameNameReplacement = AgentEndpoint(id: "different-agent", endpointEpoch: "other-epoch", name: "Agent")
        try require(restoration.candidate(hint: store.load(forOrigin: "https://voice.example.test"), origin: "https://voice.example.test", phase: .ready, rosterConnected: true, rosterRevision: 13, agents: [sameNameReplacement], selected: nil) == nil, "same-name replacement inherited stable-ID authority")
        restoration.begin(after: 13); restoration.cancel()
        try require(restoration.candidate(hint: store.load(forOrigin: "https://voice.example.test"), origin: "https://voice.example.test", phase: .ready, rosterConnected: true, rosterRevision: 14, agents: [fresh], selected: nil) == nil, "manual nil did not cancel restoration")
        store.clear(forOrigin: "https://voice.example.test")
        try require(store.load(forOrigin: "https://voice.example.test") == nil, "forget did not clear the exact-origin hint")
    }

    @MainActor
    private static func voiceNavigationRouteContract() throws {
        try require(VoiceNavigationRoute(url: URL(string: "pivoice://live")!) == .live, "exact navigation-only Live Activity URL was rejected")
        for value in [
            "pivoice://live/end", "pivoice://live?generation=secret", "pivoice://live#mute",
            "pivoice://user@live", "pivoice://live:443", "https://live", "pivoice://other"
        ] {
            try require(VoiceNavigationRoute(url: URL(string: value)!) == nil, "navigation parser accepted action or authority components: \(value)")
        }
    }

    @MainActor
    private static func liveActivityControlAuthorityContract() throws {
        var authority = LiveActivityControlAuthority()
        authority.bind(ticket: "ticket-one", generation: "generation-one", activityID: "activity-one")
        try require(authority.matches(ticket: "ticket-one", currentGeneration: "generation-one", currentActivityID: "activity-one"), "exact Live Activity control authority was rejected")
        try require(!authority.matches(ticket: "ticket-old", currentGeneration: "generation-one", currentActivityID: "activity-one"), "stale activity ticket was accepted")
        try require(!authority.matches(ticket: "ticket-one", currentGeneration: "generation-two", currentActivityID: "activity-one"), "activity control crossed generations")
        try require(!authority.matches(ticket: "ticket-one", currentGeneration: "generation-one", currentActivityID: "activity-two"), "activity control crossed activity identities")
        authority.clear()
        try require(!authority.matches(ticket: "ticket-one", currentGeneration: "generation-one", currentActivityID: "activity-one"), "ended activity retained control authority")
    }

    @MainActor
    private static func deferredStartupReconnectContract() throws {
        var coldBackground = DeferredStartupReconnect(launchedInBackground: true)
        try require(!coldBackground.claimAtInitialization(eligible: true), "background Live Activity intent launch started authorization")
        try require(!coldBackground.claimOnForeground(eligible: false), "foreground without safe disconnected authority consumed recovery")
        try require(coldBackground.claimOnForeground(eligible: true), "actual foreground did not perform one deferred authorization recovery")
        try require(!coldBackground.claimOnForeground(eligible: true), "subsequent foreground repeated startup authorization")

        var ordinaryForeground = DeferredStartupReconnect(launchedInBackground: false)
        try require(ordinaryForeground.claimAtInitialization(eligible: true), "ordinary foreground launch did not recover saved authorization")
        try require(!ordinaryForeground.claimOnForeground(eligible: true), "ordinary launch repeated authorization on scene activation")
    }

    @MainActor
    private static func boundedCaptionContract() throws {
        var caption = BoundedCaption(characterLimit: 5, utf8ByteLimit: 32)
        caption.append("ab")
        caption.append("cdef")
        try require(caption.text == "bcdef", "caption append exceeded or misplaced its recent window")
        caption.append("👨‍👩‍👧‍👦🙂🙃😉😊😇")
        try require(caption.text == "🙂🙃😉😊😇" && caption.text.count == 5, "caption limit split a grapheme cluster")
        try require(caption.text.utf8.count <= 32, "caption exceeded its UTF-8 memory bound")
        caption.replace(with: "0123456789")
        try require(caption.text == "56789", "caption replacement was not bounded")

        var giant = BoundedCaption(characterLimit: 500, utf8ByteLimit: 64)
        giant.append("kept")
        giant.append("a" + String(repeating: "\u{0301}", count: 10_000))
        try require(giant.text == "kept", "one oversized grapheme was retained or split")
        giant.append("z")
        for _ in 0..<1_000 { giant.append("\u{0301}") }
        try require(giant.text.utf8.count <= 64 && giant.text.count <= 500, "cross-delta combining marks escaped the byte bound")
        giant.append("🙂🙃")
        try require(giant.text.hasSuffix("🙂🙃") && giant.text.utf8.count <= 64, "byte trimming split or lost bounded emoji graphemes")

        caption.clear()
        try require(caption.text.isEmpty, "caption clear retained session text")
    }

    @MainActor
    private static func callKitMuteIntentLedgerContract() throws {
        let call = UUID()
        var policy = CallKitAttemptPolicy(providerEpoch: 7)
        guard let attempt = policy.beginAttempt(callUUID: call, targetID: "agent", targetEpoch: "epoch") else {
            throw CheckFailure.failed("mute-ledger attempt was rejected")
        }
        _ = policy.acceptStartAction(callUUID: call, providerEpoch: 7)

        var reusable = CallKitMuteIntentLedger(capacity: 32)
        for index in 0..<300 {
            guard case let .request(request) = policy.requestMuted(false) else {
                throw CheckFailure.failed("normal reusable Unmute request \(index) was rejected")
            }
            let action = UUID()
            try require(reusable.issueApp(actionUUID: action, callUUID: call, providerEpoch: 7, request: request),
                        "normal terminal cycle exhausted the bounded ledger")
            try require(reusable.retirePerformed(actionUUID: action, providerEpoch: 7) != nil && reusable.count == 0,
                        "normal fulfill/fail evidence did not free its slot")
            policy.forceMutedSupersedingPendingRequest()
        }

        var bounded = CallKitMuteIntentLedger(capacity: 32)
        var issued: [(UUID, CallKitAttemptPolicy.MuteRequest)] = []
        for _ in 0..<32 {
            guard case let .request(request) = policy.requestMuted(false) else {
                throw CheckFailure.failed("bounded Unmute request was rejected")
            }
            let action = UUID()
            try require(bounded.issueApp(actionUUID: action, callUUID: call, providerEpoch: 7, request: request),
                        "ledger rejected one of its 32 bounded records")
            issued.append((action, request))
        }
        guard case let .request(overflowRequest) = policy.requestMuted(false) else {
            throw CheckFailure.failed("overflow request was not minted for the capacity check")
        }
        try require(!bounded.issueApp(actionUUID: UUID(), callUUID: call, providerEpoch: 7, request: overflowRequest),
                    "33rd unresolved action exceeded bounded capacity")
        _ = bounded.retirePerformed(actionUUID: issued[0].0, providerEpoch: 7)
        try require(bounded.issueApp(actionUUID: UUID(), callUUID: call, providerEpoch: 7, request: overflowRequest),
                    "terminal evidence did not allow a fresh explicit gesture")

        let timedOutAction = issued[1].0
        let timedOutRequest = issued[1].1
        try require(bounded.quarantineTimeout(
            actionUUID: timedOutAction,
            callUUID: call,
            providerEpoch: 7,
            muted: false
        )?.state == .timedOut, "actual app timeout was not quarantined")
        try require(bounded.record(actionUUID: timedOutAction, providerEpoch: 7)?.appRequest == timedOutRequest,
                    "late timed-out old Unmute lost correlation and could become native")
        try require(bounded.retireDefiniteSubmissionFailure(actionUUID: timedOutAction, providerEpoch: 7) == nil &&
                    bounded.record(actionUUID: timedOutAction, providerEpoch: 7)?.state == .timedOut,
                    "late request error erased an already-observed timeout")
        try require(bounded.retireCompleted(actionUUID: timedOutAction, providerEpoch: 8) == nil,
                    "stale provider epoch retired a quarantined action")
        var nativeQuarantine = CallKitMuteIntentLedger(capacity: 2)
        let nativeTimeout = UUID()
        try require(nativeQuarantine.quarantineTimeout(
            actionUUID: nativeTimeout,
            callUUID: call,
            providerEpoch: 7,
            muted: false
        )?.origin == .native(muted: false),
                    "genuine native timeout UUID was not quarantined")
        try require(nativeQuarantine.record(actionUUID: nativeTimeout, providerEpoch: 7)?.state == .timedOut,
                    "late native timed-out Unmute could be reclassified as fresh native")
        guard case let .request(nativeCapacityRequest) = policy.requestMuted(false) else {
            throw CheckFailure.failed("native-timeout capacity request was rejected")
        }
        try require(nativeQuarantine.issueApp(
            actionUUID: UUID(),
            callUUID: call,
            providerEpoch: 7,
            request: nativeCapacityRequest
        ), "native-timeout ledger could not fill its second slot")
        try require(nativeQuarantine.quarantineTimeout(
            actionUUID: UUID(),
            callUUID: call,
            providerEpoch: 7,
            muted: false
        ) == nil, "unrepresentable unknown timeout exceeded the hard bound")

        let retainedCount = bounded.count
        try require(bounded.retireRegistration(providerEpoch: 8).isEmpty && bounded.count == retainedCount,
                    "stale provider reset affected the current registration")
        try require(!bounded.retireRegistration(providerEpoch: 7).isEmpty && bounded.count == 0,
                    "exact reset/rotation did not retire registration-scoped records")

        guard case let .request(oldUnmute) = policy.requestMuted(false),
              case let .gateOutboundAndRequest(newerMute) = policy.requestMuted(true) else {
            throw CheckFailure.failed("superseded timeout policy intents were not minted")
        }
        try require(policy.userMuted, "newer Mute did not gate before old timeout")
        // A superseded old timeout only quarantines correlation; it must not
        // complete the older request or overwrite the newer Mute.
        try require(policy.completeMuteRequest(newerMute, accepted: true) == .acceptedMuted && policy.userMuted,
                    "superseded old timeout overrode the newer Mute")
        try require(policy.completeMuteRequest(oldUnmute, accepted: true) == .reject && policy.userMuted,
                    "old timed-out Unmute later reopened mute authority")
        _ = attempt
    }

    @MainActor
    private static func callKitAttemptPolicyContract() throws {
        let call = UUID()
        let replacementCall = UUID()
        let peer = PeerConnectionAuthority(revision: 7, peerIdentifier: "peer-7")
        let binding = CallKitAttemptPolicy.SessionBinding(generation: "generation-7", peerAuthority: peer)
        var policy = CallKitAttemptPolicy(providerEpoch: 41)

        guard let attempt = policy.beginAttempt(callUUID: call, targetID: "agent-id", targetEpoch: "endpoint-epoch") else {
            throw CheckFailure.failed("explicit outgoing attempt was rejected")
        }
        try require(policy.didActivate(providerEpoch: 40) == .none, "old immutable provider bridge epoch activated replacement media")
        try require(policy.didActivate(providerEpoch: 41) == .none, "untagged activation was attributed before the Start action")
        try require(policy.acceptStartAction(callUUID: replacementCall, providerEpoch: 41) == .reject, "replacement UUID accepted another call's Start action")
        try require(policy.acceptStartAction(callUUID: call, providerEpoch: 41) == .fulfillPromptly(attemptEpoch: attempt.attemptEpoch), "exact Start action was not prompt")
        try require(policy.acceptStartAction(callUUID: call, providerEpoch: 41) == .reject, "Start action completion was reusable")

        try require(policy.didActivate(providerEpoch: 41) == .latchOnly, "early CallKit activation was not latched at attempt scope")
        try require(policy.bindSession(attemptEpoch: attempt.attemptEpoch, generation: binding.generation, peerAuthority: peer) == .none, "audio opened before primary readiness")
        try require(policy.markPrimaryReady(attemptEpoch: attempt.attemptEpoch + 1, generation: binding.generation, peerAuthority: peer) == .none, "stale attempt marked the primary ready")
        try require(policy.markPrimaryReady(attemptEpoch: attempt.attemptEpoch, generation: binding.generation, peerAuthority: peer) == .enableExact(binding), "exact activation/session/peer/primary conjunction did not enable media")
        let replacementPeer = PeerConnectionAuthority(revision: 8, peerIdentifier: "peer-8")
        try require(policy.bindSession(attemptEpoch: attempt.attemptEpoch, generation: "replacement-generation", peerAuthority: peer) == .none && policy.binding == binding && policy.primaryReady,
                    "replacement generation mutated immutable binding or readiness")
        try require(policy.bindSession(attemptEpoch: attempt.attemptEpoch, generation: binding.generation, peerAuthority: replacementPeer) == .none && policy.binding == binding && policy.primaryReady,
                    "replacement peer mutated immutable binding or readiness")
        try require(policy.bindSession(attemptEpoch: attempt.attemptEpoch, generation: binding.generation, peerAuthority: peer) == .enableExact(binding) && policy.primaryReady,
                    "exact duplicate binding was not idempotent")
        try require(!policy.replaceProvider(epoch: 42) && policy.currentAttempt == attempt && policy.binding == binding,
                    "provider rotation erased submitted bound authority before closure proof")

        guard case let .gateOutboundAndRequest(muteRequest) = policy.requestMuted(true) else {
            throw CheckFailure.failed("Mute was not privacy-immediate")
        }
        try require(policy.userMuted, "pending Mute left outbound authority open")
        try require(policy.completeMuteRequest(muteRequest, accepted: false) == .failedRemainMuted && policy.userMuted, "failed Mute reopened outbound audio")
        guard case let .request(unmuteRequest) = policy.requestMuted(false) else {
            throw CheckFailure.failed("Unmute did not await a system action")
        }
        try require(policy.userMuted, "pending Unmute reopened outbound audio")
        try require(policy.completeMuteRequest(unmuteRequest, accepted: true) == .acceptedUnmutedRestoreIfAllowed && !policy.userMuted, "accepted exact Unmute did not restore policy authority")
        try require(policy.completeMuteRequest(unmuteRequest, accepted: true) == .reject, "mute action completion was reusable")
        guard case let .request(delayedUnmute) = policy.requestMuted(false),
              case let .gateOutboundAndRequest(newerMute) = policy.requestMuted(true) else {
            throw CheckFailure.failed("overlapping mute intents were not minted")
        }
        try require(policy.completeMuteRequest(delayedUnmute, accepted: true) == .reject && policy.userMuted,
                    "delayed accepted Unmute overrode a newer Mute")
        try require(policy.completeMuteRequest(newerMute, accepted: true) == .acceptedMuted && policy.userMuted,
                    "newest exact Mute did not remain authoritative")
        guard case let .request(capacityUnmute) = policy.requestMuted(false) else {
            throw CheckFailure.failed("capacity Unmute intent was not minted")
        }
        policy.forceMutedSupersedingPendingRequest()
        try require(policy.userMuted && policy.completeMuteRequest(capacityUnmute, accepted: true) == .reject,
                    "fail-closed mute capacity did not invalidate an older Unmute")

        var replacedMute = CallKitAttemptPolicy(providerEpoch: 80)
        let replacedMuteCall = UUID()
        guard let replacedMuteAttempt = replacedMute.beginAttempt(callUUID: replacedMuteCall, targetID: "agent", targetEpoch: "epoch") else {
            throw CheckFailure.failed("replacement-mute attempt was rejected")
        }
        _ = replacedMute.acceptStartAction(callUUID: replacedMuteCall, providerEpoch: 80)
        _ = replacedMute.bindSession(attemptEpoch: replacedMuteAttempt.attemptEpoch, generation: "old-generation", peerAuthority: peer)
        guard case let .request(oldUnmute) = replacedMute.requestMuted(false) else {
            throw CheckFailure.failed("old Unmute intent was not captured")
        }
        try require(replacedMute.providerClosed(generation: "old-generation") && replacedMute.replaceProvider(epoch: 81),
                    "exact old call could not close before replacement")
        let newMuteCall = UUID()
        guard replacedMute.beginAttempt(callUUID: newMuteCall, targetID: "agent-2", targetEpoch: "epoch-2") != nil else {
            throw CheckFailure.failed("replacement call was rejected")
        }
        try require(replacedMute.completeMuteRequest(oldUnmute, accepted: true) == .reject,
                    "delayed old Activity Unmute targeted a replacement call")

        try require(policy.setHeld(callUUID: call, held: true) == .gateBothCancelPTT, "system Hold did not gate both directions")
        let heldGestureEpoch = policy.pttGestureEpoch
        try require(policy.setHeld(callUUID: replacementCall, held: false) == .reject, "replacement UUID resumed a held call")
        try require(policy.setHeld(callUUID: call, held: false) == .resumeExactFreshGesture(binding), "exact Unhold did not restore the current binding")
        try require(policy.pttGestureEpoch > heldGestureEpoch, "Unhold did not require a fresh PTT gesture")

        try require(policy.acceptEndAction(callUUID: call) == .gateFulfillAndClose(binding), "exact End did not gate and detach system UI promptly")
        try require(policy.acceptEndAction(callUUID: call) == .reject, "End action completion was reusable")
        try require(policy.retainedEndRetry() == .retryRetainedClose(binding), "post-CallKit End retry tried to create a new call")
        try require(policy.didActivate(providerEpoch: 41) == .none, "late activation reopened system-ended media")
        try require(policy.unsupportedAction() == .failWithoutEffect, "unsupported CallKit action gained provider effects")
        try require(!policy.providerClosed(generation: "replacement"), "replacement generation released retained authority")
        try require(policy.providerClosed(generation: binding.generation), "exact provider closure did not release attempt authority")
        try require(!policy.replaceProvider(epoch: 42), "provider rotated before the attributed deactivation barrier")
        try require(policy.beginAttempt(callUUID: replacementCall, targetID: "agent-2", targetEpoch: "epoch-2") == nil, "replacement began before serialized deactivation barrier")
        try require(policy.didDeactivate(providerEpoch: 40) == .none, "old provider bridge epoch cleared the deactivation barrier")
        _ = policy.didDeactivate(providerEpoch: 41)
        guard let replacementAttempt = policy.beginAttempt(callUUID: replacementCall, targetID: "agent-2", targetEpoch: "epoch-2") else {
            throw CheckFailure.failed("current provider deactivation did not permit a fresh explicit attempt")
        }
        try require(!policy.replaceProvider(epoch: 42) && policy.currentAttempt == replacementAttempt,
                    "provider rotation erased an unresolved pre-submit attempt")
        try require(!policy.releaseDefinitePreSubmitFailure(callUUID: call, attemptEpoch: replacementAttempt.attemptEpoch),
                    "mismatched pre-submit failure released current authority")
        try require(policy.releaseDefinitePreSubmitFailure(callUUID: replacementCall, attemptEpoch: replacementAttempt.attemptEpoch) && policy.currentAttempt == nil,
                    "definite exact pre-submit failure did not release local attempt authority")
        try require(policy.replaceProvider(epoch: 42), "provider could not rotate after definite pre-submit release")
        let thirdCall = UUID()
        guard let thirdAttempt = policy.beginAttempt(callUUID: thirdCall, targetID: "agent-3", targetEpoch: "epoch-3") else {
            throw CheckFailure.failed("new immutable provider registration could not create an attempt")
        }
        try require(policy.acceptStartAction(callUUID: thirdCall, providerEpoch: 41) == .reject, "retired provider bridge callback was relabeled current")
        try require(policy.acceptStartAction(callUUID: thirdCall, providerEpoch: 42) == .fulfillPromptly(attemptEpoch: thirdAttempt.attemptEpoch), "new provider bridge epoch was rejected")
        try require(!policy.releaseDefinitePreSubmitFailure(callUUID: thirdCall, attemptEpoch: thirdAttempt.attemptEpoch),
                    "submitted unbound attempt was misclassified as a definite pre-submit failure")
        try require(!policy.replaceProvider(epoch: 43) && policy.currentAttempt == thirdAttempt,
                    "provider rotation erased submitted unbound authority")
        try require(policy.providerDidReset(providerEpoch: 41) == .reject, "stale provider reset affected current attempt")
        try require(policy.providerDidReset(providerEpoch: 42) == .gateFulfillAndClose(nil) &&
                    policy.currentAttempt == thirdAttempt && policy.binding == nil,
                    "current provider reset released or fabricated unbound allocation authority")

        var backgroundPreflight = CallKitAttemptPolicy(providerEpoch: 89)
        let backgroundCall = UUID()
        guard let backgroundAttempt = backgroundPreflight.beginAttempt(callUUID: backgroundCall, targetID: "agent", targetEpoch: "epoch") else {
            throw CheckFailure.failed("background-preflight attempt was rejected")
        }
        try require(backgroundPreflight.requestLocalEnd(callUUID: backgroundCall) == .gateFulfillAndClose(nil),
                    "background End did not synchronously gate the pre-Core Start intent")
        try require(backgroundPreflight.acceptStartAction(callUUID: backgroundCall, providerEpoch: 89) == .reject,
                    "late Start callback revived a background-ended attempt")
        try require(backgroundPreflight.releaseDefinitePreSubmitFailure(callUUID: backgroundCall, attemptEpoch: backgroundAttempt.attemptEpoch),
                    "pre-Core End could not release proven no-allocation authority without another Start callback")
        try require(backgroundPreflight.beginAttempt(callUUID: UUID(), targetID: "replacement", targetEpoch: "epoch-2") == nil,
                    "replacement began before the pending exact system End action resolved")
        try require(backgroundPreflight.acceptEndAction(callUUID: backgroundCall) == .gateFulfillAndClose(nil),
                    "exact system End was not fulfillable after no-allocation release")
        try require(backgroundPreflight.acceptEndAction(callUUID: backgroundCall) == .reject,
                    "background End action was reusable")

        var resetEnded = CallKitAttemptPolicy(providerEpoch: 89)
        let resetEndedCall = UUID()
        guard let resetEndedAttempt = resetEnded.beginAttempt(callUUID: resetEndedCall, targetID: "agent", targetEpoch: "epoch") else {
            throw CheckFailure.failed("reset-ended attempt was rejected")
        }
        _ = resetEnded.requestLocalEnd(callUUID: resetEndedCall)
        try require(resetEnded.releaseDefinitePreSubmitFailure(callUUID: resetEndedCall, attemptEpoch: resetEndedAttempt.attemptEpoch),
                    "reset-ended no-allocation proof was rejected")
        try require(resetEnded.replaceProvider(epoch: 90),
                    "proven no-allocation rotation was stranded by an old UI End tombstone")
        try require(resetEnded.acceptEndAction(callUUID: resetEndedCall) == .reject &&
                    resetEnded.providerDidReset(providerEpoch: 89) == .reject,
                    "retired old registration callback affected the fresh provider epoch")
        try require(resetEnded.beginAttempt(callUUID: UUID(), targetID: "replacement", targetEpoch: "epoch-2") != nil,
                    "fresh attempt remained blocked after eligible tombstone-retiring rotation")

        var preflight = CallKitAttemptPolicy(providerEpoch: 90)
        let preflightCall = UUID()
        guard let preflightAttempt = preflight.beginAttempt(callUUID: preflightCall, targetID: "agent", targetEpoch: "epoch") else {
            throw CheckFailure.failed("preflight attempt was rejected")
        }
        try require(preflight.acceptStartAction(callUUID: preflightCall, providerEpoch: 90) == .fulfillPromptly(attemptEpoch: preflightAttempt.attemptEpoch),
                    "preflight Start was not accepted promptly")
        try require(preflight.releaseProvenNoProviderAllocation(callUUID: preflightCall, attemptEpoch: preflightAttempt.attemptEpoch) && preflight.currentAttempt == nil,
                    "proven pre-session-request failure stranded accepted CallKit authority")
        try require(preflight.replaceProvider(epoch: 91),
                    "never-activated no-allocation release waited for an impossible deactivation callback")

        var activatedPreflight = CallKitAttemptPolicy(providerEpoch: 95)
        let activatedCall = UUID()
        guard let activatedAttempt = activatedPreflight.beginAttempt(callUUID: activatedCall, targetID: "agent", targetEpoch: "epoch") else {
            throw CheckFailure.failed("activated preflight attempt was rejected")
        }
        _ = activatedPreflight.acceptStartAction(callUUID: activatedCall, providerEpoch: 95)
        _ = activatedPreflight.didActivate(providerEpoch: 95)
        try require(activatedPreflight.releaseProvenNoProviderAllocation(callUUID: activatedCall, attemptEpoch: activatedAttempt.attemptEpoch),
                    "activated proven no-allocation failure was not released")
        try require(!activatedPreflight.replaceProvider(epoch: 96),
                    "activated no-allocation failure bypassed attributed deactivation")
        _ = activatedPreflight.didDeactivate(providerEpoch: 95)
        try require(activatedPreflight.replaceProvider(epoch: 96),
                    "activated no-allocation release remained blocked after deactivation")

        var activatedEnded = CallKitAttemptPolicy(providerEpoch: 96)
        let activatedEndedCall = UUID()
        guard let activatedEndedAttempt = activatedEnded.beginAttempt(callUUID: activatedEndedCall, targetID: "agent", targetEpoch: "epoch") else {
            throw CheckFailure.failed("activated-ended preflight attempt was rejected")
        }
        _ = activatedEnded.acceptStartAction(callUUID: activatedEndedCall, providerEpoch: 96)
        _ = activatedEnded.didActivate(providerEpoch: 96)
        _ = activatedEnded.acceptEndAction(callUUID: activatedEndedCall)
        try require(activatedEnded.releaseProvenNoProviderAllocation(callUUID: activatedEndedCall, attemptEpoch: activatedEndedAttempt.attemptEpoch) &&
                    !activatedEnded.replaceProvider(epoch: 97),
                    "End erased the historical activation/deactivation barrier")
        _ = activatedEnded.didDeactivate(providerEpoch: 96)
        try require(activatedEnded.replaceProvider(epoch: 97),
                    "real deactivation did not release activated-ended preflight")

        var endedPreflight = CallKitAttemptPolicy(providerEpoch: 97)
        let endedCall = UUID()
        guard let endedAttempt = endedPreflight.beginAttempt(callUUID: endedCall, targetID: "agent", targetEpoch: "epoch") else {
            throw CheckFailure.failed("ended preflight attempt was rejected")
        }
        _ = endedPreflight.acceptStartAction(callUUID: endedCall, providerEpoch: 97)
        _ = endedPreflight.acceptEndAction(callUUID: endedCall)
        try require(endedPreflight.releaseProvenNoProviderAllocation(callUUID: endedCall, attemptEpoch: endedAttempt.attemptEpoch) &&
                    endedPreflight.replaceProvider(epoch: 98),
                    "genuine never-activated no-allocation proof remained stranded after system End")

        var lateAllocation = CallKitAttemptPolicy(providerEpoch: 98)
        let lateCall = UUID()
        let latePeer = PeerConnectionAuthority(revision: 98, peerIdentifier: "peer-98")
        let lateBinding = CallKitAttemptPolicy.SessionBinding(generation: "generation-98", peerAuthority: latePeer)
        guard let lateAttempt = lateAllocation.beginAttempt(callUUID: lateCall, targetID: "agent", targetEpoch: "epoch") else {
            throw CheckFailure.failed("late-allocation attempt was rejected")
        }
        _ = lateAllocation.acceptStartAction(callUUID: lateCall, providerEpoch: 98)
        _ = lateAllocation.acceptEndAction(callUUID: lateCall)
        try require(lateAllocation.bindSession(attemptEpoch: lateAttempt.attemptEpoch, generation: lateBinding.generation, peerAuthority: latePeer) == .none &&
                    lateAllocation.binding == lateBinding && lateAllocation.retainedEndRetry() == .retryRetainedClose(lateBinding),
                    "known allocation arriving after system End was not retained for exact close")

        var failedUnknown = CallKitAttemptPolicy(providerEpoch: 99)
        let failedCall = UUID()
        guard let failedAttempt = failedUnknown.beginAttempt(callUUID: failedCall, targetID: "agent", targetEpoch: "epoch") else {
            throw CheckFailure.failed("failed-provider attempt was rejected")
        }
        _ = failedUnknown.acceptStartAction(callUUID: failedCall, providerEpoch: 99)
        try require(failedUnknown.detachSystemUIAfterProviderFailure(callUUID: failedCall) &&
                    failedUnknown.currentAttempt == failedAttempt && failedUnknown.binding == nil &&
                    !failedUnknown.replaceProvider(epoch: 100),
                    "provider failure report erased or replaced submitted unknown authority")
        try require(failedUnknown.releaseProvenNoProviderAllocation(callUUID: failedCall, attemptEpoch: failedAttempt.attemptEpoch),
                    "later genuine no-allocation proof could not release failed system UI")

        var readiness = CallKitAttemptPolicy(providerEpoch: 100)
        let readinessCall = UUID()
        let readinessPeer = PeerConnectionAuthority(revision: 100, peerIdentifier: "peer-100")
        guard let readinessAttempt = readiness.beginAttempt(callUUID: readinessCall, targetID: "agent", targetEpoch: "epoch") else {
            throw CheckFailure.failed("readiness attempt was rejected")
        }
        _ = readiness.acceptStartAction(callUUID: readinessCall, providerEpoch: 100)
        _ = readiness.bindSession(attemptEpoch: readinessAttempt.attemptEpoch, generation: "generation-100", peerAuthority: readinessPeer)
        _ = readiness.didActivate(providerEpoch: 100)
        try require(readiness.markPrimaryReady(attemptEpoch: readinessAttempt.attemptEpoch, generation: "generation-100", peerAuthority: readinessPeer) != .none,
                    "current exact readiness could not enable")
        _ = readiness.setHeld(callUUID: readinessCall, held: true)
        try require(readiness.markPrimaryReady(attemptEpoch: readinessAttempt.attemptEpoch, generation: "generation-100", peerAuthority: readinessPeer) == .none,
                    "stale readiness reopened held audio")
        _ = readiness.didDeactivate(providerEpoch: 100)
        try require(readiness.setHeld(callUUID: readinessCall, held: false) == .resumeExactFreshGesture(.init(generation: "generation-100", peerAuthority: readinessPeer)) &&
                    !readiness.systemHeld,
                    "valid deactivated Unhold was not accepted while awaiting real activation")
        try require(readiness.didActivate(providerEpoch: 100) == .enableExact(.init(generation: "generation-100", peerAuthority: readinessPeer)),
                    "real post-Unhold activation did not release exact audio")
        _ = readiness.didDeactivate(providerEpoch: 100)
        try require(readiness.markPrimaryReady(attemptEpoch: readinessAttempt.attemptEpoch, generation: "generation-100", peerAuthority: readinessPeer) == .none,
                    "stale readiness reopened deactivated audio")
        _ = readiness.didActivate(providerEpoch: 100)
        _ = readiness.acceptEndAction(callUUID: readinessCall)
        try require(readiness.markPrimaryReady(attemptEpoch: readinessAttempt.attemptEpoch, generation: "generation-100", peerAuthority: readinessPeer) == .none,
                    "stale readiness reopened system-ended audio")
        _ = readiness.providerClosed(generation: "generation-100")
        _ = readiness.didDeactivate(providerEpoch: 100)
        try require(readiness.replaceProvider(epoch: 101) &&
                    readiness.markPrimaryReady(attemptEpoch: readinessAttempt.attemptEpoch, generation: "generation-100", peerAuthority: readinessPeer) == .none,
                    "stale readiness reopened audio after provider rotation")

        var invalidUnhold = CallKitAttemptPolicy(providerEpoch: 102)
        let invalidCall = UUID()
        guard invalidUnhold.beginAttempt(callUUID: invalidCall, targetID: "agent", targetEpoch: "epoch") != nil else {
            throw CheckFailure.failed("invalid-Unhold attempt was rejected")
        }
        _ = invalidUnhold.acceptStartAction(callUUID: invalidCall, providerEpoch: 102)
        _ = invalidUnhold.setHeld(callUUID: invalidCall, held: true)
        try require(invalidUnhold.setHeld(callUUID: invalidCall, held: false) == .reject && invalidUnhold.systemHeld,
                    "rejected ineligible Unhold cleared the held gate")
    }

    @MainActor
    private static func boundedCaptionThreadContract() throws {
        var thread = BoundedCaptionThread(segmentLimit: 3, speakerCharacterLimit: 12, speakerUTF8ByteLimit: 64)
        thread.accept(generation: "generation", speaker: .user, delta: "User A", groupID: "user-1")
        thread.accept(generation: "generation", speaker: .agent, delta: "Agent", groupID: "agent-1")
        thread.accept(generation: "generation", speaker: .user, delta: "User B", groupID: "user-1")
        try require(
            thread.segments.map(\.text) == ["User A", "Agent", "User B"] &&
                thread.segments.map(\.speaker) == [.user, .agent, .user] &&
                thread.segments.map(\.isCurrent) == [false, false, true],
            "interleaved same-group captions lost accepted display order"
        )
        try require(thread.markStable(generation: "generation", speaker: .user, groupID: "user-1") && !thread.segments.last!.isCurrent,
                    "stable marker did not apply to the newest exact matching display segment")
        thread.accept(generation: "generation", speaker: .agent, delta: "123456789012", groupID: "agent-2")
        try require(thread.segments.count == 3 && thread.segments.map(\.text) == ["User A", "User B", "123456789012"],
                    "segment or per-speaker aggregate bound retained obsolete display material")
        thread.accept(generation: "generation", speaker: .agent, delta: "legacy", groupID: nil)
        thread.accept(generation: "generation", speaker: .agent, delta: "replacement", groupID: nil)
        try require(thread.segments.last?.text == "replacement" && thread.segments.count <= 3,
                    "legacy tail replacement created duplicate or unbounded history")
        thread.clear()
        try require(thread.segments.isEmpty, "caption thread clear retained display text")
    }

    @MainActor
    private static func liveActivityReconciliationContract() throws {
        var fence = LiveActivityReconciliationFence()
        let oldCreate = fence.begin(desiredGeneration: "old")
        let end = fence.begin(desiredGeneration: nil)
        try require(!fence.mayCommit(oldCreate, currentGeneration: "old"), "End did not invalidate an awaiting old Activity create")
        try require(fence.mayCommit(end, currentGeneration: nil), "current End reconciliation was rejected")

        let newCreate = fence.begin(desiredGeneration: "new")
        try require(!fence.mayCommit(oldCreate, currentGeneration: "new"), "old generation committed after replacement")
        try require(fence.mayCommit(newCreate, currentGeneration: "new"), "new generation could not commit")
        try require(!fence.mayCommit(newCreate, currentGeneration: nil), "new generation committed after a fresh phase check observed End")

        let newerSameGeneration = fence.begin(desiredGeneration: "new")
        try require(!fence.mayCommit(newCreate, currentGeneration: "new"), "duplicate reconciliation left an older same-generation job authoritative")
        try require(fence.mayCommit(newerSameGeneration, currentGeneration: "new"), "newest same-generation reconciliation was rejected")
    }

    @MainActor
    private static func automaticConnectionRetryContract() async throws {
        var attempts = 0, failures = 0, sleeps: [Duration] = []
        let connected = await AutomaticConnectionRetry.run(
            shouldContinue: { true },
            reconnect: {
                attempts += 1
                if attempts < 3 { throw URLError(.cannotConnectToHost) }
            },
            shouldRetry: SavedDeviceReconnectPolicy.shouldRetry,
            reportFailure: { _ in failures += 1 },
            sleep: { sleeps.append($0) }
        )
        try require(connected && attempts == 3 && failures == 2 && sleeps == [.seconds(1), .seconds(2)], "saved-device reconnect was not bounded to transient authorization attempts")

        attempts = 0
        let rejected = await AutomaticConnectionRetry.run(
            shouldContinue: { true },
            reconnect: { attempts += 1; throw DeviceAuthenticationError.deviceRevoked },
            shouldRetry: SavedDeviceReconnectPolicy.shouldRetry,
            reportFailure: { _ in },
            sleep: { _ in throw CheckFailure.failed("non-transient authentication failure slept for retry") }
        )
        try require(!rejected && attempts == 1 && SavedDeviceReconnectPolicy.requiresRepair(DeviceAuthenticationError.deviceRevoked), "revoked device was retried or not marked for explicit repair")
    }

    @MainActor
    private static func durableCredentialContract() throws {
        let canonical = try CanonicalGatewayOrigin(URL(string: "HTTPS://VOICE.Example.TEST:443/")!)
        try require(canonical.value == "https://voice.example.test", "origin canonicalization differs from gateway contract")
        let nondefaultPort = try CanonicalGatewayOrigin(URL(string: "https://voice.example.test:8443")!)
        let idna = try CanonicalGatewayOrigin(URL(string: "https://bücher.example")!)
        let ipv6Loopback = try CanonicalGatewayOrigin(URL(string: "http://[::1]:80")!)
        try require(nondefaultPort.value == "https://voice.example.test:8443", "nondefault port was not retained")
        try require(idna.value == "https://xn--bcher-kva.example", "IDNA hostname was not canonicalized to ASCII")
        try require(ipv6Loopback.value == "http://[::1]", "explicit IPv6 loopback HTTP was not canonicalized")
        _ = try DurableDeviceCredential(origin: canonical.value, value: String(repeating: "a", count: 43))
        do { _ = try CanonicalGatewayOrigin(URL(string: "http://voice.example.test")!); throw CheckFailure.failed("remote plaintext origin was accepted") }
        catch VoiceError.invalidOrigin {}
        do { _ = try CanonicalGatewayOrigin(URL(string: "https://voice.example.test/path")!); throw CheckFailure.failed("origin with a path was accepted") }
        catch VoiceError.invalidOrigin {}
        do { _ = try DurableDeviceCredential(origin: canonical.value, value: "root-bearer"); throw CheckFailure.failed("non-device credential was accepted") }
        catch DeviceAuthenticationError.invalidCredential {}
        try require(DeviceAuthenticationError.deviceRevoked.mustEraseCredential, "revocation must erase the credential")
        try require(!DeviceAuthenticationError.wrongOrigin.mustEraseCredential, "wrong origin must retain the credential")
        let endpoint = URL(string: "https://voice.example.test/api/browser-session/pair")!
        let redirected = URLRequest(url: URL(string: "https://voice.example.test:444/stolen")!)
        for status in [301, 302, 307, 308] {
            let response = HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": redirected.url!.absoluteString])!
            try require(GatewayHTTPRedirectPolicy.redirectedRequest(response: response, proposedRequest: redirected) == nil, "HTTP \(status) redirect was allowed to issue a second authentication request")
        }
        let strictSession = GatewayDeviceAuthenticator.makeEphemeralSession(
            configuration: GatewayDeviceAuthenticator.defaultConfiguration()
        )
        try require(strictSession.delegate is RejectRedirectsURLSessionDelegate, "authentication session was not wired to the no-redirect delegate")
        try require(
            !strictSession.configuration.waitsForConnectivity &&
                strictSession.configuration.timeoutIntervalForRequest == 20 &&
                strictSession.configuration.timeoutIntervalForResource == 20,
            "native authentication can wait indefinitely for missing connectivity"
        )
        strictSession.invalidateAndCancel()
        try require(GatewaySocketEventPolicy.mayAccept(isCancelled: false, isCurrentTask: true, revisionMatches: true), "current WebSocket event was rejected")
        try require(!GatewaySocketEventPolicy.mayAccept(isCancelled: false, isCurrentTask: true, revisionMatches: false), "old WebSocket revision could mutate a newer pairing")
        try require(!GatewaySocketEventPolicy.mayAccept(isCancelled: false, isCurrentTask: false, revisionMatches: true), "replaced WebSocket task could mutate a newer pairing")
        try require(!GatewaySocketEventPolicy.mayAccept(isCancelled: true, isCurrentTask: true, revisionMatches: true), "cancelled WebSocket task could mutate a newer pairing")
        var newerCredentialPresent = true
        if GatewaySocketEventPolicy.mayAccept(isCancelled: false, isCurrentTask: false, revisionMatches: false) { newerCredentialPresent = false }
        try require(newerCredentialPresent, "stale WebSocket 4003 erased the newer pairing")
        var currentRoster = "new"
        if GatewaySocketEventPolicy.mayAccept(isCancelled: false, isCurrentTask: false, revisionMatches: false) { currentRoster = "old" }
        try require(currentRoster == "new", "stale WebSocket success replaced the newer roster")
    }

    @MainActor
    private static func startupReadinessContract() throws {
        let connectionID = "abcdefghijklmnopqrstuv"
        var connection = VoiceConnectionFence()
        let firstSocket = connection.beginSocket()
        try require(
            !connection.acceptFirst(.notAnnouncement, revision: firstSocket) &&
                connection.connectionID(for: firstSocket) == nil,
            "socket accepted application authority without the first voice_connection event"
        )
        try require(
            connection.acceptFirst(
                VoiceConnectionAnnouncement.decode(Data("{\"type\":\"voice_connection\",\"connectionId\":\"\(connectionID)\"}".utf8)),
                revision: firstSocket
            ) && connection.connectionID(for: firstSocket) == connectionID,
            "valid exact WebSocket connection authority was not bound"
        )
        let replacementSocket = connection.beginSocket()
        try require(
            !connection.bind(connectionID: connectionID, revision: firstSocket) &&
                connection.connectionID(for: replacementSocket) == nil,
            "stale WebSocket authority rebound a replacement connection"
        )

        var readiness = PeerStartupReadiness()
        readiness.begin(1)
        readiness.iceGathered(1)
        try require(!readiness.ready(1), "ICE alone made the provider peer ready")
        readiness.observe(type: "session.started", revision: 1)
        try require(readiness.ready(1), "gathered ICE and primary startup did not make the peer ready")
        readiness.begin(2)
        readiness.observe(type: "session.started", revision: 1)
        readiness.iceGathered(1)
        try require(!readiness.ready(2), "stale peer callbacks made a replacement peer ready")
        readiness.iceGathered(2)
        readiness.observe(type: "response.audio.delta", revision: 2)
        try require(!readiness.ready(2), "non-startup provider traffic made the peer ready")
        readiness.observe(type: "session.started", revision: 2)
        try require(readiness.ready(2), "fresh peer never reached exact startup readiness")
    }

    @MainActor
    private static func peerConnectionRecoveryContract() throws {
        struct Clock {
            var milliseconds: Int64 = 1_000
            mutating func advance(_ delta: Int64) { milliseconds += delta }
        }

        let first = PeerConnectionAuthority(revision: 1, peerIdentifier: "peer-one")
        let replacement = PeerConnectionAuthority(revision: 2, peerIdentifier: "peer-two")
        var clock = Clock()
        var policy = PeerConnectionRecoveryPolicy(graceMilliseconds: 5_000)
        policy.begin(first)
        try require(policy.bind(generation: "generation-1", to: first), "exact peer could not bind its provider generation")
        try require(!policy.bind(generation: "stale", to: replacement), "replacement peer rebound the current generation")

        let armed = policy.observe(
            .disconnected,
            authority: first,
            nowMilliseconds: clock.milliseconds,
            mediaBeforeDisconnect: .continuous
        )
        try require(
            armed == .gateMediaAndArmGrace(graceSequence: 1, deadlineMilliseconds: 6_000),
            "disconnect did not immediately gate media and arm a bounded grace"
        )
        clock.advance(4_000)
        try require(
            policy.observe(
                .disconnected,
                authority: first,
                nowMilliseconds: clock.milliseconds,
                mediaBeforeDisconnect: .continuous
            ) == .none,
            "repeated disconnect extended or replaced the active grace"
        )
        try require(
            policy.observe(
                .connected,
                authority: replacement,
                nowMilliseconds: clock.milliseconds,
                mediaBeforeDisconnect: .continuous
            ) == .none,
            "stale peer callback recovered current media"
        )
        try require(
            policy.observe(
                .connected,
                authority: first,
                nowMilliseconds: clock.milliseconds,
                mediaBeforeDisconnect: .gated
            ) == .restoreContinuousSameSession,
            "exact peer did not restore only its captured same-session continuous state"
        )

        policy.begin(first)
        _ = policy.bind(generation: "generation-2", to: first)
        let heldGrace = policy.observe(
            .disconnected,
            authority: first,
            nowMilliseconds: clock.milliseconds,
            mediaBeforeDisconnect: .pttHeld
        )
        try require(
            heldGrace == .gateMediaAndArmGrace(graceSequence: 1, deadlineMilliseconds: 10_000),
            "PTT disconnect did not gate immediately"
        )
        clock.advance(1_000)
        try require(
            policy.observe(
                .completed,
                authority: first,
                nowMilliseconds: clock.milliseconds,
                mediaBeforeDisconnect: .pttHeld
            ) == .cancelPTTHoldBeforePlayback(generation: "generation-2"),
            "same-peer recovery revived a physical PTT hold instead of requiring cancellation"
        )

        policy.begin(first)
        let startingGrace = policy.observe(
            .disconnected,
            authority: first,
            nowMilliseconds: clock.milliseconds,
            mediaBeforeDisconnect: .gated
        )
        try require(
            startingGrace == .gateMediaAndArmGrace(graceSequence: 1, deadlineMilliseconds: 11_000),
            "starting peer did not receive a bounded gated grace"
        )
        try require(
            policy.observe(
                .failed,
                authority: first,
                nowMilliseconds: clock.milliseconds,
                mediaBeforeDisconnect: .gated
            ) == .endSession(generation: nil),
            "failed starting peer attempted to close an unknown provider generation"
        )
        try require(
            policy.observe(
                .connected,
                authority: first,
                nowMilliseconds: clock.milliseconds,
                mediaBeforeDisconnect: .continuous
            ) == .none,
            "terminal starting failure recovered after invalidation"
        )

        policy.begin(replacement)
        _ = policy.bind(generation: "generation-3", to: replacement)
        let expiring = policy.observe(
            .disconnected,
            authority: replacement,
            nowMilliseconds: clock.milliseconds,
            mediaBeforeDisconnect: .pttIdle
        )
        try require(
            expiring == .gateMediaAndArmGrace(graceSequence: 1, deadlineMilliseconds: 11_000),
            "replacement peer did not arm its own first grace"
        )
        clock.advance(5_000)
        try require(
            policy.graceExpired(authority: first, graceSequence: 1, nowMilliseconds: clock.milliseconds) == .none,
            "stale peer expired the replacement grace"
        )
        try require(
            policy.graceExpired(authority: replacement, graceSequence: 2, nowMilliseconds: clock.milliseconds) == .none,
            "stale timer sequence expired the active grace"
        )
        try require(
            policy.graceExpired(authority: replacement, graceSequence: 1, nowMilliseconds: clock.milliseconds) == .endSession(generation: "generation-3"),
            "exact grace expiry did not End only the known generation"
        )
        try require(
            policy.observe(
                .connected,
                authority: replacement,
                nowMilliseconds: clock.milliseconds,
                mediaBeforeDisconnect: .continuous
            ) == .none,
            "late recovery callback revived an Ended peer"
        )

        policy.begin(first)
        _ = policy.bind(generation: "generation-4", to: first)
        _ = policy.observe(
            .disconnected,
            authority: first,
            nowMilliseconds: clock.milliseconds,
            mediaBeforeDisconnect: .continuous
        )
        clock.advance(5_000)
        try require(
            policy.observe(
                .connected,
                authority: first,
                nowMilliseconds: clock.milliseconds,
                mediaBeforeDisconnect: .continuous
            ) == .endSession(generation: "generation-4"),
            "late connected callback bypassed an expired grace"
        )

        policy.begin(replacement)
        _ = policy.bind(generation: "generation-5", to: replacement)
        _ = policy.observe(
            .disconnected,
            authority: replacement,
            nowMilliseconds: clock.milliseconds,
            mediaBeforeDisconnect: .continuous
        )
        policy.invalidate()
        try require(
            policy.observe(
                .connected,
                authority: replacement,
                nowMilliseconds: clock.milliseconds,
                mediaBeforeDisconnect: .continuous
            ) == .none,
            "End, revocation, or background cancellation allowed peer recovery"
        )
    }

    @MainActor
    private static func gatewayDeviceAuthenticatorContract() async throws {
        let origin = URL(string: "https://voice.example.test")!
        let credentialValue = String(repeating: "d", count: 43)
        let store = MemoryCredentialStore()
        let authenticator = GatewayDeviceAuthenticator(credentialStore: store) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FakeAuthURLProtocol.self]
            configuration.httpShouldSetCookies = true
            configuration.httpCookieAcceptPolicy = .always
            FakeAuthURLProtocol.cookieStorage = configuration.httpCookieStorage
            return configuration
        }

        FakeAuthURLProtocol.handler = { request in
            FakeAuthURLProtocol.lastRequest = request
            FakeAuthURLProtocol.installCookie(name: "__Host-pi_voice_device", value: credentialValue, origin: origin)
            FakeAuthURLProtocol.installCookie(name: "__Host-pi_voice_session", value: String(repeating: "s", count: 43), origin: origin)
            return (201, ["authenticated": true, "device": ["origin": "https://voice.example.test"]])
        }
        let paired = try await authenticator.authenticate(origin: origin, pairingToken: String(repeating: "p", count: 32), deviceName: "Pi Voice iPhone")
        try require(FakeAuthURLProtocol.lastRequest?.url?.path == "/api/browser-session/pair" && FakeAuthURLProtocol.lastRequest?.value(forHTTPHeaderField: "Origin") == "https://voice.example.test", "pair request contract mismatch")
        try require(store.values["https://voice.example.test"]?.value == credentialValue, "pair did not persist only the durable credential")
        let storedCredentialAvailable = try authenticator.hasCredential(origin: origin)
        try require(storedCredentialAvailable, "credential availability did not reflect the exact-origin stored pairing")
        let pairedCookies = paired.session.configuration.httpCookieStorage?.cookies(for: origin) ?? []
        try require(pairedCookies.contains { $0.name.hasSuffix("pi_voice_session") } && !pairedCookies.contains { $0.name.hasSuffix("pi_voice_device") }, "paired ordinary session retained the durable cookie")

        FakeAuthURLProtocol.handler = { request in
            FakeAuthURLProtocol.lastRequest = request
            FakeAuthURLProtocol.installCookie(name: "__Host-pi_voice_session", value: String(repeating: "r", count: 43), origin: origin)
            return (201, ["authenticated": true, "device": ["origin": "https://voice.example.test"]])
        }
        let renewed = try await authenticator.authenticate(origin: origin, pairingToken: nil, deviceName: "Pi Voice iPhone")
        try require(FakeAuthURLProtocol.lastRequest?.url?.path == "/api/browser-session/renew" && FakeAuthURLProtocol.observedCookies.contains { $0.name.hasSuffix("pi_voice_device") && $0.value == credentialValue }, "renew did not load the exact durable cookie into its fresh authentication jar")
        let renewedCookies = renewed.session.configuration.httpCookieStorage?.cookies(for: origin) ?? []
        try require(renewedCookies.contains { $0.name.hasSuffix("pi_voice_session") } && !renewedCookies.contains { $0.name.hasSuffix("pi_voice_device") }, "renewed ordinary session retained the durable cookie")

        FakeAuthURLProtocol.handler = { _ in (401, ["error": "wrong_origin"]) }
        do { _ = try await authenticator.authenticate(origin: origin, pairingToken: nil, deviceName: "Pi Voice iPhone"); throw CheckFailure.failed("wrong origin succeeded") }
        catch DeviceAuthenticationError.wrongOrigin {}
        try require(store.values["https://voice.example.test"] != nil, "wrong origin erased a valid credential")

        for mismatchedURL in ["https://voice.example.test:444/api/browser-session/renew", "https://voice.example.test/other"] {
            FakeAuthURLProtocol.responseURLOverride = URL(string: mismatchedURL)!
            FakeAuthURLProtocol.handler = { _ in
                FakeAuthURLProtocol.installCookie(name: "__Host-pi_voice_session", value: String(repeating: "x", count: 43), origin: origin)
                return (201, ["authenticated": true, "device": ["origin": "https://voice.example.test"]])
            }
            do { _ = try await authenticator.authenticate(origin: origin, pairingToken: nil, deviceName: "Pi Voice iPhone"); throw CheckFailure.failed("mismatched final response URL succeeded") }
            catch DeviceAuthenticationError.invalidResponse {}
            try require(store.values["https://voice.example.test"] != nil, "mismatched final response URL erased the credential")
        }
        FakeAuthURLProtocol.responseURLOverride = nil

        FakeAuthURLProtocol.handler = { _ in (401, ["error": "revoked_device"]) }
        do { _ = try await authenticator.authenticate(origin: origin, pairingToken: nil, deviceName: "Pi Voice iPhone"); throw CheckFailure.failed("revoked device succeeded") }
        catch DeviceAuthenticationError.deviceRevoked {}
        try require(store.values["https://voice.example.test"] == nil, "revocation did not erase the credential")

        try store.save(DurableDeviceCredential(origin: "https://voice.example.test", value: credentialValue))
        let sequence = LockedCounter()
        FakeAuthURLProtocol.handler = { _ in
            if sequence.next() == 1 {
                Thread.sleep(forTimeInterval: 0.05)
                return (401, ["error": "revoked_device"])
            }
            FakeAuthURLProtocol.installCookie(name: "__Host-pi_voice_session", value: String(repeating: "n", count: 43), origin: origin)
            return (201, ["authenticated": true, "device": ["origin": "https://voice.example.test"]])
        }
        let stale = Task { try await authenticator.authenticate(origin: origin, pairingToken: nil, deviceName: "Pi Voice iPhone") }
        try await Task.sleep(for: .milliseconds(10))
        _ = try await authenticator.authenticate(origin: origin, pairingToken: nil, deviceName: "Pi Voice iPhone")
        do { _ = try await stale.value; throw CheckFailure.failed("stale revoked renewal completed") }
        catch let failure as CheckFailure { throw failure }
        catch {}
        try require(store.values["https://voice.example.test"] != nil, "stale revoked renewal erased the newer authentication credential")

        let independent = GatewayDeviceAuthenticator(credentialStore: store) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FakeAuthURLProtocol.self]
            configuration.httpShouldSetCookies = true
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpCookieStorage = FakeAuthURLProtocol.cookieStorage
            return configuration
        }
        FakeAuthURLProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return (401, ["error": "revoked_device"])
        }
        let oldCredentialFailure = Task { try await independent.authenticate(origin: origin, pairingToken: nil, deviceName: "Pi Voice iPhone") }
        try await Task.sleep(for: .milliseconds(10))
        let replacementValue = String(repeating: "r", count: 43)
        try store.save(DurableDeviceCredential(origin: "https://voice.example.test", value: replacementValue))
        do { _ = try await oldCredentialFailure.value; throw CheckFailure.failed("old replaced credential unexpectedly renewed") }
        catch let failure as CheckFailure { throw failure }
        catch DeviceAuthenticationError.deviceRevoked {}
        try require(store.values["https://voice.example.test"]?.value == replacementValue, "old authenticator erased a credential replaced by another authenticator")
        let oldSnapshot = try independent.durableCredentialSnapshot(origin: origin)
        let newestValue = String(repeating: "z", count: 43)
        try store.save(DurableDeviceCredential(origin: "https://voice.example.test", value: newestValue))
        independent.eraseCredentialIfUnchanged(oldSnapshot)
        try require(store.values["https://voice.example.test"]?.value == newestValue, "stale post-receipt 401 compare-delete erased a replacement credential")
        let currentSnapshot = try independent.durableCredentialSnapshot(origin: origin)
        independent.eraseCredentialIfUnchanged(currentSnapshot)
        try require(store.values["https://voice.example.test"] == nil, "matching revoked credential was not erased")
    }

    @MainActor
    private static func staleConnectFencing() async throws {
        let fake = FakeTransport()
        fake.delayedAuthenticationToken = "old"
        let subject = VoiceSessionCoordinator(transport: fake)
        let stale = Task { try await subject.connect(origin: URL(string: "https://voice.example.test")!, pairingToken: "old") }
        try await Task.sleep(for: .milliseconds(10))
        try await subject.connect(origin: URL(string: "https://voice.example.test")!, pairingToken: "new")
        do { try await stale.value; throw CheckFailure.failed("stale authentication completed after a newer connect") }
        catch is CancellationError {}
        try require(subject.phase == .ready && fake.connectedOrigins == ["https://voice.example.test"], "stale connect replaced or disconnected the newer session")
    }

    @MainActor
    private static func exactProviderClosureRecovery() async throws {
        let fake = FakeTransport()
        let (subject, target) = try await connected(fake)
        try subject.select(target)
        try await subject.start(mode: .continuous, voice: .marin)
        fake.emit(.sessionEnded(code: "websocket_closed", message: "airplane mode"))
        try await Task.sleep(for: .milliseconds(10))
        guard let epoch = subject.closureRecoveryEpoch else { throw CheckFailure.failed("active control loss did not create an exact closure recovery epoch") }
        try require(subject.activeGeneration == "generation-1" && !fake.microphone && !fake.playback, "closure recovery did not retain exact gated authority")
        fake.closureReceiptResult = .unconfirmed
        let unconfirmed = try await subject.checkProviderClosure(epoch: epoch)
        try require(!unconfirmed && subject.activeGeneration == "generation-1", "unconfirmed receipt released authority")
        fake.closureReceiptResult = .providerClosed
        let confirmed = try await subject.checkProviderClosure(epoch: epoch)
        try require(confirmed && subject.activeGeneration == nil && subject.phase == .disconnected && subject.automaticReconnectEpoch != nil, "exact provider-closed receipt did not release authority into normal authorization recovery")
        try require(subject.confirmedEndRevision == 1 && subject.lastConfirmedProviderClosedGeneration == "generation-1",
                    "exact closure receipt did not expose the provider generation for CallKit release")
        try require(fake.closureReceiptQueries.count == 2 && fake.closureReceiptQueries.allSatisfy { $0.0 == "https://voice.example.test" && $0.1 == "generation-1" }, "closure checks changed origin/generation")
        try require(fake.startCount == 1 && fake.closed.isEmpty, "closure receipt check started or closed provider work")

        let staleFake = FakeTransport(); staleFake.delayClosureReceipt = true; staleFake.closureReceiptResult = .providerClosed
        let (stale, staleTarget) = try await connected(staleFake); try stale.select(staleTarget); try await stale.start(mode: .continuous, voice: .marin)
        staleFake.emit(.sessionEnded(code: "websocket_closed", message: "airplane mode")); try await Task.sleep(for: .milliseconds(10))
        guard let firstEpoch = stale.closureRecoveryEpoch else { throw CheckFailure.failed("missing first recovery epoch") }
        let oldRequest = Task { try await stale.checkProviderClosure(epoch: firstEpoch) }
        await Task.yield()
        staleFake.emit(.voiceState(generation: "generation-1", state: "closed", reason: "provider_closed"))
        try await Task.sleep(for: .milliseconds(5))
        try await stale.connect(origin: URL(string: "https://voice.example.test")!, pairingToken: nil)
        staleFake.emit(.roster(connected: true, agents: [staleTarget])); try await Task.sleep(for: .milliseconds(5))
        try stale.select(staleTarget); try await stale.start(mode: .continuous, voice: .marin)
        staleFake.emit(.sessionEnded(code: "websocket_closed", message: "second airplane mode")); try await Task.sleep(for: .milliseconds(10))
        guard let secondEpoch = stale.closureRecoveryEpoch, secondEpoch != firstEpoch else { throw CheckFailure.failed("missing distinct second recovery epoch") }
        try require(!stale.hasProviderClosureRecoveryScope(epoch: firstEpoch) && stale.hasProviderClosureRecoveryScope(epoch: secondEpoch), "stale receipt failure could mutate new-scope UI state")
        try require(stale.mayCheckProviderClosure(epoch: secondEpoch), "old receipt request wedged a new generation's check")
        let newRequest = Task { try await stale.checkProviderClosure(epoch: secondEpoch) }
        let oldConfirmed = try await oldRequest.value
        let newConfirmed = try await newRequest.value
        try require(!oldConfirmed && newConfirmed && stale.activeGeneration == nil, "stale old receipt blocked or overwrote the new request")
        try require(Array(staleFake.closureReceiptQueries.map(\.1).suffix(2)) == ["generation-1", "generation-2"], "closure receipt requests crossed generations")
    }

    @MainActor
    private static func providerClosureRecoveryBudget() throws {
        var budget = ProviderClosureRecoveryBudget()
        try require((0..<3).allSatisfy { _ in budget.claimAutomaticAttempt(epoch: 7) }, "automatic closure budget rejected one of three attempts")
        try require(!budget.claimAutomaticAttempt(epoch: 7), "network resumption reset the same loss epoch's bounded budget")
        try require(budget.claimAutomaticAttempt(epoch: 8) && budget.attempts == 1, "a distinct generation loss did not receive a fresh budget")
    }

    @MainActor
    private static func sessionEndedAllowsReconnect() async throws {
        let fake = FakeTransport()
        let subject = VoiceSessionCoordinator(transport: fake)
        try await subject.connect(origin: URL(string: "https://voice.example.test")!, pairingToken: nil)
        fake.emit(.sessionEnded(code: "session_expired", message: "device_expired"))
        try await Task.sleep(for: .milliseconds(10))
        try require(subject.phase == .disconnected && fake.teardownCount == 1, "4001/session end did not tear down into reconnectable state")
        try require(fake.forgottenOrigins.isEmpty, "4001/session end erased the durable pairing")
        try await subject.connect(origin: URL(string: "https://voice.example.test")!, pairingToken: nil)
        try require(subject.phase == .ready && fake.authentications.count == 2, "stored pairing could not reconnect after short-session end")
    }

    @MainActor
    private static func automaticNetworkRecoveryEligibility() async throws {
        let origin = URL(string: "https://voice.example.test")!
        let fake = FakeTransport()
        let subject = VoiceSessionCoordinator(transport: fake)
        let agent = AgentEndpoint(id: "agent", endpointEpoch: "epoch", name: "General")
        try await subject.connect(origin: origin, pairingToken: nil)
        fake.emit(.roster(connected: true, agents: [agent]))
        try await Task.sleep(for: .milliseconds(10))
        try subject.select(agent)

        fake.emit(.roster(connected: false, agents: []))
        try await Task.sleep(for: .milliseconds(10))
        guard let firstLoss = subject.automaticReconnectEpoch else {
            throw CheckFailure.failed("idle relay loss did not request saved-device recovery")
        }
        try require(subject.mayAutomaticallyReconnect(epoch: firstLoss), "idle relay loss was not eligible for recovery")
        try require(subject.selected == nil && subject.agents.isEmpty, "loss retained a stale selected target")
        fake.emit(.roster(connected: false, agents: []))
        try await Task.sleep(for: .milliseconds(10))
        try require(subject.automaticReconnectEpoch == firstLoss, "repeated empty roster created another recovery campaign")

        // Model the app's authorization-only recovery. It uses no one-use code and
        // must not select, Start, or open either media direction.
        try await subject.connect(origin: origin, pairingToken: nil)
        fake.emit(.roster(connected: false, agents: []))
        try await Task.sleep(for: .milliseconds(10))
        try require(subject.automaticReconnectEpoch == nil, "same loss epoch spun after a successful reconnect")
        try require(fake.authentications.last?.1 == nil && fake.startCount == 0 && !fake.microphone && !fake.playback,
                    "idle recovery used pairing or started voice/media")
        fake.emit(.roster(connected: true, agents: [agent]))
        try await Task.sleep(for: .milliseconds(10))
        try require(!subject.mayAutomaticallyReconnect(epoch: firstLoss), "healthy roster did not fence stale async recovery")
        fake.emit(.roster(connected: false, agents: []))
        try await Task.sleep(for: .milliseconds(10))
        try require(subject.automaticReconnectEpoch != nil && subject.automaticReconnectEpoch != firstLoss,
                    "a later healthy-to-lost transition did not create one new loss epoch")

        let activeFake = FakeTransport()
        let active = try await activePTT(activeFake)
        activeFake.emit(.sessionEnded(code: "websocket_closed", message: "network lost"))
        try await Task.sleep(for: .milliseconds(10))
        try require({ if case .uncertain = active.phase { true } else { false } }() &&
                    active.activeGeneration == "generation-1" && active.automaticReconnectEpoch == nil,
                    "unknown active-session closure did not retain fail-closed authority")
        try require(!activeFake.microphone && !activeFake.playback, "unknown closure did not fail closed locally")

        let startingFake = FakeTransport()
        startingFake.delayStart = true
        let (starting, startingAgent) = try await connected(startingFake)
        try starting.select(startingAgent)
        let start = Task { try await starting.start(mode: .continuous, voice: .marin) }
        try await Task.sleep(for: .milliseconds(10))
        startingFake.emit(.sessionEnded(code: "websocket_closed", message: "network lost"))
        try await Task.sleep(for: .milliseconds(10))
        do { try await start.value; throw CheckFailure.failed("stale Start survived connection loss") }
        catch let failure as CheckFailure { throw failure }
        catch {}
        try require(starting.automaticReconnectEpoch == nil && !startingFake.microphone && !startingFake.playback,
                    "Starting loss auto-recovered or left media open")

        let acceptedCloseFake = FakeTransport()
        let acceptedClose = try await activePTT(acceptedCloseFake)
        await acceptedClose.stop()
        acceptedCloseFake.emit(.roster(connected: false, agents: []))
        try await Task.sleep(for: .milliseconds(10))
        try require(acceptedCloseFake.closed == ["generation-1"] &&
                    acceptedClose.phase == .stopping && acceptedClose.activeGeneration == "generation-1" &&
                    acceptedClose.automaticReconnectEpoch == nil && !acceptedCloseFake.microphone && !acceptedCloseFake.playback,
                    "accepted close POST was treated as provider-closure proof")
        let closesBeforeRetry = acceptedCloseFake.closed.count
        await acceptedClose.stop()
        try require(acceptedCloseFake.closed.count == closesBeforeRetry + 1 &&
                    acceptedCloseFake.closed.last == "generation-1",
                    "Stop retry did not retain the exact same generation")

        let failedCloseFake = FakeTransport()
        let failedClose = try await activePTT(failedCloseFake)
        failedCloseFake.failClose = true
        await failedClose.stop()
        try require({ if case .uncertain = failedClose.phase { true } else { false } }() &&
                    failedClose.activeGeneration == "generation-1" && !failedCloseFake.microphone && !failedCloseFake.playback,
                    "failed close request erased unknown generation authority")

        for terminalReason in ["close_timeout", "sideband_disconnected"] {
            let terminalFake = FakeTransport()
            let terminal = try await activePTT(terminalFake)
            terminalFake.emit(.voiceState(generation: "generation-1", state: "closed", reason: terminalReason))
            try await Task.sleep(for: .milliseconds(10))
            terminalFake.emit(.sessionEnded(code: "websocket_closed", message: "after \(terminalReason)"))
            try await Task.sleep(for: .milliseconds(10))
            try require({ if case .uncertain = terminal.phase { true } else { false } }() &&
                        terminal.activeGeneration == "generation-1" && terminal.automaticReconnectEpoch == nil,
                        "\(terminalReason) was treated as provider-closure proof")
        }

        let closedFake = FakeTransport()
        let confirmed = try await activePTT(closedFake)
        closedFake.emit(.voiceState(generation: "generation-1", state: "closing", reason: "hard_max"))
        try await Task.sleep(for: .milliseconds(10))
        try require(confirmed.phase == .stopping && confirmed.activeGeneration == "generation-1" &&
                    !closedFake.microphone && !closedFake.playback,
                    "server hard maximum did not gate local media while retaining authority")
        closedFake.emit(.voiceState(generation: "generation-1", state: "closed", reason: "provider_closed"))
        try await Task.sleep(for: .milliseconds(10))
        try require(confirmed.phase == .ready && confirmed.selected == nil && confirmed.activeGeneration == nil,
                    "exact provider_closed did not return to unselected Ready")
        closedFake.emit(.sessionEnded(code: "websocket_closed", message: "after close"))
        try await Task.sleep(for: .milliseconds(10))
        guard let confirmedEpoch = confirmed.automaticReconnectEpoch else {
            throw CheckFailure.failed("exact provider_closed did not allow later auth recovery")
        }
        try require(confirmed.mayAutomaticallyReconnect(epoch: confirmedEpoch),
                    "confirmed-close recovery was not bounded to its loss epoch")
        try await confirmed.connect(origin: URL(string: "https://voice.example.test")!, pairingToken: nil)
        let refreshed = AgentEndpoint(id: "fresh", endpointEpoch: "epoch-fresh", name: "General")
        closedFake.emit(.roster(connected: true, agents: [refreshed]))
        try await Task.sleep(for: .milliseconds(10))
        try require(confirmed.phase == .ready && confirmed.agents == [refreshed] && confirmed.selected == nil &&
                    closedFake.authentications.last?.1 == nil && closedFake.startCount == 1 &&
                    !closedFake.microphone && !closedFake.playback,
                    "post-provider-close auth recovery did not refresh roster without Start/media")
    }

    @MainActor
    private static func peerConnectionRecoveryWiring() async throws {
        let continuousFake = FakeTransport()
        let (continuous, target) = try await connected(continuousFake)
        try continuous.select(target)
        try await continuous.start(mode: .continuous, voice: .marin)
        guard case let .active(continuousAuthority) = continuous.phase else {
            throw CheckFailure.failed("continuous recovery fixture did not start")
        }
        continuousFake.emit(.peerConnectionState(authority: continuousAuthority.peerAuthority, state: .disconnected))
        try await Task.sleep(for: .milliseconds(10))
        try require(continuous.mediaConnectionState == .reconnecting && !continuousFake.microphone && !continuousFake.playback,
                    "ICE disconnect did not immediately gate both media directions")
        continuous.setUserMuted(true)
        try require(!continuousFake.microphone, "mute change during grace reopened capture")
        continuousFake.emit(.peerConnectionState(authority: continuousAuthority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(10))
        try require(continuous.mediaConnectionState == .connected && continuous.userMuted &&
                    !continuousFake.microphone && continuousFake.playback,
                    "continuous recovery bypassed current mute authority")
        continuous.setUserMuted(false)
        try require(continuousFake.microphone, "explicit unmute after recovery did not reapply current policy")
        continuousFake.emit(.peerConnectionState(
            authority: PeerConnectionAuthority(revision: 999, peerIdentifier: "stale-peer"),
            state: .failed
        ))
        try await Task.sleep(for: .milliseconds(10))
        try require(continuous.phase == .active(continuousAuthority) && continuousFake.closed.isEmpty,
                    "stale peer callback ended the current generation")

        let startupFake = FakeTransport()
        startupFake.initialPeerState = .disconnected
        let (startup, startupTarget) = try await connected(startupFake)
        try startup.select(startupTarget)
        try await startup.start(mode: .continuous, voice: .marin)
        guard case let .active(startupAuthority) = startup.phase else {
            throw CheckFailure.failed("startup ICE fixture did not retain active generation")
        }
        try require(startup.mediaConnectionState == .reconnecting && !startupFake.microphone && !startupFake.playback,
                    "pre-generation ICE disconnect was ignored at activation")
        startupFake.emit(.peerConnectionState(authority: startupAuthority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(10))
        try require(startup.mediaConnectionState == .connected && startupFake.microphone && startupFake.playback,
                    "current startup ICE state did not reconcile after generation binding")

        let pttFake = FakeTransport()
        let ptt = try await activePTT(pttFake)
        guard case let .active(pttAuthority) = ptt.phase else {
            throw CheckFailure.failed("PTT recovery fixture did not start")
        }
        let heldGestureEpoch = ptt.pttGestureEpoch
        try await ptt.beginPushToTalk(gestureEpoch: heldGestureEpoch)
        pttFake.emit(.peerConnectionState(authority: pttAuthority.peerAuthority, state: .disconnected))
        try await Task.sleep(for: .milliseconds(10))
        try require(ptt.mediaConnectionState == .reconnecting && ptt.pttGestureEpoch != heldGestureEpoch &&
                    !pttFake.microphone && !pttFake.playback,
                    "PTT disconnect did not invalidate the physical gesture and gate media")
        pttFake.emit(.peerConnectionState(authority: pttAuthority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(20))
        try require(ptt.mediaConnectionState == .connected && !ptt.pttHeld &&
                    pttFake.ptt.last == .init(generation: "generation-1", held: false, cancel: true, commandSequence: 2) &&
                    !pttFake.microphone && pttFake.playback,
                    "recovery resurrected a held PTT gesture or skipped exact cancellation")
        do {
            try await ptt.beginPushToTalk(gestureEpoch: heldGestureEpoch)
            throw CheckFailure.failed("pre-loss gesture epoch rearmed PTT")
        } catch VoiceError.pttNotReady {}
        pttFake.emit(.pttReady(generation: "generation-1"))
        try await Task.sleep(for: .milliseconds(10))
        try await ptt.beginPushToTalk(gestureEpoch: ptt.pttGestureEpoch)
        try require(ptt.pttHeld, "fresh post-recovery gesture could not begin PTT")

        let repeatedLossFake = FakeTransport()
        repeatedLossFake.delayReleaseAcknowledgement = true
        let repeatedLoss = try await activePTT(repeatedLossFake)
        guard case let .active(repeatedAuthority) = repeatedLoss.phase else {
            throw CheckFailure.failed("repeated-loss PTT fixture did not start")
        }
        try await repeatedLoss.beginPushToTalk(gestureEpoch: repeatedLoss.pttGestureEpoch)
        repeatedLossFake.emit(.peerConnectionState(authority: repeatedAuthority.peerAuthority, state: .disconnected))
        repeatedLossFake.emit(.peerConnectionState(authority: repeatedAuthority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(10))
        repeatedLossFake.emit(.peerConnectionState(authority: repeatedAuthority.peerAuthority, state: .disconnected))
        try await Task.sleep(for: .milliseconds(60))
        try require(repeatedLoss.mediaConnectionState == .reconnecting &&
                    !repeatedLossFake.microphone && !repeatedLossFake.playback,
                    "old PTT cancel acknowledgement reopened media across a newer loss")
        repeatedLossFake.emit(.peerConnectionState(authority: repeatedAuthority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(20))
        try require(repeatedLoss.mediaConnectionState == .connected && !repeatedLossFake.microphone && repeatedLossFake.playback,
                    "second grace did not remain authoritative after old PTT acknowledgement")

        let terminalRaceFake = FakeTransport()
        terminalRaceFake.delayCloseAcknowledgement = true
        let (terminalRace, terminalTarget) = try await connected(terminalRaceFake)
        try terminalRace.select(terminalTarget)
        try await terminalRace.start(mode: .continuous, voice: .marin)
        guard case let .active(oldAuthority) = terminalRace.phase else {
            throw CheckFailure.failed("terminal race fixture did not start")
        }
        terminalRaceFake.emit(.peerConnectionState(authority: oldAuthority.peerAuthority, state: .failed))
        terminalRaceFake.emit(.peerConnectionState(authority: oldAuthority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(10))
        try require(terminalRace.phase == .stopping && terminalRace.mediaConnectionState == .unknown &&
                    terminalRaceFake.closed == ["generation-1"] && !terminalRaceFake.microphone && !terminalRaceFake.playback,
                    "late Connected resurrected media or skipped exact close after terminal failure")
        terminalRaceFake.emit(.voiceState(generation: "generation-1", state: "closed", reason: "provider_closed"))
        try await Task.sleep(for: .milliseconds(10))
        try terminalRace.select(terminalTarget)
        try await terminalRace.start(mode: .continuous, voice: .marin)
        try await Task.sleep(for: .milliseconds(60))
        guard case let .active(newAuthority) = terminalRace.phase else {
            throw CheckFailure.failed("old terminal close task stopped the replacement generation")
        }
        try require(newAuthority.generation == "generation-2" && terminalRaceFake.startCount == 2 &&
                    terminalRaceFake.closed == ["generation-1"] && terminalRaceFake.microphone && terminalRaceFake.playback,
                    "stale terminal task mutated or closed the replacement generation")

        let expiryFake = FakeTransport()
        let expiry = VoiceSessionCoordinator(
            transport: expiryFake,
            peerRecoveryPolicy: PeerConnectionRecoveryPolicy(graceMilliseconds: 20)
        )
        let expiryAgent = AgentEndpoint(id: "expiry", endpointEpoch: "epoch", name: "Expiry")
        try await expiry.connect(origin: URL(string: "https://voice.example.test")!, pairingToken: nil)
        expiryFake.emit(.roster(connected: true, agents: [expiryAgent]))
        try await Task.sleep(for: .milliseconds(10))
        try expiry.select(expiryAgent)
        try await expiry.start(mode: .continuous, voice: .marin)
        guard case let .active(expiryAuthority) = expiry.phase else {
            throw CheckFailure.failed("expiry recovery fixture did not start")
        }
        expiryFake.emit(.peerConnectionState(authority: expiryAuthority.peerAuthority, state: .disconnected))
        try await Task.sleep(for: .milliseconds(25))
        expiryFake.emit(.peerConnectionState(authority: expiryAuthority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(25))
        try require(expiry.phase == .stopping && expiry.mediaConnectionState == .unknown && expiry.activeGeneration == "generation-1" &&
                    expiryFake.closed == ["generation-1"] && !expiryFake.microphone && !expiryFake.playback &&
                    expiryFake.startCount == 1,
                    "ICE grace expiry did not use exact-generation Stop without rollover")

        let unknownFake = FakeTransport()
        let (unknown, unknownTarget) = try await connected(unknownFake)
        try unknown.select(unknownTarget)
        try await unknown.start(mode: .continuous, voice: .marin)
        guard case let .active(unknownAuthority) = unknown.phase else {
            throw CheckFailure.failed("unknown recovery fixture did not start")
        }
        unknownFake.emit(.peerConnectionState(authority: unknownAuthority.peerAuthority, state: .disconnected))
        unknownFake.emit(.sessionEnded(code: "websocket_closed", message: "control lost"))
        try await Task.sleep(for: .milliseconds(10))
        unknownFake.emit(.peerConnectionState(authority: unknownAuthority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(10))
        try require({ if case .uncertain = unknown.phase { true } else { false } }() &&
                    unknown.activeGeneration == "generation-1" && unknown.mediaConnectionState == .unknown &&
                    !unknownFake.microphone && !unknownFake.playback && unknownFake.startCount == 1,
                    "media recovery overrode retained closure Unknown authority")
    }

    @MainActor
    private static func oneShotGreetingReadiness() async throws {
        let fake = FakeTransport()
        let (subject, target) = try await connected(fake)
        try subject.select(target)
        try await subject.start(mode: .continuous, voice: .marin)
        try await Task.sleep(for: .milliseconds(10))
        try require(fake.mediaReady == ["generation-1"], "initial exact media readiness did not announce once")
        guard case let .active(authority) = subject.phase else { throw CheckFailure.failed("greeting fixture was not active") }
        fake.emit(.peerConnectionState(authority: authority.peerAuthority, state: .disconnected))
        fake.emit(.peerConnectionState(authority: authority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(10))
        try require(fake.mediaReady == ["generation-1"], "ICE recovery repeated media readiness")
        subject.setUserMuted(true)
        try require(fake.mediaReady == ["generation-1"], "outbound user mute repeated or suppressed an already-ready greeting")
        await subject.stop()
        fake.emit(.voiceState(generation: "generation-1", state: "closed", reason: "provider_closed"))
        try await Task.sleep(for: .milliseconds(10))
        try subject.select(target)
        try await subject.start(mode: .continuous, voice: .marin)
        try await Task.sleep(for: .milliseconds(10))
        try require(fake.mediaReady == ["generation-1", "generation-2"], "a fresh explicit Start did not receive fresh greeting authority")

        let queuedGateFake = FakeTransport()
        let (queuedGate, queuedGateTarget) = try await connected(queuedGateFake)
        try queuedGate.select(queuedGateTarget)
        try await queuedGate.start(mode: .continuous, voice: .marin)
        let queuedGeneration = queuedGate.activeGeneration!
        await queuedGate.audioInterruptionBegan(generation: queuedGeneration)
        try await Task.sleep(for: .milliseconds(10))
        try require(queuedGateFake.mediaReady.isEmpty, "queued readiness ignored an interruption established before dispatch")
        await queuedGate.audioInterruptionEnded(generation: queuedGeneration, shouldResume: true)
        try await Task.sleep(for: .milliseconds(10))
        try require(queuedGateFake.mediaReady == [queuedGeneration], "release after queued readiness gating did not dispatch exactly once")

        let deferredFake = FakeTransport()
        deferredFake.initialPeerState = .connecting
        let (deferred, deferredTarget) = try await connected(deferredFake)
        try deferred.select(deferredTarget)
        try await deferred.start(mode: .continuous, voice: .marin)
        guard case let .active(deferredAuthority) = deferred.phase else { throw CheckFailure.failed("deferred greeting fixture was not active") }
        await deferred.audioInterruptionBegan(generation: deferredAuthority.generation)
        deferredFake.emit(.peerConnectionState(authority: deferredAuthority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(10))
        try require(deferredFake.mediaReady.isEmpty, "interrupted playback announced greeting readiness")
        await deferred.audioInterruptionEnded(generation: deferredAuthority.generation, shouldResume: true)
        try await Task.sleep(for: .milliseconds(10))
        try require(deferredFake.mediaReady == ["generation-1"], "same-generation interruption recovery did not release deferred readiness once")

        let unknownFake = FakeTransport()
        unknownFake.failMediaReady = true
        let (unknown, unknownTarget) = try await connected(unknownFake)
        try unknown.select(unknownTarget)
        try await unknown.start(mode: .continuous, voice: .marin)
        try await Task.sleep(for: .milliseconds(10))
        guard case let .active(unknownAuthority) = unknown.phase else { throw CheckFailure.failed("unknown readiness fixture was not active") }
        unknownFake.emit(.peerConnectionState(authority: unknownAuthority.peerAuthority, state: .disconnected))
        unknownFake.emit(.peerConnectionState(authority: unknownAuthority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(10))
        try require(unknownFake.mediaReady == ["generation-1"], "unknown readiness outcome was retried")
    }

    @MainActor
    private static func externalAudioAuthorizationContract() async throws {
        let fake = FakeTransport()
        let (subject, target) = try await connected(fake)
        subject.requireExternalAudioAuthorization()
        try subject.select(target)
        try await subject.start(mode: .continuous, voice: .marin)
        guard let authority = subject.activeSessionAuthority else {
            throw CheckFailure.failed("external-audio session authority was unavailable")
        }
        try require(!fake.microphone && !fake.playback && fake.mediaReady.isEmpty,
                    "provider setup opened tracks or greeting before CallKit authorization")
        subject.setExternalAudioAuthorized(
            generation: authority.generation,
            peerAuthority: PeerConnectionAuthority(revision: 999, peerIdentifier: "stale"),
            authorized: true
        )
        try require(!fake.microphone && !fake.playback && fake.mediaReady.isEmpty,
                    "replacement peer authorized CallKit media")
        subject.setExternalAudioAuthorized(
            generation: authority.generation,
            peerAuthority: authority.peerAuthority,
            authorized: true
        )
        try await Task.sleep(for: .milliseconds(10))
        try require(fake.microphone && fake.playback && fake.mediaReady == [authority.generation],
                    "exact CallKit authorization did not release tracks and one-shot greeting")
        fake.emit(.peerConnectionState(authority: authority.peerAuthority, state: .disconnected))
        try await Task.sleep(for: .milliseconds(5))
        subject.applyExternalAudioTransition(
            generation: authority.generation,
            peerAuthority: authority.peerAuthority,
            revision: 1,
            authorized: false
        )
        fake.emit(.peerConnectionState(authority: authority.peerAuthority, state: .connected))
        try await Task.sleep(for: .milliseconds(5))
        try require(!fake.microphone && !fake.playback,
                    "CallKit gate loss during reconnect was ignored or reopened on peer recovery")
        subject.applyExternalAudioTransition(
            generation: authority.generation,
            peerAuthority: authority.peerAuthority,
            revision: 2,
            authorized: true
        )
        try require(fake.microphone && fake.playback,
                    "actual accepted resume did not reopen recovered exact media")
        subject.applyExternalAudioTransition(
            generation: authority.generation,
            peerAuthority: authority.peerAuthority,
            revision: 3,
            authorized: false
        )
        try require(!fake.microphone && !fake.playback,
                    "CallKit deauthorization did not synchronously gate both directions")
        fake.emit(.sessionEnded(code: "websocket_closed", message: "lost"))
        try await Task.sleep(for: .milliseconds(10))
        try require(!subject.mayAuthorizeExternalAudio(generation: authority.generation, peerAuthority: authority.peerAuthority),
                    "Core Unknown state remained eligible to reopen the audio unit")
        subject.setExternalAudioAuthorized(
            generation: authority.generation,
            peerAuthority: authority.peerAuthority,
            authorized: true
        )
        try require(!fake.microphone && !fake.playback,
                    "late CallKit activation reopened Core Unknown media")

        let pttFake = FakeTransport()
        pttFake.delayHeldAcknowledgement = true
        let (pttSubject, pttTarget) = try await connected(pttFake)
        pttSubject.requireExternalAudioAuthorization()
        try pttSubject.select(pttTarget)
        try await pttSubject.start(mode: .ptt, voice: .marin)
        guard let pttAuthority = pttSubject.activeSessionAuthority else {
            throw CheckFailure.failed("external-audio PTT authority was unavailable")
        }
        pttSubject.applyExternalAudioTransition(
            generation: pttAuthority.generation,
            peerAuthority: pttAuthority.peerAuthority,
            revision: 1,
            authorized: true
        )
        let staleGesture = pttSubject.pttGestureEpoch
        let pendingACK = Task { try await pttSubject.beginPushToTalk(gestureEpoch: staleGesture) }
        try await Task.sleep(for: .milliseconds(10))
        pttSubject.applyExternalAudioTransition(
            generation: pttAuthority.generation,
            peerAuthority: pttAuthority.peerAuthority,
            revision: 2,
            authorized: false
        )
        let cancelPendingACK = Task { await pttSubject.performPendingExternalPTTCancel() }
        pttSubject.applyExternalAudioTransition(
            generation: pttAuthority.generation,
            peerAuthority: pttAuthority.peerAuthority,
            revision: 3,
            authorized: true
        )
        await cancelPendingACK.value
        try await pendingACK.value
        try require(!pttSubject.pttHeld && !pttFake.microphone && pttSubject.pttGestureEpoch != staleGesture,
                    "gate loss plus rapid reactivation reopened pending PTT ACK or old gesture")
        do {
            try await pttSubject.beginPushToTalk(gestureEpoch: staleGesture)
            throw CheckFailure.failed("old physical PTT gesture remained reusable after gate loss")
        } catch let failure as CheckFailure { throw failure }
        catch {}
        pttSubject.applyExternalAudioTransition(
            generation: pttAuthority.generation,
            peerAuthority: pttAuthority.peerAuthority,
            revision: 4,
            authorized: false
        )
        pttSubject.applyExternalAudioTransition(
            generation: pttAuthority.generation,
            peerAuthority: pttAuthority.peerAuthority,
            revision: 3,
            authorized: true
        )
        try require(pttSubject.audioInterrupted && !pttFake.microphone && !pttFake.playback,
                    "old audio-resume transition cleared a newer Hold/deactivation")

        let failedCancelFake = FakeTransport()
        let (failedCancel, failedTarget) = try await connected(failedCancelFake)
        failedCancel.requireExternalAudioAuthorization()
        try failedCancel.select(failedTarget)
        try await failedCancel.start(mode: .ptt, voice: .marin)
        guard let failedAuthority = failedCancel.activeSessionAuthority else {
            throw CheckFailure.failed("failed-cancel authority was unavailable")
        }
        failedCancel.applyExternalAudioTransition(generation: failedAuthority.generation, peerAuthority: failedAuthority.peerAuthority, revision: 1, authorized: true)
        try await failedCancel.beginPushToTalk(gestureEpoch: failedCancel.pttGestureEpoch)
        failedCancelFake.failPTT = true
        failedCancel.applyExternalAudioTransition(generation: failedAuthority.generation, peerAuthority: failedAuthority.peerAuthority, revision: 2, authorized: false)
        await failedCancel.performPendingExternalPTTCancel()
        try require({ if case .uncertain = failedCancel.phase { true } else { false } }() &&
                    !failedCancelFake.microphone && !failedCancelFake.playback,
                    "current failed PTT cancel was swallowed instead of retaining Unknown gated state")

        let delayedCancelFake = FakeTransport()
        delayedCancelFake.delayReleaseAcknowledgement = true
        let (delayedCancel, delayedTarget) = try await connected(delayedCancelFake)
        delayedCancel.requireExternalAudioAuthorization()
        try delayedCancel.select(delayedTarget)
        try await delayedCancel.start(mode: .ptt, voice: .marin)
        guard let oldAuthority = delayedCancel.activeSessionAuthority else {
            throw CheckFailure.failed("delayed-cancel authority was unavailable")
        }
        delayedCancel.applyExternalAudioTransition(generation: oldAuthority.generation, peerAuthority: oldAuthority.peerAuthority, revision: 1, authorized: true)
        try await delayedCancel.beginPushToTalk(gestureEpoch: delayedCancel.pttGestureEpoch)
        delayedCancel.applyExternalAudioTransition(generation: oldAuthority.generation, peerAuthority: oldAuthority.peerAuthority, revision: 2, authorized: false)
        let oldCancel = Task { await delayedCancel.performPendingExternalPTTCancel() }
        try await Task.sleep(for: .milliseconds(10))
        let duplicateCancel = Task { await delayedCancel.performPendingExternalPTTCancel() }
        await duplicateCancel.value
        try require(delayedCancelFake.ptt.filter { !$0.held && $0.cancel }.count == 1,
                    "concurrent external-gate helpers sent duplicate cancel commands")
        delayedCancelFake.emit(.voiceState(generation: oldAuthority.generation, state: "closed", reason: "provider_closed"))
        try await Task.sleep(for: .milliseconds(5))
        delayedCancelFake.emit(.roster(connected: true, agents: [delayedTarget]))
        try await Task.sleep(for: .milliseconds(5))
        try delayedCancel.select(delayedTarget)
        try await delayedCancel.start(mode: .ptt, voice: .marin)
        let replacementGeneration = delayedCancel.activeGeneration
        await oldCancel.value
        try require(delayedCancel.activeGeneration == replacementGeneration &&
                    { if case .active = delayedCancel.phase { true } else { false } }(),
                    "old delayed cancel mutated replacement session on return")
    }

    @MainActor
    private static func durableReconnectAndRevocation() async throws {
        let fake = FakeTransport()
        let subject = VoiceSessionCoordinator(transport: fake)
        try await subject.connect(origin: URL(string: "HTTPS://VOICE.Example.TEST:443/")!, pairingToken: nil)
        try require(fake.authentications.count == 1 && fake.authentications[0].0 == "https://voice.example.test" && fake.authentications[0].1 == nil, "blank token did not select exact-origin renewal")
        fake.emit(.deviceRevoked)
        try await Task.sleep(for: .milliseconds(10))
        try require(subject.phase == .disconnected && fake.teardownCount == 1, "device revocation did not disconnect and tear down media")
        try require(fake.forgottenOrigins.isEmpty, "disconnect or revocation event incorrectly invoked local forget")
        try await subject.forgetDevice(origin: URL(string: "https://voice.example.test")!)
        try require(fake.forgottenOrigins == ["https://voice.example.test"], "explicit local forget did not delete the exact-origin credential")
    }

    @MainActor
    private static func connected(_ fake: FakeTransport) async throws -> (VoiceSessionCoordinator, AgentEndpoint) {
        let subject = VoiceSessionCoordinator(transport: fake)
        let agent = AgentEndpoint(id: "agent", endpointEpoch: "epoch-live", name: "Research")
        try await subject.connect(origin: URL(string: "https://voice.example.test")!, pairingToken: "one-use")
        fake.emit(.roster(connected: true, agents: [agent]))
        try await Task.sleep(for: .milliseconds(10))
        return (subject, agent)
    }

    @MainActor
    private static func activePTT(_ fake: FakeTransport) async throws -> VoiceSessionCoordinator {
        let (subject, agent) = try await connected(fake)
        try subject.select(agent)
        try await subject.start(mode: .ptt, voice: .marin)
        return subject
    }

    @MainActor
    private static func exactEpochAndContinuousStart() async throws {
        let fake = FakeTransport()
        let (subject, live) = try await connected(fake)
        let stale = AgentEndpoint(id: live.id, endpointEpoch: "old", name: live.name)
        do { try subject.select(stale); throw CheckFailure.failed("stale epoch was accepted") }
        catch VoiceError.staleTarget {}
        try subject.select(live)
        try await subject.start(mode: .continuous, voice: .marin)
        try require(fake.startedTargets == [live], "start did not preserve exact target")
        try require(fake.startedRoutings == [.liaison], "native voice did not request central liaison routing")
        let connectionID = "abcdefghijklmnopqrstuv"
        let body = LiveSessionRequest(target: live, mode: .continuous, voice: .marin, routing: .liaison).gatewayBody(sdp: "offer", connectionID: connectionID)
        try require(body["routingMode"] == "liaison" && body["connectionId"] == connectionID && body["conversationMode"] == nil, "gateway routing contract lost liaison or exact WebSocket authority")
        try require(body["targetId"] == live.id && body["targetEpoch"] == live.endpointEpoch, "gateway body lost exact target authority")
        try require(fake.microphone && fake.playback, "continuous liaison media gates are wrong")
    }

    @MainActor
    private static func mediaAndCaptionPresentationContract() async throws {
        let clock = TestMonotonicClock(now: 1_000_000_000)
        let fake = FakeTransport()
        let subject = VoiceSessionCoordinator(transport: fake, monotonicNanoseconds: { clock.now })
        let agent = AgentEndpoint(id: "agent", endpointEpoch: "epoch-live", name: "Research")
        try await subject.connect(origin: URL(string: "https://voice.example.test")!, pairingToken: "one-use")
        fake.emit(.roster(connected: true, agents: [agent])); try await Task.sleep(for: .milliseconds(10))
        try subject.select(agent); try await subject.start(mode: .continuous, voice: .marin)
        guard case let .active(authority) = subject.phase else { throw CheckFailure.failed("presentation fixture did not become active") }
        var controlChanges = 0
        var presentationChanges = 0
        subject.didChange = { controlChanges += 1 }
        subject.presentationDidChange = { presentationChanges += 1 }
        try require(VoiceMediaPollPolicy.accepts(
            requestStartedAtUptimeNanoseconds: 1_000,
            completedAtUptimeNanoseconds: 501_000,
            capturedGateRevision: 7,
            currentGateRevision: 7
        ), "timely same-gate media poll was rejected")
        try require(!VoiceMediaPollPolicy.accepts(
            requestStartedAtUptimeNanoseconds: 1_000,
            completedAtUptimeNanoseconds: 500_001_001,
            capturedGateRevision: 7,
            currentGateRevision: 7
        ), "delayed stats result became a fresh media observation")
        try require(!VoiceMediaPollPolicy.accepts(
            requestStartedAtUptimeNanoseconds: 1_000,
            completedAtUptimeNanoseconds: 2_000,
            capturedGateRevision: 7,
            currentGateRevision: 8
        ), "same-peer media gate toggle accepted an in-flight stats result")
        var remoteActivity = VoiceRemoteSourceActivityTracker()
        try require(remoteActivity.observe(sourceID: 1, rtpTimestamp: 10, level: 0.8, observedAtUptimeNanoseconds: 1_000) == 0, "initial remote marker was treated as fresh activity")
        try require(remoteActivity.observe(sourceID: 1, rtpTimestamp: 10, level: 0.8, observedAtUptimeNanoseconds: 81_000_000) == 0, "unchanged initial remote marker became active on its second poll")
        try require(remoteActivity.observe(sourceID: 2, rtpTimestamp: 20, level: 0.9, observedAtUptimeNanoseconds: 82_000_000) == 0, "changed source identity skipped conservative baselining")
        try require(remoteActivity.observe(sourceID: 2, rtpTimestamp: 20, level: 0.9, observedAtUptimeNanoseconds: 162_000_000) == 0, "new source baseline became active without RTP advance")
        try require(remoteActivity.observe(sourceID: 2, rtpTimestamp: 21, level: 0.7, observedAtUptimeNanoseconds: 163_000_000) == 0.7, "genuine same-source RTP advance was not exposed")
        try require(remoteActivity.observe(sourceID: 2, rtpTimestamp: 21, level: 0.6, observedAtUptimeNanoseconds: 663_000_000) == 0.6, "freshness boundary rejected the advanced remote marker too early")
        try require(remoteActivity.observe(sourceID: 2, rtpTimestamp: 21, level: 0.6, observedAtUptimeNanoseconds: 663_000_001) == 0, "unchanged remote marker survived its freshness bound")
        remoteActivity.reset()
        try require(remoteActivity.observe(sourceID: 2, rtpTimestamp: 21, level: 0.6, observedAtUptimeNanoseconds: 700_000_000) == 0, "resumed remote observation reused a pre-pause marker")

        fake.emitMedia(.init(
            generation: authority.generation,
            peerAuthority: authority.peerAuthority,
            observedAtUptimeNanoseconds: clock.now,
            outgoingLevel: 0.7,
            playbackLevel: 0.4,
            speakerActive: true
        ))
        try require(subject.visualMediaState == .init(generation: authority.generation, outgoingLevel: 0.7, playbackLevel: 0.4, speakerActive: true), "exact fresh media sample was not exposed")
        try require(controlChanges == 0 && presentationChanges == 1, "meter refresh entered control lifecycle callbacks")
        for _ in 1...8 {
            fake.emitMedia(.init(
                generation: authority.generation,
                peerAuthority: authority.peerAuthority,
                observedAtUptimeNanoseconds: clock.now,
                outgoingLevel: 0.7,
                playbackLevel: 0.4,
                speakerActive: true
            ))
        }
        try require(controlChanges == 0 && presentationChanges == 9, "meter burst issued control-state work")
        fake.emitMedia(.init(generation: "wrong", peerAuthority: authority.peerAuthority, observedAtUptimeNanoseconds: clock.now, outgoingLevel: 1, playbackLevel: 1, speakerActive: true))
        fake.emitMedia(.init(generation: authority.generation, peerAuthority: .init(revision: 99, peerIdentifier: "wrong"), observedAtUptimeNanoseconds: clock.now, outgoingLevel: 1, playbackLevel: 1, speakerActive: true))
        try require(subject.visualMediaState?.outgoingLevel == 0.7, "wrong generation or peer replaced authoritative media levels")
        subject.setUserMuted(true)
        try require(subject.visualMediaState?.outgoingLevel == 0 && subject.visualMediaState?.playbackLevel == 0.4, "mute did not gate only outgoing presentation")
        subject.setUserMuted(false)
        fake.emitMedia(.init(
            generation: authority.generation,
            peerAuthority: authority.peerAuthority,
            observedAtUptimeNanoseconds: clock.now - 499_000_000,
            outgoingLevel: 0.7,
            playbackLevel: 0.4,
            speakerActive: true
        ))
        try require(subject.visualMediaState != nil, "near-budget timely stats result was rejected immediately")
        presentationChanges = 0
        clock.now += 2_000_000
        try await Task.sleep(for: .milliseconds(20))
        try require(subject.visualMediaState == nil, "near-budget result received a second full freshness window")
        try require(presentationChanges > 0 && controlChanges == 2, "remaining-budget expiry did not isolate UI invalidation from mute control changes")

        fake.emit(.caption(generation: authority.generation, speaker: "user", delta: "User A ", groupID: "user-1"))
        fake.emit(.caption(generation: authority.generation, speaker: "assistant", delta: "Huh.", groupID: "assistant-1"))
        fake.emit(.caption(generation: authority.generation, speaker: "user", delta: "User B", groupID: "user-1"))
        try await Task.sleep(for: .milliseconds(10))
        try require(
            subject.captionThread.map(\.text) == ["User A ", "Huh.", "User B"] &&
                subject.captionThread.map(\.speaker) == [.user, .agent, .user] &&
                subject.captionPresentation == .init(generation: authority.generation, speaker: .user, text: "User B", isCurrent: true),
            "accepted interleaved caption order was aggregated or reordered"
        )
        subject.setUserMuted(true)
        try require(subject.captionPresentation == .init(generation: authority.generation, speaker: .user, text: "User B", isCurrent: false), "muted user activity remained current or changed accepted display order")
        subject.setUserMuted(false)
        try require(subject.captionPresentation?.speaker == .user && subject.captionPresentation?.isCurrent == true, "unmuted authorized current user group was not restored")
        await subject.audioInterruptionBegan(generation: authority.generation)
        try require(subject.captionPresentation?.speaker == .user && subject.captionPresentation?.isCurrent == false, "interrupted user activity remained current or changed accepted display order")
        await subject.audioInterruptionEnded(generation: authority.generation, shouldResume: true)
        try require(subject.captionPresentation?.speaker == .user && subject.captionPresentation?.isCurrent == true, "resumed exact-generation user activity did not regain current status")
        fake.emit(.peerConnectionState(authority: authority.peerAuthority, state: .disconnected)); try await Task.sleep(for: .milliseconds(5))
        try require(subject.captionPresentation?.speaker == .user && subject.captionPresentation?.isCurrent == false, "reconnecting user activity remained current or changed accepted display order")
        fake.emit(.peerConnectionState(authority: authority.peerAuthority, state: .connected)); try await Task.sleep(for: .milliseconds(5))
        try require(subject.captionPresentation?.speaker == .user && subject.captionPresentation?.isCurrent == true, "same-peer recovery did not restore authorized user currentness")
        fake.emit(.captionStable(generation: authority.generation, speaker: "user", groupID: "user-stale")); try await Task.sleep(for: .milliseconds(5))
        try require(subject.captionPresentation?.isCurrent == true, "mismatched stability ended the current user group")
        fake.emit(.captionStable(generation: authority.generation, speaker: "user", groupID: "user-1")); try await Task.sleep(for: .milliseconds(5))
        try require(subject.captionPresentation == .init(generation: authority.generation, speaker: .user, text: "User B", isCurrent: false), "stable user caption changed accepted display order")
        fake.emit(.caption(generation: authority.generation, speaker: "assistant", delta: String(repeating: "x", count: 600), groupID: "assistant-2")); try await Task.sleep(for: .milliseconds(5))
        try require(subject.captionPresentation?.speaker == .agent && subject.captionPresentation?.text.count == 500, "agent caption was not a single bounded group")
        fake.emit(.caption(generation: authority.generation, speaker: "assistant", delta: "legacy", groupID: nil)); try await Task.sleep(for: .milliseconds(5))
        try require(subject.captionPresentation == .init(generation: authority.generation, speaker: .agent, text: "legacy", isCurrent: false), "missing metadata was not fail-silent/not-current")
        let captionsBeforeBackground = subject.captionPresentation
        subject.setPresentationVisible(false)
        try require(subject.visualMediaState == nil && subject.captionPresentation == captionsBeforeBackground, "background meter pause cleared captions or retained a level")
        subject.setPresentationVisible(true)
        try require(fake.mediaObservationChanges == [false, true], "scene visibility did not pause and resume only media observation")

        await subject.stop()
        try require(subject.visualMediaState == nil && subject.captionPresentation == nil, "Stop retained ephemeral presentation state")

        let pttFake = FakeTransport()
        let pttSubject = try await activePTT(pttFake)
        guard case let .active(pttAuthority) = pttSubject.phase else { throw CheckFailure.failed("PTT presentation fixture was not active") }
        pttFake.emitMedia(.init(
            generation: pttAuthority.generation,
            peerAuthority: pttAuthority.peerAuthority,
            observedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            outgoingLevel: 0.8,
            playbackLevel: 0.3,
            speakerActive: true
        ))
        try require(pttSubject.visualMediaState?.outgoingLevel == 0, "idle PTT exposed outgoing activity")
        try await pttSubject.beginPushToTalk(gestureEpoch: pttSubject.pttGestureEpoch)
        pttFake.emit(.caption(generation: pttAuthority.generation, speaker: "user", delta: "PTT words", groupID: "user-ptt")); try await Task.sleep(for: .milliseconds(5))
        try require(pttSubject.captionPresentation?.isCurrent == true, "acknowledged PTT hold did not authorize its matching current user group")
        try require(pttSubject.visualMediaState == nil, "new PTT hold reused an idle or previous-hold sample")
        pttFake.emitMedia(.init(
            generation: pttAuthority.generation,
            peerAuthority: pttAuthority.peerAuthority,
            observedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            outgoingLevel: 0.8,
            playbackLevel: 0.3,
            speakerActive: true
        ))
        try require(pttSubject.visualMediaState?.outgoingLevel == 0.8 && pttSubject.visualMediaState?.playbackLevel == 0 && pttSubject.visualMediaState?.speakerActive == false, "held PTT did not gate playback or expose only its fresh outgoing level")
        await pttSubject.audioInterruptionBegan(generation: pttAuthority.generation)
        try require(pttSubject.visualMediaState == nil, "audio interruption retained media presentation authority")
        try require(pttSubject.captionPresentation?.isCurrent == false, "interrupted or released PTT user activity remained current")
    }

    @MainActor
    private static func pttReleaseHasNoClientFlush() async throws {
        let fake = FakeTransport()
        let subject = try await activePTT(fake)
        try require(!fake.microphone && fake.playback, "idle PTT liaison gates are wrong")
        try await subject.beginPushToTalk(gestureEpoch: subject.pttGestureEpoch)
        try require(fake.microphone && !fake.playback, "accepted hold did not gate media correctly")
        try await subject.endPushToTalk()
        try require(!fake.microphone && fake.playback, "release did not restore liaison playback")
        try require(fake.ptt == [
            .init(generation: "generation-1", held: true, cancel: false, commandSequence: 1),
            .init(generation: "generation-1", held: false, cancel: false, commandSequence: 2),
        ], "PTT sequence was not strict")
        try require(fake.startCount == 1, "release created extra work instead of leaving trailing flush to gateway")
        fake.emit(.pttReady(generation: "wrong")); try await Task.sleep(for: .milliseconds(10))
        try require(subject.pttFinishing, "stale generation changed PTT state")
        fake.emit(.pttReady(generation: "generation-1")); try await Task.sleep(for: .milliseconds(10))
        try require(!subject.pttFinishing, "matching ready event was ignored")
    }

    @MainActor
    private static func fastReleaseNeverOpensCaptureAfterAcknowledgement() async throws {
        let fake = FakeTransport()
        fake.delayHeldAcknowledgement = true
        let subject = try await activePTT(fake)
        let press = Task { try await subject.beginPushToTalk(gestureEpoch: subject.pttGestureEpoch) }
        try await Task.sleep(for: .milliseconds(10))
        try await subject.endPushToTalk()
        try await press.value
        try require(!fake.microphone, "fast release reopened capture after the held acknowledgement")
        try require(fake.ptt.map(\.commandSequence) == [1, 2], "fast release lost strict command order")
    }

    @MainActor
    private static func stopFencesPendingStart() async throws {
        let fake = FakeTransport()
        fake.delayStart = true
        let (subject, agent) = try await connected(fake)
        try subject.select(agent)
        let pending = Task { try await subject.start(mode: .continuous, voice: .marin) }
        try await Task.sleep(for: .milliseconds(10))
        guard let pendingScope = subject.exactStopScope() else { throw CheckFailure.failed("pending Start had no exact stop scope") }
        await subject.stop(ifCurrent: pendingScope)
        do { try await subject.start(mode: .continuous, voice: .marin); throw CheckFailure.failed("new start overlapped pending start") }
        catch VoiceError.notReady {}
        do { try await pending.value; throw CheckFailure.failed("stopped start became active") }
        catch is RetainedVoiceStartAuthority {}
        guard case .uncertain = subject.phase else { throw CheckFailure.failed("accepted close request was treated as provider-closure proof") }
        try require(subject.activeGeneration == "generation-1" && !fake.microphone && !fake.playback, "stale start completion discarded exact authority or retained media")
        try require(fake.closed == ["generation-1"], "stale start generation was not closed exactly once")

        let replacementFake = FakeTransport()
        let (replacement, replacementAgent) = try await connected(replacementFake)
        try replacement.select(replacementAgent)
        try await replacement.start(mode: .continuous, voice: .marin)
        guard let oldScope = replacement.exactStopScope() else { throw CheckFailure.failed("active call had no exact stop scope") }
        replacementFake.emit(.voiceState(generation: "generation-1", state: "closed", reason: "provider_closed"))
        try await Task.sleep(for: .milliseconds(5))
        try replacement.select(replacementAgent)
        try await replacement.start(mode: .continuous, voice: .marin)
        await replacement.stop(ifCurrent: oldScope)
        try require(replacement.activeGeneration == "generation-2",
                    "delayed old exact stop scope stopped its replacement")
    }

    @MainActor
    private static func startupAllocationRetentionContract() async throws {
        for (requestStarted, failure, expected) in [
            (false, VoiceStartRequestFailureKind.canceled, false),
            (true, .canceled, true),
            (true, .transport, true),
            (true, .invalidResponse, true),
            (true, .httpStatus(408), true),
            (true, .httpStatus(500), true),
            (true, .httpStatus(503), true),
            (true, .httpStatus(400), false),
            (true, .httpStatus(401), false),
            (true, .localPreflight, false),
        ] {
            try require(
                VoiceStartRequestOutcomePolicy.allocationIsUnknown(requestStarted: requestStarted, failure: failure) == expected,
                "session POST outcome classification was unsafe for \(failure)"
            )
        }

        let origin = URL(string: "https://voice.example.test")!
        let retainedFake = FakeTransport(); retainedFake.failStartRetained = true
        let (retained, retainedTarget) = try await connected(retainedFake)
        try retained.select(retainedTarget)
        do { try await retained.start(mode: .continuous, voice: .marin); throw CheckFailure.failed("known allocated failure became Ready") }
        catch is RetainedVoiceStartAuthority {}
        guard case .uncertain = retained.phase, let retainedEpoch = retained.closureRecoveryEpoch else {
            throw CheckFailure.failed("known allocated failure did not retain exact recovery scope")
        }
        try require(retained.activeGeneration == "generation-1" && retained.activeTarget == retainedTarget && retained.retainsAuthorityOrigin(origin), "known allocation lost generation/origin/target")
        retainedFake.closureReceiptResult = .unconfirmed
        let retainedConfirmed = try await retained.checkProviderClosure(epoch: retainedEpoch)
        try require(!retainedConfirmed, "unconfirmed receipt released known startup allocation")

        let safeFake = FakeTransport(); safeFake.failStartSafe = true
        let (safe, safeTarget) = try await connected(safeFake)
        try safe.select(safeTarget)
        do { try await safe.start(mode: .continuous, voice: .marin); throw CheckFailure.failed("definite pre-submit failure succeeded") }
        catch VoiceError.notReady {}
        try require(safe.phase == .ready && safe.activeGeneration == nil && !safe.hasUnknownStartAllocation, "definite pre-submit failure stranded authority")

        let pendingFake = FakeTransport(); pendingFake.delayStart = true
        let (pendingSubject, pendingTarget) = try await connected(pendingFake)
        try pendingSubject.select(pendingTarget)
        let pendingStart = Task { try await pendingSubject.start(mode: .continuous, voice: .marin) }
        try await Task.sleep(for: .milliseconds(10))
        await pendingSubject.disconnect()
        do { try await pendingSubject.forgetDevice(origin: origin); throw CheckFailure.failed("Forget crossed pending startup") }
        catch VoiceError.callAlreadyActive {}
        do { try await pendingSubject.connect(origin: URL(string: "https://replacement.example.test")!, pairingToken: nil); throw CheckFailure.failed("new auth crossed pending startup") }
        catch VoiceError.callAlreadyActive {}
        do { try await pendingStart.value; throw CheckFailure.failed("pending disconnected Start became active") }
        catch is RetainedVoiceStartAuthority {}
        guard let pendingEpoch = pendingSubject.closureRecoveryEpoch else { throw CheckFailure.failed("pending allocation lost recovery epoch") }
        _ = try await pendingSubject.checkProviderClosure(epoch: pendingEpoch)
        try require(pendingFake.closureReceiptQueries.last?.0 == origin.absoluteString && pendingSubject.activeTarget == pendingTarget, "pending startup rebound original origin/target")
        try require(pendingFake.forgottenOrigins.isEmpty, "pending Forget deleted durable authorization")

        let unknownFake = FakeTransport(); unknownFake.delayStart = true; unknownFake.failStartUnknown = true
        let (unknown, unknownTarget) = try await connected(unknownFake)
        try unknown.select(unknownTarget)
        let unknownStart = Task { try await unknown.start(mode: .continuous, voice: .marin) }
        try await Task.sleep(for: .milliseconds(10))
        await unknown.applicationDidEnterBackground()
        unknownFake.emit(.sessionEnded(code: "socket_lost", message: "terminal during unknown POST"))
        try await Task.sleep(for: .milliseconds(5))
        do { try await unknownStart.value; throw CheckFailure.failed("unknown POST became Ready") }
        catch is UnknownVoiceStartAllocation {}
        guard case .uncertain = unknown.phase else { throw CheckFailure.failed("unknown POST did not remain blocked") }
        try require(unknown.hasUnknownStartAllocation && unknown.activeGeneration == nil && unknown.activeTarget == unknownTarget && unknown.retainsAuthorityOrigin(origin), "unknown POST guessed or discarded original authority")
        unknownFake.emit(.deviceRevoked); unknownFake.emit(.roster(connected: true, agents: []))
        try await Task.sleep(for: .milliseconds(5))
        await unknown.disconnect()
        do { try await unknown.forgetDevice(origin: origin); throw CheckFailure.failed("terminal-chain Unknown allowed Forget") }
        catch VoiceError.callAlreadyActive {}
        do { try await unknown.connect(origin: origin, pairingToken: nil); throw CheckFailure.failed("terminal-chain Unknown allowed auth") }
        catch VoiceError.callAlreadyActive {}
        do { try await unknown.start(mode: .continuous, voice: .marin); throw CheckFailure.failed("terminal-chain Unknown allowed Start") }
        catch VoiceError.notReady {}
        try require(unknown.hasUnknownStartAllocation && unknown.activeTarget == unknownTarget && unknown.retainsAuthorityOrigin(origin), "terminal event chain erased unknown startup authority")
    }

    @MainActor
    private static func uncertainReleaseCanStillClose() async throws {
        let fake = FakeTransport()
        let subject = try await activePTT(fake)
        try await subject.beginPushToTalk(gestureEpoch: subject.pttGestureEpoch)
        fake.failPTT = true
        do { try await subject.endPushToTalk(); throw CheckFailure.failed("release failure was swallowed") } catch is URLError {}
        try require(!fake.microphone && !fake.playback, "uncertain release did not fail closed")
        await subject.stop()
        try require(fake.closed == ["generation-1"] && subject.phase == .stopping && subject.activeGeneration == "generation-1",
                    "Stop lost generation authority after uncertain release")
        fake.emit(.voiceState(generation: "generation-1", state: "closed", reason: "provider_closed"))
        try await Task.sleep(for: .milliseconds(10))
        try require(subject.phase == .ready && subject.activeGeneration == nil, "provider closure did not release retained authority")
    }

    @MainActor
    private static func backgroundLifecyclePolicy() async throws {
        let continuousFake = FakeTransport()
        let (continuous, target) = try await connected(continuousFake)
        try continuous.select(target)
        try await continuous.start(mode: .continuous, voice: .marin)
        await continuous.applicationDidEnterBackground()
        try require(
            continuous.activeGeneration == "generation-1" && continuousFake.closed.isEmpty &&
                continuousFake.microphone && continuousFake.playback,
            "background stopped or gated an established user-started continuous session"
        )

        let pttFake = FakeTransport()
        let ptt = try await activePTT(pttFake)
        try await ptt.beginPushToTalk(gestureEpoch: ptt.pttGestureEpoch)
        await ptt.applicationDidEnterBackground()
        try require(
            ptt.activeGeneration == "generation-1" && !pttFake.microphone && pttFake.playback &&
                pttFake.ptt.last == .init(generation: "generation-1", held: false, cancel: true, commandSequence: 2),
            "background retained a physical PTT hold or ended the established session"
        )

        let failedCancelFake = FakeTransport()
        let failedCancel = try await activePTT(failedCancelFake)
        try await failedCancel.beginPushToTalk(gestureEpoch: failedCancel.pttGestureEpoch)
        failedCancelFake.failPTT = true
        await failedCancel.applicationDidEnterBackground()
        try require(
            failedCancel.phase == .stopping && failedCancel.activeGeneration == "generation-1" &&
                failedCancelFake.closed == ["generation-1"] && !failedCancelFake.microphone && !failedCancelFake.playback,
            "failed background PTT cancellation left an uncertain paid session running"
        )

        let alreadyUncertainFake = FakeTransport()
        let alreadyUncertain = try await activePTT(alreadyUncertainFake)
        try await alreadyUncertain.beginPushToTalk(gestureEpoch: alreadyUncertain.pttGestureEpoch)
        alreadyUncertainFake.failPTT = true
        do { try await alreadyUncertain.endPushToTalk(); throw CheckFailure.failed("failed PTT release unexpectedly succeeded") }
        catch is URLError {}
        await alreadyUncertain.applicationDidEnterBackground()
        try require(
            { if case .uncertain = alreadyUncertain.phase { true } else { false } }() &&
                alreadyUncertain.activeGeneration == "generation-1" && alreadyUncertainFake.closed.isEmpty &&
                !alreadyUncertainFake.microphone && !alreadyUncertainFake.playback,
            "background retried or erased an already-uncertain generation"
        )

        let startingFake = FakeTransport()
        startingFake.delayStart = true
        let (starting, startingTarget) = try await connected(startingFake)
        try starting.select(startingTarget)
        let pending = Task { try await starting.start(mode: .continuous, voice: .marin) }
        try await Task.sleep(for: .milliseconds(10))
        await starting.applicationDidEnterBackground()
        do { try await pending.value; throw CheckFailure.failed("backgrounded pending Start became active") }
        catch is RetainedVoiceStartAuthority {}
        try require(
            { if case .uncertain = starting.phase { true } else { false } }() &&
                starting.activeGeneration == "generation-1" && starting.closureRecoveryEpoch != nil &&
                !startingFake.microphone && !startingFake.playback && startingFake.closed == ["generation-1"],
            "background discarded or activated a session that was allocated while Start was pending"
        )
    }

    @MainActor
    private static func userMuteAuthority() async throws {
        let continuousFake = FakeTransport()
        let (continuous, target) = try await connected(continuousFake)
        try continuous.select(target)
        try await continuous.start(mode: .continuous, voice: .marin)
        continuous.setUserMuted(true)
        try require(continuous.userMuted && !continuousFake.microphone && continuousFake.playback, "user mute also silenced reply playback")
        await continuous.audioInterruptionBegan(generation: "generation-1")
        await continuous.audioInterruptionEnded(generation: "generation-1", shouldResume: true)
        try require(continuous.userMuted && !continuousFake.microphone && continuousFake.playback, "interruption resume bypassed user mute")
        continuous.setUserMuted(false)
        try require(!continuous.userMuted && continuousFake.microphone && continuousFake.playback, "explicit unmute did not restore active continuous sending")
        await continuous.stop()
        do { try await continuous.start(mode: .continuous, voice: .marin); throw CheckFailure.failed("Start bypassed unconfirmed closure") }
        catch VoiceError.notReady {}
        continuousFake.emit(.voiceState(generation: "generation-1", state: "closed", reason: "provider_closed"))
        try await Task.sleep(for: .milliseconds(10))
        try continuous.select(target)
        try await continuous.start(mode: .continuous, voice: .marin)
        try require(!continuous.userMuted && continuousFake.microphone, "a fresh explicit Start did not use its documented unmuted default")

        let pttFake = FakeTransport()
        let ptt = try await activePTT(pttFake)
        ptt.setUserMuted(true)
        try await ptt.beginPushToTalk(gestureEpoch: ptt.pttGestureEpoch)
        try require(ptt.pttHeld && !pttFake.microphone && !pttFake.playback, "muted PTT hold enabled outbound audio")
        try await ptt.endPushToTalk(cancel: true)
        try require(ptt.userMuted && !pttFake.microphone && pttFake.playback, "PTT release changed mute authority or reply playback")
        ptt.setUserMuted(false)
        try require(!pttFake.microphone, "unmute opened PTT capture without a fresh physical hold")
    }

    @MainActor
    private static func audioInterruptionAndRouteSafety() async throws {
        let fake = FakeTransport()
        let (subject, target) = try await connected(fake)
        try subject.select(target)
        try await subject.start(mode: .continuous, voice: .marin)
        await subject.audioInterruptionBegan(generation: "generation-1")
        try require(subject.audioInterrupted && !fake.microphone && !fake.playback, "interruption left active media enabled")
        await subject.audioInterruptionEnded(generation: "stale-generation", shouldResume: true)
        try require(fake.reactivationCount == 0 && !fake.microphone && !fake.playback, "stale interruption resumed current media")
        await subject.audioInterruptionEnded(generation: "generation-1", shouldResume: true)
        try require(
            !subject.audioInterrupted && fake.reactivationCount == 0 && fake.microphone && fake.playback,
            "exact session independently activated audio or did not restore media gates"
        )
        await subject.stop()
        await subject.audioInterruptionEnded(generation: "generation-1", shouldResume: true)
        try require(
            fake.reactivationCount == 0 && fake.startCount == 1 && !fake.microphone && !fake.playback,
            "late interruption callback reopened media or created a new provider session after End"
        )

        let routeFake = FakeTransport()
        let (routeSubject, routeTarget) = try await connected(routeFake)
        try routeSubject.select(routeTarget)
        try await routeSubject.start(mode: .continuous, voice: .marin)
        await routeSubject.privateAudioRouteLost(generation: "generation-1")
        try require(
            routeFake.closed == ["generation-1"] && !routeFake.microphone && !routeFake.playback &&
                routeSubject.phase == .stopping && routeSubject.activeGeneration == "generation-1",
            "private-route loss did not End fail closed before speaker fallback"
        )

        let resettingFake = FakeTransport()
        let (resetting, resettingTarget) = try await connected(resettingFake)
        try resetting.select(resettingTarget)
        try await resetting.start(mode: .continuous, voice: .marin)
        await resetting.audioMediaServicesReset(generation: "generation-1")
        try require(
            resettingFake.closed == ["generation-1"] && resetting.phase == .stopping &&
                resetting.activeGeneration == "generation-1" && !resettingFake.microphone && !resettingFake.playback,
            "media-services reset did not require a fresh explicit Start"
        )

        let disconnectedFake = FakeTransport()
        let (disconnected, disconnectedTarget) = try await connected(disconnectedFake)
        try disconnected.select(disconnectedTarget)
        try await disconnected.start(mode: .continuous, voice: .marin)
        await disconnected.audioInterruptionBegan(generation: "generation-1")
        await disconnected.disconnect()
        await disconnected.audioInterruptionEnded(generation: "generation-1", shouldResume: true)
        try require(
            { if case .uncertain = disconnected.phase { true } else { false } }() &&
                disconnected.activeGeneration == "generation-1" && disconnectedFake.reactivationCount == 0 &&
                disconnectedFake.closed == ["generation-1"] && !disconnectedFake.microphone && !disconnectedFake.playback,
            "disconnect during interruption allowed a late resume"
        )

        let revokedFake = FakeTransport()
        let (revoked, revokedTarget) = try await connected(revokedFake)
        try revoked.select(revokedTarget)
        try await revoked.start(mode: .continuous, voice: .marin)
        await revoked.audioInterruptionBegan(generation: "generation-1")
        revokedFake.emit(.deviceRevoked)
        try await Task.sleep(for: .milliseconds(10))
        await revoked.audioInterruptionEnded(generation: "generation-1", shouldResume: true)
        try require(
            { if case .uncertain = revoked.phase { true } else { false } }() &&
                revoked.activeGeneration == "generation-1" && revokedFake.reactivationCount == 0 &&
                !revokedFake.microphone && !revokedFake.playback,
            "revocation during interruption allowed a late resume"
        )

        let startingRouteFake = FakeTransport()
        startingRouteFake.delayStart = true
        let (startingRoute, startingTarget) = try await connected(startingRouteFake)
        try startingRoute.select(startingTarget)
        let pendingStart = Task { try await startingRoute.start(mode: .continuous, voice: .marin) }
        try await Task.sleep(for: .milliseconds(10))
        startingRouteFake.emit(.privateAudioRouteLost(generation: nil))
        do { try await pendingStart.value; throw CheckFailure.failed("route-lost pending Start became active") }
        catch is RetainedVoiceStartAuthority {}
        try require(
            startingRouteFake.closed == ["generation-1"] &&
                { if case .uncertain = startingRoute.phase { true } else { false } }() &&
                startingRoute.activeGeneration == "generation-1" && startingRoute.closureRecoveryEpoch != nil &&
                !startingRouteFake.microphone && !startingRouteFake.playback,
            "private-route loss discarded or activated a session allocated while Start was pending"
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class MemoryCredentialStore: DurableDeviceCredentialStore {
    var values: [String: DurableDeviceCredential] = [:]
    func load(origin: String) throws -> DurableDeviceCredential? { values[origin] }
    func save(_ credential: DurableDeviceCredential) throws { values[credential.origin] = credential }
    func delete(origin: String) throws { values.removeValue(forKey: origin) }
}

private final class FakeAuthURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    nonisolated(unsafe) static var cookieStorage: HTTPCookieStorage?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var observedCookies: [HTTPCookie] = []
    nonisolated(unsafe) static var responseURLOverride: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw URLError(.badURL) }
            Self.observedCookies = Self.cookieStorage?.cookies(for: url) ?? []
            let (status, object) = try handler(request)
            let data = try JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(url: Self.responseURLOverride ?? url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static func installCookie(name: String, value: String, origin: URL) {
        guard let cookie = HTTPCookie(properties: [.originURL: origin, .path: "/", .name: name, .value: value, .secure: "TRUE"]) else { return }
        cookieStorage?.setCookie(cookie)
    }
}

@MainActor
private final class FakeTransport: VoiceTransport {
    struct PTT: Equatable {
        let generation: String
        let held: Bool
        let cancel: Bool
        let commandSequence: Int
    }

    var mediaLevelsDidChange: ((VoiceMediaLevelSample) -> Void)?
    let events: AsyncStream<GatewayEvent>
    private let continuation: AsyncStream<GatewayEvent>.Continuation
    var authentications: [(String, String?)] = []
    var forgottenOrigins: [String] = []
    var startedTargets: [AgentEndpoint] = []
    var startedRoutings: [ConversationRouting] = []
    var startCount = 0
    var ptt: [PTT] = []
    var mediaReady: [String] = []
    var mediaObservationChanges: [Bool] = []
    var closed: [String] = []
    var microphone = false
    var playback = false
    var teardownCount = 0
    var failPTT = false
    var failMediaReady = false
    var failClose = false
    var failStartRetained = false
    var failStartUnknown = false
    var failStartSafe = false
    var delayCloseAcknowledgement = false
    var delayHeldAcknowledgement = false
    var delayReleaseAcknowledgement = false
    var delayStart = false
    var delayedAuthenticationToken: String?
    var connectedOrigins: [String] = []
    var reactivationCount = 0
    var initialPeerState: PeerConnectionState = .connected
    var closureReceiptResult: ProviderClosureReceiptResult = .unconfirmed
    var closureReceiptQueries: [(String, String)] = []
    var delayClosureReceipt = false

    init() {
        let pair = AsyncStream<GatewayEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func emit(_ event: GatewayEvent) { continuation.yield(event) }
    func emitMedia(_ sample: VoiceMediaLevelSample) { mediaLevelsDidChange?(sample) }
    func authenticate(origin: URL, pairingToken: String?, deviceName: String) async throws {
        authentications.append((origin.absoluteString, pairingToken))
        if pairingToken == delayedAuthenticationToken { try await Task.sleep(for: .milliseconds(50)) }
    }
    func forgetDevice(origin: URL) throws { forgottenOrigins.append(origin.absoluteString) }
    func connectEvents(origin: URL) async throws { connectedOrigins.append(origin.absoluteString) }
    func disconnectEvents() {}
    func providerClosureReceipt(origin: URL, generation: String) async throws -> ProviderClosureReceiptResult {
        closureReceiptQueries.append((origin.absoluteString, generation))
        if delayClosureReceipt { try await Task.sleep(for: .milliseconds(50)) }
        return closureReceiptResult
    }
    func start(target: AgentEndpoint, mode: VoiceMode, voice: VoiceName, routing: ConversationRouting) async throws -> SessionAuthority {
        startCount += 1
        startedTargets.append(target)
        startedRoutings.append(routing)
        if delayStart { try await Task.sleep(for: .milliseconds(50)) }
        if failStartUnknown { throw UnknownVoiceStartAllocation(message: "fake unknown allocation") }
        if failStartSafe { throw VoiceError.notReady }
        let allocated = SessionAuthority(
            generation: "generation-\(startCount)",
            idleDeadline: .now.addingTimeInterval(300),
            hardDeadline: .now.addingTimeInterval(7_200),
            peerAuthority: PeerConnectionAuthority(revision: startCount, peerIdentifier: "fake-peer-\(startCount)"),
            initialPeerState: initialPeerState
        )
        if failStartRetained {
            throw RetainedVoiceStartAuthority(authority: allocated, message: "fake retained allocation")
        }
        return allocated
    }
    func announceMediaReady(generation: String) async throws {
        mediaReady.append(generation)
        if failMediaReady { throw URLError(.networkConnectionLost) }
    }
    func sendPushToTalk(generation: String, held: Bool, cancel: Bool, commandSequence: Int) async throws {
        ptt.append(.init(generation: generation, held: held, cancel: cancel, commandSequence: commandSequence))
        if held, delayHeldAcknowledgement { try await Task.sleep(for: .milliseconds(50)) }
        if !held, delayReleaseAcknowledgement { try await Task.sleep(for: .milliseconds(50)) }
        if failPTT { throw URLError(.networkConnectionLost) }
    }
    func close(generation: String) async throws {
        closed.append(generation)
        if delayCloseAcknowledgement { try await Task.sleep(for: .milliseconds(50)) }
        if failClose { throw URLError(.networkConnectionLost) }
    }
    func setMicrophoneEnabled(_ enabled: Bool) { microphone = enabled }
    func setPlaybackEnabled(_ enabled: Bool) { playback = enabled }
    func setMediaObservationEnabled(_ enabled: Bool) { mediaObservationChanges.append(enabled) }
    func teardownMedia() { teardownCount += 1; microphone = false; playback = false }
}
