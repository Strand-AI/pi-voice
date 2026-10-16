import AVFoundation
@preconcurrency import Foundation
import PiVoiceCore
@preconcurrency import WebRTC

@MainActor
final class GatewayVoiceTransport: NSObject, VoiceTransport {
    var audioRouteDidChange: (() -> Void)?
    var mediaLevelsDidChange: ((VoiceMediaLevelSample) -> Void)?
    let events: AsyncStream<GatewayEvent>
    private let eventContinuation: AsyncStream<GatewayEvent>.Continuation

    private var session: URLSession
    private let authenticator: GatewayDeviceAuthenticator
    private let closureReceiptAuthenticator: GatewayDeviceAuthenticator
    private var origin: URL?
    private var socket: URLSessionWebSocketTask?
    private var socketTask: Task<Void, Never>?
    private var mediaLevelTask: Task<Void, Never>?
    private var mediaObservationEnabled = true
    private var mediaGateRevision: UInt64 = 0
    private var remoteSourceActivity = VoiceRemoteSourceActivityTracker()
    private var peer: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var remoteAudioTracks: [RTCAudioTrack] = []
    private var dataChannel: RTCDataChannel?
    private var factory: RTCPeerConnectionFactory?
    private var playbackEnabled = false
    private var mediaRevision = 0
    private var connectionRevision = 0
    private var voiceConnectionFence = VoiceConnectionFence()
    private var peerStartupReadiness = PeerStartupReadiness()
    private var currentPeerAuthority: PeerConnectionAuthority?
    private var currentPeerState: PeerConnectionState = .connecting
    private var audioNotificationTokens: [NSObjectProtocol] = []
    private var mediaStarting = false
    private var mediaGeneration: String?
    private var speakerphonePreferred = true

    init(credentialStore: DurableDeviceCredentialStore = KeychainDeviceCredentialStore()) {
        let pair = AsyncStream<GatewayEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = pair.stream
        eventContinuation = pair.continuation
        authenticator = GatewayDeviceAuthenticator(credentialStore: credentialStore)
        closureReceiptAuthenticator = GatewayDeviceAuthenticator(credentialStore: credentialStore)
        session = GatewayDeviceAuthenticator.makeEphemeralSession()
        super.init()
        Self.configureWebRTCAudio(preferSpeaker: true)
        RTCInitializeSSL()
        observeAudioSession()
    }

    isolated deinit {
        for token in audioNotificationTokens { NotificationCenter.default.removeObserver(token) }
        RTCCleanupSSL()
    }

    func authenticate(origin: URL, pairingToken: String?, deviceName: String) async throws {
        connectionRevision &+= 1
        let revision = connectionRevision
        closeEventSocket()
        session.invalidateAndCancel()
        session = GatewayDeviceAuthenticator.makeEphemeralSession()
        self.origin = nil
        let authenticated = try await authenticator.authenticate(origin: origin, pairingToken: pairingToken, deviceName: deviceName)
        guard connectionRevision == revision else {
            authenticated.session.invalidateAndCancel()
            throw CancellationError()
        }
        session.invalidateAndCancel()
        self.origin = authenticated.origin
        session = authenticated.session
    }

    func hasStoredCredential(origin: URL) throws -> Bool {
        try authenticator.hasCredential(origin: origin)
    }

    func forgetDevice(origin: URL) throws {
        connectionRevision &+= 1
        closeEventSocket()
        session.invalidateAndCancel()
        session = GatewayDeviceAuthenticator.makeEphemeralSession()
        self.origin = nil
        try authenticator.forgetCredential(origin: origin)
    }

