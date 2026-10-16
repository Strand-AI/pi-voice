import Foundation

/// UI-facing policy owner. It pins every call to one exact broker ID + endpoint epoch and never
/// creates a local transcript/send path: PTT release only tells the gateway to finish its trailing
/// transcript window.
@MainActor
public final class VoiceSessionCoordinator {
    public private(set) var phase: CallPhase = .disconnected
    public private(set) var agents: [AgentEndpoint] = []
    public private(set) var selected: AgentEndpoint?
    public private(set) var activeTarget: AgentEndpoint?
    public private(set) var activeMode: VoiceMode?
    public private(set) var activeRouting: ConversationRouting?
    public private(set) var pttHeld = false
    public private(set) var pttFinishing = false
    public private(set) var audioInterrupted = false
    public private(set) var userMuted = false
    public private(set) var mediaConnectionState: MediaConnectionState = .unknown
    public private(set) var pttGestureEpoch = 0
    public var captionThread: [VoiceCaptionSegment] {
        guard case .active = phase, let generation = activeAuthority?.generation else { return [] }
        let inputCurrent = mediaConnectionState == .connected
            && !audioInterrupted
            && !userMuted
            && (activeMode == .continuous || (activeMode == .ptt && pttHeld))
        let raw = captionThreadStore.segments.filter { $0.generation == generation }
        let newestAgent = raw.lastIndex(where: { $0.speaker == .agent })
        return raw.enumerated().map { index, segment in
            let isCurrent: Bool
            if segment.speaker == .user {
                isCurrent = segment.isCurrent && inputCurrent
            } else {
                isCurrent = index == newestAgent && visualMediaState?.speakerActive == true
            }
            return VoiceCaptionSegment(
                generation: segment.generation,
                speaker: segment.speaker,
                text: segment.text,
                isCurrent: isCurrent
            )
        }
    }
    public var userCaption: String { captionThread.last(where: { $0.speaker == .user })?.text ?? "" }
    public var piCaption: String { captionThread.last(where: { $0.speaker == .agent })?.text ?? "" }
    public var visualMediaState: VoiceVisualMediaState? {
        guard case .active = phase,
              let authority = activeAuthority,
              presentationVisible,
              mediaConnectionState == .connected,
              !audioInterrupted,
              let sample = latestMediaSample,
              sample.generation == authority.generation,
              sample.peerAuthority == authority.peerAuthority else { return nil }
        let now = monotonicNanoseconds()
        guard now >= sample.observedAtUptimeNanoseconds,
              now - sample.observedAtUptimeNanoseconds <= VoiceMediaPollPolicy.maximumAgeNanoseconds else { return nil }
        let outgoingAllowed = !userMuted && (activeMode == .continuous || (activeMode == .ptt && pttHeld))
        let playbackAllowed = activeMode != .ptt || !pttHeld
        return VoiceVisualMediaState(
            generation: authority.generation,
            outgoingLevel: outgoingAllowed ? sample.outgoingLevel : 0,
            playbackLevel: playbackAllowed ? sample.playbackLevel : 0,
            speakerActive: playbackAllowed && sample.speakerActive
        )
    }
    public var captionPresentation: VoiceCaptionPresentation? {
        guard let segment = captionThread.last(where: { $0.isCurrent }) ?? captionThread.last else { return nil }
        return VoiceCaptionPresentation(
            generation: segment.generation,
            speaker: segment.speaker == .user ? .user : .agent,
            text: segment.text,
            isCurrent: segment.isCurrent
        )
    }
    public private(set) var lastError: String?
    public private(set) var automaticReconnectEpoch: UInt64?
    public private(set) var closureRecoveryEpoch: UInt64?
    public private(set) var rosterRevision = 0
    public private(set) var confirmedEndRevision = 0
    public private(set) var lastConfirmedProviderClosedGeneration: String?
    public var rosterConnected: Bool { relayConnected == true }
    public var connectedOrigin: String? { connectionOrigin.flatMap { try? CanonicalGatewayOrigin($0).value } }
    public var activeGeneration: String? { sessionAuthority?.generation }
    public var activeSessionAuthority: SessionAuthority? { sessionAuthority }

    public struct ExactStopScope: Equatable, Sendable {
        fileprivate let operationNonce: Int
        fileprivate let generation: String?
        fileprivate let pendingStart: Bool
    }

    public func exactStopScope() -> ExactStopScope? {
        if startInFlight || hasUnknownStartAllocation {
            return ExactStopScope(operationNonce: operationNonce, generation: activeAuthority?.generation, pendingStart: true)
        }
        if let generation = activeAuthority?.generation {
            return ExactStopScope(operationNonce: operationNonce, generation: generation, pendingStart: false)
        }
        return nil
    }

    public func stop(ifCurrent scope: ExactStopScope) async {
        guard operationNonce == scope.operationNonce else { return }
        if scope.pendingStart {
            guard startInFlight || hasUnknownStartAllocation else { return }
            if let generation = scope.generation {
                guard activeAuthority?.generation == generation else { return }
            } else {
                guard activeAuthority == nil else { return }
            }
        } else {
            guard activeAuthority?.generation == scope.generation else { return }
        }
        await stop()
    }
    public var isStartInFlight: Bool { startInFlight }
    public private(set) var hasUnknownStartAllocation = false
    public func retainsAuthorityOrigin(_ candidate: URL) -> Bool {
        guard let exact = try? CanonicalGatewayOrigin(candidate).value else { return false }
        return connectionOrigin.flatMap { try? CanonicalGatewayOrigin($0).value } == exact
    }
    public var didChange: (@MainActor () -> Void)?
    public var presentationDidChange: (@MainActor () -> Void)?

