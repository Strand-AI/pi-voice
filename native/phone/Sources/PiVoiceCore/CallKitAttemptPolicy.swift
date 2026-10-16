import Foundation

/// Memory-only authority for one explicit outgoing CallKit attempt.
/// CallKit audio callbacks carry no call UUID, so attribution is allowed only
/// while one serialized attempt owns the current provider epoch.
public struct CallKitAttemptPolicy: Sendable {
    public struct Attempt: Equatable, Sendable {
        public let callUUID: UUID
        public let attemptEpoch: UInt64
        public let providerEpoch: UInt64
        public let targetID: String
        public let targetEpoch: String

        public init(callUUID: UUID, attemptEpoch: UInt64, providerEpoch: UInt64, targetID: String, targetEpoch: String) {
            self.callUUID = callUUID
            self.attemptEpoch = attemptEpoch
            self.providerEpoch = providerEpoch
            self.targetID = targetID
            self.targetEpoch = targetEpoch
        }
    }

    public struct SessionBinding: Equatable, Sendable {
        public let generation: String
        public let peerAuthority: PeerConnectionAuthority

        public init(generation: String, peerAuthority: PeerConnectionAuthority) {
            self.generation = generation
            self.peerAuthority = peerAuthority
        }
    }

    public struct MuteRequest: Equatable, Sendable {
        public let attemptEpoch: UInt64
        public let token: UInt64
        public let muted: Bool
    }

    public enum StartAction: Equatable, Sendable {
        case reject
        case fulfillPromptly(attemptEpoch: UInt64)
    }

    public enum AudioAction: Equatable, Sendable {
        case none
        case latchOnly
        case enableExact(SessionBinding)
        case gateAndCancelPTT
    }

    public enum EndAction: Equatable, Sendable {
        case reject
        case gateFulfillAndClose(SessionBinding?)
        case retryRetainedClose(SessionBinding)
    }

    public enum MuteAction: Equatable, Sendable {
        case reject
        case gateOutboundAndRequest(MuteRequest)
        case request(MuteRequest)
        case acceptedMuted
        case acceptedUnmutedRestoreIfAllowed
        case failedRemainMuted
    }

    public enum HoldAction: Equatable, Sendable {
        case reject
        case gateBothCancelPTT
        case resumeExactFreshGesture(SessionBinding)
    }

    public enum UnsupportedAction: Equatable, Sendable { case failWithoutEffect }

    public private(set) var currentAttempt: Attempt?
    public private(set) var binding: SessionBinding?
    public private(set) var startActionAccepted = false
    public private(set) var systemAudioActivated = false
    public private(set) var primaryReady = false
    public private(set) var systemUIEnded = false
    public private(set) var userMuted = false
    public private(set) var systemHeld = false
    public private(set) var pttGestureEpoch: UInt64 = 0
    public var currentProviderEpoch: UInt64 { providerEpoch }

    private var nextAttemptEpoch: UInt64 = 0
    private var nextMuteToken: UInt64 = 0
    private var pendingMuteRequest: MuteRequest?
    private var localEndAwaitingSystemAction: UUID?
    private var providerEpoch: UInt64
    private var replacementBlockedUntilDeactivation = false

    public init(providerEpoch: UInt64) {
        self.providerEpoch = providerEpoch
    }

    public mutating func beginAttempt(callUUID: UUID, targetID: String, targetEpoch: String) -> Attempt? {
        guard currentAttempt == nil, localEndAwaitingSystemAction == nil,
              !replacementBlockedUntilDeactivation,
              !targetID.isEmpty, !targetEpoch.isEmpty else { return nil }
        nextAttemptEpoch &+= 1
        let attempt = Attempt(
            callUUID: callUUID,
            attemptEpoch: nextAttemptEpoch,
            providerEpoch: providerEpoch,
            targetID: targetID,
            targetEpoch: targetEpoch
        )
        currentAttempt = attempt
        binding = nil
        startActionAccepted = false
        systemAudioActivated = false
        primaryReady = false
        systemUIEnded = false
        userMuted = false
        systemHeld = false
        pendingMuteRequest = nil
        localEndAwaitingSystemAction = nil
        pttGestureEpoch &+= 1
        return attempt
    }

    /// This is intentionally prompt: network/provider setup happens after the
    /// system action has been accepted and may not consume CallKit's deadline.
    public mutating func acceptStartAction(callUUID: UUID, providerEpoch incomingProviderEpoch: UInt64) -> StartAction {
        guard let attempt = currentAttempt,
              attempt.callUUID == callUUID,
              attempt.providerEpoch == incomingProviderEpoch,
              incomingProviderEpoch == providerEpoch,
              !startActionAccepted,
              !systemUIEnded else { return .reject }
        startActionAccepted = true
        return .fulfillPromptly(attemptEpoch: attempt.attemptEpoch)
    }

