import Foundation

public struct AgentEndpoint: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let endpointEpoch: String
    public let name: String?
    public let model: String?
    public let status: String?

    public init(id: String, endpointEpoch: String, name: String? = nil, model: String? = nil, status: String? = nil) {
        self.id = id
        self.endpointEpoch = endpointEpoch
        self.name = name
        self.model = model
        self.status = status
    }

    public var identityKey: String { "\(id)\u{0}\(endpointEpoch)" }
    public var displayName: String { name ?? id }
}

public enum VoiceMode: String, Codable, CaseIterable, Sendable {
    case continuous
    case ptt
}

public enum ConversationRouting: String, Codable, Sendable {
    case direct
    case liaison
}

public enum VoiceName: String, Codable, CaseIterable, Sendable {
    case marin, quartz, ripple, vesper, willow, stone, gleam, meridian, bossa, tempo, beacon, delta, cinder
}

public struct LiveSessionRequest: Equatable, Sendable {
    public let target: AgentEndpoint
    public let mode: VoiceMode
    public let voice: VoiceName
    public let routing: ConversationRouting

    public init(target: AgentEndpoint, mode: VoiceMode, voice: VoiceName, routing: ConversationRouting) {
        self.target = target
        self.mode = mode
        self.voice = voice
        self.routing = routing
    }

    public func gatewayBody(sdp: String, connectionID: String) -> [String: String] {
        [
            "sdp": sdp,
            "connectionId": connectionID,
            "targetId": target.id,
            "targetEpoch": target.endpointEpoch,
            "voice": voice.rawValue,
            "inputMode": mode.rawValue,
            "routingMode": routing.rawValue,
        ]
    }
}

public enum VoiceStartRequestFailureKind: Equatable, Sendable {
    case canceled
    case transport
    case invalidResponse
    case httpStatus(Int)
    case localPreflight
}

public enum VoiceStartRequestOutcomePolicy {
    /// Once the session POST may have reached the gateway, cancellation,
    /// transport failure, an unusable success body, 408, or 5xx cannot prove
    /// that no provider generation was allocated.
    public static func allocationIsUnknown(requestStarted: Bool, failure: VoiceStartRequestFailureKind) -> Bool {
        guard requestStarted else { return false }
        switch failure {
        case .canceled, .transport, .invalidResponse: return true
        case .httpStatus(let status): return status == 408 || status >= 500
        case .localPreflight: return false
        }
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

public struct SessionAuthority: Codable, Equatable, Sendable {
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
        initialPeerState: PeerConnectionState = .connected
    ) {
        self.generation = generation
        self.idleDeadline = idleDeadline
        self.hardDeadline = hardDeadline
        self.peerAuthority = peerAuthority
        self.initialPeerState = initialPeerState
    }
}

public enum MediaConnectionState: Equatable, Sendable {
    case connected
    case reconnecting
    case unknown
}

public enum GatewayEvent: Equatable, Sendable {
    case roster(connected: Bool, agents: [AgentEndpoint])
    case voiceState(generation: String, state: String, reason: String?)
    case pttReady(generation: String)
    case replyWindow(generation: String, durationMilliseconds: Int)
    case caption(generation: String, speaker: String, delta: String, groupID: String?)
    case captionStable(generation: String, speaker: String, groupID: String)
    case utterance(generation: String, text: String)
    case deviceRevoked
    case sessionEnded(code: String, message: String)
    case peerConnectionState(authority: PeerConnectionAuthority, state: PeerConnectionState)
    case audioInterruptionBegan(generation: String?)
    case audioInterruptionEnded(generation: String, shouldResume: Bool)
    case privateAudioRouteLost(generation: String?)
    case audioMediaServicesReset(generation: String?)
    case error(generation: String?, code: String, message: String)
}

public enum ProviderClosureReceiptResult: Equatable, Sendable {
    case providerClosed
    case unconfirmed
}

public enum CallPhase: Equatable, Sendable {
    case disconnected
    case ready
    case starting
    case active(SessionAuthority)
    case stopping
    case uncertain(String)
}

public enum VoiceError: Error, Equatable, LocalizedError {
    case invalidOrigin
    case notReady
    case targetUnavailable
    case staleTarget
    case callAlreadyActive
    case wrongMode
    case pttNotReady

    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: "Use the exact private HTTPS gateway origin."
        case .notReady: "The native relay is not ready."
        case .targetUnavailable: "Choose a currently available Pi agent."
        case .staleTarget: "The selected agent endpoint changed. Choose it again."
        case .callAlreadyActive: "A voice session is already active."
        case .wrongMode: "Push to talk is not the active mode."
        case .pttNotReady: "Wait for the current push-to-talk turn to finish."
        }
    }
}

public enum VoiceMediaPollPolicy {
    public static let maximumAgeNanoseconds: UInt64 = 500_000_000

    public static func accepts(
        requestStartedAtUptimeNanoseconds: UInt64,
        completedAtUptimeNanoseconds: UInt64,
        capturedGateRevision: UInt64,
        currentGateRevision: UInt64
    ) -> Bool {
        completedAtUptimeNanoseconds >= requestStartedAtUptimeNanoseconds
            && completedAtUptimeNanoseconds - requestStartedAtUptimeNanoseconds <= maximumAgeNanoseconds
            && capturedGateRevision == currentGateRevision
    }
}

