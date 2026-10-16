@preconcurrency import CallKit
import Foundation
import PiVoiceCore

/// Owns every CallKit transaction and the one memory-only attempt snapshot.
/// App/UI integration is deliberately separate; this controller never starts a
/// call except from an explicit `requestStart` invocation.
@MainActor
final class PiVoiceCallKitController {
    private struct PendingMuteIntent {
        let actionUUID: UUID
        let callUUID: UUID
        let request: CallKitAttemptPolicy.MuteRequest
    }

    private struct PendingEndIntent: Equatable {
        let attempt: CallKitAttemptPolicy.Attempt
        let actionUUID: UUID
    }

    private struct StartContext {
        let attempt: CallKitAttemptPolicy.Attempt
        let target: AgentEndpoint
        let mode: VoiceMode
        let voice: VoiceName
    }

    private let coordinator: VoiceSessionCoordinator
    private let callController = CXCallController()
    private var policy: CallKitAttemptPolicy
    private var registry: CallKitProviderRegistry
    private var context: StartContext?
    private var nextProviderEpoch: UInt64 = 1
    private var registrationConsumed = false
    private var muteIntentLedger = CallKitMuteIntentLedger(capacity: 32)
    private var unsafeMuteAttributionEpoch: UInt64?
    private var pendingMuteActionUUID: UUID?
    private var pendingEndIntent: PendingEndIntent?
    private var lastCompletedAppEndActionUUID: UUID?
    private var audioTransitionRevision: UInt64 = 0
    private var lastCoreReadiness: (binding: CallKitAttemptPolicy.SessionBinding, eligible: Bool)?

    var didChange: (() -> Void)?
    var didFail: ((Error) -> Void)?
    var hasPendingStartupIntent: Bool {
        policy.currentAttempt != nil && policy.binding == nil && !policy.systemUIEnded
    }

    init(coordinator: VoiceSessionCoordinator) {
        self.coordinator = coordinator
        policy = CallKitAttemptPolicy(providerEpoch: 1)
        registry = CallKitProviderRegistry(
            configuration: Self.providerConfiguration(),
            registrationEpoch: 1
        )
        registry.mayEnableExact = { [weak coordinator] binding in
            coordinator?.mayAuthorizeExternalAudio(
                generation: binding.generation,
                peerAuthority: binding.peerAuthority
            ) == true
        }
        registry.resolveActivation = { [weak self] epoch in
            guard let self else { return .none }
            let action = self.policy.didActivate(providerEpoch: epoch)
            if case let .enableExact(binding) = action,
               !self.coordinator.mayAuthorizeExternalAudio(
                   generation: binding.generation,
                   peerAuthority: binding.peerAuthority
               ) {
                return .latchOnly
            }
            return action
        }
        registry.resolveDeactivation = { [weak self] epoch in
            guard let self else { return .none }
            return self.policy.didDeactivate(providerEpoch: epoch)
        }
        registry.acceptAudioAction = { [weak self] action in self?.acceptAudioAction(action) }
        registry.acceptProviderReset = { [weak self] epoch in self?.acceptProviderReset(epoch: epoch) }
        registry.acceptTimedOutAction = { [weak self] action, epoch in
            self?.acceptTimedOut(action, providerEpoch: epoch)
        }
        registry.performStart = { [weak self] action, epoch in self?.perform(action, providerEpoch: epoch) }
        registry.performEnd = { [weak self] action, epoch in self?.perform(action, providerEpoch: epoch) }
        registry.performMute = { [weak self] action, epoch in self?.perform(action, providerEpoch: epoch) }
        registry.performHold = { [weak self] action, epoch in self?.perform(action, providerEpoch: epoch) }
        coordinator.requireExternalAudioAuthorization()
    }

