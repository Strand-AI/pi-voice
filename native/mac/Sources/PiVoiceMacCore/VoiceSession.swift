import Dispatch
import Foundation

public struct AsyncOperationAuthority: Equatable, Sendable {
    public private(set) var current = UUID()

    public init() {}

    public mutating func begin() -> UUID {
        current = UUID()
        return current
    }

    public mutating func invalidate() { current = UUID() }
    public func owns(_ candidate: UUID) -> Bool { candidate == current }
}

public struct MediaOwnershipFence: Equatable, Sendable {
    public private(set) var revision = 0

    public init() {}

    public mutating func begin() -> Int {
        revision += 1
        return revision
    }

    public mutating func invalidate() { revision += 1 }
    public func owns(_ candidate: Int) -> Bool { candidate == revision }
}

public enum VoiceMode: String, Codable, CaseIterable, Sendable {
    case continuous
    case ptt
}

public enum ConversationRouting: String, Codable, Sendable {
    case liaison
}

public enum VoiceName: String, Codable, CaseIterable, Sendable {
    case marin, quartz, ripple, vesper, willow, stone, gleam, meridian, bossa, tempo, beacon, delta, cinder
}

public struct LiveSessionRequest: Equatable, Sendable {
    public let target: AgentTarget
    public let mode: VoiceMode
    public let voice: VoiceName
    public let routing: ConversationRouting
    public let idleTimeoutMinutes: Int

    public init(target: AgentTarget, mode: VoiceMode, voice: VoiceName, routing: ConversationRouting = .liaison, idleTimeoutMinutes: Int = 5) {
        self.target = target
        self.mode = mode
        self.voice = voice
        self.routing = routing
        self.idleTimeoutMinutes = min(30, max(1, idleTimeoutMinutes))
    }

    public struct Body: Encodable, Sendable {
        public let sdp, connectionId, targetId, targetEpoch, voice, inputMode, routingMode: String
        public let idleTimeoutMinutes: Int
    }
    public func gatewayBody(sdp: String, connectionID: String) -> Body {
        Body(sdp: sdp, connectionId: connectionID, targetId: target.id, targetEpoch: target.endpointEpoch,
             voice: voice.rawValue, inputMode: mode.rawValue, routingMode: routing.rawValue,
             idleTimeoutMinutes: idleTimeoutMinutes)
    }
}

public struct SessionAuthority: Equatable, Sendable {
    public let generation: String
    public let idleDeadline: Date
    public let hardDeadline: Date
    public let peerAuthority: PeerConnectionAuthority
    public let initialPeerState: PeerConnectionState

    public init(
        generation: String,
        idleDeadline: Date,
        hardDeadline: Date,
        peerAuthority: PeerConnectionAuthority,
        initialPeerState: PeerConnectionState
    ) {
        self.generation = generation
        self.idleDeadline = idleDeadline
        self.hardDeadline = hardDeadline
        self.peerAuthority = peerAuthority
        self.initialPeerState = initialPeerState
    }
}

public struct UnknownVoiceStartAllocation: Error, LocalizedError, Sendable {
    public let message: String

    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct RetainedVoiceStartAuthority: Error, LocalizedError, Sendable {
    public let authority: SessionAuthority
    public let message: String

    public init(authority: SessionAuthority, message: String) {
        self.authority = authority
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum MediaConnectionState: Equatable, Sendable {
    case connected
    case reconnecting
    case unknown
}

public enum VoiceGatewayEvent: Equatable, Sendable {
    case roster(connected: Bool, agents: [AgentTarget])
    case voiceState(generation: String, state: String, reason: String?)
    case pttReady(generation: String)
    case caption(generation: String, speaker: String, delta: String, groupID: String?)
    case captionStable(generation: String, speaker: String, groupID: String)
    case utterance(generation: String, text: String)
    case playbackActivity(generation: String, active: Bool)
    case peerConnectionState(authority: PeerConnectionAuthority, state: PeerConnectionState)
    case error(generation: String?, code: String, message: String)
    case deviceRevoked(credentialCleared: Bool)
    case sessionEnded(message: String)
}

public enum CallPhase: Equatable, Sendable {
    case disconnected
    case ready
    case starting
    case active(SessionAuthority)
    case stopping
    case uncertain(String)
}

public enum VoiceFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidOrigin
    case notReady
    case targetUnavailable
    case staleTarget
    case callAlreadyActive
    case wrongMode
    case pttNotReady

    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: "Use private HTTPS, or loopback HTTP on this Mac."
        case .notReady: "The native gateway connection is not ready."
        case .targetUnavailable: "Choose a currently available exact Pi endpoint."
        case .staleTarget: "The selected endpoint ID or epoch changed. Choose it again."
        case .callAlreadyActive: "A voice session is already active."
        case .wrongMode: "Push to talk is not the active mode."
        case .pttNotReady: "Wait for the current push-to-talk turn to finish."
        }
    }
}