    private let transport: VoiceTransport
    private var eventTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var mediaSampleExpiryTask: Task<Void, Never>?
    private var peerGraceTask: Task<Void, Never>?
    private var peerRecovery: PeerConnectionRecoveryPolicy
    private var mediaRecoveryRevision = 0
    private var greetingReadinessSent = false
    private var externalAudioAuthorizationRequired = false
    private var externalAudioAuthorized = true
    private var externalAudioTransitionRevision: UInt64 = 0
    private struct ExternalPTTCancelRequest: Equatable {
        let generation: String
        let peerAuthority: PeerConnectionAuthority
        let operationNonce: Int
        let commandSequence: Int
    }
    private var pendingExternalPTTCancel: ExternalPTTCancelRequest?
    private var inFlightExternalPTTCancel: ExternalPTTCancelRequest?
    private var commandSequence = 0
    private var operationNonce = 0
    private var startInFlight = false
    private var connectionOrigin: URL?
    private var sessionAuthority: SessionAuthority?
    private var interruptedGeneration: String?
    private var captionThreadStore = BoundedCaptionThread()
    private var latestMediaSample: VoiceMediaLevelSample?
    private let monotonicNanoseconds: @MainActor () -> UInt64
    private var presentationVisible = true
    private var knownIdleAuthority = false
    private var relayConnected: Bool?
    private var reconnectEpochCounter: UInt64 = 0
    private var closureRecoveryEpochCounter: UInt64 = 0
    private struct ClosureRecoveryRequest: Equatable {
        let token: UInt64
        let epoch: UInt64
        let generation: String
    }
    private var closureRecoveryOrigin: URL?
    private var closureRecoveryRequest: ClosureRecoveryRequest?
    private var closureRecoveryRequestCounter: UInt64 = 0

    public init(
        transport: VoiceTransport,
        peerRecoveryPolicy: PeerConnectionRecoveryPolicy = PeerConnectionRecoveryPolicy(),
        monotonicNanoseconds: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.transport = transport
        peerRecovery = peerRecoveryPolicy
        self.monotonicNanoseconds = monotonicNanoseconds
        transport.mediaLevelsDidChange = { [weak self] sample in
            self?.acceptMediaLevelSample(sample)
        }
    }

    deinit {
        eventTask?.cancel()
        playbackTask?.cancel()
        mediaSampleExpiryTask?.cancel()
        peerGraceTask?.cancel()
    }

    public func connect(origin: URL, pairingToken: String?, deviceName: String = "Pi Voice iPhone") async throws {
        guard (phase == .disconnected || phase == .ready), activeAuthority == nil,
              !startInFlight, !hasUnknownStartAllocation else { throw VoiceError.callAlreadyActive }
        let canonical = try CanonicalGatewayOrigin(origin)
        operationNonce &+= 1
        let connectNonce = operationNonce
        try await transport.authenticate(origin: canonical.url, pairingToken: pairingToken, deviceName: deviceName)
        guard operationNonce == connectNonce else { throw CancellationError() }
        try await transport.connectEvents(origin: canonical.url)
        guard operationNonce == connectNonce else { throw CancellationError() }
        connectionOrigin = canonical.url
        phase = .ready
        knownIdleAuthority = true
        automaticReconnectEpoch = nil
        observeEvents()
        changed()
    }

    public func mayAutomaticallyReconnect(epoch: UInt64) -> Bool {
        guard automaticReconnectEpoch == epoch, knownIdleAuthority else { return false }
        switch phase {
        case .ready, .disconnected: return true
        default: return false
        }
    }

    public func hasProviderClosureRecoveryScope(epoch: UInt64) -> Bool {
        guard closureRecoveryEpoch == epoch, closureRecoveryOrigin != nil, activeAuthority != nil else { return false }
        if case .uncertain = phase { return true }
        return false
    }

    public func mayCheckProviderClosure(epoch: UInt64) -> Bool {
        hasProviderClosureRecoveryScope(epoch: epoch) && closureRecoveryRequest?.epoch != epoch
    }

    @discardableResult
    public func checkProviderClosure(epoch: UInt64) async throws -> Bool {
        guard mayCheckProviderClosure(epoch: epoch), let authority = activeAuthority, let origin = closureRecoveryOrigin else { return false }
        closureRecoveryRequestCounter &+= 1
        let request = ClosureRecoveryRequest(token: closureRecoveryRequestCounter, epoch: epoch, generation: authority.generation)
        closureRecoveryRequest = request
        let nonce = operationNonce, generation = authority.generation
        defer {
            if closureRecoveryRequest == request { closureRecoveryRequest = nil }
        }
        let receipt = try await transport.providerClosureReceipt(origin: origin, generation: generation)
        guard operationNonce == nonce, closureRecoveryEpoch == epoch, activeAuthority?.generation == generation else { return false }
        guard receipt == .providerClosed else {
            lastError = "Provider closure remains unconfirmed."
            changed()
            return false
        }
        operationNonce &+= 1
        lastConfirmedProviderClosedGeneration = generation
        confirmedEndRevision &+= 1
        localTeardown(nextPhase: .disconnected)
        connectionOrigin = nil
        knownIdleAuthority = true
        relayConnected = false
        requestAutomaticReconnect()
        lastError = nil
        changed()
        return true
    }