    func requestStart(target: AgentEndpoint, mode: VoiceMode, voice: VoiceName) async throws {
        guard coordinator.phase == .ready, coordinator.selected == target else { throw VoiceError.targetUnavailable }
        if registrationConsumed {
            let retiredProviderEpoch = registry.current.epoch
            nextProviderEpoch &+= 1
            guard registry.rotate(
                configuration: Self.providerConfiguration(),
                registrationEpoch: nextProviderEpoch,
                policy: &policy
            ) else { throw VoiceError.callAlreadyActive }
            registrationConsumed = false
            lastCoreReadiness = nil
            pendingEndIntent = nil
            lastCompletedAppEndActionUUID = nil
            _ = muteIntentLedger.retireRegistration(providerEpoch: retiredProviderEpoch)
            if unsafeMuteAttributionEpoch == retiredProviderEpoch { unsafeMuteAttributionEpoch = nil }
            pendingMuteActionUUID = nil
        }

        let callUUID = UUID()
        guard let attempt = registry.beginAttempt(
            callUUID: callUUID,
            targetID: target.id,
            targetEpoch: target.endpointEpoch,
            policy: &policy
        ) else { throw VoiceError.callAlreadyActive }
        registrationConsumed = true
        context = StartContext(attempt: attempt, target: target, mode: mode, voice: voice)

        let handle = CXHandle(type: .generic, value: target.displayName)
        let action = CXStartCallAction(call: callUUID, handle: handle)
        action.isVideo = false
        do {
            try await request(CXTransaction(action: action))
        } catch {
            let released = policy.releaseDefinitePreSubmitFailure(
                callUUID: callUUID,
                attemptEpoch: attempt.attemptEpoch
            )
            if released, context?.attempt == attempt { context = nil }
            throw error
        }
    }