@MainActor
public protocol VoiceTransport: AnyObject {
    var events: AsyncStream<VoiceGatewayEvent> { get }
    func pair(origin: URL, token: String, deviceName: String) async throws
    func renew(origin: URL) async throws
    func hasSavedDevice(origin: URL) throws -> Bool
    func forgetSavedDevice(origin: URL) throws
    func providerClosureReceipt(
        origin: URL,
        generation: String,
        mayMutateCredential: @escaping @MainActor () -> Bool
    ) async throws -> ProviderClosureReceiptResult
    func connectEvents(origin: URL) async throws
    func disconnectEvents()
    func start(target: AgentTarget, mode: VoiceMode, voice: VoiceName, routing: ConversationRouting, idleTimeoutMinutes: Int) async throws -> SessionAuthority
    func announceMediaReady(generation: String) async throws
    func sendPushToTalk(generation: String, held: Bool, cancel: Bool, commandSequence: Int) async throws
    /// Success means provider closure for this exact generation is confirmed, not merely requested.
    func close(generation: String) async throws
    func setMicrophoneEnabled(_ enabled: Bool)
    func setPlaybackEnabled(_ enabled: Bool)
    func setPlaybackGain(_ gain: Double)
    func teardownMedia()
}

/// Owns exact target and generation authority. It has no local transcript/send path:
/// a PTT release only asks the existing gateway to finish its provider-side turn.
@MainActor
public final class VoiceSessionCoordinator {
    public private(set) var phase: CallPhase = .disconnected
    public private(set) var lastEndConfirmed = false
    public private(set) var lastEndGeneration: String?
    public private(set) var idleTimeoutMinutes = 5
    public private(set) var rosterConnected = false
    public private(set) var rosterRevision = 0
    public private(set) var agents: [AgentTarget] = []
    public private(set) var selected: AgentTarget?
    public private(set) var activeTarget: AgentTarget?
    public private(set) var activeMode: VoiceMode?
    public private(set) var userMuted = false
    public var continuousMicrophoneMuted: Bool { userMuted }
    public private(set) var mediaConnectionState: MediaConnectionState = .unknown
    public private(set) var pttHeld = false
    public private(set) var pttFinishing = false
    public var captionThread: [VoiceCaptionSegment] {
        guard case .active = phase, let generation = authority?.generation else { return [] }
        let inputCurrent = mediaConnectionState == .connected
            && !userMuted
            && (activeMode == .continuous || (activeMode == .ptt && pttHeld))
        let raw = captionThreadStore.segments.filter { $0.generation == generation }
        let newestAgent = raw.lastIndex(where: { $0.speaker == .agent })
        let playbackCurrent = mediaConnectionState == .connected
            && (activeMode != .ptt || !pttHeld)
            && playbackActivityCurrent
        return raw.enumerated().map { index, segment in
            let isCurrent: Bool
            if segment.speaker == .user {
                isCurrent = segment.isCurrent && inputCurrent
            } else {
                isCurrent = index == newestAgent && playbackCurrent
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
    public private(set) var lastError: String?
    public private(set) var outputGain = 1.0
    public var activeGeneration: String? { authority?.generation }
    public var isStartInFlight: Bool { startInFlight }
    public private(set) var hasUnknownStartAllocation = false
    public private(set) var explicitReconnectRequired = false
    public func retainsAuthorityOrigin(_ candidate: URL) -> Bool {
        guard let exact = try? GatewayConfiguration(baseURL: candidate).origin else { return false }
        return connectionOrigin.flatMap { try? GatewayConfiguration(baseURL: $0).origin } == exact
    }
    public private(set) var closureRecoveryEpoch: UInt64?
    public var didChange: (@MainActor () -> Void)?

    private let transport: VoiceTransport
    private var eventTask: Task<Void, Never>?
    private var hardwareControlTask: Task<Void, Never>?
    private var commandSequence = 0
    private var pttCaptureAcknowledged = false
    private var operationNonce = 0
    private var startInFlight = false
    private var greetingReadinessSent = false
    private var peerRecoveryPolicy: PeerConnectionRecoveryPolicy
    private var peerGraceTask: Task<Void, Never>?
    private var peerMediaGateRevision = 0
    private var closureRecoveryFence = ProviderClosureRecoveryFence()
    private var closureRecoveryMayResumeReady = false
    private var captionThreadStore = BoundedCaptionThread()
    private var playbackActivityCurrent = false
    private let monotonicMilliseconds: @MainActor () -> Int64
    private var connectionOrigin: URL?
    private var authority: SessionAuthority?

    public init(
        transport: VoiceTransport,
        peerRecoveryPolicy: PeerConnectionRecoveryPolicy = PeerConnectionRecoveryPolicy(),
        monotonicMilliseconds: @escaping @MainActor () -> Int64 = {
            Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        }
    ) {
        self.transport = transport
        self.peerRecoveryPolicy = peerRecoveryPolicy
        self.monotonicMilliseconds = monotonicMilliseconds
        transport.setPlaybackGain(outputGain)
    }

    deinit {
        eventTask?.cancel()
        peerGraceTask?.cancel()
    }

    public func connect(origin: URL, pairingToken: String, deviceName: String) async throws {
        guard phase == .disconnected else { throw VoiceFailure.callAlreadyActive }
        guard Self.allowed(origin) else { throw VoiceFailure.invalidOrigin }
        operationNonce += 1
        let nonce = operationNonce
        try await transport.pair(origin: origin, token: pairingToken, deviceName: deviceName)
        try await finishConnection(origin: origin, nonce: nonce)
    }

    public func reconnectSavedDevice(origin: URL) async throws {
        guard phase == .disconnected else { throw VoiceFailure.callAlreadyActive }
        guard Self.allowed(origin) else { throw VoiceFailure.invalidOrigin }
        operationNonce += 1
        let nonce = operationNonce
        try await transport.renew(origin: origin)
        try await finishConnection(origin: origin, nonce: nonce)
    }

    public func hasSavedDevice(origin: URL) throws -> Bool {
        guard Self.allowed(origin) else { throw VoiceFailure.invalidOrigin }
        return try transport.hasSavedDevice(origin: origin)
    }

    public func hasProviderClosureRecoveryScope(epoch: UInt64) -> Bool {
        closureRecoveryEpoch == epoch && activeGeneration != nil && {
            if case .uncertain = phase { return true }
            return false
        }()
    }

    public func mayCheckProviderClosure(epoch: UInt64) -> Bool {
        hasProviderClosureRecoveryScope(epoch: epoch) && closureRecoveryFence.canBeginRequest(epoch: epoch)
    }

    public func cancelProviderClosureCheck(epoch: UInt64) {
        guard closureRecoveryEpoch == epoch else { return }
        closureRecoveryFence.invalidateRequest()
    }

    public func checkProviderClosure(epoch: UInt64) async throws -> Bool {
        guard hasProviderClosureRecoveryScope(epoch: epoch),
              let origin = connectionOrigin,
              let request = closureRecoveryFence.beginRequest(epoch: epoch) else { return false }
        let result: ProviderClosureReceiptResult
        do {
            result = try await transport.providerClosureReceipt(
                origin: origin,
                generation: request.generation,
                mayMutateCredential: { [weak self] in
                    !Task.isCancelled && self?.closureRecoveryFence.owns(request) == true
                }
            )
        } catch {
            guard !Task.isCancelled, closureRecoveryFence.finish(request) else { return false }
            throw error
        }
        guard !Task.isCancelled, closureRecoveryFence.owns(request), activeGeneration == request.generation,
              connectionOrigin.flatMap({ try? GatewayConfiguration(baseURL: $0).origin }) == request.origin else {
            return false
        }
        _ = closureRecoveryFence.finish(request)
        guard result == .providerClosed else { return false }
        lastEndGeneration = request.generation
        lastEndConfirmed = true
        lastError = nil
        releaseAfterConfirmedProviderClosure()
        changed()
        return true
    }

    public func forgetSavedDevice(origin: URL) async throws {
        guard Self.allowed(origin) else { throw VoiceFailure.invalidOrigin }
        guard !startInFlight, !hasUnknownStartAllocation else { throw VoiceFailure.callAlreadyActive }
        await disconnect()
        guard authority == nil else { throw VoiceFailure.callAlreadyActive }
        try transport.forgetSavedDevice(origin: origin)
    }

    public func setIdleTimeoutMinutes(_ minutes: Int) {
        idleTimeoutMinutes = min(30, max(1, minutes))
        changed()
    }

    public func setOutputGain(_ gain: Double) {
        outputGain = gain.isFinite ? min(1, max(0, gain)) : 1
        transport.setPlaybackGain(outputGain)
        changed()
    }

    public func select(_ endpoint: AgentTarget?) throws {
        guard authority == nil else { throw VoiceFailure.callAlreadyActive }
        guard let endpoint else { selected = nil; changed(); return }
        guard agents.contains(where: { Self.sameEndpoint($0, endpoint) }) else { throw VoiceFailure.staleTarget }
        selected = endpoint
        changed()
    }

    public func start(mode: VoiceMode, voice: VoiceName) async throws {
        guard phase == .ready, !startInFlight else { throw VoiceFailure.notReady }
        guard let target = selected else { throw VoiceFailure.targetUnavailable }
        guard agents.contains(where: { Self.sameEndpoint($0, target) }) else { throw VoiceFailure.staleTarget }

        operationNonce += 1
        let nonce = operationNonce
        startInFlight = true
        defer { startInFlight = false }
        phase = .starting
        activeTarget = target
        activeMode = mode
        hasUnknownStartAllocation = false
        userMuted = false
        pttCaptureAcknowledged = false
        pttHeld = false
        pttFinishing = false
        commandSequence = 0
        hardwareControlTask = nil
        greetingReadinessSent = false
        mediaConnectionState = .unknown
        peerGraceTask?.cancel()
        peerGraceTask = nil
        peerRecoveryPolicy.invalidate()
        clearCaptions()
        lastEndGeneration = nil
        lastEndConfirmed = false
        lastError = nil
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        changed()

        do {
            let started = try await transport.start(target: target, mode: mode, voice: voice, routing: .liaison, idleTimeoutMinutes: idleTimeoutMinutes)
            guard operationNonce == nonce, phase == .starting else {
                throw await resolvedAllocatedStartFailure(started, confirmedFailure: CancellationError())
            }
            guard started.initialPeerState == .connected || started.initialPeerState == .completed else {
                throw await resolvedAllocatedStartFailure(started, confirmedFailure: VoiceFailure.notReady)
            }
            authority = started
            peerRecoveryPolicy.begin(started.peerAuthority)
            guard peerRecoveryPolicy.bind(generation: started.generation, to: started.peerAuthority) else {
                throw await resolvedAllocatedStartFailure(started, confirmedFailure: VoiceFailure.notReady)
            }
            mediaConnectionState = .connected
            phase = .active(started)
            applyMicrophonePolicy()
            transport.setPlaybackEnabled(true)
            changed()
            announceGreetingReadinessIfAllowed()
        } catch {
            if let retained = error as? RetainedVoiceStartAuthority {
                retainAllocatedStartAuthority(retained.authority, message: retained.message)
            } else if let unknown = error as? UnknownVoiceStartAllocation {
                retainUnknownStartAllocation(unknown.message)
            } else if operationNonce == nonce {
                localTeardown(nextPhase: .ready)
                lastError = error.localizedDescription
                changed()
            } else if phase == .starting {
                localTeardown(nextPhase: rosterConnected ? .ready : .disconnected)
                lastError = error.localizedDescription
                changed()
            }
            throw error
        }
    }

    private func resolvedAllocatedStartFailure(_ started: SessionAuthority, confirmedFailure: Error) async -> Error {
        do {
            try await transport.close(generation: started.generation)
            transport.teardownMedia()
            return confirmedFailure
        } catch {
            return RetainedVoiceStartAuthority(
                authority: started,
                message: "Startup was interrupted after provider allocation. Provider closure remains unconfirmed."
            )
        }
    }

    public func interruptPendingStart() {
        guard startInFlight, phase == .starting else { return }
        operationNonce += 1
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia()
        clearCaptions()
        changed()
    }

    private func retainAllocatedStartAuthority(_ retained: SessionAuthority, message: String) {
        hasUnknownStartAllocation = false
        authority = retained
        mediaConnectionState = .unknown
        phase = .active(retained)
        retainAuthorityAfterConnectionLoss(message)
    }

    private func retainUnknownStartAllocation(_ message: String) {
        hasUnknownStartAllocation = true
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia()
        clearCaptions()
        mediaConnectionState = .unknown
        phase = .uncertain(message)
        lastError = message
        changed()
    }

    /// Starts a hardware PTT gesture synchronously, then performs control I/O in order.
    /// This prevents a release/chord event from racing ahead of local hold state.
    public func beginPushToTalkFromHardwareEvent() throws {
        guard activeMode == .ptt, let authority else { throw VoiceFailure.wrongMode }
        guard mediaConnectionState == .connected else { throw VoiceFailure.notReady }
        guard !pttHeld, !pttFinishing else { throw VoiceFailure.pttNotReady }
        commandSequence += 1
        let sequence = commandSequence
        transport.setPlaybackEnabled(false)
        pttCaptureAcknowledged = false
        pttHeld = true
        changed()
        let predecessor = hardwareControlTask
        hardwareControlTask = Task { [weak self] in
            await predecessor?.value
            guard let self, self.authority?.generation == authority.generation else { return }
            do {
                try await transport.sendPushToTalk(
                    generation: authority.generation,
                    held: true,
                    cancel: false,
                    commandSequence: sequence
                )
                guard self.authority?.generation == authority.generation,
                      commandSequence == sequence, pttHeld,
                      case .active = phase else { return }
                pttCaptureAcknowledged = true
                applyMicrophonePolicy()
                changed()
            } catch {
                guard self.authority?.generation == authority.generation else { return }
                enterUncertain("Push-to-talk start outcome is uncertain. End the conversation before trying again.")
            }
        }
    }

    /// Ends a hardware PTT gesture synchronously, then performs control I/O in order.
    public func endPushToTalkFromHardwareEvent(cancel: Bool) throws {
        guard case .active = phase, activeMode == .ptt, let authority else { throw VoiceFailure.wrongMode }
        guard pttHeld else { return }
        transport.setMicrophoneEnabled(false)
        pttCaptureAcknowledged = false
        pttHeld = false
        pttFinishing = true
        commandSequence += 1
        let sequence = commandSequence
        // The physical hold is over and input is already disabled. Do not drop a
        // short response while waiting for the release HTTP acknowledgement.
        transport.setPlaybackEnabled(true)
        changed()
        let predecessor = hardwareControlTask
        hardwareControlTask = Task { [weak self] in
            await predecessor?.value
            guard let self, self.authority?.generation == authority.generation else { return }
            do {
                try await transport.sendPushToTalk(
                    generation: authority.generation,
                    held: false,
                    cancel: cancel,
                    commandSequence: sequence
                )
                guard self.authority?.generation == authority.generation, commandSequence == sequence,
                      case .active = phase else { return }
                transport.setPlaybackEnabled(true)
            } catch {
                guard self.authority?.generation == authority.generation else { return }
                enterUncertain("Push-to-talk release outcome is uncertain. End the conversation before trying again.")
            }
        }
    }

    /// The local track stays disabled until the gateway acknowledges held=true.
    public func beginPushToTalk() async throws {
        guard activeMode == .ptt, let authority else { throw VoiceFailure.wrongMode }
        guard mediaConnectionState == .connected else { throw VoiceFailure.notReady }
        guard !pttHeld, !pttFinishing else { throw VoiceFailure.pttNotReady }
        commandSequence += 1
        let sequence = commandSequence
        transport.setPlaybackEnabled(false)
        pttCaptureAcknowledged = false
        pttHeld = true
        changed()
        do {
            try await transport.sendPushToTalk(generation: authority.generation, held: true, cancel: false, commandSequence: sequence)
            guard self.authority?.generation == authority.generation,
                  commandSequence == sequence, pttHeld else { return }
            pttCaptureAcknowledged = true
            applyMicrophonePolicy()
            changed()
        } catch {
            enterUncertain("Push-to-talk start outcome is uncertain. End the conversation before trying again.")
            throw error
        }
    }

    /// The local track closes synchronously before the release request starts.
    public func endPushToTalk(cancel: Bool = false) async throws {
        guard case .active = phase, activeMode == .ptt, let authority else { throw VoiceFailure.wrongMode }
        guard pttHeld else { return }
        transport.setMicrophoneEnabled(false)
        pttCaptureAcknowledged = false
        pttHeld = false
        pttFinishing = true
        commandSequence += 1
        let sequence = commandSequence
        transport.setPlaybackEnabled(true)
        changed()
        do {
            try await transport.sendPushToTalk(generation: authority.generation, held: false, cancel: cancel, commandSequence: sequence)
            guard self.authority?.generation == authority.generation, commandSequence == sequence else { return }
            transport.setPlaybackEnabled(true)
        } catch {
            enterUncertain("Push-to-talk release outcome is uncertain. End the conversation before trying again.")
            throw error
        }
    }

    public func setUserMuted(_ muted: Bool) throws {
        guard authority != nil, case .active = phase else { throw VoiceFailure.notReady }
        userMuted = muted
        applyMicrophonePolicy()
        changed()
    }

    public func setContinuousMicrophoneMuted(_ muted: Bool) throws {
        guard activeMode == .continuous else { throw VoiceFailure.wrongMode }
        try setUserMuted(muted)
    }

    private func applyMicrophonePolicy() {
        let modeAllowsCapture = activeMode == .continuous ||
            (activeMode == .ptt && pttHeld && pttCaptureAcknowledged)
        let active: Bool
        if case .active = phase { active = authority != nil }
        else { active = false }
        transport.setMicrophoneEnabled(
            active && mediaConnectionState == .connected && !userMuted && modeAllowsCapture
        )
    }

    public func stop() async {
        if startInFlight || hasUnknownStartAllocation {
            interruptPendingStart()
            return
        }
        operationNonce += 1
        let nonce = operationNonce
        let current = authority
        if let current {
            lastEndGeneration = current.generation
            lastEndConfirmed = false
        }
        phase = .stopping
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia() // End releases hardware before awaiting server finalization.
        clearCaptions()
        pttCaptureAcknowledged = false
        pttHeld = false
        changed()
        if let current {
            do {
                try await transport.close(generation: current.generation)
                guard operationNonce == nonce else { return }
                lastEndConfirmed = true
                lastError = nil
            } catch {
                guard operationNonce == nonce else { return }
                if authority == nil, lastEndConfirmed, lastEndGeneration == current.generation {
                    return // An exact provider-closed event won the race with the failed HTTP response.
                }
                retainAuthorityAfterUnconfirmedEnd(error.localizedDescription)
                return
            }
        }
        guard operationNonce == nonce else { return }
        if current != nil { releaseAfterConfirmedProviderClosure() }
        else { localTeardown(nextPhase: connectionOrigin == nil ? .disconnected : .ready) }
        changed()
    }

    private func retainAuthorityAfterUnconfirmedEnd(_ message: String) {
        guard let authority, let connectionOrigin,
              let exactOrigin = try? GatewayConfiguration(baseURL: connectionOrigin).origin,
              let epoch = closureRecoveryFence.begin(origin: exactOrigin, generation: authority.generation) else {
            enterUncertain("\(message) Exact closure-recovery scope is unavailable; authority remains retained.")
            return
        }
        lastEndGeneration = authority.generation
        lastEndConfirmed = false
        closureRecoveryEpoch = epoch
        closureRecoveryMayResumeReady = true
        peerGraceTask?.cancel()
        peerGraceTask = nil
        peerRecoveryPolicy.invalidate()
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia()
        mediaConnectionState = .unknown
        pttCaptureAcknowledged = false
        pttHeld = false
        pttFinishing = true
        clearCaptions()
        phase = .uncertain(message)
        lastError = message
        changed()
    }

    /// Losing foreground focus only cancels an in-progress app-local PTT hold.
    /// An explicitly started continuous conversation is independent of window focus.
    public func suspendForFocusLoss() async {
        guard activeMode == .ptt else { return }
        if pttHeld { try? endPushToTalkFromHardwareEvent(cancel: true) }
        else { transport.setMicrophoneEnabled(false) }
    }

    public func retainAuthorityAfterConnectionLoss(_ message: String) {
        if let epoch = closureRecoveryEpoch, hasProviderClosureRecoveryScope(epoch: epoch) {
            closureRecoveryMayResumeReady = false
            transport.setMicrophoneEnabled(false)
            transport.setPlaybackEnabled(false)
            transport.teardownMedia()
            transport.disconnectEvents()
            agents = []
            rosterConnected = false
            rosterRevision += 1
            selected = nil
            mediaConnectionState = .unknown
            clearCaptions()
            changed()
            return
        }
        guard let authority, let connectionOrigin,
              let exactOrigin = try? GatewayConfiguration(baseURL: connectionOrigin).origin,
              let epoch = closureRecoveryFence.begin(origin: exactOrigin, generation: authority.generation) else {
            enterUncertain("\(message) Exact closure-recovery scope is unavailable; authority remains retained.")
            return
        }
        operationNonce += 1
        lastEndGeneration = authority.generation
        lastEndConfirmed = false
        closureRecoveryEpoch = epoch
        closureRecoveryMayResumeReady = false
        peerGraceTask?.cancel()
        peerGraceTask = nil
        peerRecoveryPolicy.invalidate()
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia()
        transport.disconnectEvents()
        agents = []
        rosterConnected = false
        rosterRevision += 1
        selected = nil
        mediaConnectionState = .unknown
        pttCaptureAcknowledged = false
        pttHeld = false
        pttFinishing = true
        clearCaptions()
        phase = .uncertain(message)
        lastError = message
        changed()
    }

    public func abandonLocally() {
        if startInFlight {
            interruptPendingStart()
            return
        }
        if authority != nil || hasUnknownStartAllocation {
            retainAuthorityAfterConnectionLoss("Connection was lost. Provider closure remains unconfirmed.")
            return
        }
        operationNonce += 1
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia()
        transport.disconnectEvents()
        authority = nil
        connectionOrigin = nil
        closureRecoveryFence.clear()
        closureRecoveryEpoch = nil
        agents = []
        rosterConnected = false
        rosterRevision += 1
        selected = nil
        phase = .disconnected
        changed()
    }

    public func disconnect() async {
        if startInFlight || hasUnknownStartAllocation {
            interruptPendingStart()
            return
        }
        operationNonce += 1
        await stop()
        guard authority == nil else { return }
        transport.disconnectEvents()
        connectionOrigin = nil
        agents = []
        rosterConnected = false
        rosterRevision += 1
        selected = nil
        phase = .disconnected
        changed()
    }

    private func finishConnection(origin: URL, nonce: Int) async throws {
        guard operationNonce == nonce else {
            transport.disconnectEvents()
            throw CancellationError()
        }
        // Observe before opening the socket so an immediate close cannot leave a stale
        // buffered session-ended event to tear down a later explicit reconnect.
        observeEvents()
        try await transport.connectEvents(origin: origin)
        guard operationNonce == nonce else {
            transport.disconnectEvents()
            throw CancellationError()
        }
        connectionOrigin = origin
        explicitReconnectRequired = false
        lastError = nil
        phase = .ready
        changed()
    }

    private func observeEvents() {
        // The transport owns one long-lived AsyncStream. Keep its single consumer
        // across explicit reconnects; cancelling that iterator can terminate the
        // stream and lose the fresh roster after a successful renewal.
        guard eventTask == nil else { return }
        let stream = transport.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.accept(event)
            }
        }
    }

    private func accept(_ event: VoiceGatewayEvent) {
        switch event {
        case let .roster(connected, incoming):
            rosterRevision += 1
            rosterConnected = connected
            agents = connected ? incoming : []
            if let selected {
                self.selected = agents.first(where: { Self.sameEndpoint($0, selected) })
            }
            if let pinned = activeTarget {
                if let refreshed = agents.first(where: { Self.sameEndpoint($0, pinned) }) {
                    activeTarget = refreshed
                } else if hasUnknownStartAllocation {
                    retainUnknownStartAllocation("Roster authority was lost after a startup request with unknown allocation outcome.")
                    return
                } else {
                    transport.setMicrophoneEnabled(false)
                    transport.setPlaybackEnabled(false)
                    pttCaptureAcknowledged = false
                    pttHeld = false
                    phase = .stopping
                    Task { await stop() }
                }
            }
        case let .voiceState(generation, state, reason):
            guard authority?.generation == generation else { return }
            if state == "closed" {
                lastEndGeneration = generation
                lastEndConfirmed = reason == "provider_closed"
                if lastEndConfirmed {
                    lastError = nil
                    releaseAfterConfirmedProviderClosure()
                } else {
                    enterUncertain("Provider closure is unconfirmed (\(reason ?? "unknown terminal state")). End retries this exact session.")
                }
            }
        case let .pttReady(generation):
            guard authority?.generation == generation else { return }
            pttFinishing = false
        case let .caption(generation, speaker, delta, rawGroupID):
            guard authority?.generation == generation, case .active = phase,
                  mediaConnectionState == .connected else { return }
            let groupID = rawGroupID.flatMap {
                !$0.isEmpty && $0.utf8.count <= 512 ? $0 : nil
            }
            if speaker == "user" {
                captionThreadStore.accept(
                    generation: generation,
                    speaker: .user,
                    delta: delta,
                    groupID: groupID
                )
            } else if speaker == "assistant" {
                captionThreadStore.accept(
                    generation: generation,
                    speaker: .agent,
                    delta: delta,
                    groupID: groupID
                )
            }
        case let .captionStable(generation, speaker, groupID):
            guard authority?.generation == generation, case .active = phase,
                  mediaConnectionState == .connected else { return }
            if speaker == "user" {
                captionThreadStore.markStable(generation: generation, speaker: .user, groupID: groupID)
            } else if speaker == "assistant" {
                captionThreadStore.markStable(generation: generation, speaker: .agent, groupID: groupID)
            }
        case .utterance:
            // Forced liaison captions come only from display-only caption events.
            // Utterance/task-routing events never create a second presentation path.
            break
        case let .playbackActivity(generation, active):
            guard authority?.generation == generation, case .active = phase,
                  mediaConnectionState == .connected else { return }
            playbackActivityCurrent = active
        case let .peerConnectionState(peerAuthority, state):
            acceptPeerConnectionState(state, authority: peerAuthority)
        case let .error(generation, code, message):
            guard generation == nil || authority?.generation == generation else { return }
            lastError = "\(code): \(message)"
        case let .deviceRevoked(credentialCleared):
            rosterConnected = false
            agents = []
            selected = nil
            let message = credentialCleared
                ? "This Mac's device authorization was revoked and its saved credential was deleted. Provider closure remains unconfirmed."
                : "This Mac's device authorization was revoked. Keychain deletion failed and provider closure remains unconfirmed."
            if authority != nil { retainAuthorityAfterConnectionLoss(message) }
            else if startInFlight { interruptPendingStart(); lastError = message }
            else if hasUnknownStartAllocation { retainUnknownStartAllocation(message) }
            else { abandonLocally(); clearConversationState(); lastError = message }
        case let .sessionEnded(message):
            explicitReconnectRequired = true
            rosterConnected = false
            agents = []
            selected = nil
            if authority != nil {
                retainAuthorityAfterConnectionLoss("\(message) Provider closure remains unconfirmed.")
            } else if startInFlight {
                interruptPendingStart()
                lastError = message
            } else if hasUnknownStartAllocation {
                retainUnknownStartAllocation("\(message) Startup allocation and provider closure remain unconfirmed.")
            } else {
                abandonLocally()
                clearConversationState()
                lastError = message
            }
        }
        changed()
    }

    private func acceptPeerConnectionState(_ state: PeerConnectionState, authority peerAuthority: PeerConnectionAuthority) {
        guard let authority, authority.peerAuthority == peerAuthority, case .active = phase else { return }
        let mediaBeforeDisconnect: PeerMediaBeforeDisconnect
        if mediaConnectionState != .connected { mediaBeforeDisconnect = .gated }
        else if activeMode == .continuous { mediaBeforeDisconnect = .continuous }
        else if pttHeld { mediaBeforeDisconnect = .pttHeld }
        else { mediaBeforeDisconnect = .pttIdle }
        let action = peerRecoveryPolicy.observe(
            state,
            authority: peerAuthority,
            nowMilliseconds: monotonicMilliseconds(),
            mediaBeforeDisconnect: mediaBeforeDisconnect
        )
        applyPeerRecoveryAction(action, authority: authority)
    }

    private func applyPeerRecoveryAction(_ action: PeerConnectionRecoveryAction, authority: SessionAuthority) {
        switch action {
        case .none:
            return
        case let .gateMediaAndArmGrace(sequence, deadline):
            peerMediaGateRevision += 1
            transport.setMicrophoneEnabled(false)
            transport.setPlaybackEnabled(false)
            playbackActivityCurrent = false
            mediaConnectionState = .reconnecting
            peerGraceTask?.cancel()
            let delay = max(0, deadline - monotonicMilliseconds())
            peerGraceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self,
                      self.authority == authority, case .active = self.phase else { return }
                let expired = self.peerRecoveryPolicy.graceExpired(
                    authority: authority.peerAuthority,
                    graceSequence: sequence,
                    nowMilliseconds: self.monotonicMilliseconds()
                )
                self.applyPeerRecoveryAction(expired, authority: authority)
            }
            changed()
        case .restoreContinuousSameSession:
            peerGraceTask?.cancel(); peerGraceTask = nil
            mediaConnectionState = .connected
            applyMicrophonePolicy()
            transport.setPlaybackEnabled(true)
            changed()
        case .restorePTTIdleSameSession:
            peerGraceTask?.cancel(); peerGraceTask = nil
            mediaConnectionState = .connected
            transport.setMicrophoneEnabled(false)
            transport.setPlaybackEnabled(true)
            changed()
        case let .cancelPTTHoldBeforePlayback(generation):
            peerGraceTask?.cancel(); peerGraceTask = nil
            guard authority.generation == generation else { return }
            transport.setMicrophoneEnabled(false)
            transport.setPlaybackEnabled(false)
            pttCaptureAcknowledged = false
            pttHeld = false
            pttFinishing = true
            commandSequence += 1
            let sequence = commandSequence
            let expectedMediaGateRevision = peerMediaGateRevision
            changed()
            Task { [weak self] in
                guard let self, self.authority == authority, case .active = self.phase,
                      self.peerMediaGateRevision == expectedMediaGateRevision else { return }
                do {
                    try await self.transport.sendPushToTalk(
                        generation: generation,
                        held: false,
                        cancel: true,
                        commandSequence: sequence
                    )
                    guard self.authority == authority, self.commandSequence == sequence,
                          self.peerMediaGateRevision == expectedMediaGateRevision,
                          case .active = self.phase else { return }
                    self.mediaConnectionState = .connected
                    self.transport.setMicrophoneEnabled(false)
                    self.transport.setPlaybackEnabled(true)
                    self.changed()
                } catch {
                    guard self.authority == authority,
                          self.peerMediaGateRevision == expectedMediaGateRevision else { return }
                    self.enterUncertain("PTT recovery cancellation is unconfirmed. Provider closure remains unconfirmed.")
                }
            }
        case .recoveredButRemainGated:
            enterUncertain("Audio recovered after a superseded media operation. Provider state remains unconfirmed; End retries this exact session.")
        case let .retainUnknown(generation):
            guard generation == nil || generation == authority.generation else { return }
            enterUncertain("Audio connection was lost. Provider closure remains unconfirmed; End retries this exact session.")
        }
    }

