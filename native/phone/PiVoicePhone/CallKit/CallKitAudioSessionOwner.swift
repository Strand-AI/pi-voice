@preconcurrency import AVFAudio
@preconcurrency import CallKit
import Foundation
import PiVoiceCore
import WebRTC

@MainActor
protocol CallKitProviderDelegateBridgeSink: AnyObject {
    func providerBridge(
        _ bridge: CallKitProviderDelegateBridge,
        provider: CXProvider,
        didActivate audioSession: AVAudioSession
    )
    func providerBridge(
        _ bridge: CallKitProviderDelegateBridge,
        provider: CXProvider,
        didDeactivate audioSession: AVAudioSession
    )
    func providerBridgeDidReset(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider)
    func providerBridge(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider, timedOutPerforming action: CXAction)
    func providerBridge(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider, perform action: CXStartCallAction)
    func providerBridge(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider, perform action: CXEndCallAction)
    func providerBridge(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider, perform action: CXSetMutedCallAction)
    func providerBridge(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider, perform action: CXSetHeldCallAction)
    func providerBridge(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider, performUnsupported action: CXAction)
}

/// CXProvider audio callbacks contain no call UUID. This bridge permanently
/// carries the registration epoch of exactly one provider instance; callbacks
/// are never relabeled with a mutable "current" epoch.
final class CallKitProviderDelegateBridge: NSObject, CXProviderDelegate, @unchecked Sendable {
    let registrationEpoch: UInt64
    weak var sink: (any CallKitProviderDelegateBridgeSink)?

    init(registrationEpoch: UInt64, sink: (any CallKitProviderDelegateBridgeSink)? = nil) {
        self.registrationEpoch = registrationEpoch
        self.sink = sink
    }

    func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { sink?.providerBridgeDidReset(self, provider: provider) }
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        MainActor.assumeIsolated {
            sink?.providerBridge(self, provider: provider, timedOutPerforming: action)
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            sink?.providerBridge(self, provider: provider, didActivate: audioSession)
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            sink?.providerBridge(self, provider: provider, didDeactivate: audioSession)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated { sink?.providerBridge(self, provider: provider, perform: action) }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated { sink?.providerBridge(self, provider: provider, perform: action) }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated { sink?.providerBridge(self, provider: provider, perform: action) }
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        MainActor.assumeIsolated { sink?.providerBridge(self, provider: provider, perform: action) }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated { sink?.providerBridge(self, provider: provider, performUnsupported: action) }
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        MainActor.assumeIsolated { sink?.providerBridge(self, provider: provider, performUnsupported: action) }
    }

    func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        MainActor.assumeIsolated { sink?.providerBridge(self, provider: provider, performUnsupported: action) }
    }
}

/// Pinned M154 WebRTC manual-audio owner. It never calls AVAudioSession
/// `setActive`; CallKit activation/deactivation callbacks are the sole owner.
@MainActor
final class CallKitManualAudioOwner {
    private let rtcAudioSession: RTCAudioSession

    init(rtcAudioSession: RTCAudioSession = .sharedInstance()) {
        self.rtcAudioSession = rtcAudioSession
        rtcAudioSession.useManualAudio = true
        rtcAudioSession.isAudioEnabled = false
    }

    fileprivate func didActivate(_ audioSession: AVAudioSession, action: CallKitAttemptPolicy.AudioAction) {
        guard action != .none else { return }
        rtcAudioSession.audioSessionDidActivate(audioSession)
        apply(action)
    }

    fileprivate func didDeactivate(_ audioSession: AVAudioSession) {
        rtcAudioSession.isAudioEnabled = false
        rtcAudioSession.audioSessionDidDeactivate(audioSession)
    }

    /// Also applies readiness actions produced after an early activation latch.
    fileprivate func apply(_ action: CallKitAttemptPolicy.AudioAction) {
        switch action {
        case .enableExact:
            rtcAudioSession.isAudioEnabled = true
        case .latchOnly, .gateAndCancelPTT:
            rtcAudioSession.isAudioEnabled = false
        case .none:
            break
        }
    }

    fileprivate func gate() {
        rtcAudioSession.isAudioEnabled = false
    }
}

/// Owns immutable provider/bridge registrations. Retired registrations remain
/// alive for a bounded window so late callbacks retain their original identity.
/// Rotation/invalidation is callback cleanup only and is never closure proof.
@MainActor
final class CallKitProviderRegistry: CallKitProviderDelegateBridgeSink {
    struct Registration {
        let epoch: UInt64
        let provider: CXProvider
        let bridge: CallKitProviderDelegateBridge
    }