    @discardableResult
    func requestEnd() async throws -> Bool {
        if policy.systemUIEnded || policy.currentAttempt == nil {
            // The system UI may already be gone while exact generation closure
            // remains retained. Retry that same generation without a new call.
            await coordinator.stop()
            return true
        }
        guard let attempt = policy.currentAttempt,
              case let .gateFulfillAndClose(binding) = policy.requestLocalEnd(callUUID: attempt.callUUID) else { return false }
        let stopScope = coordinator.exactStopScope()
        let action = CXEndCallAction(call: attempt.callUUID)
        let intent = PendingEndIntent(attempt: attempt, actionUUID: action.uuid)
        pendingEndIntent = intent
        lastCompletedAppEndActionUUID = nil
        registry.gateAudio()
        if let binding { applyAudioTransition(binding, authorized: false) }

        // If provider establishment has not entered Core yet, preventing its
        // deferred task from running is positive no-allocation proof. Retain
        // context in every other case until the exact result is known.
        if !policy.startActionAccepted {
            if policy.releaseDefinitePreSubmitFailure(
                callUUID: attempt.callUUID,
                attemptEpoch: attempt.attemptEpoch
            ) { context = nil }
        } else if stopScope == nil, coordinator.phase == .ready {
            if policy.releaseProvenNoProviderAllocation(
                callUUID: attempt.callUUID,
                attemptEpoch: attempt.attemptEpoch
            ) { context = nil }
        }
        didChange?()

        let requestTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            guard self.pendingEndIntent == intent,
                  self.registry.current.epoch == attempt.providerEpoch,
                  self.policy.currentAttempt == nil || self.policy.currentAttempt == attempt else { return false }
            try await self.request(CXTransaction(action: action))
            return true
        }
        if let stopScope { await coordinator.stop(ifCurrent: stopScope) }
        do {
            let submitted = try await requestTask.value
            guard submitted else { return false }
        } catch {
            guard pendingEndIntent == intent,
                  registry.current.epoch == attempt.providerEpoch,
                  policy.currentAttempt == nil || policy.currentAttempt == attempt else { return false }
            pendingEndIntent = nil
            policy.rejectLocalEndSubmission(callUUID: attempt.callUUID)
            throw error
        }
        let exactActionRemains = pendingEndIntent == intent || lastCompletedAppEndActionUUID == action.uuid
        return exactActionRemains && (policy.currentAttempt == nil || policy.currentAttempt == attempt)
    }

    /// Captures the exact current call and applies the privacy gate before
    /// returning. Only CallKit transaction submission is deferred.
    func requestMuted(_ muted: Bool) throws {
        guard let callUUID = policy.currentAttempt?.callUUID else { throw VoiceError.notReady }
        guard unsafeMuteAttributionEpoch != registry.current.epoch else {
            policy.forceMutedSupersedingPendingRequest()
            pendingMuteActionUUID = nil
            coordinator.setUserMuted(true)
            throw VoiceError.callAlreadyActive
        }
        guard !muteIntentLedger.isFull else {
            policy.forceMutedSupersedingPendingRequest()
            pendingMuteActionUUID = nil
            coordinator.setUserMuted(true)
            throw VoiceError.callAlreadyActive
        }
        let action = CXSetMutedCallAction(call: callUUID, muted: muted)
        let muteRequest: CallKitAttemptPolicy.MuteRequest
        switch policy.requestMuted(muted) {
        case .gateOutboundAndRequest(let exact):
            coordinator.setUserMuted(true)
            muteRequest = exact
        case .request(let exact):
            muteRequest = exact
        case .reject, .acceptedMuted, .acceptedUnmutedRestoreIfAllowed, .failedRemainMuted:
            throw VoiceError.notReady
        }
        let intent = PendingMuteIntent(actionUUID: action.uuid, callUUID: callUUID, request: muteRequest)
        let providerEpoch = registry.current.epoch
        guard muteIntentLedger.issueApp(
            actionUUID: action.uuid,
            callUUID: callUUID,
            providerEpoch: providerEpoch,
            request: muteRequest
        ) else {
            policy.forceMutedSupersedingPendingRequest()
            pendingMuteActionUUID = nil
            coordinator.setUserMuted(true)
            throw VoiceError.callAlreadyActive
        }
        pendingMuteActionUUID = action.uuid
        Task { [weak self] in
            guard let self,
                  let record = self.muteIntentLedger.record(
                    actionUUID: intent.actionUUID,
                    providerEpoch: providerEpoch
                  ),
                  record.state == .unresolved,
                  record.appRequest == intent.request,
                  self.registry.current.epoch == providerEpoch,
                  self.policy.currentAttempt?.callUUID == intent.callUUID else { return }
            do {
                try await self.request(CXTransaction(action: action))
            } catch {
                guard self.muteIntentLedger.retireDefiniteSubmissionFailure(
                    actionUUID: intent.actionUUID,
                    providerEpoch: providerEpoch
                ) != nil else { return }
                guard self.pendingMuteActionUUID == intent.actionUUID,
                      self.policy.currentAttempt?.callUUID == intent.callUUID else { return }
                self.pendingMuteActionUUID = nil
                _ = self.policy.completeMuteRequest(muteRequest, accepted: false)
                self.coordinator.setUserMuted(true)
                self.didFail?(error)
            }
        }
    }

    /// Idempotently reconciles late Core connectivity with the already-latched
    /// exact CallKit activation. It never starts, retries, or replaces a call.
    func reconcileCoreReadiness() {
        guard let attempt = policy.currentAttempt,
              let binding = policy.binding,
              attempt.providerEpoch == registry.current.epoch,
              !policy.systemUIEnded else {
            lastCoreReadiness = nil
            return
        }
        let eligible = coordinator.mayAuthorizeExternalAudio(
            generation: binding.generation,
            peerAuthority: binding.peerAuthority
        )
        if let lastCoreReadiness,
           lastCoreReadiness.binding == binding,
           lastCoreReadiness.eligible == eligible { return }
        lastCoreReadiness = (binding, eligible)
        if eligible {
            let action = registry.markPrimaryReady(
                attemptEpoch: attempt.attemptEpoch,
                generation: binding.generation,
                peerAuthority: binding.peerAuthority,
                policy: &policy
            )
            acceptAudioAction(action)
        } else {
            registry.gateAudio()
            applyAudioTransition(binding, authorized: false)
        }
    }

    func requestHeld(_ held: Bool) async throws {
        guard let callUUID = policy.currentAttempt?.callUUID else { throw VoiceError.notReady }
        try await request(CXTransaction(action: CXSetHeldCallAction(call: callUUID, onHold: held)))
    }

    func acceptProviderClosed(generation: String) {
        guard let attempt = policy.currentAttempt,
              let binding = policy.binding,
              binding.generation == generation,
              registry.current.epoch == attempt.providerEpoch else { return }
        registry.gateAudio()
        applyAudioTransition(binding, authorized: false)
        registry.current.provider.reportCall(
            with: attempt.callUUID,
            endedAt: Date(),
            reason: .remoteEnded
        )
        guard policy.providerClosed(generation: generation) else { return }
        context = nil
        lastCoreReadiness = nil
        pendingMuteActionUUID = nil
        didChange?()
    }

    private func perform(_ action: CXStartCallAction, providerEpoch: UInt64) {
        guard let attempt = policy.currentAttempt,
              attempt.callUUID == action.callUUID,
              attempt.providerEpoch == providerEpoch else {
            action.fail()
            return
        }
        guard let context,
              context.attempt == attempt,
              policy.acceptStartAction(callUUID: action.callUUID, providerEpoch: providerEpoch) ==
                .fulfillPromptly(attemptEpoch: context.attempt.attemptEpoch) else {
            // A background End can beat the provider's Start callback. This
            // exact rejection proves no provider session request was issued.
            if policy.systemUIEnded, !policy.startActionAccepted {
                _ = policy.releaseDefinitePreSubmitFailure(
                    callUUID: attempt.callUUID,
                    attemptEpoch: attempt.attemptEpoch
                )
                lastCoreReadiness = nil
                didChange?()
            }
            action.fail()
            return
        }

        // CallKit's deadline is independent of provider setup.
        action.fulfill()
        registry.current.provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        didChange?()
        Task { [weak self] in await self?.establishProviderSession(context) }
    }

    private func establishProviderSession(_ exact: StartContext) async {
        guard isCurrent(exact), !policy.systemUIEnded,
              coordinator.phase == .ready,
              coordinator.selected == exact.target else {
            completeProvenNoAllocationFailure(exact, error: VoiceError.targetUnavailable)
            return
        }
        do {
            coordinator.requireExternalAudioAuthorization()
            try await coordinator.start(mode: exact.mode, voice: exact.voice)
            guard isAttemptCurrent(exact), let authority = coordinator.activeSessionAuthority else {
                return
            }
            _ = registry.bindSession(
                attemptEpoch: exact.attempt.attemptEpoch,
                generation: authority.generation,
                peerAuthority: authority.peerAuthority,
                policy: &policy
            )
            let binding = CallKitAttemptPolicy.SessionBinding(
                generation: authority.generation,
                peerAuthority: authority.peerAuthority
            )
            if policy.systemUIEnded {
                registry.gateAudio()
                applyAudioTransition(binding, authorized: false)
                if let stopScope = coordinator.exactStopScope() {
                    Task { [weak self] in
                        guard let self, self.isAttemptCurrent(exact) else { return }
                        await self.coordinator.stop(ifCurrent: stopScope)
                    }
                }
                didChange?()
                return
            }
            lastCoreReadiness = (
                binding,
                coordinator.mayAuthorizeExternalAudio(
                    generation: binding.generation,
                    peerAuthority: binding.peerAuthority
                )
            )
            let readiness = registry.markPrimaryReady(
                attemptEpoch: exact.attempt.attemptEpoch,
                generation: authority.generation,
                peerAuthority: authority.peerAuthority,
                policy: &policy
            )
            // Notify only after the inout borrow above has ended.
            acceptAudioAction(readiness)
            if !policy.systemUIEnded {
                registry.current.provider.reportOutgoingCall(with: exact.attempt.callUUID, connectedAt: Date())
            }
            didChange?()
        } catch let retained as RetainedVoiceStartAuthority {
            guard isAttemptCurrent(exact) else { return }
            let wasAlreadyEnded = policy.systemUIEnded
            _ = registry.bindSession(
                attemptEpoch: exact.attempt.attemptEpoch,
                generation: retained.authority.generation,
                peerAuthority: retained.authority.peerAuthority,
                policy: &policy
            )
            _ = policy.detachSystemUIAfterProviderFailure(callUUID: exact.attempt.callUUID)
            registry.gateAudio()
            registry.current.provider.reportCall(with: exact.attempt.callUUID, endedAt: Date(), reason: .failed)
            if wasAlreadyEnded {
                if let stopScope = coordinator.exactStopScope() {
                    Task { [weak self] in
                        guard let self, self.isAttemptCurrent(exact) else { return }
                        await self.coordinator.stop(ifCurrent: stopScope)
                    }
                }
            } else {
                didFail?(retained)
            }
            didChange?()
        } catch let unknown as UnknownVoiceStartAllocation {
            guard isCurrent(exact) else { return }
            _ = policy.detachSystemUIAfterProviderFailure(callUUID: exact.attempt.callUUID)
            registry.gateAudio()
            registry.current.provider.reportCall(with: exact.attempt.callUUID, endedAt: Date(), reason: .failed)
            didFail?(unknown)
            didChange?()
        } catch {
            guard isAttemptCurrent(exact) else { return }
            if policy.systemUIEnded {
                if policy.releaseProvenNoProviderAllocation(
                    callUUID: exact.attempt.callUUID,
                    attemptEpoch: exact.attempt.attemptEpoch
                ) { context = nil }
                lastCoreReadiness = nil
                didChange?()
                return
            }
            guard isCurrent(exact) else { return }
            completeProvenNoAllocationFailure(exact, error: error)
        }
    }

    private func completeProvenNoAllocationFailure(_ exact: StartContext, error: Error) {
        guard isCurrent(exact) else { return }
        _ = policy.releaseProvenNoProviderAllocation(
            callUUID: exact.attempt.callUUID,
            attemptEpoch: exact.attempt.attemptEpoch
        )
        registry.gateAudio()
        registry.current.provider.reportCall(with: exact.attempt.callUUID, endedAt: Date(), reason: .failed)
        context = nil
        didFail?(error)
        didChange?()
    }

    private func perform(_ action: CXEndCallAction, providerEpoch: UInt64) {
        guard registry.current.epoch == providerEpoch else { action.fail(); return }
        let attempt = policy.currentAttempt
        let stopScope = coordinator.exactStopScope()
        switch policy.acceptEndAction(callUUID: action.callUUID) {
        case .gateFulfillAndClose(let binding):
            if let pending = pendingEndIntent, pending.attempt.callUUID == action.callUUID {
                if pending.actionUUID == action.uuid { lastCompletedAppEndActionUUID = action.uuid }
                pendingEndIntent = nil
            }
            registry.gateAudio()
            if let binding { applyAudioTransition(binding, authorized: false) }
            action.fulfill()
            didChange?()
            if let attempt, let stopScope {
                Task { [weak self] in
                    guard let self,
                          self.policy.currentAttempt == attempt,
                          self.policy.systemUIEnded else { return }
                    await self.coordinator.stop(ifCurrent: stopScope)
                }
            }
        case .reject, .retryRetainedClose:
            action.fail()
        }
    }

    private func perform(_ action: CXSetMutedCallAction, providerEpoch: UInt64) {
        // Completed actions and known UUIDs are classified before the native
        // branch. A forgotten app/native Unmute can never be relabeled native.
        if action.isComplete {
            if muteIntentLedger.retireCompleted(
                actionUUID: action.uuid,
                providerEpoch: providerEpoch
            ) != nil, pendingMuteActionUUID == action.uuid {
                pendingMuteActionUUID = nil
                policy.forceMutedSupersedingPendingRequest()
                coordinator.setUserMuted(true)
            }
            return
        }

        if let intent = muteIntentLedger.record(actionUUID: action.uuid, providerEpoch: providerEpoch) {
            // Apple forbids fulfilling or failing an action after its timeout.
            // Keep it quarantined until reset/eligible registration rotation.
            guard intent.state == .unresolved else { return }
            if unsafeMuteAttributionEpoch == providerEpoch {
                action.fail()
                _ = muteIntentLedger.retirePerformed(actionUUID: action.uuid, providerEpoch: providerEpoch)
                if pendingMuteActionUUID == action.uuid {
                    pendingMuteActionUUID = nil
                    policy.forceMutedSupersedingPendingRequest()
                }
                coordinator.setUserMuted(true)
                return
            }
            guard let appRequest = intent.appRequest else { return }
            guard let attempt = policy.currentAttempt,
                  attempt.providerEpoch == providerEpoch,
                  attempt.callUUID == action.callUUID,
                  intent.callUUID == action.callUUID,
                  appRequest.muted == action.isMuted else {
                action.fail()
                _ = muteIntentLedger.retirePerformed(actionUUID: action.uuid, providerEpoch: providerEpoch)
                return
            }
            guard pendingMuteActionUUID == action.uuid else {
                action.fail()
                _ = muteIntentLedger.retirePerformed(actionUUID: action.uuid, providerEpoch: providerEpoch)
                return
            }
            pendingMuteActionUUID = nil
            action.fulfill()
            _ = muteIntentLedger.retirePerformed(actionUUID: action.uuid, providerEpoch: providerEpoch)
            let completion = policy.completeMuteRequest(appRequest, accepted: true)
            if completion == .acceptedUnmutedRestoreIfAllowed { coordinator.setUserMuted(false) }
            else if action.isMuted { coordinator.setUserMuted(true) }
            didChange?()
            return
        }

        // Capacity exhaustion can leave one unknown timeout identity
        // unrepresentable. Until reset/rotation, no unknown callback is safe to
        // fulfill, fail, or interpret as a new native action.
        if unsafeMuteAttributionEpoch == providerEpoch {
            coordinator.setUserMuted(true)
            return
        }

        guard let attempt = policy.currentAttempt,
              attempt.providerEpoch == providerEpoch,
              attempt.callUUID == action.callUUID else { action.fail(); return }

        // A genuine native system action supersedes any pending app intent.
        // Its old issued UUID remains correlated until terminal evidence.
        pendingMuteActionUUID = nil
        switch policy.requestMuted(action.isMuted) {
        case .gateOutboundAndRequest(let request):
            coordinator.setUserMuted(true)
            action.fulfill()
            _ = policy.completeMuteRequest(request, accepted: true)
            didChange?()
        case .request(let request):
            action.fulfill()
            if policy.completeMuteRequest(request, accepted: true) == .acceptedUnmutedRestoreIfAllowed {
                coordinator.setUserMuted(false)
            }
            didChange?()
        case .reject, .acceptedMuted, .acceptedUnmutedRestoreIfAllowed, .failedRemainMuted:
            action.fail()
        }
    }

    private func perform(_ action: CXSetHeldCallAction, providerEpoch: UInt64) {
        guard policy.currentAttempt?.providerEpoch == providerEpoch else { action.fail(); return }
        switch policy.setHeld(callUUID: action.callUUID, held: action.isOnHold) {
        case .gateBothCancelPTT:
            registry.gateAudio()
            if let binding = policy.binding { applyAudioTransition(binding, authorized: false) }
            action.fulfill()
            didChange?()
        case .resumeExactFreshGesture(let binding):
            if registry.resumeAfterHold(binding: binding, policy: policy) {
                applyAudioTransition(binding, authorized: true)
            }
            action.fulfill()
            didChange?()
        case .reject:
            action.fail()
        }
    }

    private func acceptAudioAction(_ action: CallKitAttemptPolicy.AudioAction) {
        switch action {
        case .enableExact(let binding):
            applyAudioTransition(binding, authorized: true)
        case .gateAndCancelPTT:
            if let binding = policy.binding { applyAudioTransition(binding, authorized: false) }
        case .none, .latchOnly:
            break
        }
        didChange?()
    }

    private func acceptTimedOut(_ action: CXAction, providerEpoch: UInt64) {
        guard let muteAction = action as? CXSetMutedCallAction else { return }
        if action.isComplete {
            _ = muteIntentLedger.retireCompleted(actionUUID: action.uuid, providerEpoch: providerEpoch)
            return
        }
        guard let intent = muteIntentLedger.quarantineTimeout(
            actionUUID: action.uuid,
            callUUID: muteAction.callUUID,
            providerEpoch: providerEpoch,
            muted: muteAction.isMuted
        ) else {
            unsafeMuteAttributionEpoch = providerEpoch
            pendingMuteActionUUID = nil
            policy.forceMutedSupersedingPendingRequest()
            coordinator.setUserMuted(true)
            didChange?()
            return
        }
        guard let appRequest = intent.appRequest,
              pendingMuteActionUUID == action.uuid,
              policy.currentAttempt?.providerEpoch == providerEpoch,
              policy.currentAttempt?.callUUID == muteAction.callUUID,
              intent.callUUID == muteAction.callUUID else { return }
        pendingMuteActionUUID = nil
        _ = policy.completeMuteRequest(appRequest, accepted: false)
        policy.forceMutedSupersedingPendingRequest()
        coordinator.setUserMuted(true)
        didChange?()
    }

    private func acceptProviderReset(epoch: UInt64) {
        guard registry.current.epoch == epoch else { return }
        let attempt = policy.currentAttempt
        guard case let .gateFulfillAndClose(binding) = policy.providerDidReset(providerEpoch: epoch) else { return }
        if pendingEndIntent?.attempt.providerEpoch == epoch { pendingEndIntent = nil }
        let retiredMuteIntents = muteIntentLedger.retireRegistration(providerEpoch: epoch)
        if unsafeMuteAttributionEpoch == epoch { unsafeMuteAttributionEpoch = nil }
        if let pendingMuteActionUUID,
           retiredMuteIntents.contains(where: { $0.actionUUID == pendingMuteActionUUID }) {
            self.pendingMuteActionUUID = nil
            policy.forceMutedSupersedingPendingRequest()
            coordinator.setUserMuted(true)
        }
        registry.gateAudio()
        if let binding { applyAudioTransition(binding, authorized: false) }
        if let attempt, let stopScope = coordinator.exactStopScope() {
            Task { [weak self] in
                guard let self,
                      self.policy.currentAttempt == attempt,
                      self.policy.systemUIEnded else { return }
                await self.coordinator.stop(ifCurrent: stopScope)
            }
        }
        didChange?()
    }

    private func applyAudioTransition(
        _ binding: CallKitAttemptPolicy.SessionBinding,
        authorized: Bool
    ) {
        audioTransitionRevision &+= 1
        coordinator.applyExternalAudioTransition(
            generation: binding.generation,
            peerAuthority: binding.peerAuthority,
            revision: audioTransitionRevision,
            authorized: authorized
        )
        if !authorized {
            Task { [weak self] in await self?.coordinator.performPendingExternalPTTCancel() }
        }
    }

    private func isCurrent(_ exact: StartContext) -> Bool {
        context?.attempt == exact.attempt && isAttemptCurrent(exact)
    }

    private func isAttemptCurrent(_ exact: StartContext) -> Bool {
        policy.currentAttempt == exact.attempt &&
            registry.current.epoch == exact.attempt.providerEpoch
    }

    private func request(_ transaction: CXTransaction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callController.request(transaction) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private static func providerConfiguration() -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.includesCallsInRecents = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        return configuration
    }
}