    private func announceGreetingReadinessIfAllowed() {
        guard !greetingReadinessSent, case .active = phase, let authority,
              !pttHeld, !pttFinishing else { return }
        let expectedNonce = operationNonce
        // Consume once-per-Start authority before awaiting. Unknown POST outcomes
        // and later peer recovery must never repeat the greeting signal.
        greetingReadinessSent = true
        Task { [weak self] in
            guard let self, self.operationNonce == expectedNonce,
                  self.authority?.generation == authority.generation,
                  case .active = self.phase else { return }
            try? await self.transport.announceMediaReady(generation: authority.generation)
        }
    }

    private func enterUncertain(_ message: String) {
        peerMediaGateRevision += 1
        peerGraceTask?.cancel()
        peerGraceTask = nil
        peerRecoveryPolicy.invalidate()
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia()
        mediaConnectionState = .unknown
        pttCaptureAcknowledged = false
        pttHeld = false
        pttFinishing = true
        clearCaptions()
        phase = .uncertain(message)
        lastError = message
        changed()
    }

    private func releaseAfterConfirmedProviderClosure() {
        let mayResumeReady = connectionOrigin != nil && rosterConnected && !explicitReconnectRequired &&
            (closureRecoveryEpoch == nil || closureRecoveryMayResumeReady)
        if !mayResumeReady { connectionOrigin = nil }
        localTeardown(nextPhase: mayResumeReady ? .ready : .disconnected)
    }

