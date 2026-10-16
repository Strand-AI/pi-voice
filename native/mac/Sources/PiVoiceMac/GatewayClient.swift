import AVFoundation
import Combine
import Foundation
import PiVoiceMacCore
import PiVoiceMacSecurity
import PiVoiceMacAudioMeter
@preconcurrency import LiveKitWebRTC

@MainActor
final class GatewayVoiceTransport: NSObject, ObservableObject, VoiceTransport {
    let events: AsyncStream<VoiceGatewayEvent>
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var playbackLevel = 0.0
    @Published private(set) var microphoneMeterActive = false
    @Published private(set) var playbackMeterActive = false
    private let eventContinuation: AsyncStream<VoiceGatewayEvent>.Continuation

    private let credentialVault: DeviceCredentialVault
    private lazy var redirectDelegate = RejectingRedirectDelegate { [weak self] receipt in
        Task { @MainActor [weak self] in
            self?.acceptURLSessionTaskCompletion(receipt)
        }
    }
    private var session: URLSession?
    private var socketSession: URLSession?
    private var cookieStorage: HTTPCookieStorage?
    private var origin: URL?
    private var socket: URLSessionWebSocketTask?
    private var socketTask: Task<Void, Never>?
    private var connectionAuthority = AsyncOperationAuthority()
    private var voiceConnectionFence = VoiceConnectionFence()
    private var peer: LKRTCPeerConnection?
    private var localAudioTrack: LKRTCAudioTrack?
    private var remoteAudioTracks: [LKRTCAudioTrack] = []
    private var microphoneMeter: AudioLevelMeter?
    private var playbackMeter: AudioLevelMeter?
    private var dataChannel: LKRTCDataChannel?
    private var peerStartupReadiness = PeerStartupReadiness()
    private var currentPeerAuthority: PeerConnectionAuthority?
    private var currentPeerState: PeerConnectionState = .connecting
    private var mediaGeneration: String?
    private var providerEventDiagnostics: ProviderEventDiagnostics?
    private var providerDiagnosticsReportTask: Task<Void, Never>?
    private var factory: LKRTCPeerConnectionFactory?
    private var playbackEnabled = false
    private var playbackActivity = false
    private var playbackGain = 1.0
    private var mediaFence = MediaOwnershipFence()

    init(credentialStore: any DeviceCredentialStore = KeychainDeviceCredentialStore()) {
        self.credentialVault = DeviceCredentialVault(store: credentialStore)
        let pair = AsyncStream<VoiceGatewayEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = pair.stream
        eventContinuation = pair.continuation
        super.init()
        LKRTCInitializeSSL()
    }

    deinit { LKRTCCleanupSSL() }

    func pair(origin: URL, token: String, deviceName: String) async throws {
        let operation = connectionAuthority.begin()
        let gateway = try GatewayConfiguration(baseURL: origin)
        guard try !credentialVault.contains(origin: gateway.origin) else {
            throw TransportFailure.deviceAlreadySaved
        }
        let request = try BrowserPairingRequest(pairingToken: token, deviceName: deviceName)
        let pending = makeSession()
        do {
            let response: DeviceSessionResponse = try await post(
                path: "/api/browser-session/pair",
                body: request,
                origin: origin,
                session: pending.session
            )
            guard connectionAuthority.owns(operation) else { throw CancellationError() }
            guard response.authenticated else { throw TransportFailure.invalidResponse }
            let value = try Self.deviceCredential(in: pending.cookies, for: gateway)
            try credentialVault.persist(
                value: value,
                echoedOrigin: response.device.origin,
                expectedOrigin: gateway.origin
            )
            guard Self.retainOnlyShortSession(in: pending.cookies, for: gateway) else {
                throw TransportFailure.missingSessionCookie
            }
            activate(pending, origin: origin)
        } catch {
            Self.removeDeviceCookies(from: pending.cookies, for: gateway)
            pending.session.invalidateAndCancel()
            throw error
        }
    }

    func renew(origin: URL) async throws {
        let operation = connectionAuthority.begin()
        let gateway = try GatewayConfiguration(baseURL: origin)
        guard let credential = try credentialVault.load(origin: gateway.origin) else {
            throw TransportFailure.noSavedDevice
        }
        let pending = makeSession()
        guard let cookie = Self.makeDeviceCookie(credential, gateway: gateway) else {
            pending.session.invalidateAndCancel()
            throw TransportFailure.invalidResponse
        }
        pending.cookies.setCookie(cookie)
        defer { Self.removeDeviceCookies(from: pending.cookies, for: gateway) }
        do {
            let response: DeviceSessionResponse = try await post(
                path: "/api/browser-session/renew",
                body: EmptyRequest(),
                origin: origin,
                session: pending.session
            )
            guard connectionAuthority.owns(operation) else { throw CancellationError() }
            guard response.authenticated, response.device.origin == gateway.origin else {
                throw TransportFailure.deviceOriginMismatch
            }
            guard Self.retainOnlyShortSession(in: pending.cookies, for: gateway) else {
                throw TransportFailure.missingSessionCookie
            }
            activate(pending, origin: origin)
        } catch let error as TransportFailure {
            pending.session.invalidateAndCancel()
            guard connectionAuthority.owns(operation) else { throw CancellationError() }
            if error.definitivelyInvalidatesDevice {
                try credentialVault.delete(origin: gateway.origin)
            }
            throw error
        } catch {
            pending.session.invalidateAndCancel()
            throw error
        }
    }