    public func select(_ endpoint: AgentEndpoint?) throws {
        guard phase == .ready, activeAuthority == nil, !startInFlight, !hasUnknownStartAllocation else { throw VoiceError.callAlreadyActive }
        guard let endpoint else { selected = nil; changed(); return }
        guard agents.contains(where: { $0.identityKey == endpoint.identityKey }) else { throw VoiceError.staleTarget }
        selected = endpoint
        changed()
    }

    public func start(mode: VoiceMode, voice: VoiceName) async throws {
        guard phase == .ready, !startInFlight else { throw VoiceError.notReady }
        guard let target = selected else { throw VoiceError.targetUnavailable }
        guard agents.contains(where: { $0.identityKey == target.identityKey }) else { throw VoiceError.staleTarget }

        operationNonce += 1
        let startNonce = operationNonce
        startInFlight = true
        defer { startInFlight = false }
        knownIdleAuthority = false
        automaticReconnectEpoch = nil
        phase = .starting
        activeTarget = target
        activeMode = mode
        activeRouting = .liaison
        hasUnknownStartAllocation = false
        pttHeld = false
        pttFinishing = false
        greetingReadinessSent = false
        closureRecoveryOrigin = nil
        closureRecoveryEpoch = nil
        userMuted = false
        commandSequence = 0
        clearPresentationState()
        lastError = nil
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        changed()

        do {
            let authority = try await transport.start(target: target, mode: mode, voice: voice, routing: .liaison)
            guard operationNonce == startNonce, phase == .starting else {
                _ = try? await transport.close(generation: authority.generation)
                throw RetainedVoiceStartAuthority(
                    authority: authority,
                    message: "Startup was interrupted after provider allocation. Provider closure remains unconfirmed."
                )
            }
            sessionAuthority = authority
            phase = .active(authority)
            mediaConnectionState = .unknown
            peerRecovery.begin(authority.peerAuthority)
            guard peerRecovery.bind(generation: authority.generation, to: authority.peerAuthority) else {
                enterUncertain("The active media peer could not be bound to this voice generation.")
                throw CancellationError()
            }
            acceptPeerConnectionState(authority: authority.peerAuthority, state: authority.initialPeerState)
            changed()
        } catch {
            if let retained = error as? RetainedVoiceStartAuthority {
                retainAllocatedStartAuthority(retained.authority, message: retained.message)
            } else if let unknown = error as? UnknownVoiceStartAllocation {
                retainUnknownStartAllocation(unknown.message)
            } else if operationNonce == startNonce {
                localTeardown(nextPhase: .ready)
                lastError = error.localizedDescription
                changed()
            } else if phase == .starting {
                let nextPhase: CallPhase = relayConnected == false ? .disconnected : .ready
                localTeardown(nextPhase: nextPhase)
                if nextPhase == .disconnected { connectionOrigin = nil }
                lastError = error.localizedDescription
                changed()
            }
            throw error
        }
    }

    public func interruptPendingStart() {
        guard startInFlight, phase == .starting else { return }
        operationNonce &+= 1
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia()
        clearPresentationState()
        changed()
    }

    private func retainAllocatedStartAuthority(_ retained: SessionAuthority, message: String) {
        hasUnknownStartAllocation = false
        sessionAuthority = retained
        releaseLocalMediaForPendingClosure()
        if closureRecoveryOrigin == nil, let connectionOrigin {
            closureRecoveryOrigin = connectionOrigin
            closureRecoveryEpochCounter &+= 1
            closureRecoveryEpoch = closureRecoveryEpochCounter
        }
        enterUncertain(message)
    }

    private func retainUnknownStartAllocation(_ message: String) {
        hasUnknownStartAllocation = true
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia()
        clearPresentationState()
        mediaConnectionState = .unknown
        phase = .uncertain(message)
        lastError = message
        knownIdleAuthority = false
        automaticReconnectEpoch = nil
        changed()
    }

    /// Call from touch/press began. Microphone audio is enabled only after the gateway accepts hold.
    public func beginPushToTalk(gestureEpoch: Int) async throws {
        guard activeMode == .ptt, let authority = activeAuthority else { throw VoiceError.wrongMode }
        guard mediaConnectionState == .connected,
              (!externalAudioAuthorizationRequired || externalAudioAuthorized),
              gestureEpoch == pttGestureEpoch,
              !pttHeld, !pttFinishing else { throw VoiceError.pttNotReady }
        commandSequence += 1
        let sequence = commandSequence
        transport.setPlaybackEnabled(false)
        // Logical hold begins immediately so a fast physical release can close it while the
        // acknowledgement is in flight. Capture itself remains closed until acknowledgement.
        // Drop the idle sample so a previous hold can never animate a new hold before ACK.
        latestMediaSample = nil
        pttHeld = true
        changed()
        do {
            try await transport.sendPushToTalk(generation: authority.generation, held: true, cancel: false, commandSequence: sequence)
            guard activeAuthority?.generation == authority.generation, commandSequence == sequence, pttHeld else { return }
            applyMicrophonePolicy()
            changed()
        } catch {
            enterUncertain("Push-to-talk start outcome is uncertain. Stop before trying again.")
            throw error
        }
    }