public struct VoiceRemoteSourceActivityTracker: Equatable, Sendable {
    private var sourceID: UInt32?
    private var rtpTimestamp: UInt32?
    private var advancedAtUptimeNanoseconds: UInt64?

    public init() {}

    public mutating func observe(
        sourceID: UInt32,
        rtpTimestamp: UInt32,
        level: Double,
        observedAtUptimeNanoseconds: UInt64
    ) -> Double {
        guard level.isFinite else { reset(); return 0 }
        guard self.sourceID == sourceID else {
            self.sourceID = sourceID
            self.rtpTimestamp = rtpTimestamp
            advancedAtUptimeNanoseconds = nil
            return 0
        }
        guard self.rtpTimestamp == rtpTimestamp else {
            self.rtpTimestamp = rtpTimestamp
            advancedAtUptimeNanoseconds = observedAtUptimeNanoseconds
            return min(max(level, 0), 1)
        }
        guard let advancedAtUptimeNanoseconds,
              observedAtUptimeNanoseconds >= advancedAtUptimeNanoseconds,
              observedAtUptimeNanoseconds - advancedAtUptimeNanoseconds <= VoiceMediaPollPolicy.maximumAgeNanoseconds else {
            return 0
        }
        return min(max(level, 0), 1)
    }

    public mutating func reset() {
        sourceID = nil
        rtpTimestamp = nil
        advancedAtUptimeNanoseconds = nil
    }
}

public struct VoiceMediaLevelSample: Equatable, Sendable {
    public let generation: String
    public let peerAuthority: PeerConnectionAuthority
    public let observedAtUptimeNanoseconds: UInt64
    public let outgoingLevel: Double
    public let playbackLevel: Double
    public let speakerActive: Bool

    public init(
        generation: String,
        peerAuthority: PeerConnectionAuthority,
        observedAtUptimeNanoseconds: UInt64,
        outgoingLevel: Double,
        playbackLevel: Double,
        speakerActive: Bool
    ) {
        self.generation = generation
        self.peerAuthority = peerAuthority
        self.observedAtUptimeNanoseconds = observedAtUptimeNanoseconds
        self.outgoingLevel = Self.normalized(outgoingLevel)
        self.playbackLevel = Self.normalized(playbackLevel)
        self.speakerActive = speakerActive
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct VoiceVisualMediaState: Equatable, Sendable {
    public let generation: String
    public let outgoingLevel: Double
    public let playbackLevel: Double
    public let speakerActive: Bool

    public init(generation: String, outgoingLevel: Double, playbackLevel: Double, speakerActive: Bool) {
        self.generation = generation
        self.outgoingLevel = outgoingLevel
        self.playbackLevel = playbackLevel
        self.speakerActive = speakerActive
    }
}

public struct VoiceCaptionPresentation: Equatable, Sendable {
    public enum Speaker: Equatable, Sendable { case user, agent }
    public let generation: String
    public let speaker: Speaker
    public let text: String
    public let isCurrent: Bool

    public init(generation: String, speaker: Speaker, text: String, isCurrent: Bool) {
        self.generation = generation
        self.speaker = speaker
        self.text = text
        self.isCurrent = isCurrent
    }
}

@MainActor
public protocol VoiceTransport: AnyObject {
    var events: AsyncStream<GatewayEvent> { get }
    var mediaLevelsDidChange: ((VoiceMediaLevelSample) -> Void)? { get set }
    /// Pauses or resumes visual-only WebRTC level observation without changing media gates.
    func setMediaObservationEnabled(_ enabled: Bool)

    /// A non-empty one-use token performs the final pair. Nil renews the exact-origin
    /// durable device credential into a new memory-only short session.
    func authenticate(origin: URL, pairingToken: String?, deviceName: String) async throws
    func forgetDevice(origin: URL) throws
    func connectEvents(origin: URL) async throws
    func disconnectEvents()
    /// Renews this device's exact-origin authorization only to read one exact generation's
    /// bounded closure receipt. It must not mutate the active transport session or media.
    func providerClosureReceipt(origin: URL, generation: String) async throws -> ProviderClosureReceiptResult

    /// Creates the peer connection, requests the gateway Live session, and returns its exact generation.
    func start(target: AgentEndpoint, mode: VoiceMode, voice: VoiceName, routing: ConversationRouting) async throws -> SessionAuthority
    /// Announces that this exact generation's native primary channel and media peer
    /// are usable. This is one-shot application context, not proof of playback.
    func announceMediaReady(generation: String) async throws
    func sendPushToTalk(generation: String, held: Bool, cancel: Bool, commandSequence: Int) async throws
    func close(generation: String) async throws

    /// These gates must take effect locally and synchronously.
    func setMicrophoneEnabled(_ enabled: Bool)
    func setPlaybackEnabled(_ enabled: Bool)
    func teardownMedia()
}