    func mayRetryConnection(_ error: Error) -> Bool {
        if let failure = error as? TransportFailure {
            if case .gateway(let status, _) = failure { return status >= 500 && status <= 599 }
            return false
        }
        guard let failure = error as? URLError else { return false }
        return [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed].contains(failure.code)
    }

    func hasSavedDevice(origin: URL) throws -> Bool {
        let gateway = try GatewayConfiguration(baseURL: origin)
        return try credentialVault.contains(origin: gateway.origin)
    }

    func forgetSavedDevice(origin: URL) throws {
        let gateway = try GatewayConfiguration(baseURL: origin)
        try credentialVault.delete(origin: gateway.origin)
    }

    func providerClosureReceipt(
        origin: URL,
        generation: String,
        mayMutateCredential: @escaping @MainActor () -> Bool
    ) async throws -> ProviderClosureReceiptResult {
        let gateway = try GatewayConfiguration(baseURL: origin)
        guard isOpaqueVoiceConnectionID(generation),
              let credential = try credentialVault.load(origin: gateway.origin) else {
            throw TransportFailure.noSavedDevice
        }
        let pending = makeSession()
        defer { pending.session.invalidateAndCancel() }
        guard let cookie = Self.makeDeviceCookie(credential, gateway: gateway) else {
            throw TransportFailure.invalidResponse
        }
        pending.cookies.setCookie(cookie)
        defer { Self.removeDeviceCookies(from: pending.cookies, for: gateway) }
        do {
            let renewed: DeviceSessionResponse = try await post(
                path: "/api/browser-session/renew",
                body: EmptyRequest(),
                origin: origin,
                session: pending.session
            )
            guard renewed.authenticated, renewed.device.origin == gateway.origin,
                  Self.retainOnlyShortSession(in: pending.cookies, for: gateway) else {
                throw TransportFailure.invalidResponse
            }
            let receipt: ProviderClosureReceiptResponse = try await post(
                path: "/api/live/closure-receipt",
                body: ["generation": generation],
                origin: origin,
                session: pending.session
            )
            guard (receipt.closed == 0 || receipt.closed == 1),
                  (receipt.providerClosed == 0 || receipt.providerClosed == 1),
                  receipt.providerClosed <= receipt.closed else {
                throw TransportFailure.invalidResponse
            }
            return receipt.closed == 1 && receipt.providerClosed == 1 ? .providerClosed : .unconfirmed
        } catch let failure as TransportFailure {
            if case .gateway(let status, _) = failure, status == 404 { return .unconfirmed }
            if failure.definitivelyInvalidatesDevice, mayMutateCredential() {
                try credentialVault.deleteIfUnchanged(credential)
            }
            throw failure
        }
    }

    func connectEvents(origin: URL) async throws {
        self.origin = origin
        let operation = connectionAuthority.current
        let gateway = try GatewayConfiguration(baseURL: origin)
        guard session != nil, let cookieStorage else { throw TransportFailure.notPaired }
        var request = URLRequest(url: gateway.webSocketURL)
        request.setValue(gateway.origin, forHTTPHeaderField: "Origin")
        let configuration = GatewayConnectionPolicy.makeWebSocketConfiguration(cookieStorage: cookieStorage)
        let replacementSocketSession = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        let task = replacementSocketSession.webSocketTask(with: request)
        socketTask?.cancel()
        socketTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        socketSession?.invalidateAndCancel()
        socketSession = replacementSocketSession
        teardownMedia()
        let socketRevision = voiceConnectionFence.beginSocket()
        socket = task
        task.resume()
        socketTask = Task { [weak self] in
            await self?.receiveEvents(task, operation: operation, socketRevision: socketRevision)
        }
        try await waitForVoiceConnection(
            task: task,
            operation: operation,
            socketRevision: socketRevision
        )
    }

    func disconnectEvents() {
        connectionAuthority.invalidate()
        voiceConnectionFence.invalidate()
        teardownMedia()
        socketTask?.cancel()
        socketTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        socketSession?.invalidateAndCancel()
        socketSession = nil
        session?.invalidateAndCancel()
        session = nil
        cookieStorage = nil
        origin = nil
    }

    func start(target: AgentTarget, mode: VoiceMode, voice: VoiceName, routing: ConversationRouting, idleTimeoutMinutes: Int) async throws -> SessionAuthority {
        guard peer == nil else { throw VoiceFailure.callAlreadyActive }
        guard let requestOrigin = origin, let requestSession = session else { throw TransportFailure.notPaired }
        guard let requestSocket = socket else { throw TransportFailure.voiceConnectionUnavailable }
        let socketRevision = voiceConnectionFence.revision
        guard let connectionID = voiceConnectionFence.connectionID(for: socketRevision) else {
            throw TransportFailure.voiceConnectionUnavailable
        }
        let connectionOperation = connectionAuthority.current
        let revision = mediaFence.begin()
        peerStartupReadiness.begin(revision)
        guard await requestMicrophonePermission() else { throw TransportFailure.microphoneDenied }
        guard mediaFence.owns(revision), ownsVoiceConnection(
            connectionID: connectionID,
            socketRevision: socketRevision,
            task: requestSocket,
            operation: connectionOperation
        ) else { throw CancellationError() }

        // Use LiveKit's maintained AVAudioEngine device explicitly; the platform-default
        // path is the legacy macOS ADM implicated in the observed AirPods failure.
        let factory = LKRTCPeerConnectionFactory(
            audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: false,
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(),
            audioProcessingModule: nil
        )
        self.factory = factory
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            if mediaFence.owns(revision) { self.factory = nil }
            throw TransportFailure.peerCreationFailed
        }
        self.peer = peer
        let peerAuthority = PeerConnectionAuthority(revision: revision, peerIdentifier: UUID().uuidString)
        currentPeerAuthority = peerAuthority
        currentPeerState = .connecting
        mediaGeneration = nil