    /// Call synchronously from touch/press ended. The local microphone closes before network work.
    /// There is deliberately no client-side commit/flush call.
    public func endPushToTalk(cancel: Bool = false) async throws {
        guard activeMode == .ptt, let authority = activeAuthority else { throw VoiceError.wrongMode }
        guard pttHeld else { return }
        transport.setMicrophoneEnabled(false)
        latestMediaSample = nil
        pttHeld = false
        pttFinishing = true
        commandSequence += 1
        let sequence = commandSequence
        changed()
        do {
            try await transport.sendPushToTalk(generation: authority.generation, held: false, cancel: cancel, commandSequence: sequence)
            guard activeAuthority?.generation == authority.generation, commandSequence == sequence else { return }
            if activeRouting == .liaison { applyPlaybackPolicy() }
        } catch {
            enterUncertain("Push-to-talk release outcome is uncertain. Stop before trying again.")
            throw error
        }
    }

    public func stop() async {
        if startInFlight || hasUnknownStartAllocation {
            interruptPendingStart()
            return
        }
        operationNonce += 1
        guard let authority = activeAuthority else {
            let remainedKnownIdle = knownIdleAuthority
            phase = .stopping
            releaseLocalMediaForPendingClosure()
            changed()
            localTeardown(nextPhase: connectionOrigin == nil ? .disconnected : .ready)
            knownIdleAuthority = remainedKnownIdle && connectionOrigin != nil
            if knownIdleAuthority, relayConnected == false { requestAutomaticReconnect() }
            changed()
            return
        }

        phase = .stopping
        // Local capture, playback, and peer resources close before any network
        // suspension. Exact generation authority remains until provider proof.
        releaseLocalMediaForPendingClosure()
        changed()
        do {
            try await transport.close(generation: authority.generation)
            guard activeAuthority?.generation == authority.generation else { return }
            // HTTP 202 means only that closing began. Stay Stopping.
        } catch {
            guard activeAuthority?.generation == authority.generation else { return }
            enterUncertain("Provider closure is unconfirmed. Stop retries only this same voice generation.")
        }
    }

    /// An established user-started session may continue under the declared audio
    /// background mode. A session still starting never becomes active after the
    /// app has left the foreground, and a physical PTT hold is never retained.
    public func requireExternalAudioAuthorization() {
        externalAudioAuthorizationRequired = true
        externalAudioAuthorized = false
        applyMicrophonePolicy()
        applyPlaybackPolicy()
    }

    public func mayAuthorizeExternalAudio(
        generation: String,
        peerAuthority: PeerConnectionAuthority
    ) -> Bool {
        guard case .active = phase else { return false }
        return sessionAuthority?.generation == generation &&
            sessionAuthority?.peerAuthority == peerAuthority &&
            mediaConnectionState == .connected
    }

    public func setExternalAudioAuthorized(
        generation: String,
        peerAuthority: PeerConnectionAuthority,
        authorized: Bool
    ) {
        guard externalAudioAuthorizationRequired,
              let authority = sessionAuthority,
              authority.generation == generation,
              authority.peerAuthority == peerAuthority,
              case .active = phase else { return }
        externalAudioAuthorized = authorized
        if !authorized {
            pttGestureEpoch &+= 1
            if pttHeld {
                pttHeld = false
                pttFinishing = true
                commandSequence += 1
                pendingExternalPTTCancel = ExternalPTTCancelRequest(
                    generation: authority.generation,
                    peerAuthority: authority.peerAuthority,
                    operationNonce: operationNonce,
                    commandSequence: commandSequence
                )
            }
        }
        applyMicrophonePolicy()
        applyPlaybackPolicy()
        if authorized { announceGreetingReadinessIfAllowed() }
        changed()
    }

    public func applyExternalAudioTransition(
        generation: String,
        peerAuthority: PeerConnectionAuthority,
        revision: UInt64,
        authorized: Bool
    ) {
        guard revision > externalAudioTransitionRevision,
              externalAudioAuthorizationRequired,
              sessionAuthority?.generation == generation,
              sessionAuthority?.peerAuthority == peerAuthority,
              case .active = phase else { return }
        if authorized {
            guard mayAuthorizeExternalAudio(generation: generation, peerAuthority: peerAuthority) else { return }
        }
        externalAudioTransitionRevision = revision
        interruptedGeneration = authorized ? nil : generation
        audioInterrupted = !authorized
        setExternalAudioAuthorized(
            generation: generation,
            peerAuthority: peerAuthority,
            authorized: authorized
        )
    }

    public func performPendingExternalPTTCancel() async {
        guard let request = pendingExternalPTTCancel,
              inFlightExternalPTTCancel == nil,
              operationNonce == request.operationNonce,
              sessionAuthority?.generation == request.generation,
              sessionAuthority?.peerAuthority == request.peerAuthority,
              commandSequence == request.commandSequence,
              case .active = phase else { return }
        // Claim once before the first await. Concurrent helpers cannot send the
        // same cancel command, and no failed/unknown outcome is auto-retried.
        pendingExternalPTTCancel = nil
        inFlightExternalPTTCancel = request
        do {
            try await transport.sendPushToTalk(
                generation: request.generation,
                held: false,
                cancel: true,
                commandSequence: request.commandSequence
            )
        } catch {
            guard inFlightExternalPTTCancel == request,
                  operationNonce == request.operationNonce,
                  sessionAuthority?.generation == request.generation,
                  sessionAuthority?.peerAuthority == request.peerAuthority,
                  commandSequence == request.commandSequence,
                  case .active = phase else { return }
            inFlightExternalPTTCancel = nil
            enterUncertain("Push-to-talk cancel outcome is uncertain. Stop before trying again.")
            return
        }
        guard inFlightExternalPTTCancel == request,
              operationNonce == request.operationNonce,
              sessionAuthority?.generation == request.generation,
              sessionAuthority?.peerAuthority == request.peerAuthority,
              commandSequence == request.commandSequence,
              case .active = phase else { return }
        inFlightExternalPTTCancel = nil
    }

