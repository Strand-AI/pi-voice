import Combine
import Foundation
@preconcurrency import Network
import PiVoiceCore
import UIKit

@MainActor
final class AppModel: ObservableObject, PiVoiceActivityControlHandling {
    let coordinator: VoiceSessionCoordinator
    let simulatorMode: Bool

    @Published var originText = ""
    @Published var pairingToken = ""
    @Published var mode: VoiceMode = .continuous
    @Published var voice: VoiceName = .marin {
        didSet { UserDefaults.standard.set(voice.rawValue, forKey: savedVoiceKey) }
    }
    @Published var busy = false
    @Published var formError: String?
    @Published var notice: String?
    @Published var speakerphoneEnabled = false
    @Published var audioRouteDescription = "System selected"
    @Published var hasStoredCredential = false
    @Published var repairPairing = false

    private var deferredStartupReconnect: DeferredStartupReconnect
    private let savedOriginKey = "piVoice.lastGatewayOrigin"
    private let savedVoiceKey = "piVoice.lastVoice"
    private let lastAgentStore = LastAgentSelectionHintStore()
    private var lastAgentRestoration = LastAgentSelectionRestoration()
    private var restorationOrigin: String?
    private var observedConfirmedEndRevision = 0
    private let gatewayTransport: GatewayVoiceTransport?
    private var callKitController: PiVoiceCallKitController?
    private let liveActivity = PiVoiceLiveActivityManager()
    private var liveActivitySyncTask: Task<Void, Never>?
    private var lastAutomaticReconnectEpoch: UInt64 = 0
    private var lastAutomaticClosureRecoveryEpoch: UInt64 = 0
    private var closureRecoveryBudget = ProviderClosureRecoveryBudget()
    private var closureRecoveryTask: Task<Void, Never>?
    private var networkAvailable = false
    private var networkMonitor: NWPathMonitor?
    private var closureRecoverySimulator: Bool { simulatorMode && ProcessInfo.processInfo.arguments.contains("--fake-provider-closed-receipt") }