        let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: [
            "googEchoCancellation": "true",
            "googNoiseSuppression": "true",
            "googAutoGainControl": "true",
        ], optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "pivoice-microphone")
        track.isEnabled = false
        let microphoneMeter = makeMicrophoneMeter(revision: revision)
        track.add(microphoneMeter)
        localAudioTrack = track
        self.microphoneMeter = microphoneMeter
        _ = peer.add(track, streamIds: ["pivoice"])

        let channelConfiguration = LKRTCDataChannelConfiguration()
        guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: channelConfiguration) else {
            teardownMedia()
            throw TransportFailure.peerCreationFailed
        }
        channel.delegate = self
        dataChannel = channel
        var allocatedAuthority: SessionAuthority?
        var sessionRequestStarted = false

        do {
            let offer = try await createOffer(peer)
            try await setLocal(offer, peer: peer)
            try await waitForIceGathering(peer: peer, revision: revision)
            guard let gatheredOffer = peer.localDescription, !gatheredOffer.sdp.isEmpty else { throw TransportFailure.invalidResponse }
            guard ownsVoiceConnection(
                connectionID: connectionID,
                socketRevision: socketRevision,
                task: requestSocket,
                operation: connectionOperation
            ) else { throw CancellationError() }
            sessionRequestStarted = true
            let response: LiveSessionResponse = try await post(
                path: "/api/live/session",
                body: LiveSessionRequest(target: target, mode: mode, voice: voice, routing: routing, idleTimeoutMinutes: idleTimeoutMinutes).gatewayBody(
                    sdp: gatheredOffer.sdp,
                    connectionID: connectionID
                ),
                origin: requestOrigin,
                session: requestSession
            )
            guard isOpaqueVoiceConnectionID(response.generation) else { throw TransportFailure.invalidResponse }
            allocatedAuthority = SessionAuthority(
                generation: response.generation,
                idleDeadline: Date(timeIntervalSince1970: response.idleDeadline / 1_000),
                hardDeadline: Date(timeIntervalSince1970: response.hardDeadline / 1_000),
                peerAuthority: peerAuthority,
                initialPeerState: currentPeerState
            )
            mediaGeneration = response.generation
            guard mediaFence.owns(revision), self.peer === peer, ownsVoiceConnection(
                connectionID: connectionID,
                socketRevision: socketRevision,
                task: requestSocket,
                operation: connectionOperation
            ) else { throw CancellationError() }
            providerEventDiagnostics = ProviderEventDiagnostics(
                generation: response.generation,
                connectionID: connectionID,
                mediaRevision: revision,
                socketRevision: socketRevision,
                connectionOperation: connectionOperation,
                channel: channel
            )
            try await setRemote(LKRTCSessionDescription(type: .answer, sdp: response.sdp), peer: peer)
            guard mediaFence.owns(revision), self.peer === peer, ownsVoiceConnection(
                connectionID: connectionID,
                socketRevision: socketRevision,
                task: requestSocket,
                operation: connectionOperation
            ) else { throw CancellationError() }
            remoteAudioTracks = peer.receivers.compactMap { $0.track as? LKRTCAudioTrack }
            let playbackMeter = makePlaybackMeter(revision: revision)
            self.playbackMeter = playbackMeter
            playbackMeter.setEnabled(playbackEnabled)
            remoteAudioTracks.forEach {
                $0.add(playbackMeter)
                $0.source.volume = playbackGain
                $0.isEnabled = playbackEnabled
            }
            try await waitForPrimaryStartup(peer: peer, revision: revision)
            try await waitForConnectedPeer(peer: peer, revision: revision)
            // Publish primary diagnostics as observation only; it does not dispatch
            // greeting readiness or any provider task.
            providerDiagnosticsReportTask?.cancel()
            providerDiagnosticsReportTask = nil
            scheduleProviderDiagnosticsReportIfNeeded(delay: .zero)
            let initialReport = providerDiagnosticsReportTask
            await initialReport?.value
            guard mediaFence.owns(revision), self.peer === peer, peerStartupReadiness.ready(revision), ownsVoiceConnection(
                connectionID: connectionID, socketRevision: socketRevision,
                task: requestSocket, operation: connectionOperation
            ) else { throw CancellationError() }
            guard let started = allocatedAuthority else { throw TransportFailure.invalidResponse }
            allocatedAuthority = nil
            return SessionAuthority(
                generation: started.generation,
                idleDeadline: started.idleDeadline,
                hardDeadline: started.hardDeadline,
                peerAuthority: started.peerAuthority,
                initialPeerState: currentPeerState
            )
        } catch {
            if mediaFence.owns(revision), self.peer === peer {
                teardownMedia()
            } else {
                microphoneMeter.setEnabled(false)
                track.isEnabled = false
                peer.receivers.compactMap { $0.track as? LKRTCAudioTrack }.forEach { $0.isEnabled = false }
                track.remove(microphoneMeter)
                channel.delegate = nil
                channel.close()
                peer.close()
            }
            if Self.isDefinitiveStaleVoiceConnection(error),
               connectionAuthority.owns(connectionOperation),
               socket === requestSocket,
               voiceConnectionFence.connectionID(for: socketRevision) == connectionID {
                endShortSession(
                    task: requestSocket,
                    message: "The gateway connection ended. Reconnect the paired device explicitly."
                )
            }
            if let allocatedAuthority {
                var closureConfirmed = false
                if ownsVoiceConnection(
                    connectionID: connectionID,
                    socketRevision: socketRevision,
                    task: requestSocket,
                    operation: connectionOperation
                ) {
                    do {
                        try await close(generation: allocatedAuthority.generation)
                        closureConfirmed = true
                    } catch {}
                }
                if !closureConfirmed {
                    throw RetainedVoiceStartAuthority(
                        authority: allocatedAuthority,
                        message: "Startup failed after provider allocation. Provider closure remains unconfirmed."
                    )
                }
                throw error
            }
            if sessionRequestStarted, Self.startAllocationOutcomeIsUnknown(error) {
                throw UnknownVoiceStartAllocation(
                    message: "Startup request outcome is unknown. New authorization and Start remain blocked."
                )
            }
            throw error
        }
    }

    func announceMediaReady(generation: String) async throws {
        guard mediaGeneration == generation,
              peer != nil,
              currentPeerState == .connected || currentPeerState == .completed,
              dataChannel?.readyState == .open,
              peerStartupReadiness.ready(mediaFence.revision),
              let connectionID = voiceConnectionFence.connectionID(for: voiceConnectionFence.revision) else {
            throw TransportFailure.voiceConnectionUnavailable
        }
        let _: EmptyResponse = try await post(
            path: "/api/live/media-ready",
            body: ["generation": generation, "connectionId": connectionID]
        )
    }

    func sendPushToTalk(generation: String, held: Bool, cancel: Bool, commandSequence: Int) async throws {
        let body = PushToTalkRequest(
            generation: generation,
            held: held,
            commandSequence: commandSequence,
            cancel: cancel ? true : nil
        )
        let _: EmptyResponse = try await post(path: "/api/live/ptt", body: body)
    }

    func close(generation: String) async throws {
        guard let requestOrigin = origin, let requestSession = session else { throw TransportFailure.notPaired }
        let operation = connectionAuthority.current
        do {
            let _: EmptyResponse = try await post(path: "/api/live/close", body: ["generation": generation])
        } catch let failure as TransportFailure {
            guard case .gateway(let status, let code) = failure, status == 409, code == "stale_voice_generation" else { throw failure }
            // Peer teardown may already have ended this exact generation. Confirm
            // it by observation only; never resend close or target another session.
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            guard connectionAuthority.owns(operation) else { throw CancellationError() }
            var request = URLRequest(url: requestOrigin.appendingPathComponent("api/live/diagnostics"))
            request.setValue(try GatewayConfiguration(baseURL: requestOrigin).origin, forHTTPHeaderField: "Origin")
            request.timeoutInterval = 1
            let (data, response) = try await requestSession.data(for: request)
            guard connectionAuthority.owns(operation), exactResponseURL(response.url, matches: request.url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16_384 else {
                throw TransportFailure.closeUnconfirmed
            }
            let diagnostic = try JSONDecoder().decode(ProviderClosureDiagnostic.self, from: data)
            guard diagnostic.isSameGeneration(generation) else { throw TransportFailure.closeUnconfirmed }
            if diagnostic.confirmsClosure(generation) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TransportFailure.closeUnconfirmed
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneMeter?.setEnabled(enabled)
        microphoneMeterActive = enabled
        localAudioTrack?.isEnabled = enabled
        if !enabled { microphoneLevel = 0 }
    }

    func setPlaybackEnabled(_ enabled: Bool) {
        playbackEnabled = enabled
        playbackMeterActive = enabled
        playbackMeter?.setEnabled(enabled)
        remoteAudioTracks.forEach { $0.isEnabled = enabled }
        if !enabled {
            playbackLevel = 0
            publishPlaybackActivity(false)
        }
    }

    func setPlaybackGain(_ gain: Double) {
        playbackGain = gain.isFinite ? min(1, max(0, gain)) : 1
        remoteAudioTracks.forEach { $0.source.volume = playbackGain }
    }

    func teardownMedia() {
        peerStartupReadiness.invalidate()
        mediaFence.invalidate()
        microphoneMeter?.setEnabled(false)
        playbackMeter?.setEnabled(false)
        localAudioTrack?.isEnabled = false
        remoteAudioTracks.forEach { $0.isEnabled = false }
        microphoneMeterActive = false
        playbackMeterActive = false
        if let microphoneMeter { localAudioTrack?.remove(microphoneMeter) }
        if let playbackMeter { remoteAudioTracks.forEach { $0.remove(playbackMeter) } }
        microphoneLevel = 0
        playbackLevel = 0
        clearProviderEventDiagnostics()
        dataChannel?.delegate = nil
        dataChannel?.close()
        currentPeerAuthority = nil
        peer?.close()
        dataChannel = nil
        peer = nil
        localAudioTrack = nil
        remoteAudioTracks = []
        microphoneMeter = nil
        playbackMeter = nil
        factory = nil
        playbackEnabled = false
        playbackActivity = false
        currentPeerState = .closed
        mediaGeneration = nil
    }

    private func observeProviderEvent(
        _ observation: ProviderEventObservation,
        channel: LKRTCDataChannel
    ) {
        guard var diagnostics = providerEventDiagnostics,
              dataChannel === channel,
              diagnostics.channel === channel,
              mediaFence.owns(diagnostics.mediaRevision),
              let currentSocket = socket,
              ownsVoiceConnection(
                  connectionID: diagnostics.connectionID,
                  socketRevision: diagnostics.socketRevision,
                  task: currentSocket,
                  operation: diagnostics.connectionOperation
              )
        else { return }
        let accepted: Bool
        switch observation {
        case .type(let type):
            accepted = diagnostics.counts.observe(type: type)
            peerStartupReadiness.observe(type: type, revision: diagnostics.mediaRevision)
        case .unparsed: accepted = diagnostics.counts.observeUnparsedFrame()
        }
        guard accepted else { return }
        providerEventDiagnostics = diagnostics
        scheduleProviderDiagnosticsReportIfNeeded()
    }

    private func scheduleProviderDiagnosticsReportIfNeeded(delay: Duration = .seconds(1)) {
        guard providerDiagnosticsReportTask == nil,
              let diagnostics = providerEventDiagnostics,
              diagnostics.counts.revision > diagnostics.lastReportedCountsRevision
        else { return }
        let generation = diagnostics.generation
        let mediaRevision = diagnostics.mediaRevision
        providerDiagnosticsReportTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reportProviderEventTypes(
                generation: generation,
                mediaRevision: mediaRevision
            )
        }
    }

    private func reportProviderEventTypes(generation: String, mediaRevision: Int) async {
        guard var diagnostics = providerEventDiagnostics,
              diagnostics.generation == generation,
              diagnostics.mediaRevision == mediaRevision,
              mediaFence.owns(mediaRevision),
              dataChannel === diagnostics.channel,
              let currentSocket = socket,
              ownsVoiceConnection(
                  connectionID: diagnostics.connectionID,
                  socketRevision: diagnostics.socketRevision,
                  task: currentSocket,
                  operation: diagnostics.connectionOperation
              ),
              diagnostics.counts.revision > diagnostics.lastReportedCountsRevision,
              diagnostics.reportSequence < ProviderEventTypeCounts.maximumSafeInteger
        else {
            finishProviderDiagnosticsReport(generation: generation, mediaRevision: mediaRevision)
            return
        }

        diagnostics.reportSequence += 1
        diagnostics.lastReportedCountsRevision = diagnostics.counts.revision
        let reportedCountsRevision = diagnostics.counts.revision
        let snapshot = diagnostics.counts.snapshot
        let request = ProviderEventTypesRequest(
            generation: diagnostics.generation,
            connectionId: diagnostics.connectionID,
            sequence: diagnostics.reportSequence,
            observations: snapshot.observations.map {
                ProviderEventTypesRequest.Observation(type: $0.type, count: $0.count)
            },
            overflow: snapshot.overflow
        )
        providerEventDiagnostics = diagnostics

        var shouldRetry = false
        do {
            let response: ProviderEventTypesResponse = try await post(
                path: "/api/live/diagnostics/provider-event-types",
                body: request
            )
            shouldRetry = !response.accepted
        } catch let error as TransportFailure {
            if case .gateway(let status, _) = error, status == 409 {
                clearProviderEventDiagnosticsIfCurrent(
                    generation: generation,
                    mediaRevision: mediaRevision
                )
                return
            }
            shouldRetry = true
        } catch {
            shouldRetry = true
        }

        guard var current = providerEventDiagnostics,
              current.generation == generation,
              current.mediaRevision == mediaRevision
        else { return }
        providerDiagnosticsReportTask = nil
        if shouldRetry {
            current.lastReportedCountsRevision = max(0, reportedCountsRevision - 1)
            providerEventDiagnostics = current
        }
        scheduleProviderDiagnosticsReportIfNeeded()
    }

    private func finishProviderDiagnosticsReport(generation: String, mediaRevision: Int) {
        guard providerEventDiagnostics?.generation == generation,
              providerEventDiagnostics?.mediaRevision == mediaRevision
        else { return }
        providerDiagnosticsReportTask = nil
    }

    private func clearProviderEventDiagnosticsIfCurrent(generation: String, mediaRevision: Int) {
        guard providerEventDiagnostics?.generation == generation,
              providerEventDiagnostics?.mediaRevision == mediaRevision
        else { return }
        clearProviderEventDiagnostics()
    }

    private func clearProviderEventDiagnostics() {
        providerDiagnosticsReportTask?.cancel()
        providerDiagnosticsReportTask = nil
        providerEventDiagnostics = nil
    }

    nonisolated private static func providerEventObservation(
        from buffer: LKRTCDataBuffer
    ) -> ProviderEventObservation {
        guard !buffer.isBinary, buffer.data.count <= 2_000_000,
              let envelope = try? JSONDecoder().decode(ProviderEventEnvelope.self, from: buffer.data),
              ProviderEventTypeCounts.isValidType(envelope.type)
        else { return .unparsed }
        return .type(envelope.type)
    }

    private func makeMicrophoneMeter(revision: Int) -> AudioLevelMeter {
        AudioLevelMeter(revision: revision) { [weak self] level, observedRevision, publication in
            Task { @MainActor [weak self] in
                guard let self,
                      mediaFence.owns(observedRevision),
                      microphoneMeter?.permitsObservation(publication) == true,
                      localAudioTrack?.isEnabled == true
                else { return }
                microphoneLevel = level
            }
        }
    }

    private func makePlaybackMeter(revision: Int) -> AudioLevelMeter {
        AudioLevelMeter(revision: revision) { [weak self] level, observedRevision, publication in
            Task { @MainActor [weak self] in
                guard let self,
                      mediaFence.owns(observedRevision),
                      playbackMeter?.permitsObservation(publication) == true,
                      playbackEnabled,
                      remoteAudioTracks.contains(where: \.isEnabled)
                else { return }
                playbackLevel = level
                publishPlaybackActivity(level >= 0.015)
            }
        }
    }

    private func publishPlaybackActivity(_ active: Bool) {
        guard playbackActivity != active else { return }
        playbackActivity = active
        guard let generation = mediaGeneration else { return }
        eventContinuation.yield(.playbackActivity(generation: generation, active: active))
    }

    private struct SessionBundle {
        let session: URLSession
        let cookies: HTTPCookieStorage
    }

    private func makeSession() -> SessionBundle {
        let configuration = GatewayConnectionPolicy.makeEphemeralConfiguration()
        guard let cookies = configuration.httpCookieStorage else {
            preconditionFailure("Ephemeral URLSession has no in-memory cookie store")
        }
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        return SessionBundle(
            session: URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil),
            cookies: cookies
        )
    }

    private func activate(_ pending: SessionBundle, origin: URL) {
        voiceConnectionFence.invalidate()
        socketTask?.cancel()
        socketTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        socketSession?.invalidateAndCancel()
        socketSession = nil
        session?.invalidateAndCancel()
        session = pending.session
        cookieStorage = pending.cookies
        self.origin = origin
    }

    private static func cookieNames(for gateway: GatewayConfiguration) -> (device: String, session: String) {
        let prefix = gateway.baseURL.scheme == "https" ? "__Host-" : ""
        return ("\(prefix)pi_voice_device", "\(prefix)pi_voice_session")
    }

    private static func cookies(in storage: HTTPCookieStorage, for gateway: GatewayConfiguration) -> [HTTPCookie] {
        storage.cookies(for: gateway.baseURL) ?? []
    }

    private static func deviceCredential(in storage: HTTPCookieStorage, for gateway: GatewayConfiguration) throws -> String {
        let name = cookieNames(for: gateway).device
        let matches = cookies(in: storage, for: gateway).filter { $0.name == name }
        guard matches.count == 1 else { throw TransportFailure.missingDeviceCookie }
        return matches[0].value
    }

    private static func retainOnlyShortSession(in storage: HTTPCookieStorage, for gateway: GatewayConfiguration) -> Bool {
        let name = cookieNames(for: gateway).session
        let allCookies = cookies(in: storage, for: gateway)
        let matches = allCookies.filter { $0.name == name && isOpaque43($0.value) }
        for cookie in allCookies where matches.count != 1 || cookie !== matches[0] {
            storage.deleteCookie(cookie)
        }
        return matches.count == 1
    }

    private static func isOpaque43(_ value: String) -> Bool {
        value.count == 43 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
                ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
        }
    }

    private static func removeDeviceCookies(from storage: HTTPCookieStorage, for gateway: GatewayConfiguration) {
        let names = Set(["pi_voice_device", "__Host-pi_voice_device"])
        for cookie in cookies(in: storage, for: gateway) where names.contains(cookie.name) {
            storage.deleteCookie(cookie)
        }
    }

    private static func makeDeviceCookie(_ credential: DeviceCredential, gateway: GatewayConfiguration) -> HTTPCookie? {
        guard credential.origin == gateway.origin, let host = gateway.baseURL.host else { return nil }
        let names = cookieNames(for: gateway)
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: names.device,
            .value: credential.value,
            .domain: host,
            .path: "/",
            .originURL: gateway.baseURL,
        ]
        if gateway.baseURL.scheme == "https" { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    private static func isDefinitiveStaleVoiceConnection(_ error: Error) -> Bool {
        guard case .gateway(let status, let code) = error as? TransportFailure else { return false }
        return status == 409 && code == "stale_voice_connection"
    }

    private static func startAllocationOutcomeIsUnknown(_ error: Error) -> Bool {
        if error is CancellationError || error is URLError || error is DecodingError { return true }
        guard let failure = error as? TransportFailure else { return false }
        switch failure {
        case .invalidResponse: return true
        case .gateway(let status, let code):
            return status >= 500 || status == 408 || code == "voice_connection_lost"
        default: return false
        }
    }

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        origin explicitOrigin: URL? = nil,
        session explicitSession: URLSession? = nil
    ) async throws -> Response {
        guard let origin = explicitOrigin ?? self.origin,
              let session = explicitSession ?? self.session else { throw TransportFailure.notPaired }
        let gateway = try GatewayConfiguration(baseURL: origin)
        var request = URLRequest(url: gateway.httpURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(gateway.origin, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              exactResponseURL(http.url, matches: request.url) else {
            throw TransportFailure.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(GatewayErrorResponse.self, from: data)
            throw TransportFailure.gateway(status: http.statusCode, code: payload?.error ?? "request_failed")
        }
        let responseData = data.isEmpty ? Data("{}".utf8) : data
        return try JSONDecoder().decode(Response.self, from: responseData)
    }

    private func acceptURLSessionTaskCompletion(
        _ receipt: URLSessionTaskCompletionReceipt,
        afterCloseFrameGrace: Bool = false
    ) {
        guard let socketSession, let socket,
              receipt.matches(session: socketSession, task: socket) else { return }
        if receipt.kind == .taskCompleted,
           receipt.webSocketCloseCode == nil,
           !afterCloseFrameGrace {
            // Terminal task completion removes Start and media authority now. A
            // close-frame callback gets one bounded grace only to classify 4003;
            // it cannot extend connection or capture authority during that grace.
            voiceConnectionFence.invalidate()
            connectionAuthority.invalidate()
            socketTask?.cancel()
            teardownMedia()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                self?.acceptURLSessionTaskCompletion(receipt, afterCloseFrameGrace: true)
            }
            return
        }
        if receipt.webSocketCloseCode == 4003 {
            endRevokedAuthorization(task: socket)
            return
        }
        endShortSession(
            task: socket,
            message: receipt.webSocketCloseCode == 4001
                ? "The short gateway session ended. Reconnect the paired device explicitly."
                : "The gateway connection ended. Reconnect the paired device explicitly."
        )
    }

    private func waitForVoiceConnection(
        task: URLSessionWebSocketTask,
        operation: UUID,
        socketRevision: Int
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            guard !Task.isCancelled, connectionAuthority.owns(operation), socket === task,
                  voiceConnectionFence.revision == socketRevision else { throw CancellationError() }
            if voiceConnectionFence.connectionID(for: socketRevision) != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard connectionAuthority.owns(operation), socket === task,
              voiceConnectionFence.revision == socketRevision else { throw CancellationError() }
        task.cancel(with: .policyViolation, reason: Data("missing_voice_connection".utf8))
        endShortSession(task: task, message: "The gateway did not establish exact voice connection authority.")
        throw TransportFailure.voiceConnectionUnavailable
    }

    private func ownsVoiceConnection(
        connectionID: String,
        socketRevision: Int,
        task: URLSessionWebSocketTask,
        operation: UUID
    ) -> Bool {
        connectionAuthority.owns(operation) && socket === task &&
            voiceConnectionFence.connectionID(for: socketRevision) == connectionID
    }

    private func receiveEvents(
        _ task: URLSessionWebSocketTask,
        operation: UUID,
        socketRevision: Int
    ) async {
        while !Task.isCancelled, connectionAuthority.owns(operation), socket === task,
              voiceConnectionFence.revision == socketRevision {
            do {
                let message = try await task.receive()
                guard !Task.isCancelled, connectionAuthority.owns(operation), socket === task,
                      voiceConnectionFence.revision == socketRevision else { return }
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                let announcement = VoiceConnectionAnnouncement.decode(data)
                if voiceConnectionFence.connectionID(for: socketRevision) == nil {
                    guard voiceConnectionFence.acceptFirst(
                        announcement,
                        revision: socketRevision
                    ) else {
                        task.cancel(with: .policyViolation, reason: Data("missing_first_voice_connection".utf8))
                        endShortSession(task: task, message: "The gateway did not send exact voice authority first.")
                        return
                    }
                    continue
                }
                switch announcement {
                case .notAnnouncement:
                    if let event = VoiceGatewayEventDecoder.decode(data) { eventContinuation.yield(event) }
                case .valid, .invalid:
                    task.cancel(with: .policyViolation, reason: Data("duplicate_voice_connection".utf8))
                    endShortSession(task: task, message: "The gateway replaced voice connection authority unexpectedly.")
                    return
                }
            } catch {
                guard !Task.isCancelled, connectionAuthority.owns(operation), socket === task,
                      voiceConnectionFence.revision == socketRevision else { return }
                if task.closeCode.rawValue == 4003 {
                    endRevokedAuthorization(task: task)
                    return
                }
                endShortSession(
                    task: task,
                    message: task.closeCode.rawValue == 4001
                        ? "The short gateway session ended. Reconnect the paired device explicitly."
                        : "The gateway connection ended. Reconnect the paired device explicitly."
                )
                return
            }
        }
    }

    private func endShortSession(task: URLSessionWebSocketTask, message: String) {
        guard socket === task else { return }
        voiceConnectionFence.invalidate()
        teardownMedia()
        let closingSession = session
        let closingSocketSession = socketSession
        socket = nil
        socketTask = nil
        socketSession = nil
        session = nil
        cookieStorage = nil
        origin = nil
        closingSocketSession?.invalidateAndCancel()
        closingSession?.invalidateAndCancel()
        connectionAuthority.invalidate()
        eventContinuation.yield(.sessionEnded(message: message))
    }

    private func endRevokedAuthorization(task: URLSessionWebSocketTask) {
        guard socket === task else { return }
        voiceConnectionFence.invalidate()
        teardownMedia()
        var credentialCleared = false
        if let origin, let gateway = try? GatewayConfiguration(baseURL: origin) {
            do {
                try credentialVault.delete(origin: gateway.origin)
                credentialCleared = true
            } catch {
                credentialCleared = false
            }
        }
        let closingSession = session
        let closingSocketSession = socketSession
        socket = nil
        socketTask = nil
        socketSession = nil
        session = nil
        cookieStorage = nil
        origin = nil
        closingSocketSession?.invalidateAndCancel()
        closingSession?.invalidateAndCancel()
        connectionAuthority.invalidate()
        eventContinuation.yield(.deviceRevoked(credentialCleared: credentialCleared))
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default: return false
        }
    }

    private func createOffer(_ peer: LKRTCPeerConnection) async throws -> LKRTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: LKRTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
                optionalConstraints: nil
            )) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: error ?? TransportFailure.invalidResponse) }
            }
        }
    }

    private func setLocal(_ sdp: LKRTCSessionDescription, peer: LKRTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func waitForIceGathering(peer: LKRTCPeerConnection, revision: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, mediaFence.owns(revision), self.peer === peer else { throw CancellationError() }
            if peer.iceGatheringState == .complete {
                peerStartupReadiness.iceGathered(revision)
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TransportFailure.iceGatheringTimedOut
    }

    private func waitForPrimaryStartup(peer: LKRTCPeerConnection, revision: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, mediaFence.owns(revision), self.peer === peer else { throw CancellationError() }
            if peerStartupReadiness.ready(revision) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TransportFailure.primaryStartupTimedOut
    }

    private func waitForConnectedPeer(peer: LKRTCPeerConnection, revision: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, mediaFence.owns(revision), self.peer === peer else { throw CancellationError() }
            if currentPeerState == .connected || currentPeerState == .completed { return }
            if currentPeerState == .failed || currentPeerState == .closed { throw TransportFailure.peerConnectionFailed }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TransportFailure.peerConnectionFailed
    }

    private static func peerConnectionState(_ state: LKRTCIceConnectionState) -> PeerConnectionState? {
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

    private func setRemote(_ sdp: LKRTCSessionDescription, peer: LKRTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}

extension GatewayVoiceTransport: LKRTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        Task { @MainActor [weak self, weak dataChannel] in
            guard let self, let dataChannel, self.dataChannel === dataChannel,
                  dataChannel.readyState == .closed,
                  let authority = currentPeerAuthority else { return }
            eventContinuation.yield(.peerConnectionState(authority: authority, state: .failed))
        }
    }

    nonisolated func dataChannel(
        _ dataChannel: LKRTCDataChannel,
        didReceiveMessageWith buffer: LKRTCDataBuffer
    ) {
        let observation = Self.providerEventObservation(from: buffer)
        Task { @MainActor [weak self, weak dataChannel] in
            guard let self, let dataChannel else { return }
            observeProviderEvent(observation, channel: dataChannel)
        }
    }
}

extension GatewayVoiceTransport: LKRTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        Task { @MainActor [weak self, weak peerConnection] in
            guard let self, let peerConnection, self.peer === peerConnection,
                  let authority = currentPeerAuthority,
                  let state = Self.peerConnectionState(newState) else { return }
            currentPeerState = state
            eventContinuation.yield(.peerConnectionState(authority: authority, state: state))
        }
    }
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}