    public func setPresentationVisible(_ visible: Bool) {
        guard presentationVisible != visible else { return }
        presentationVisible = visible
        transport.setMediaObservationEnabled(visible)
        if !visible { clearMediaSample() }
        presentationChanged()
    }

    public func applicationDidEnterBackground() async {
        switch phase {
        case .starting:
            await stop()
            return
        case .active:
            break
        case .disconnected, .ready, .stopping, .uncertain:
            return
        }
        guard sessionAuthority != nil else { return }
        if pttHeld {
            do { try await endPushToTalk(cancel: true) }
            catch { await stop() }
        }
    }

    public func audioInterruptionBegan(generation: String?) async {
        guard !externalAudioAuthorizationRequired else { return }
        if generation == nil, phase == .starting {
            await stop()
            return
        }
        guard let authority = sessionAuthority, generation == authority.generation,
              case .active = phase else { return }
        interruptedGeneration = authority.generation
        audioInterrupted = true
        latestMediaSample = nil
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        if pttHeld { try? await endPushToTalk(cancel: true) }
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        changed()
    }

    public func audioInterruptionEnded(generation: String, shouldResume: Bool) async {
        guard !externalAudioAuthorizationRequired else { return }
        guard audioInterrupted, interruptedGeneration == generation,
              sessionAuthority?.generation == generation, case .active = phase else { return }
        guard shouldResume else {
            await stop()
            return
        }
        interruptedGeneration = nil
        audioInterrupted = false
        applyMicrophonePolicy()
        applyPlaybackPolicy()
        announceGreetingReadinessIfAllowed()
        changed()
    }

    public func setUserMuted(_ muted: Bool) {
        guard activeAuthority != nil, case .active = phase else { return }
        userMuted = muted
        applyMicrophonePolicy()
        changed()
    }

    public func privateAudioRouteLost(generation: String?) async {
        if generation == nil, phase == .starting {
            lastError = "Private audio route disconnected while voice was starting."
            await stop()
            return
        }
        guard let generation, sessionAuthority?.generation == generation else { return }
        lastError = "Private audio route disconnected. The conversation was ended before audio could move to the speaker."
        await stop()
    }

    public func audioMediaServicesReset(generation: String?) async {
        if generation == nil, phase == .starting {
            lastError = "System audio services reset while voice was starting."
            await stop()
            return
        }
        guard let generation, sessionAuthority?.generation == generation else { return }
        lastError = "System audio services reset. Start a new conversation explicitly."
        await stop()
    }

    public func disconnect() async {
        if startInFlight || hasUnknownStartAllocation {
            interruptPendingStart()
            return
        }
        await stop()
        guard activeAuthority == nil else {
            enterUncertain("Provider closure is unconfirmed. This session authority was retained.")
            return
        }
        transport.disconnectEvents()
        connectionOrigin = nil
        agents = []
        selected = nil
        knownIdleAuthority = false
        automaticReconnectEpoch = nil
        relayConnected = nil
        phase = .disconnected
        changed()
    }

    public func forgetDevice(origin: URL) async throws {
        let canonical = try CanonicalGatewayOrigin(origin)
        guard !startInFlight, !hasUnknownStartAllocation else { throw VoiceError.callAlreadyActive }
        await disconnect()
        guard activeAuthority == nil else { throw VoiceError.callAlreadyActive }
        try transport.forgetDevice(origin: canonical.url)
    }

    private var activeAuthority: SessionAuthority? { sessionAuthority }