    public mutating func bindSession(
        attemptEpoch: UInt64,
        generation: String,
        peerAuthority: PeerConnectionAuthority
    ) -> AudioAction {
        guard let attempt = currentAttempt,
              attempt.attemptEpoch == attemptEpoch,
              startActionAccepted,
              !generation.isEmpty else { return .none }
        let exact = SessionBinding(generation: generation, peerAuthority: peerAuthority)
        if let binding {
            // Binding is immutable. Exact duplicate delivery is idempotent;
            // a different generation or peer can never replace authority or
            // reset readiness for the accepted attempt.
            guard binding == exact else { return .none }
            return audioEnableActionIfReady()
        }
        binding = exact
        return audioEnableActionIfReady()
    }

    public mutating func markPrimaryReady(
        attemptEpoch: UInt64,
        generation: String,
        peerAuthority: PeerConnectionAuthority
    ) -> AudioAction {
        guard let attempt = currentAttempt,
              attempt.attemptEpoch == attemptEpoch,
              binding == SessionBinding(generation: generation, peerAuthority: peerAuthority),
              !systemUIEnded else { return .none }
        primaryReady = true
        return audioEnableActionIfReady()
    }

    /// CXProvider gives no call UUID here. The provider instance epoch and the
    /// sole serialized current attempt are the only valid attribution scope.
    public mutating func didActivate(providerEpoch incomingProviderEpoch: UInt64) -> AudioAction {
        guard let attempt = currentAttempt,
              attempt.providerEpoch == incomingProviderEpoch,
              providerEpoch == incomingProviderEpoch,
              startActionAccepted,
              !systemUIEnded else { return .none }
        systemAudioActivated = true
        replacementBlockedUntilDeactivation = true
        let action = audioEnableActionIfReady()
        return action == .none ? .latchOnly : action
    }

    public mutating func didDeactivate(providerEpoch incomingProviderEpoch: UInt64) -> AudioAction {
        guard incomingProviderEpoch == providerEpoch else { return .none }
        replacementBlockedUntilDeactivation = false
        guard currentAttempt != nil else { return .none }
        systemAudioActivated = false
        pttGestureEpoch &+= 1
        return .gateAndCancelPTT
    }

    public mutating func requestMuted(_ muted: Bool) -> MuteAction {
        guard let attempt = currentAttempt, startActionAccepted, !systemUIEnded else { return .reject }
        nextMuteToken &+= 1
        let request = MuteRequest(attemptEpoch: attempt.attemptEpoch, token: nextMuteToken, muted: muted)
        pendingMuteRequest = request
        if muted {
            userMuted = true
            return .gateOutboundAndRequest(request)
        }
        return .request(request)
    }

    public mutating func forceMutedSupersedingPendingRequest() {
        pendingMuteRequest = nil
        userMuted = true
    }

    public mutating func completeMuteRequest(_ request: MuteRequest, accepted: Bool) -> MuteAction {
        guard pendingMuteRequest == request,
              currentAttempt?.attemptEpoch == request.attemptEpoch,
              !systemUIEnded else { return .reject }
        pendingMuteRequest = nil
        if request.muted {
            userMuted = true
            return accepted ? .acceptedMuted : .failedRemainMuted
        }
        guard accepted else {
            userMuted = true
            return .failedRemainMuted
        }
        userMuted = false
        return .acceptedUnmutedRestoreIfAllowed
    }

    public mutating func setHeld(callUUID: UUID, held: Bool) -> HoldAction {
        guard let attempt = currentAttempt,
              attempt.callUUID == callUUID,
              startActionAccepted,
              !systemUIEnded else { return .reject }
        if held {
            pttGestureEpoch &+= 1
            systemHeld = true
            return .gateBothCancelPTT
        }
        guard let binding, systemHeld, primaryReady else { return .reject }
        pttGestureEpoch &+= 1
        systemHeld = false
        return .resumeExactFreshGesture(binding)
    }

    /// Gates a locally requested End before any asynchronous CallKit request.
    /// The eventual exact CXEndCallAction remains fulfillable exactly once.
    public mutating func requestLocalEnd(callUUID: UUID) -> EndAction {
        guard currentAttempt?.callUUID == callUUID, !systemUIEnded else { return .reject }
        systemUIEnded = true
        localEndAwaitingSystemAction = callUUID
        systemAudioActivated = false
        pttGestureEpoch &+= 1
        return .gateFulfillAndClose(binding)
    }

    public mutating func acceptEndAction(callUUID: UUID) -> EndAction {
        if localEndAwaitingSystemAction == callUUID {
            localEndAwaitingSystemAction = nil
            systemUIEnded = true
            systemAudioActivated = false
            pttGestureEpoch &+= 1
            return .gateFulfillAndClose(currentAttempt?.callUUID == callUUID ? binding : nil)
        }
        guard currentAttempt?.callUUID == callUUID, !systemUIEnded else { return .reject }
        systemUIEnded = true
        systemAudioActivated = false
        pttGestureEpoch &+= 1
        return .gateFulfillAndClose(binding)
    }