    func connectEvents(origin: URL) async throws {
        let canonical = try CanonicalGatewayOrigin(origin)
        guard self.origin == canonical.url else { throw VoiceError.invalidOrigin }
        connectionRevision &+= 1
        let revision = connectionRevision
        closeEventSocket()
        guard var components = URLComponents(url: canonical.url, resolvingAgainstBaseURL: false) else { throw VoiceError.invalidOrigin }
        components.scheme = "wss"
        components.path = "/ws"
        guard let url = components.url else { throw VoiceError.invalidOrigin }
        var request = URLRequest(url: url)
        request.setValue(canonical.value, forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
        let socketRevision = voiceConnectionFence.beginSocket()
        socket = task
        task.resume()
        socketTask = Task { [weak self] in
            await self?.receiveEvents(task, origin: canonical.url, revision: revision, socketRevision: socketRevision)
        }
        do {
            try await waitForVoiceConnection(task: task, connectionRevision: revision, socketRevision: socketRevision)
        } catch {
            if socket === task { clearInMemoryAuthentication() }
            throw error
        }
    }

    func disconnectEvents() {
        connectionRevision &+= 1
        authenticator.cancelPendingAuthentication()
        closeEventSocket()
    }

    func providerClosureReceipt(origin: URL, generation: String) async throws -> ProviderClosureReceiptResult {
        let canonical = try CanonicalGatewayOrigin(origin)
        guard generation.count == 22, generation.utf8.allSatisfy({
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
        }) else { throw TransportError.invalidResponse }
        let credentialSnapshot = try closureReceiptAuthenticator.durableCredentialSnapshot(origin: canonical.url)
        let authenticated = try await closureReceiptAuthenticator.authenticate(origin: canonical.url, pairingToken: nil, deviceName: "Pi Voice iPhone")
        defer { authenticated.session.invalidateAndCancel() }
        guard let url = URL(string: "/api/live/closure-receipt", relativeTo: authenticated.origin)?.absoluteURL else { throw TransportError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(canonical.value, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["generation": generation])
        let (data, response) = try await authenticated.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.absoluteString == url.absoluteString else { throw TransportError.invalidResponse }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode == 404 { return .unconfirmed }
        if http.statusCode == 401 {
            let code = body["error"] as? String
            let authenticationError: DeviceAuthenticationError
            switch code {
            case "revoked_device": authenticationError = .deviceRevoked
            case "expired_device": authenticationError = .deviceExpired
            case "invalid_device": authenticationError = .deviceInvalid
            default: throw TransportError.invalidResponse
            }
            closureReceiptAuthenticator.eraseCredentialIfUnchanged(credentialSnapshot)
            throw authenticationError
        }
        guard http.statusCode == 200,
              let closed = body["closed"] as? Int,
              let providerClosed = body["providerClosed"] as? Int,
              (closed == 0 || closed == 1), (providerClosed == 0 || providerClosed == 1), providerClosed <= closed else { throw TransportError.invalidResponse }
        return closed == 1 && providerClosed == 1 ? .providerClosed : .unconfirmed
    }

    private func closeEventSocket() {
        voiceConnectionFence.invalidate()
        socketTask?.cancel()
        socketTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func clearInMemoryAuthentication() {
        connectionRevision &+= 1
        closeEventSocket()
        session.invalidateAndCancel()
        session = GatewayDeviceAuthenticator.makeEphemeralSession()
        origin = nil
    }

    func start(target: AgentEndpoint, mode: VoiceMode, voice: VoiceName, routing: ConversationRouting) async throws -> SessionAuthority {
        guard peer == nil else { throw VoiceError.callAlreadyActive }
        mediaRevision += 1
        let revision = mediaRevision
        peerStartupReadiness.begin(revision)
        let socketRevision = voiceConnectionFence.revision
        guard let connectionID = voiceConnectionFence.connectionID(for: socketRevision) else {
            throw TransportError.voiceConnectionUnavailable
        }
        guard await microphonePermission() else { throw TransportError.microphoneDenied }
        guard mediaRevision == revision,
              voiceConnectionFence.connectionID(for: socketRevision) == connectionID else {
            throw CancellationError()
        }
        mediaStarting = true
        mediaGeneration = nil

        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        let factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
        self.factory = factory

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            teardownMedia()
            throw TransportError.peerCreationFailed
        }
        self.peer = peer
        let peerAuthority = PeerConnectionAuthority(revision: revision, peerIdentifier: UUID().uuidString)
        currentPeerAuthority = peerAuthority
        currentPeerState = Self.peerConnectionState(peer.iceConnectionState) ?? .connecting

        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: [
            "googEchoCancellation": "true",
            "googNoiseSuppression": "true",
            "googAutoGainControl": "true",
        ], optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "pivoice-microphone")
        track.isEnabled = false
        localAudioTrack = track
        _ = peer.add(track, streamIds: ["pivoice"])

        let channelConfiguration = RTCDataChannelConfiguration()
        dataChannel = peer.dataChannel(forLabel: "oai-events", configuration: channelConfiguration)
        dataChannel?.delegate = self

        var allocatedAuthority: SessionAuthority?
        var sessionRequestStarted = false
        do {
            let offer = try await createOffer(peer)
            try await setLocal(offer, peer: peer)
            try await waitForIceGathering(peer: peer, revision: revision)
            guard let gatheredSDP = peer.localDescription?.sdp else { throw TransportError.invalidResponse }
            let request = LiveSessionRequest(target: target, mode: mode, voice: voice, routing: routing)
            sessionRequestStarted = true
            let response = try await post(
                path: "/api/live/session",
                body: request.gatewayBody(sdp: gatheredSDP, connectionID: connectionID)
            )
            guard let generation = response["generation"] as? String,
                  generation.count == 22,
                  generation.utf8.allSatisfy({
                      ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                          ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
                  }) else {
                throw TransportError.invalidResponse
            }
            // Retain exact generation authority even if the rest of a malformed
            // success body cannot become a live session. These placeholder dates
            // are never presented as active; the coordinator immediately enters
            // retained Unknown and uses only the exact generation for closure.
            allocatedAuthority = SessionAuthority(
                generation: generation,
                idleDeadline: .distantPast,
                hardDeadline: .distantPast,
                peerAuthority: peerAuthority,
                initialPeerState: currentPeerState
            )
            guard let sdp = response["sdp"] as? String,
                  let idle = milliseconds(response["idleDeadline"]),
                  let hard = milliseconds(response["hardDeadline"]) else {
                throw TransportError.invalidResponse
            }
            allocatedAuthority = SessionAuthority(
                generation: generation,
                idleDeadline: idle,
                hardDeadline: hard,
                peerAuthority: peerAuthority,
                initialPeerState: currentPeerState
            )
            mediaStarting = false
            mediaGeneration = generation
            guard mediaRevision == revision, self.peer === peer,
                  voiceConnectionFence.connectionID(for: socketRevision) == connectionID else {
                peer.close()
                throw CancellationError()
            }
            try await setRemote(RTCSessionDescription(type: .answer, sdp: sdp), peer: peer)
            guard mediaRevision == revision, self.peer === peer,
                  voiceConnectionFence.connectionID(for: socketRevision) == connectionID else {
                peer.close()
                throw CancellationError()
            }
            remoteAudioTracks = peer.receivers.compactMap { $0.track as? RTCAudioTrack }
            remoteAudioTracks.forEach { $0.isEnabled = false }
            try await waitForPrimaryStartup(peer: peer, revision: revision)
            guard currentPeerAuthority == peerAuthority, self.peer === peer else { throw CancellationError() }
            beginMediaLevelPolling(peer: peer, authority: peerAuthority, generation: generation, localTrackID: track.trackId)
            guard let started = allocatedAuthority else { throw TransportError.invalidResponse }
            allocatedAuthority = nil
            return SessionAuthority(
                generation: started.generation,
                idleDeadline: started.idleDeadline,
                hardDeadline: started.hardDeadline,
                peerAuthority: started.peerAuthority,
                initialPeerState: currentPeerState
            )
        } catch {
            teardownMedia()
            if let allocatedAuthority {
                _ = try? await post(path: "/api/live/close", body: ["generation": allocatedAuthority.generation])
                throw RetainedVoiceStartAuthority(
                    authority: allocatedAuthority,
                    message: "Startup failed after provider allocation. Provider closure remains unconfirmed."
                )
            }
            if VoiceStartRequestOutcomePolicy.allocationIsUnknown(
                requestStarted: sessionRequestStarted,
                failure: Self.startFailureKind(error)
            ) {
                throw UnknownVoiceStartAllocation(
                    message: "Startup request outcome is unknown. New authorization and Start remain blocked."
                )
            }
            throw error
        }
    }

    func announceMediaReady(generation: String) async throws {
        guard mediaGeneration == generation,
              let authority = currentPeerAuthority,
              authority.revision == mediaRevision,
              peer != nil,
              (currentPeerState == .connected || currentPeerState == .completed),
              dataChannel?.readyState == .open,
              peerStartupReadiness.ready(mediaRevision),
              let connectionID = voiceConnectionFence.connectionID(for: voiceConnectionFence.revision) else {
            throw TransportError.voiceConnectionUnavailable
        }
        _ = try await post(
            path: "/api/live/media-ready",
            body: ["generation": generation, "connectionId": connectionID]
        )
    }

    func sendPushToTalk(generation: String, held: Bool, cancel: Bool, commandSequence: Int) async throws {
        var body: [String: Any] = [
            "generation": generation,
            "held": held,
            "commandSequence": commandSequence,
        ]
        if cancel { body["cancel"] = true }
        _ = try await post(path: "/api/live/ptt", body: body)
    }

    func close(generation: String) async throws {
        _ = try await post(path: "/api/live/close", body: ["generation": generation])
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        if localAudioTrack?.isEnabled != enabled { mediaGateRevision &+= 1 }
        localAudioTrack?.isEnabled = enabled
    }

    func setPlaybackEnabled(_ enabled: Bool) {
        if playbackEnabled != enabled { mediaGateRevision &+= 1 }
        playbackEnabled = enabled
        if !enabled { remoteSourceActivity.reset() }
        remoteAudioTracks.forEach { $0.isEnabled = enabled }
    }

    func setMediaObservationEnabled(_ enabled: Bool) {
        guard mediaObservationEnabled != enabled else { return }
        mediaObservationEnabled = enabled
        mediaLevelTask?.cancel()
        mediaLevelTask = nil
        remoteSourceActivity.reset()
        guard enabled,
              let peer,
              let authority = currentPeerAuthority,
              let generation = mediaGeneration,
              let localTrackID = localAudioTrack?.trackId else { return }
        beginMediaLevelPolling(peer: peer, authority: authority, generation: generation, localTrackID: localTrackID)
    }

    var currentAudioRouteDescription: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return "No active output" }
        return outputs.map(\.portName).joined(separator: ", ")
    }

    func setSpeakerphoneEnabled(_ enabled: Bool) throws {
        speakerphonePreferred = enabled
        Self.configureWebRTCAudio(preferSpeaker: enabled)
        let rtcAudio = RTCAudioSession.sharedInstance()
        let privateOutputActive = rtcAudio.currentRoute.outputs.contains { Self.isPrivateOutput($0.portType.rawValue) }
        rtcAudio.lockForConfiguration()
        defer { rtcAudio.unlockForConfiguration() }
        let options: AVAudioSession.CategoryOptions = enabled
            ? [.allowBluetoothHFP, .defaultToSpeaker]
            : [.allowBluetoothHFP]
        try rtcAudio.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try rtcAudio.overrideOutputAudioPort(enabled && !privateOutputActive ? .speaker : .none)
        audioRouteDidChange?()
    }

    func teardownMedia() {
        mediaRevision += 1
        peerStartupReadiness.invalidate()
        mediaLevelTask?.cancel()
        mediaLevelTask = nil
        remoteSourceActivity.reset()
        // Invalidate callback identity before close emits intentional terminal callbacks.
        currentPeerAuthority = nil
        currentPeerState = .closed
        localAudioTrack?.isEnabled = false
        remoteAudioTracks.forEach { $0.isEnabled = false }
        dataChannel?.delegate = nil
        dataChannel?.close()
        peer?.close()
        dataChannel = nil
        peer = nil
        localAudioTrack = nil
        remoteAudioTracks = []
        factory = nil
        playbackEnabled = false
        mediaStarting = false
        mediaGeneration = nil
        speakerphonePreferred = true
        Self.configureWebRTCAudio(preferSpeaker: true)
    }

    private static func startFailureKind(_ error: Error) -> VoiceStartRequestFailureKind {
        if error is CancellationError { return .canceled }
        if error is URLError { return .transport }
        guard let failure = error as? TransportError else { return .invalidResponse }
        switch failure {
        case .gateway(let status, _): return .httpStatus(status)
        case .invalidResponse: return .invalidResponse
        case .notPaired, .microphoneDenied, .peerCreationFailed, .voiceConnectionUnavailable,
             .iceGatheringTimedOut, .primaryStartupTimedOut:
            return .localPreflight
        }
    }

    private func post(path: String, body: Any) async throws -> [String: Any] {
        guard let origin, let url = URL(string: path, relativeTo: origin)?.absoluteURL else { throw TransportError.notPaired }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.absoluteString == url.absoluteString else { throw TransportError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw TransportError.gateway(status: http.statusCode, code: object["error"] as? String ?? "request_failed")
        }
        return object
    }

    private func waitForVoiceConnection(
        task: URLSessionWebSocketTask,
        connectionRevision: Int,
        socketRevision: Int
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, socket === task, self.connectionRevision == connectionRevision,
                  voiceConnectionFence.revision == socketRevision else {
                throw CancellationError()
            }
            if voiceConnectionFence.connectionID(for: socketRevision) != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TransportError.voiceConnectionUnavailable
    }

    private func receiveEvents(
        _ task: URLSessionWebSocketTask,
        origin socketOrigin: URL,
        revision: Int,
        socketRevision: Int
    ) async {
        while !Task.isCancelled, socket === task, connectionRevision == revision,
              voiceConnectionFence.revision == socketRevision {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case let .data(value): data = value
                case let .string(value): data = Data(value.utf8)
                @unknown default: continue
                }
                guard GatewaySocketEventPolicy.mayAccept(
                    isCancelled: Task.isCancelled,
                    isCurrentTask: socket === task,
                    revisionMatches: connectionRevision == revision && voiceConnectionFence.revision == socketRevision
                ) else { return }
                let announcement = VoiceConnectionAnnouncement.decode(data)
                if voiceConnectionFence.connectionID(for: socketRevision) == nil {
                    guard voiceConnectionFence.acceptFirst(announcement, revision: socketRevision) else {
                        task.cancel(with: .policyViolation, reason: Data("missing_first_voice_connection".utf8))
                        clearInMemoryAuthentication()
                        eventContinuation.yield(.sessionEnded(code: "missing_voice_connection", message: "The gateway did not send exact voice authority first."))
                        return
                    }
                    continue
                }
                switch announcement {
                case .notAnnouncement:
                    if let event = Self.decodeEvent(data) { eventContinuation.yield(event) }
                case .valid, .invalid:
                    task.cancel(with: .policyViolation, reason: Data("duplicate_voice_connection".utf8))
                    clearInMemoryAuthentication()
                    eventContinuation.yield(.sessionEnded(code: "duplicate_voice_connection", message: "The gateway replaced exact voice authority unexpectedly."))
                    return
                }
            } catch {
                if GatewaySocketEventPolicy.mayAccept(isCancelled: Task.isCancelled, isCurrentTask: socket === task, revisionMatches: connectionRevision == revision) {
                    let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
                    if task.closeCode.rawValue == 4003 || reason == "device_revoked" {
                        authenticator.eraseRevokedCredential(origin: socketOrigin)
                        clearInMemoryAuthentication()
                        eventContinuation.yield(.deviceRevoked)
                    } else {
                        let code = reason ?? (task.closeCode.rawValue == 4001 ? "session_expired" : "websocket_closed")
                        clearInMemoryAuthentication()
                        eventContinuation.yield(.sessionEnded(code: code, message: reason ?? error.localizedDescription))
                    }
                }
                return
            }
        }
    }

    private static func decodeEvent(_ data: Data) -> GatewayEvent? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = value["type"] as? String else { return nil }
        let generation = value["generation"] as? String
        switch type {
        case "relay_snapshot":
            guard let snapshot = value["snapshot"] as? [String: Any] else { return nil }
            return .roster(connected: snapshot["connected"] as? Bool ?? false, agents: decodeAgents(snapshot["sessions"]))
        case "relay_roster": return .roster(connected: true, agents: decodeAgents(value["sessions"]))
        case "relay_connection":
            guard value["connected"] as? Bool != true else { return nil }
            return .roster(connected: false, agents: [])
        case "voice_state":
            guard let generation, let state = value["state"] as? String else { return nil }
            return .voiceState(generation: generation, state: state, reason: value["reason"] as? String)
        case "voice_ptt_ready":
            guard let generation else { return nil }; return .pttReady(generation: generation)
        case "voice_agent_reply_window":
            guard let generation, let duration = value["durationMs"] as? NSNumber else { return nil }
            return .replyWindow(generation: generation, durationMilliseconds: duration.intValue)
        case "voice_caption":
            guard let generation, let speaker = value["speaker"] as? String, let delta = value["delta"] as? String else { return nil }
            let groupID = (value["groupId"] as? String).flatMap { validCaptionGroupID($0) ? $0 : nil }
            return .caption(generation: generation, speaker: speaker, delta: delta, groupID: groupID)
        case "voice_caption_stable":
            guard let generation, let speaker = value["speaker"] as? String,
                  let groupID = value["groupId"] as? String, validCaptionGroupID(groupID) else { return nil }
            return .captionStable(generation: generation, speaker: speaker, groupID: groupID)
        case "voice_utterance":
            guard let generation, let text = value["text"] as? String else { return nil }
            return .utterance(generation: generation, text: text)
        case "voice_error", "relay_error":
            return .error(generation: generation, code: value["code"] as? String ?? type, message: value["message"] as? String ?? "Unknown error")
        default: return nil
        }
    }

    private static func validCaptionGroupID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
        }
    }

    private static func decodeAgents(_ value: Any?) -> [AgentEndpoint] {
        guard let records = value as? [[String: Any]] else { return [] }
        return records.compactMap { item in
            guard item["kind"] as? String == "agent", let id = item["id"] as? String, let epoch = item["endpointEpoch"] as? String else { return nil }
            return AgentEndpoint(id: id, endpointEpoch: epoch, name: item["name"] as? String, model: item["model"] as? String, status: item["status"] as? String)
        }
    }

    private func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1_000)
    }

    private func microphonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        audioNotificationTokens = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue
                MainActor.assumeIsolated { self?.acceptInterruption(type: type, options: options) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                let previousOutputs = (notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
                    .outputs.map { $0.portType.rawValue } ?? []
                MainActor.assumeIsolated { self?.acceptRouteChange(reason: reason, previousOutputs: previousOutputs) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.acceptMediaServicesReset() }
            },
        ]
    }

    private func acceptInterruption(type: UInt?, options: UInt?) {
        guard mediaStarting || mediaGeneration != nil, let type,
              let interruption = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch interruption {
        case .began:
            setMicrophoneEnabled(false)
            setPlaybackEnabled(false)
            eventContinuation.yield(.audioInterruptionBegan(generation: mediaGeneration))
        case .ended:
            guard let generation = mediaGeneration else { return }
            let shouldResume = options.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            eventContinuation.yield(.audioInterruptionEnded(generation: generation, shouldResume: shouldResume))
        @unknown default:
            if let generation = mediaGeneration {
                eventContinuation.yield(.audioInterruptionEnded(generation: generation, shouldResume: false))
            } else {
                setMicrophoneEnabled(false)
                setPlaybackEnabled(false)
                eventContinuation.yield(.audioInterruptionBegan(generation: nil))
            }
        }
    }

    private func acceptRouteChange(reason: UInt?, previousOutputs: [String]) {
        let currentOutputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }
        if currentOutputs.contains(where: Self.isPrivateOutput) {
            let rtcAudio = RTCAudioSession.sharedInstance()
            rtcAudio.lockForConfiguration()
            try? rtcAudio.overrideOutputAudioPort(.none)
            rtcAudio.unlockForConfiguration()
        }
        audioRouteDidChange?()
        guard mediaStarting || mediaGeneration != nil,
              reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
              previousOutputs.contains(where: Self.isPrivateOutput) else { return }
        guard !currentOutputs.contains(where: Self.isPrivateOutput) else { return }
        setMicrophoneEnabled(false)
        setPlaybackEnabled(false)
        eventContinuation.yield(.privateAudioRouteLost(generation: mediaGeneration))
    }

    private func acceptMediaServicesReset() {
        guard mediaStarting || mediaGeneration != nil else { return }
        setMicrophoneEnabled(false)
        setPlaybackEnabled(false)
        eventContinuation.yield(.audioMediaServicesReset(generation: mediaGeneration))
    }

    private static func configureWebRTCAudio(preferSpeaker: Bool) {
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        configuration.categoryOptions = preferSpeaker
            ? [.allowBluetoothHFP, .defaultToSpeaker]
            : [.allowBluetoothHFP]
        configuration.ioBufferDuration = 0.01
        RTCAudioSessionConfiguration.setWebRTC(configuration)
    }

    private static func isPrivateOutput(_ rawPortType: String) -> Bool {
        [
            AVAudioSession.Port.headphones.rawValue,
            AVAudioSession.Port.bluetoothA2DP.rawValue,
            AVAudioSession.Port.bluetoothHFP.rawValue,
            AVAudioSession.Port.bluetoothLE.rawValue,
        ].contains(rawPortType)
    }

    private func beginMediaLevelPolling(
        peer: RTCPeerConnection,
        authority: PeerConnectionAuthority,
        generation: String,
        localTrackID: String
    ) {
        guard mediaObservationEnabled else { return }
        mediaLevelTask?.cancel()
        remoteSourceActivity.reset()
        mediaLevelTask = Task { [weak self, weak peer] in
            while !Task.isCancelled {
                guard let polledPeer = peer, let capturedGateRevision = self?.mediaGateRevision else { return }
                let requestStarted = DispatchTime.now().uptimeNanoseconds
                let report = await Self.peerStatistics(polledPeer)
                let completed = DispatchTime.now().uptimeNanoseconds
                guard !Task.isCancelled else { return }
                if let owner = self {
                    guard owner.acceptMediaLevelReport(
                        report,
                        peer: polledPeer,
                        authority: authority,
                        generation: generation,
                        localTrackID: localTrackID,
                        requestStarted: requestStarted,
                        completed: completed,
                        capturedGateRevision: capturedGateRevision
                    ) else { return }
                } else { return }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func acceptMediaLevelReport(
        _ report: RTCStatisticsReport,
        peer polledPeer: RTCPeerConnection,
        authority: PeerConnectionAuthority,
        generation: String,
        localTrackID: String,
        requestStarted: UInt64,
        completed: UInt64,
        capturedGateRevision: UInt64
    ) -> Bool {
        guard mediaObservationEnabled,
              peer === polledPeer,
              currentPeerAuthority == authority,
              mediaGeneration == generation else { return false }
        let pollAccepted = VoiceMediaPollPolicy.accepts(
            requestStartedAtUptimeNanoseconds: requestStarted,
            completedAtUptimeNanoseconds: completed,
            capturedGateRevision: capturedGateRevision,
            currentGateRevision: mediaGateRevision
        )
        let outgoing = pollAccepted && localAudioTrack?.isEnabled == true
            ? Self.localAudioLevel(report: report, trackID: localTrackID)
            : 0
        let playback = pollAccepted && playbackEnabled
            ? remoteAudioLevel(peer: polledPeer, observedAtUptimeNanoseconds: completed)
            : 0
        if !pollAccepted { remoteSourceActivity.reset() }
        mediaLevelsDidChange?(VoiceMediaLevelSample(
            generation: generation,
            peerAuthority: authority,
            observedAtUptimeNanoseconds: pollAccepted ? requestStarted : completed,
            outgoingLevel: outgoing,
            playbackLevel: playback,
            speakerActive: playback > 0.01
        ))
        return true
    }

    private static func peerStatistics(_ peer: RTCPeerConnection) async -> RTCStatisticsReport {
        await withCheckedContinuation { continuation in
            peer.statistics { report in continuation.resume(returning: report) }
        }
    }

    private static func localAudioLevel(report: RTCStatisticsReport, trackID: String) -> Double {
        for statistic in report.statistics.values where statistic.type == "media-source" {
            guard statistic.values["kind"] as? String == "audio",
                  statistic.values["trackIdentifier"] as? String == trackID,
                  let level = statistic.values["audioLevel"] as? NSNumber else { continue }
            let value = level.doubleValue
            return value.isFinite ? min(max(value, 0), 1) : 0
        }
        return 0
    }

    private func remoteAudioLevel(peer: RTCPeerConnection, observedAtUptimeNanoseconds: UInt64) -> Double {
        let source = peer.receivers
            .filter { $0.track?.kind == "audio" }
            .flatMap(\.sources)
            .max { $0.timestampUs < $1.timestampUs }
        guard let source, let number = source.audioLevel else {
            remoteSourceActivity.reset()
            return 0
        }
        return remoteSourceActivity.observe(
            sourceID: source.sourceId,
            rtpTimestamp: source.rtpTimestamp,
            level: number.doubleValue,
            observedAtUptimeNanoseconds: observedAtUptimeNanoseconds
        )
    }

    private func waitForIceGathering(peer: RTCPeerConnection, revision: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, mediaRevision == revision, self.peer === peer else { throw CancellationError() }
            if peer.iceGatheringState == .complete {
                peerStartupReadiness.iceGathered(revision)
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TransportError.iceGatheringTimedOut
    }

    private func waitForPrimaryStartup(peer: RTCPeerConnection, revision: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, mediaRevision == revision, self.peer === peer else { throw CancellationError() }
            if peerStartupReadiness.ready(revision) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TransportError.primaryStartupTimedOut
    }

    private func acceptPeerConnectionState(_ state: RTCIceConnectionState, peer callbackPeer: RTCPeerConnection) {
        guard peer === callbackPeer, let authority = currentPeerAuthority,
              authority.revision == mediaRevision,
              let state = Self.peerConnectionState(state) else { return }
        currentPeerState = state
        eventContinuation.yield(.peerConnectionState(authority: authority, state: state))
    }

    private func acceptDataChannelState(_ channel: RTCDataChannel) {
        guard dataChannel === channel, let authority = currentPeerAuthority,
              authority.revision == mediaRevision else { return }
        if channel.readyState == .closed {
            currentPeerState = .failed
            eventContinuation.yield(.peerConnectionState(authority: authority, state: .failed))
        }
    }

    private static func peerConnectionState(_ state: RTCIceConnectionState) -> PeerConnectionState? {
        switch state {
        case .new, .checking: .connecting
        case .connected: .connected
        case .completed: .completed
        case .disconnected: .disconnected
        case .failed: .failed
        case .closed: .closed
        case .count: nil
        @unknown default: nil
        }
    }

    private func observePrimaryProviderEvent(_ data: Data, channel: RTCDataChannel) {
        guard dataChannel === channel,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = value["type"] as? String else { return }
        peerStartupReadiness.observe(type: type, revision: mediaRevision)
    }

    private func createOffer(_ peer: RTCPeerConnection) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"], optionalConstraints: nil)) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: error ?? TransportError.invalidResponse) }
            }
        }
    }

    private func setLocal(_ sdp: RTCSessionDescription, peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            }
        }
    }

    private func setRemote(_ sdp: RTCSessionDescription, peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            }
        }
    }
}