    private func observeEvents() {
        guard eventTask == nil else { return }
        let stream = transport.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.accept(event)
            }
        }
    }

    private func accept(_ event: GatewayEvent) {
        switch event {
        case let .roster(connected, incoming):
            rosterRevision &+= 1
            let beganLossEpoch = !connected && relayConnected != false
            relayConnected = connected
            agents = connected ? incoming : []
            if connected { automaticReconnectEpoch = nil }
            else if beganLossEpoch, knownIdleAuthority { requestAutomaticReconnect() }
            if let selected, !agents.contains(where: { $0.identityKey == selected.identityKey }) { self.selected = nil }
            if let pinned = activeTarget, !agents.contains(where: { $0.identityKey == pinned.identityKey }) {
                switch phase {
                case .active, .starting:
                    let expectedOperationNonce = operationNonce
                    let expectedGeneration = activeAuthority?.generation
                    Task { [weak self] in
                        await self?.stopIfCurrent(
                            operationNonce: expectedOperationNonce,
                            generation: expectedGeneration
                        )
                    }
                case .disconnected, .ready, .stopping, .uncertain: break
                }
            }
        case let .voiceState(generation, state, reason):
            guard activeAuthority?.generation == generation else { return }
            if state == "closing" {
                phase = .stopping
                releaseLocalMediaForPendingClosure()
                if let reason { lastError = reason }
            } else if state == "closed", reason == "provider_closed" {
                lastConfirmedProviderClosedGeneration = generation
                localTeardown(nextPhase: connectionOrigin == nil ? .disconnected : .ready)
                selected = nil
                confirmedEndRevision &+= 1
                knownIdleAuthority = connectionOrigin != nil
                if knownIdleAuthority, relayConnected == false { requestAutomaticReconnect() }
                lastError = nil
            } else if state == "closed" {
                knownIdleAuthority = false
                automaticReconnectEpoch = nil
                releaseLocalMediaForPendingClosure()
                enterUncertain("Provider closure is unconfirmed (\(reason ?? "unknown terminal state")). Stop retries only this same voice generation.")
            }
        case let .pttReady(generation):
            guard activeAuthority?.generation == generation else { return }
            pttFinishing = false
            announceGreetingReadinessIfAllowed()
        case let .replyWindow(generation, milliseconds):
            guard activeRouting == .direct, let authority = activeAuthority, authority.generation == generation, !pttHeld else { return }
            playbackTask?.cancel()
            guard mediaConnectionState == .connected,
                  !externalAudioAuthorizationRequired || externalAudioAuthorized else { return }
            transport.setPlaybackEnabled(true)
            playbackTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(max(0, milliseconds)))
                guard !Task.isCancelled else { return }
                self?.transport.setPlaybackEnabled(false)
            }
        case let .caption(generation, rawSpeaker, delta, groupID):
            guard case .active = phase, activeAuthority?.generation == generation, !delta.isEmpty else { return }
            let speaker: VoiceCaptionSegment.Speaker
            if rawSpeaker == "user" { speaker = .user }
            else if rawSpeaker == "assistant" { speaker = .agent }
            else { return }
            captionThreadStore.accept(generation: generation, speaker: speaker, delta: delta, groupID: groupID)
            presentationChanged()
            return
        case let .captionStable(generation, speaker, groupID):
            guard case .active = phase, activeAuthority?.generation == generation, speaker == "user",
                  captionThreadStore.markStable(generation: generation, speaker: .user, groupID: groupID) else { return }
            presentationChanged()
            return
        case let .utterance(generation, text):
            guard case .active = phase, activeAuthority?.generation == generation else { return }
            captionThreadStore.accept(generation: generation, speaker: .user, delta: text, groupID: nil)
            presentationChanged()
            return
        case .deviceRevoked:
            knownIdleAuthority = false
            automaticReconnectEpoch = nil
            endAuthenticatedSession(message: DeviceAuthenticationError.deviceRevoked.localizedDescription, reconnectAllowed: false)
        case let .sessionEnded(code, message):
            let reconnectAllowed = knownIdleAuthority
            endAuthenticatedSession(message: "\(code): \(message)", reconnectAllowed: reconnectAllowed)
        case let .peerConnectionState(authority, state):
            acceptPeerConnectionState(authority: authority, state: state)
        case let .audioInterruptionBegan(generation):
            Task { await audioInterruptionBegan(generation: generation) }
        case let .audioInterruptionEnded(generation, shouldResume):
            Task { await audioInterruptionEnded(generation: generation, shouldResume: shouldResume) }
        case let .privateAudioRouteLost(generation):
            Task { await privateAudioRouteLost(generation: generation) }
        case let .audioMediaServicesReset(generation):
            Task { await audioMediaServicesReset(generation: generation) }
        case let .error(generation, code, message):
            guard generation == nil || activeAuthority?.generation == generation else { return }
            lastError = "\(code): \(message)"
        }
        changed()
    }

    private func endAuthenticatedSession(message: String, reconnectAllowed: Bool) {
        operationNonce &+= 1
        transport.disconnectEvents()
        if startInFlight {
            transport.setMicrophoneEnabled(false)
            transport.setPlaybackEnabled(false)
            transport.teardownMedia()
            knownIdleAuthority = false
            relayConnected = false
            automaticReconnectEpoch = nil
            agents = []
            selected = nil
            lastError = message
            changed()
            return
        }
        if hasUnknownStartAllocation {
            knownIdleAuthority = false
            relayConnected = false
            automaticReconnectEpoch = nil
            agents = []
            selected = nil
            retainUnknownStartAllocation("\(message) Startup allocation and provider closure remain unconfirmed.")
            return
        }
        if activeAuthority != nil {
            let lostOrigin = connectionOrigin
            releaseLocalMediaForPendingClosure()
            connectionOrigin = nil
            agents = []
            selected = nil
            knownIdleAuthority = false
            relayConnected = false
            automaticReconnectEpoch = nil
            if closureRecoveryOrigin == nil, let lostOrigin {
                closureRecoveryOrigin = lostOrigin
                closureRecoveryEpochCounter &+= 1
                closureRecoveryEpoch = closureRecoveryEpochCounter
            }
            enterUncertain("\(message) Provider closure is unconfirmed; session authority was retained.")
            return
        }
        localTeardown(nextPhase: .disconnected)
        connectionOrigin = nil
        agents = []
        selected = nil
        knownIdleAuthority = reconnectAllowed
        relayConnected = false
        if reconnectAllowed { requestAutomaticReconnect() }
        else { automaticReconnectEpoch = nil }
        lastError = message
    }

    private func acceptPeerConnectionState(authority: PeerConnectionAuthority, state: PeerConnectionState) {
        guard case .active = phase,
              let sessionAuthority,
              sessionAuthority.peerAuthority == authority else { return }
        let mediaBeforeDisconnect: PeerMediaBeforeDisconnect
        if audioInterrupted {
            mediaBeforeDisconnect = .gated
        } else if activeMode == .continuous {
            mediaBeforeDisconnect = .continuous
        } else if activeMode == .ptt {
            mediaBeforeDisconnect = pttHeld ? .pttHeld : .pttIdle
        } else {
            mediaBeforeDisconnect = .gated
        }
        let action = peerRecovery.observe(
            state,
            authority: authority,
            nowMilliseconds: Self.monotonicMilliseconds(),
            mediaBeforeDisconnect: mediaBeforeDisconnect
        )
        if action == .none, (state == .connected || state == .completed), mediaConnectionState == .unknown {
            mediaConnectionState = .connected
            restoreCurrentMediaPolicy()
            announceGreetingReadinessIfAllowed()
            changed()
            return
        }
        applyPeerRecoveryAction(action, authority: authority)
    }

    private func applyPeerRecoveryAction(_ action: PeerConnectionRecoveryAction, authority: PeerConnectionAuthority) {
        switch action {
        case .none:
            return
        case let .gateMediaAndArmGrace(sequence, deadline):
            mediaRecoveryRevision &+= 1
            pttGestureEpoch &+= 1
            latestMediaSample = nil
            mediaConnectionState = .reconnecting
            transport.setMicrophoneEnabled(false)
            transport.setPlaybackEnabled(false)
            peerGraceTask?.cancel()
            peerGraceTask = Task { [weak self] in
                let remaining = max(0, deadline - Self.monotonicMilliseconds())
                try? await Task.sleep(for: .milliseconds(remaining))
                guard !Task.isCancelled else { return }
                self?.peerGraceExpired(authority: authority, sequence: sequence)
            }
            changed()
        case .restoreContinuousSameSession, .restorePTTIdlePlaybackSameSession, .recoveredButRemainGated:
            peerGraceTask?.cancel()
            peerGraceTask = nil
            mediaConnectionState = .connected
            restoreCurrentMediaPolicy()
            announceGreetingReadinessIfAllowed()
            changed()
        case let .cancelPTTHoldBeforePlayback(generation):
            peerGraceTask?.cancel()
            peerGraceTask = nil
            let expectedRecoveryRevision = mediaRecoveryRevision
            Task { [weak self] in
                await self?.finishPTTRecovery(
                    generation: generation,
                    authority: authority,
                    recoveryRevision: expectedRecoveryRevision
                )
            }
        case let .endSession(generation):
            guard let generation, generation == activeAuthority?.generation,
                  authority == activeAuthority?.peerAuthority,
                  case .active = phase else { return }
            // Terminal media authority becomes non-active synchronously. A late
            // Connected callback cannot use the normal recovery fallback while
            // the exact-generation close request waits to run.
            operationNonce &+= 1
            let terminalStopNonce = operationNonce
            phase = .stopping
            releaseLocalMediaForPendingClosure()
            changed()
            Task { [weak self] in
                await self?.stopAfterPeerTerminal(
                    generation: generation,
                    authority: authority,
                    operationNonce: terminalStopNonce
                )
            }
        }
    }

    private func peerGraceExpired(authority: PeerConnectionAuthority, sequence: Int) {
        guard case .active = phase, activeAuthority?.peerAuthority == authority else { return }
        let action = peerRecovery.graceExpired(
            authority: authority,
            graceSequence: sequence,
            nowMilliseconds: Self.monotonicMilliseconds()
        )
        applyPeerRecoveryAction(action, authority: authority)
    }

    private func finishPTTRecovery(
        generation: String,
        authority: PeerConnectionAuthority,
        recoveryRevision: Int
    ) async {
        guard case .active = phase, activeAuthority?.generation == generation,
              activeAuthority?.peerAuthority == authority,
              mediaRecoveryRevision == recoveryRevision,
              mediaConnectionState == .reconnecting else { return }
        if pttHeld {
            do { try await endPushToTalk(cancel: true) }
            catch { return }
        }
        guard case .active = phase, activeAuthority?.generation == generation,
              activeAuthority?.peerAuthority == authority,
              mediaRecoveryRevision == recoveryRevision,
              mediaConnectionState == .reconnecting else { return }
        mediaConnectionState = .connected
        restoreCurrentMediaPolicy()
        announceGreetingReadinessIfAllowed()
        changed()
    }

    private func announceGreetingReadinessIfAllowed() {
        guard !greetingReadinessSent,
              case let .active(authority) = phase,
              mediaConnectionState == .connected,
              (!externalAudioAuthorizationRequired || externalAudioAuthorized),
              !audioInterrupted, !pttHeld, !pttFinishing else { return }
        let expectedNonce = operationNonce
        Task { [weak self] in
            guard let self,
                  self.operationNonce == expectedNonce,
                  self.activeAuthority == authority,
                  case .active = self.phase,
                  self.mediaConnectionState == .connected,
                  (!self.externalAudioAuthorizationRequired || self.externalAudioAuthorized),
                  !self.audioInterrupted, !self.pttHeld, !self.pttFinishing,
                  !self.greetingReadinessSent else { return }
            // Recheck every playback gate at actual dispatch, then consume the
            // per-Start authority before the first await. Unknown POST outcomes
            // and later ICE recovery must never repeat it.
            self.greetingReadinessSent = true
            try? await self.transport.announceMediaReady(generation: authority.generation)
        }
    }

    private func restoreCurrentMediaPolicy() {
        guard case .active = phase, activeAuthority != nil, mediaConnectionState == .connected else {
            transport.setMicrophoneEnabled(false)
            transport.setPlaybackEnabled(false)
            return
        }
        applyMicrophonePolicy()
        applyPlaybackPolicy()
    }

    private func stopAfterPeerTerminal(
        generation: String,
        authority: PeerConnectionAuthority,
        operationNonce expectedNonce: Int
    ) async {
        guard phase == .stopping, operationNonce == expectedNonce,
              activeAuthority?.generation == generation,
              activeAuthority?.peerAuthority == authority,
              mediaConnectionState == .unknown else {
            // A delayed terminal task must never act on whatever is current now.
            return
        }
        do {
            try await transport.close(generation: generation)
        } catch {
            guard activeAuthority?.generation == generation,
                  activeAuthority?.peerAuthority == authority else { return }
            enterUncertain("Provider closure is unconfirmed after media failure. Stop retries only this same voice generation.")
        }
    }

    private func stopIfCurrent(operationNonce expectedNonce: Int, generation: String?) async {
        guard operationNonce == expectedNonce else { return }
        if let generation {
            guard case .active = phase, activeAuthority?.generation == generation else { return }
        } else {
            guard phase == .starting, activeAuthority == nil else { return }
        }
        await stop()
    }

    private func invalidatePeerRecovery() {
        mediaRecoveryRevision &+= 1
        peerGraceTask?.cancel()
        peerGraceTask = nil
        peerRecovery.invalidate()
        mediaConnectionState = .unknown
        pttGestureEpoch &+= 1
    }

    private static func monotonicMilliseconds() -> Int64 {
        Int64(min(UInt64(Int64.max), DispatchTime.now().uptimeNanoseconds / 1_000_000))
    }

    private func releaseLocalMediaForPendingClosure() {
        invalidatePeerRecovery()
        playbackTask?.cancel()
        playbackTask = nil
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia()
        pttHeld = false
        pttFinishing = false
        pendingExternalPTTCancel = nil
        inFlightExternalPTTCancel = nil
        audioInterrupted = false
        interruptedGeneration = nil
        userMuted = false
        if externalAudioAuthorizationRequired { externalAudioAuthorized = false }
        clearPresentationState()
    }

    private func requestAutomaticReconnect() {
        guard automaticReconnectEpoch == nil else { return }
        reconnectEpochCounter &+= 1
        automaticReconnectEpoch = reconnectEpochCounter
    }

    private func enterUncertain(_ message: String) {
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        if externalAudioAuthorizationRequired { externalAudioAuthorized = false }
        pendingExternalPTTCancel = nil
        inFlightExternalPTTCancel = nil
        clearPresentationState()
        pttHeld = false
        pttFinishing = true
        phase = .uncertain(message)
        lastError = message
        changed()
    }

    private func localTeardown(nextPhase: CallPhase) {
        invalidatePeerRecovery()
        hasUnknownStartAllocation = false
        playbackTask?.cancel()
        playbackTask = nil
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia()
        sessionAuthority = nil
        closureRecoveryOrigin = nil
        closureRecoveryEpoch = nil
        activeTarget = nil
        activeMode = nil
        activeRouting = nil
        pttHeld = false
        pttFinishing = false
        pendingExternalPTTCancel = nil
        inFlightExternalPTTCancel = nil
        audioInterrupted = false
        interruptedGeneration = nil
        userMuted = false
        commandSequence = 0
        if externalAudioAuthorizationRequired { externalAudioAuthorized = false }
        clearPresentationState()
        phase = nextPhase
    }

    private func acceptMediaLevelSample(_ sample: VoiceMediaLevelSample) {
        guard presentationVisible,
              case .active = phase,
              let authority = activeAuthority,
              sample.generation == authority.generation,
              sample.peerAuthority == authority.peerAuthority else { return }
        latestMediaSample = sample
        mediaSampleExpiryTask?.cancel()
        let now = monotonicNanoseconds()
        let remainingNanoseconds: UInt64
        if now >= sample.observedAtUptimeNanoseconds {
            let age = now - sample.observedAtUptimeNanoseconds
            remainingNanoseconds = age <= VoiceMediaPollPolicy.maximumAgeNanoseconds
                ? VoiceMediaPollPolicy.maximumAgeNanoseconds - age
                : 0
        } else {
            remainingNanoseconds = 0
        }
        mediaSampleExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .nanoseconds(Int64(remainingNanoseconds + 1)))
            guard !Task.isCancelled, let self, self.latestMediaSample == sample else { return }
            self.presentationChanged()
        }
        presentationChanged()
    }

    private func clearMediaSample() {
        mediaSampleExpiryTask?.cancel()
        mediaSampleExpiryTask = nil
        latestMediaSample = nil
    }

    private func clearPresentationState() {
        clearMediaSample()
        captionThreadStore.clear()
    }

    private func applyMicrophonePolicy() {
        let modeAllowsMicrophone = activeMode == .continuous || (activeMode == .ptt && pttHeld)
        let sessionAllowsMicrophone: Bool
        if case .active = phase { sessionAllowsMicrophone = activeAuthority != nil }
        else { sessionAllowsMicrophone = false }
        transport.setMicrophoneEnabled(
            sessionAllowsMicrophone && mediaConnectionState == .connected &&
                (!externalAudioAuthorizationRequired || externalAudioAuthorized) &&
                modeAllowsMicrophone && !audioInterrupted && !userMuted
        )
    }

    private func applyPlaybackPolicy() {
        let sessionActive: Bool
        if case .active = phase { sessionActive = true } else { sessionActive = false }
        let externallyAuthorized = !externalAudioAuthorizationRequired || externalAudioAuthorized
        let modeAllowsPlayback = activeMode == .continuous || (activeMode == .ptt && !pttHeld)
        transport.setPlaybackEnabled(
            sessionActive && activeAuthority != nil && mediaConnectionState == .connected &&
                externallyAuthorized && modeAllowsPlayback && !audioInterrupted
        )
    }

    private func changed() { didChange?() }
    private func presentationChanged() { presentationDidChange?() }
}