    private(set) var current: Registration
    private(set) var retired: [Registration] = []
    private let retiredLimit: Int
    private let audioOwner: CallKitManualAudioOwner
    private var currentRegistrationClaimed = false
    private var currentRegistrationReset = false
    var resolveActivation: ((UInt64) -> CallKitAttemptPolicy.AudioAction)?
    var resolveDeactivation: ((UInt64) -> CallKitAttemptPolicy.AudioAction)?
    var acceptProviderReset: ((UInt64) -> Void)?
    var acceptTimedOutAction: ((CXAction, UInt64) -> Void)?
    var acceptAudioAction: ((CallKitAttemptPolicy.AudioAction) -> Void)?
    var mayEnableExact: ((CallKitAttemptPolicy.SessionBinding) -> Bool)?
    var performStart: ((CXStartCallAction, UInt64) -> Void)?
    var performEnd: ((CXEndCallAction, UInt64) -> Void)?
    var performMute: ((CXSetMutedCallAction, UInt64) -> Void)?
    var performHold: ((CXSetHeldCallAction, UInt64) -> Void)?

    init(
        configuration: CXProviderConfiguration,
        registrationEpoch: UInt64,
        retiredLimit: Int = 2,
        audioOwner: CallKitManualAudioOwner = CallKitManualAudioOwner()
    ) {
        precondition(registrationEpoch > 0 && retiredLimit > 0)
        self.retiredLimit = retiredLimit
        self.audioOwner = audioOwner
        let provider = CXProvider(configuration: configuration)
        let bridge = CallKitProviderDelegateBridge(registrationEpoch: registrationEpoch)
        current = Registration(epoch: registrationEpoch, provider: provider, bridge: bridge)
        bridge.sink = self
        provider.setDelegate(bridge, queue: .main)
    }

    /// Claims this actual provider/bridge registration for exactly one call.
    /// Even a safely failed attempt consumes it; the next call must rotate to a
    /// fresh registration so an untagged late callback cannot cross attempts.
    func beginAttempt(
        callUUID: UUID,
        targetID: String,
        targetEpoch: String,
        policy: inout CallKitAttemptPolicy
    ) -> CallKitAttemptPolicy.Attempt? {
        guard !currentRegistrationClaimed,
              policy.currentProviderEpoch == current.epoch,
              let attempt = policy.beginAttempt(
                  callUUID: callUUID,
                  targetID: targetID,
                  targetEpoch: targetEpoch
              ),
              attempt.providerEpoch == current.epoch else { return nil }
        currentRegistrationClaimed = true
        return attempt
    }

    /// Rotation and policy authority move atomically. Provider invalidation is
    /// reached only after policy proves that no unresolved attempt can be
    /// erased; a rejected rotation leaves both identities untouched.
    @discardableResult
    func rotate(
        configuration: CXProviderConfiguration,
        registrationEpoch: UInt64,
        policy: inout CallKitAttemptPolicy
    ) -> Bool {
        guard registrationEpoch > current.epoch,
              !retired.contains(where: { $0.epoch == registrationEpoch }),
              policy.replaceProvider(epoch: registrationEpoch) else { return false }
        audioOwner.gate()
        current.provider.invalidate()
        retired.append(current)
        if retired.count > retiredLimit { retired.removeFirst(retired.count - retiredLimit) }

        let provider = CXProvider(configuration: configuration)
        let bridge = CallKitProviderDelegateBridge(registrationEpoch: registrationEpoch, sink: self)
        current = Registration(epoch: registrationEpoch, provider: provider, bridge: bridge)
        currentRegistrationClaimed = false
        currentRegistrationReset = false
        provider.setDelegate(bridge, queue: .main)
        return true
    }

    /// Session binding/readiness is resolved and applied synchronously against
    /// the current provider registration and current policy state. Callers
    /// cannot replay a previously captured `.enableExact` action.
    @discardableResult
    func bindSession(
        attemptEpoch: UInt64,
        generation: String,
        peerAuthority: PeerConnectionAuthority,
        policy: inout CallKitAttemptPolicy
    ) -> CallKitAttemptPolicy.AudioAction {
        guard policy.currentAttempt?.providerEpoch == current.epoch else { return .none }
        let action = policy.bindSession(
            attemptEpoch: attemptEpoch,
            generation: generation,
            peerAuthority: peerAuthority
        )
        applyCurrentEnable(
            action,
            attemptEpoch: attemptEpoch,
            generation: generation,
            peerAuthority: peerAuthority,
            policy: policy
        )
        return action
    }

    @discardableResult
    func markPrimaryReady(
        attemptEpoch: UInt64,
        generation: String,
        peerAuthority: PeerConnectionAuthority,
        policy: inout CallKitAttemptPolicy
    ) -> CallKitAttemptPolicy.AudioAction {
        guard policy.currentAttempt?.providerEpoch == current.epoch else { return .none }
        let action = policy.markPrimaryReady(
            attemptEpoch: attemptEpoch,
            generation: generation,
            peerAuthority: peerAuthority
        )
        applyCurrentEnable(
            action,
            attemptEpoch: attemptEpoch,
            generation: generation,
            peerAuthority: peerAuthority,
            policy: policy
        )
        return action
    }