private struct ProviderEventDiagnostics {
    let generation: String
    let connectionID: String
    let mediaRevision: Int
    let socketRevision: Int
    let connectionOperation: UUID
    let channel: LKRTCDataChannel
    var counts = ProviderEventTypeCounts()
    var reportSequence = 0
    var lastReportedCountsRevision = 0
}

private enum ProviderEventObservation: Sendable {
    case type(String)
    case unparsed
}

private struct ProviderEventEnvelope: Decodable {
    let type: String
}

private struct ProviderEventTypesRequest: Encodable {
    struct Observation: Encodable {
        let type: String
        let count: Int
    }

    let generation: String
    let connectionId: String
    let sequence: Int
    let observations: [Observation]
    let overflow: Int
}

private struct ProviderEventTypesResponse: Decodable {
    let accepted: Bool
}

private struct DeviceSessionResponse: Decodable {
    struct Device: Decodable { let origin: String }
    let authenticated: Bool
    let sessionExpiresAt: Double
    let device: Device
}

private struct LiveSessionResponse: Decodable {
    let sdp: String
    let generation: String
    let idleDeadline: Double
    let hardDeadline: Double
}

private struct ProviderClosureReceiptResponse: Decodable {
    let closed: Int
    let providerClosed: Int
}

private struct PushToTalkRequest: Encodable {
    let generation: String
    let held: Bool
    let commandSequence: Int
    let cancel: Bool?
}