extension GatewayVoiceTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self, weak dataChannel] in
            guard let self, let dataChannel else { return }
            acceptDataChannelState(dataChannel)
        }
    }

    nonisolated func dataChannel(
        _ dataChannel: RTCDataChannel,
        didReceiveMessageWith buffer: RTCDataBuffer
    ) {
        let data = buffer.data
        Task { @MainActor [weak self, weak dataChannel] in
            guard let self, let dataChannel else { return }
            observePrimaryProviderEvent(data, channel: dataChannel)
        }
    }
}

extension GatewayVoiceTransport: RTCPeerConnectionDelegate {
    // Unified-plan receivers are collected immediately after applying the remote description.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self, weak peerConnection] in
            guard let self, let peerConnection else { return }
            acceptPeerConnectionState(newState, peer: peerConnection)
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

private enum TransportError: LocalizedError {
    case notPaired
    case microphoneDenied
    case peerCreationFailed
    case voiceConnectionUnavailable
    case iceGatheringTimedOut
    case primaryStartupTimedOut
    case invalidResponse
    case gateway(status: Int, code: String)

    var errorDescription: String? {
        switch self {
        case .notPaired: "Pair this phone before connecting."
        case .microphoneDenied: "Microphone permission is required only after Start."
        case .peerCreationFailed: "WebRTC peer creation failed."
        case .voiceConnectionUnavailable: "The gateway did not establish exact voice connection authority."
        case .iceGatheringTimedOut: "Audio connection setup timed out before a complete offer was available."
        case .primaryStartupTimedOut: "The provider audio channel did not become ready. No conversation was started."
        case .invalidResponse: "The gateway returned an invalid response."
        case let .gateway(status, code): "Gateway \(status): \(code)"
        }
    }
}