    /// A rejected local End transaction cannot produce its pending system
    /// action. This clears only that exact action tombstone, never allocation.
    public mutating func rejectLocalEndSubmission(callUUID: UUID) {
        guard localEndAwaitingSystemAction == callUUID else { return }
        localEndAwaitingSystemAction = nil
    }

    /// Once the CallKit UI has ended, an explicit app End retry operates only
    /// on retained exact generation authority and does not create another call.
    public func retainedEndRetry() -> EndAction {
        guard systemUIEnded, let binding else { return .reject }
        return .retryRetainedClose(binding)
    }

    public mutating func providerClosed(generation: String) -> Bool {
        guard binding?.generation == generation else { return false }
        clearAttempt(requiresDeactivation: replacementBlockedUntilDeactivation)
        return true
    }

    /// Provider setup failed after CallKit Start was accepted. This detaches
    /// system UI and gates audio but retains unknown/bound provider authority;
    /// it is not closure proof.
    @discardableResult
    public mutating func detachSystemUIAfterProviderFailure(callUUID: UUID) -> Bool {
        guard currentAttempt?.callUUID == callUUID, startActionAccepted else { return false }
        systemUIEnded = true
        systemAudioActivated = false
        pttGestureEpoch &+= 1
        return true
    }

    public mutating func providerDidReset(providerEpoch incomingProviderEpoch: UInt64) -> EndAction {
        guard incomingProviderEpoch == providerEpoch else { return .reject }
        let retained = binding
        // Reset may retire a UI-only pending End action, but is never treated
        // as closure proof for any retained provider allocation.
        localEndAwaitingSystemAction = nil
        systemUIEnded = true
        systemAudioActivated = false
        pttGestureEpoch &+= 1
        return .gateFulfillAndClose(retained)
    }

    /// Releases a local attempt only when the system Start transaction is
    /// known not to have been submitted/accepted and no provider allocation or
    /// audio callback can belong to it.
    @discardableResult
    public mutating func releaseDefinitePreSubmitFailure(callUUID: UUID, attemptEpoch: UInt64) -> Bool {
        guard let attempt = currentAttempt,
              attempt.callUUID == callUUID,
              attempt.attemptEpoch == attemptEpoch,
              !startActionAccepted,
              binding == nil,
              !systemAudioActivated else { return false }
        clearAttempt(requiresDeactivation: false)
        return true
    }

    /// Releases an accepted CallKit Start only when the provider-session owner
    /// has positively proved that failure occurred before its session request
    /// could allocate anything. CallKit End/reset is never such proof. A
    /// submitted-unbound request with an unknown outcome must not call this.
    @discardableResult
    public mutating func releaseProvenNoProviderAllocation(callUUID: UUID, attemptEpoch: UInt64) -> Bool {
        guard let attempt = currentAttempt,
              attempt.callUUID == callUUID,
              attempt.attemptEpoch == attemptEpoch,
              startActionAccepted,
              binding == nil else { return false }
        // End/reset may clear the current activation bit, but cannot erase the
        // historical fact that this provider registration activated and still
        // owes an exact deactivation callback.
        clearAttempt(requiresDeactivation: replacementBlockedUntilDeactivation)
        return true
    }

    /// Provider replacement is never cleanup proof. It is allowed only after
    /// exact closure (and any attributed deactivation) or a definite local
    /// pre-submit failure has already released the attempt.
    @discardableResult
    public mutating func replaceProvider(epoch newProviderEpoch: UInt64) -> Bool {
        guard currentAttempt == nil, !replacementBlockedUntilDeactivation else { return false }
        // Allocation authority is already proven absent/closed here. Rotation
        // may retire only the old registration's UI End action tombstone.
        localEndAwaitingSystemAction = nil
        providerEpoch = newProviderEpoch
        return true
    }

    public func unsupportedAction() -> UnsupportedAction { .failWithoutEffect }

    private func audioEnableActionIfReady() -> AudioAction {
        guard systemAudioActivated, primaryReady, !systemUIEnded, !systemHeld,
              let binding else { return .none }
        return .enableExact(binding)
    }

    private mutating func clearAttempt(requiresDeactivation: Bool) {
        currentAttempt = nil
        binding = nil
        startActionAccepted = false
        systemAudioActivated = false
        primaryReady = false
        systemUIEnded = false
        userMuted = false
        systemHeld = false
        pendingMuteRequest = nil
        replacementBlockedUntilDeactivation = requiresDeactivation
        pttGestureEpoch &+= 1
    }
}