private struct EmptyRequest: Encodable {}
private struct EmptyResponse: Codable {}
private struct GatewayErrorResponse: Decodable { let error: String }

private enum TransportFailure: LocalizedError {
    case notPaired
    case noSavedDevice
    case deviceAlreadySaved
    case missingDeviceCookie
    case missingSessionCookie
    case deviceOriginMismatch
    case voiceConnectionUnavailable
    case microphoneDenied
    case peerCreationFailed
    case peerConnectionFailed
    case iceGatheringTimedOut
    case primaryStartupTimedOut
    case closeUnconfirmed
    case invalidResponse
    case gateway(status: Int, code: String)

    var errorDescription: String? {
        switch self {
        case .notPaired: "Pair or reconnect this Mac before connecting."
        case .noSavedDevice: "No paired-device credential is saved for this exact gateway origin."
        case .deviceAlreadySaved: "This exact gateway is already paired on this Mac. Reconnect it, or explicitly Forget on this Mac before pairing again."
        case .missingDeviceCookie: "The gateway did not return one valid durable device cookie."
        case .missingSessionCookie: "The gateway did not return one valid short session cookie."
        case .deviceOriginMismatch: "The gateway's device origin did not match the exact requested origin."
        case .voiceConnectionUnavailable: "Reconnect this Mac before starting voice. Exact WebSocket authority is unavailable."
        case .microphoneDenied: "Microphone permission is required only after Start voice."
        case .peerCreationFailed: "WebRTC peer creation failed."
        case .peerConnectionFailed: "The audio peer did not become connected. Local media is off and closure was requested."
        case .iceGatheringTimedOut: "Audio connection setup timed out. No conversation was started."
        case .primaryStartupTimedOut: "The voice event connection did not become ready. Local media is off and closure was requested; try a fresh Start."
        case .closeUnconfirmed: "Session ended locally, but provider closure is unconfirmed. A new conversation was not started."
        case .invalidResponse: "The gateway returned an invalid response."
        case .gateway(let status, let code): "Gateway \(status): \(code)"
        }
    }

    var definitivelyInvalidatesDevice: Bool {
        guard case .gateway(let status, let code) = self else { return false }
        return deviceCredentialFailureDisposition(httpStatus: status, code: code) == .deleteSavedCredential
    }
}