    func providerBridge(
        _ bridge: CallKitProviderDelegateBridge,
        provider: CXProvider,
        didActivate audioSession: AVAudioSession
    ) {
        guard bridge.registrationEpoch == current.epoch, provider === current.provider,
              bridge === current.bridge,
              let action = resolveActivation?(bridge.registrationEpoch), action != .none else { return }
        audioOwner.didActivate(audioSession, action: action)
        acceptAudioAction?(action)
    }

    func providerBridge(
        _ bridge: CallKitProviderDelegateBridge,
        provider: CXProvider,
        didDeactivate audioSession: AVAudioSession
    ) {
        guard bridge.registrationEpoch == current.epoch, provider === current.provider,
              bridge === current.bridge else { return }
        let action = resolveDeactivation?(bridge.registrationEpoch) ?? .none
        audioOwner.didDeactivate(audioSession)
        acceptAudioAction?(action)
    }

    func providerBridgeDidReset(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider) {
        guard isCurrent(bridge, provider: provider) else { return }
        currentRegistrationReset = true
        audioOwner.gate()
        acceptProviderReset?(bridge.registrationEpoch)
    }

    func providerBridge(
        _ bridge: CallKitProviderDelegateBridge,
        provider: CXProvider,
        timedOutPerforming action: CXAction
    ) {
        guard isCurrent(bridge, provider: provider), !currentRegistrationReset else { return }
        acceptTimedOutAction?(action, bridge.registrationEpoch)
    }

    func providerBridge(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider, perform action: CXStartCallAction) {
        guard isCurrent(bridge, provider: provider) else { action.fail(); return }
        guard let performStart else { action.fail(); return }
        performStart(action, bridge.registrationEpoch)
    }

    func providerBridge(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider, perform action: CXEndCallAction) {
        guard isCurrent(bridge, provider: provider) else { action.fail(); return }
        guard let performEnd else { action.fail(); return }
        performEnd(action, bridge.registrationEpoch)
    }

    func providerBridge(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider, perform action: CXSetMutedCallAction) {
        // Retired/reset mute actions may already have timed out. Apple forbids
        // fulfilling or failing those actions, so ignore them without effects.
        guard isCurrent(bridge, provider: provider), !currentRegistrationReset else { return }
        guard let performMute else { action.fail(); return }
        performMute(action, bridge.registrationEpoch)
    }

    func providerBridge(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard isCurrent(bridge, provider: provider) else { action.fail(); return }
        guard let performHold else { action.fail(); return }
        performHold(action, bridge.registrationEpoch)
    }

    func providerBridge(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider, performUnsupported action: CXAction) {
        action.fail()
    }

    func gateAudio() {
        audioOwner.gate()
    }

    @discardableResult
    func resumeAfterHold(
        binding: CallKitAttemptPolicy.SessionBinding,
        policy: CallKitAttemptPolicy
    ) -> Bool {
        guard policy.currentAttempt?.providerEpoch == current.epoch,
              policy.binding == binding,
              mayEnableExact?(binding) == true,
              policy.startActionAccepted,
              policy.systemAudioActivated,
              policy.primaryReady,
              !policy.systemUIEnded,
              !policy.systemHeld else { return false }
        audioOwner.apply(.enableExact(binding))
        return true
    }

    private func isCurrent(_ bridge: CallKitProviderDelegateBridge, provider: CXProvider) -> Bool {
        bridge.registrationEpoch == current.epoch && provider === current.provider && bridge === current.bridge
    }

    private func applyCurrentEnable(
        _ action: CallKitAttemptPolicy.AudioAction,
        attemptEpoch: UInt64,
        generation: String,
        peerAuthority: PeerConnectionAuthority,
        policy: CallKitAttemptPolicy
    ) {
        let exact = CallKitAttemptPolicy.SessionBinding(generation: generation, peerAuthority: peerAuthority)
        guard action == .enableExact(exact),
              mayEnableExact?(exact) == true,
              let attempt = policy.currentAttempt,
              attempt.attemptEpoch == attemptEpoch,
              attempt.providerEpoch == current.epoch,
              policy.binding == exact,
              policy.startActionAccepted,
              policy.systemAudioActivated,
              policy.primaryReady,
              !policy.systemUIEnded,
              !policy.systemHeld else { return }
        audioOwner.apply(action)
        // The caller receives `action` and may notify observers only after its
        // inout policy borrow has ended; never reenter policy synchronously here.
    }
}