    private func clearConversationState() {
        peerMediaGateRevision += 1
        hasUnknownStartAllocation = false
        activeTarget = nil
        activeMode = nil
        userMuted = false
        mediaConnectionState = .unknown
        peerGraceTask?.cancel()
        peerGraceTask = nil
        peerRecoveryPolicy.invalidate()
        pttCaptureAcknowledged = false
        pttHeld = false
        pttFinishing = false
        commandSequence = 0
        hardwareControlTask = nil
        greetingReadinessSent = false
        closureRecoveryFence.clear()
        closureRecoveryEpoch = nil
        closureRecoveryMayResumeReady = false
        clearCaptions()
    }

    private func clearCaptions() {
        captionThreadStore.clear()
        playbackActivityCurrent = false
    }

    private func localTeardown(nextPhase: CallPhase) {
        transport.setMicrophoneEnabled(false)
        transport.setPlaybackEnabled(false)
        transport.teardownMedia()
        authority = nil
        clearConversationState()
        phase = nextPhase
    }

    private func changed() { didChange?() }

    private static func sameEndpoint(_ lhs: AgentTarget, _ rhs: AgentTarget) -> Bool {
        lhs.id == rhs.id && lhs.endpointEpoch == rhs.endpointEpoch
    }

    private static func allowed(_ origin: URL) -> Bool {
        guard origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/" else { return false }
        if origin.scheme == "https" { return true }
        return origin.scheme == "http" && (origin.host == "localhost" || origin.host == "127.0.0.1")
    }
}