    init() {
        simulatorMode = ProcessInfo.processInfo.arguments.contains("--fake-voice")
        deferredStartupReconnect = DeferredStartupReconnect(
            launchedInBackground: !simulatorMode && UIApplication.shared.applicationState != .active
        )
        if simulatorMode {
            gatewayTransport = nil
            coordinator = VoiceSessionCoordinator(transport: SimulatorVoiceTransport())
        } else {
            let transport = GatewayVoiceTransport()
            gatewayTransport = transport
            coordinator = VoiceSessionCoordinator(transport: transport)
        }
        if ProcessInfo.processInfo.arguments.contains("--reset-test-preferences") {
            UserDefaults.standard.removeObject(forKey: savedOriginKey)
            UserDefaults.standard.removeObject(forKey: savedVoiceKey)
            lastAgentStore.clearAll()
        }
        if let rawVoice = UserDefaults.standard.string(forKey: savedVoiceKey), let savedVoice = VoiceName(rawValue: rawVoice) {
            voice = savedVoice
        } else {
            UserDefaults.standard.removeObject(forKey: savedVoiceKey)
        }
        coordinator.didChange = { [weak self] in
            guard let self else { return }
            self.callKitController?.reconcileCoreReadiness()
            self.objectWillChange.send()
            if !self.simulatorMode { self.scheduleLiveActivitySynchronization() }
            self.handleAgentRestoration()
            self.scheduleAutomaticReconnectIfNeeded()
            self.scheduleClosureRecoveryIfNeeded()
        }
        coordinator.presentationDidChange = { [weak self] in
            self?.objectWillChange.send()
        }
        if !simulatorMode {
            let callKit = PiVoiceCallKitController(coordinator: coordinator)
            callKit.didChange = { [weak self] in self?.objectWillChange.send() }
            callKit.didFail = { [weak self] error in self?.formError = error.localizedDescription }
            callKitController = callKit
        }
        gatewayTransport?.audioRouteDidChange = { [weak self] in self?.refreshAudioRoute() }
        PiVoiceActivityControlBridge.handler = self
        if !simulatorMode {
            let monitor = NWPathMonitor()
            networkMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.networkAvailable = path.status == .satisfied
                    if self.networkAvailable { self.scheduleClosureRecoveryIfNeeded() }
                    else if let epoch = self.coordinator.closureRecoveryEpoch, self.lastAutomaticClosureRecoveryEpoch == epoch {
                        self.closureRecoveryTask?.cancel()
                        self.lastAutomaticClosureRecoveryEpoch = epoch &- 1
                    }
                }
            }
            monitor.start(queue: DispatchQueue(label: "ai.strand.pivoice.network-availability"))
        }
        originText = UserDefaults.standard.string(forKey: savedOriginKey) ?? ""
        refreshStoredCredentialAvailability()
        if simulatorMode, ProcessInfo.processInfo.arguments.contains("--fake-saved-disconnected") {
            originText = "https://simulator.invalid"
            hasStoredCredential = true
            repairPairing = false
        } else if simulatorMode {
            originText = "https://simulator.invalid"
            pairingToken = "offline"
            Task { await connect() }
        } else if deferredStartupReconnect.claimAtInitialization(eligible: hasStoredCredential) {
            Task { [weak self] in await self?.reconnectSavedDevice() }
        }
    }

    deinit {
        closureRecoveryTask?.cancel()
        networkMonitor?.cancel()
    }

    var connected: Bool { coordinator.phase != .disconnected }
    var active: Bool {
        switch coordinator.phase {
        case .starting, .active, .stopping, .uncertain: true
        default: false
        }
    }
    var mediaControlsEnabled: Bool {
        if case .active = coordinator.phase { true } else { false }
    }
    var voiceVisualLevels: VoiceVisualLevels {
        guard let state = coordinator.visualMediaState else { return .silent }
        return VoiceVisualLevels(
            generation: state.generation,
            outgoingLevel: state.outgoingLevel,
            playbackLevel: state.playbackLevel,
            speakerActive: state.speakerActive,
            outgoingAuthorized: true,
            playbackAuthorized: true
        )
    }
    var pttControlsEnabled: Bool {
        mediaControlsEnabled && coordinator.mediaConnectionState == .connected && !coordinator.pttFinishing
    }
    var status: String {
        switch coordinator.phase {
        case .disconnected: "Not connected"
        case .ready: "Ready — microphone and billing are off"
        case .starting: "Starting paid voice…"
        case let .active(authority):
            switch coordinator.mediaConnectionState {
            case .connected: "Live · hard stop \(authority.hardDeadline.formatted(date: .omitted, time: .shortened))"
            case .reconnecting: "Reconnecting audio… microphone and playback are gated"
            case .unknown: "Audio connection unknown · Stop retains exact session authority"
            }
        case .stopping: "Stopping…"
        case let .uncertain(message): message
        }
    }

    func connect() async {
        guard !busy else { return }
        let token = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty, hasStoredCredential, !repairPairing {
            await reconnectSavedDevice()
            return
        }

        busy = true; formError = nil; notice = nil
        defer { busy = false }
        do {
            guard let origin = URL(string: originText.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw VoiceError.invalidOrigin }
            let canonical = try CanonicalGatewayOrigin(origin)
            if !token.isEmpty { pairingToken = "" } // One-use attempts are never staged for retry after an unknown outcome.
            prepareAgentRestoration(origin: canonical.value)
            try await coordinator.connect(origin: canonical.url, pairingToken: token.isEmpty ? nil : token)
            UserDefaults.standard.set(canonical.value, forKey: savedOriginKey)
            originText = canonical.value
            hasStoredCredential = true
            repairPairing = false
        } catch {
            lastAgentRestoration.cancel()
            formError = error.localizedDescription
            if SavedDeviceReconnectPolicy.requiresRepair(error) { repairPairing = true; hasStoredCredential = false }
        }
    }

    func presentationVisibilityChanged(_ visible: Bool) {
        coordinator.setPresentationVisible(visible)
    }

    func originDidChange() {
        guard !connected, !busy else { return }
        lastAgentRestoration.cancel()
        restorationOrigin = nil
        refreshStoredCredentialAvailability()
    }

    func requestRepairPairing() {
        repairPairing = true
        pairingToken = ""
        formError = nil
    }

    func useSavedPairing() {
        guard hasStoredCredential else { return }
        repairPairing = false
        pairingToken = ""
        formError = nil
    }

    func forgetDevice() async {
        guard !busy else { return }
        busy = true; formError = nil; notice = nil
        defer { busy = false }
        do {
            guard let origin = URL(string: originText.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw VoiceError.invalidOrigin }
            let canonical = try CanonicalGatewayOrigin(origin)
            try await coordinator.forgetDevice(origin: canonical.url)
            lastAgentStore.clear(forOrigin: canonical.value)
            lastAgentRestoration.cancel()
            restorationOrigin = nil
            UserDefaults.standard.removeObject(forKey: savedOriginKey)
            pairingToken = ""
            hasStoredCredential = false
            repairPairing = true
            notice = "Only this phone's local credential was deleted. Server authorization remains until local-owner revocation or expiry."
        } catch { formError = error.localizedDescription }
    }

    func select(_ endpoint: AgentEndpoint?) {
        lastAgentRestoration.cancel()
        do {
            try coordinator.select(endpoint)
            if let origin = coordinator.connectedOrigin {
                if let endpoint { try lastAgentStore.save(origin: origin, agentID: endpoint.id) }
                else { lastAgentStore.clear(forOrigin: origin) }
            }
        } catch { formError = error.localizedDescription }
    }

    func start() async {
        guard !busy else { return }
        busy = true; formError = nil
        defer { busy = false }
        do {
            if simulatorMode {
                try await coordinator.start(mode: mode, voice: voice)
            } else {
                guard let target = coordinator.selected, let callKitController else { throw VoiceError.targetUnavailable }
                try await callKitController.requestStart(target: target, mode: mode, voice: voice)
            }
            speakerphoneEnabled = true
            refreshAudioRoute()
        } catch { formError = error.localizedDescription }
    }

    func setUserMuted(_ muted: Bool) {
        if simulatorMode {
            coordinator.setUserMuted(muted)
            return
        }
        guard let callKitController else { return }
        do { try callKitController.requestMuted(muted) }
        catch { formError = error.localizedDescription }
    }

    func setSpeakerphoneEnabled(_ enabled: Bool) {
        guard mediaControlsEnabled, let gatewayTransport else { return }
        do {
            try gatewayTransport.setSpeakerphoneEnabled(enabled)
            speakerphoneEnabled = enabled
            refreshAudioRoute()
        } catch { formError = error.localizedDescription }
    }

    func retryClosureCheck() async {
        guard !busy, let epoch = coordinator.closureRecoveryEpoch else { return }
        let automatic = closureRecoveryTask
        automatic?.cancel()
        await automatic?.value
        guard coordinator.mayCheckProviderClosure(epoch: epoch) else { return }
        busy = true; formError = nil
        do {
            let confirmed = try await coordinator.checkProviderClosure(epoch: epoch)
            busy = false
            if confirmed { scheduleAutomaticReconnectIfNeeded() }
        } catch {
            busy = false
            guard coordinator.hasProviderClosureRecoveryScope(epoch: epoch) else { return }
            formError = error.localizedDescription
            if SavedDeviceReconnectPolicy.requiresRepair(error) { repairPairing = true; hasStoredCredential = false }
        }
    }

    func stop() async {
        guard !busy else { return }
        busy = true
        var endAccepted = false
        if simulatorMode {
            await coordinator.stop()
            endAccepted = true
        } else if let callKitController {
            do {
                endAccepted = try await callKitController.requestEnd()
            } catch { formError = error.localizedDescription }
        }
        if endAccepted {
            await scheduleLiveActivityEnd()
            speakerphoneEnabled = false
            audioRouteDescription = "System selected"
        }
        busy = false
    }

    func pressPTT(gestureEpoch: Int) async {
        do { try await coordinator.beginPushToTalk(gestureEpoch: gestureEpoch) }
        catch { formError = error.localizedDescription }
    }

    func releasePTT(cancel: Bool = false) async {
        do { try await coordinator.endPushToTalk(cancel: cancel) }
        catch { formError = error.localizedDescription }
    }

    func enteredBackground() async {
        if !simulatorMode,
           let callKitController,
           coordinator.phase == .starting || callKitController.hasPendingStartupIntent {
            do { try await callKitController.requestEnd() }
            catch { formError = error.localizedDescription }
            return
        }
        await coordinator.applicationDidEnterBackground()
    }

    func becameActive() {
        let eligible = hasStoredCredential && !busy && coordinator.phase == .disconnected
        guard deferredStartupReconnect.claimOnForeground(eligible: eligible) else { return }
        Task { [weak self] in await self?.reconnectSavedDevice() }
    }

    func handleOpenURL(_ url: URL) {
        guard VoiceNavigationRoute(url: url) == .live else { return }
        notice = "Showing the current Pi Voice session."
    }

    func activitySetMuted(ticket: String, desiredMuted: Bool) {
        guard liveActivity.controlsMatch(ticket: ticket, coordinator: coordinator) else { return }
        setUserMuted(desiredMuted)
    }

    func activityEnd(ticket: String) async {
        guard liveActivity.controlsMatch(ticket: ticket, coordinator: coordinator) else { return }
        await stop()
    }

    private func scheduleLiveActivitySynchronization() {
        let ticket = liveActivity.issueTicket(for: coordinator)
        let previous = liveActivitySyncTask
        liveActivitySyncTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.liveActivity.synchronize(with: self.coordinator, ticket: ticket)
        }
    }

    private func scheduleLiveActivityEnd() async {
        guard !simulatorMode else { return }
        let ticket = liveActivity.issueEndTicket()
        let previous = liveActivitySyncTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.liveActivity.end(with: self.coordinator, ticket: ticket)
        }
        liveActivitySyncTask = task
        await task.value
    }

    private func scheduleClosureRecoveryIfNeeded() {
        guard !simulatorMode, networkAvailable, hasStoredCredential,
              let epoch = coordinator.closureRecoveryEpoch,
              epoch > lastAutomaticClosureRecoveryEpoch,
              coordinator.mayCheckProviderClosure(epoch: epoch) else { return }
        lastAutomaticClosureRecoveryEpoch = epoch
        closureRecoveryTask?.cancel()
        closureRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delays: [Duration] = [.zero, .seconds(5), .seconds(10)]
            for delay in delays {
                if delay != .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, self.networkAvailable, self.coordinator.mayCheckProviderClosure(epoch: epoch) else { return }
                guard self.closureRecoveryBudget.claimAutomaticAttempt(epoch: epoch) else { return }
                do {
                    if try await self.coordinator.checkProviderClosure(epoch: epoch) { return }
                } catch {
                    guard self.coordinator.hasProviderClosureRecoveryScope(epoch: epoch) else { return }
                    self.formError = error.localizedDescription
                    if SavedDeviceReconnectPolicy.requiresRepair(error) {
                        self.repairPairing = true; self.hasStoredCredential = false
                        return
                    }
                    guard SavedDeviceReconnectPolicy.shouldRetry(error) else { return }
                }
            }
        }
    }

    private func scheduleAutomaticReconnectIfNeeded() {
        guard (!simulatorMode || closureRecoverySimulator), hasStoredCredential,
              let epoch = coordinator.automaticReconnectEpoch,
              epoch > lastAutomaticReconnectEpoch else { return }
        lastAutomaticReconnectEpoch = epoch
        Task { [weak self] in await self?.reconnectSavedDevice(automaticEpoch: epoch) }
    }

    private func reconnectSavedDevice(automaticEpoch: UInt64? = nil) async {
        guard !busy, (!simulatorMode || closureRecoverySimulator),
              automaticEpoch.map({ coordinator.mayAutomaticallyReconnect(epoch: $0) }) ?? (coordinator.phase == .disconnected),
              let input = URL(string: originText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let canonical = try? CanonicalGatewayOrigin(input) else { return }
        busy = true; formError = nil; notice = nil
        defer { busy = false }
        let expectedOrigin = canonical.value
        let succeeded = await AutomaticConnectionRetry.run(
            shouldContinue: { [weak self] in
                guard let self, self.originText == expectedOrigin, self.hasStoredCredential else { return false }
                if let automaticEpoch {
                    return self.coordinator.mayAutomaticallyReconnect(epoch: automaticEpoch)
                }
                return self.coordinator.phase == .disconnected
            },
            reconnect: { [weak self] in
                guard let self else { throw CancellationError() }
                self.prepareAgentRestoration(origin: canonical.value)
                try await self.coordinator.connect(origin: canonical.url, pairingToken: nil)
            },
            shouldRetry: SavedDeviceReconnectPolicy.shouldRetry,
            reportFailure: { [weak self] error in
                self?.formError = error.localizedDescription
                if SavedDeviceReconnectPolicy.requiresRepair(error) {
                    self?.repairPairing = true
                    self?.hasStoredCredential = false
                }
            }
        )
        if succeeded {
            UserDefaults.standard.set(expectedOrigin, forKey: savedOriginKey)
            originText = expectedOrigin
            repairPairing = false
            formError = nil
        }
    }

    private func prepareAgentRestoration(origin: String) {
        restorationOrigin = origin
        lastAgentRestoration.begin(after: coordinator.rosterRevision)
    }

    private func handleAgentRestoration() {
        if coordinator.confirmedEndRevision > observedConfirmedEndRevision {
            observedConfirmedEndRevision = coordinator.confirmedEndRevision
            if let generation = coordinator.lastConfirmedProviderClosedGeneration {
                callKitController?.acceptProviderClosed(generation: generation)
            }
            if let origin = coordinator.connectedOrigin { prepareAgentRestoration(origin: origin) }
        }
        guard let origin = restorationOrigin else { return }
        let candidate = lastAgentRestoration.candidate(
            hint: lastAgentStore.load(forOrigin: origin),
            origin: origin,
            phase: coordinator.phase,
            rosterConnected: coordinator.rosterConnected,
            rosterRevision: coordinator.rosterRevision,
            agents: coordinator.agents,
            selected: coordinator.selected
        )
        guard let candidate else { return }
        do { try coordinator.select(candidate) }
        catch { formError = error.localizedDescription }
    }

    private func refreshStoredCredentialAvailability() {
        guard !simulatorMode, let gatewayTransport,
              let input = URL(string: originText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let canonical = try? CanonicalGatewayOrigin(input) else {
            hasStoredCredential = false
            repairPairing = !originText.isEmpty
            return
        }
        do {
            hasStoredCredential = try gatewayTransport.hasStoredCredential(origin: canonical.url)
            repairPairing = !hasStoredCredential
        } catch {
            hasStoredCredential = false
            repairPairing = true
            formError = error.localizedDescription
        }
    }

    private func refreshAudioRoute() {
        audioRouteDescription = gatewayTransport?.currentAudioRouteDescription ?? "Offline simulator"
    }
}
