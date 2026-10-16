import AppKit
import Combine
import PiVoiceMacCore
import SwiftUI

@main
struct PiVoiceMacApp: App {
    @StateObject private var model = VoiceModel()

    var body: some Scene {
        MenuBarExtra {
            VoiceHelperMenu(model: model, rightOptionMonitor: model.rightOptionMonitor)
        } label: {
            HelperMenuLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class VoiceModel: ObservableObject {
    let coordinator: VoiceSessionCoordinator
    let simulatorMode: Bool
    let rightOptionMonitor: RightOptionPTTMonitor
    private let gatewayTransport: GatewayVoiceTransport?
    private let preferenceDefaults: UserDefaults
    private let lastAgentStore: LastAgentSelectionHintStore
    private var lastAgentRestoration = LastAgentSelectionRestoration()

    @Published var origin: String
    @Published var pairingToken = ""
    @Published var mode: VoiceMode {
        didSet { VoicePreferencePolicy.save(mode: mode, to: preferenceDefaults) }
    }
    @Published var voice: VoiceName {
        didSet { VoicePreferencePolicy.save(voice: voice, to: preferenceDefaults) }
    }
    @Published var audioRoute = AudioRouteInspector.current()
    @Published var busy = false
    @Published var formError: String?
    @Published private(set) var closureStatusMessage: String?
    @Published private(set) var savedDeviceAvailable = false
    private var automaticConnectionTask: Task<Void, Never>?
    private var closureRecoveryTask: Task<Void, Never>?
    private var closureRecoveryTaskID: UUID?
    private var closureRecoveryBudget = ProviderClosureRecoveryBudget()
    private var closureRecoveryCampaignEpoch: UInt64?
    private var closureRecoveryStartedAt: ContinuousClock.Instant?
    private var wantsAutomaticConnection = true
    private var systemInactive = false
    private var wasConnected = false

    private var physicalHolds = PhysicalHoldAuthority()
    private var pointerToken: PhysicalPTTHoldToken?
    private var rightOptionToken: PhysicalPTTHoldToken?
    private var lifecycleCancellables: Set<AnyCancellable> = []

    init(preferenceDefaults: UserDefaults = .standard) {
        self.preferenceDefaults = preferenceDefaults
        lastAgentStore = LastAgentSelectionHintStore(defaults: preferenceDefaults)
        let restoredPreferences = VoicePreferencePolicy.restore(from: preferenceDefaults)
        origin = preferenceDefaults.string(forKey: "gatewayOrigin") ?? "http://localhost:43120"
        mode = restoredPreferences.mode
        voice = restoredPreferences.voice
        simulatorMode = ProcessInfo.processInfo.arguments.contains("--fake-voice")
        rightOptionMonitor = RightOptionPTTMonitor()
        let transport: VoiceTransport
        if simulatorMode {
            gatewayTransport = nil
            transport = SimulatorVoiceTransport()
        } else {
            let gatewayTransport = GatewayVoiceTransport()
            self.gatewayTransport = gatewayTransport
            transport = gatewayTransport
        }
        coordinator = VoiceSessionCoordinator(transport: transport)
        coordinator.didChange = { [weak self] in
            guard let self else { return }
            if coordinator.activeGeneration == nil {
                rightOptionMonitor.cancelActiveHold()
                physicalHolds.invalidate()
                pointerToken = nil
                rightOptionToken = nil
            } else if coordinator.mediaConnectionState != .connected {
                rightOptionMonitor.invalidateActiveHoldWithoutAction()
                physicalHolds.invalidate()
                pointerToken = nil
                rightOptionToken = nil
            }
            if coordinator.explicitReconnectRequired {
                wantsAutomaticConnection = false
                automaticConnectionTask?.cancel()
            }
            let lostConnection = wasConnected && !connected
            wasConnected = connected
            restoreLastAgentIfEligible()
            objectWillChange.send()
            if let epoch = coordinator.closureRecoveryEpoch {
                wantsAutomaticConnection = false
                automaticConnectionTask?.cancel()
                scheduleClosureRecovery(epoch: epoch)
            }
            if lostConnection && coordinator.phase == .disconnected && wantsAutomaticConnection &&
                !coordinator.explicitReconnectRequired {
                scheduleAutomaticConnection()
            }
        }
        rightOptionMonitor.install(
            activeGeneration: { [weak self] in
                guard let self, live, coordinator.activeMode == .ptt else { return nil }
                return coordinator.activeGeneration
            },
            perform: { [weak self] action in self?.handleRightOption(action) }
        )
        gatewayTransport?.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &lifecycleCancellables)
        installProcessLifecycleObservers()
        if simulatorMode {
            origin = "https://offline.invalid"
            pairingToken = String(repeating: "a", count: 32)
            Task { [weak self] in await self?.connect() }
        } else {
            coordinator.setOutputGain(UserDefaults.standard.object(forKey: "replyVolume") as? Double ?? 1)
            coordinator.setIdleTimeoutMinutes(UserDefaults.standard.object(forKey: "idleTimeoutMinutes") as? Int ?? 5)
            scheduleAutomaticConnection()
        }
    }

    var connected: Bool { coordinator.phase != .disconnected }
    var active: Bool {
        switch coordinator.phase {
        case .starting, .active, .stopping, .uncertain: true
        case .disconnected, .ready: false
        }
    }
    var selected: AgentTarget? { coordinator.selected }
    var contextTarget: AgentTarget? { coordinator.activeTarget ?? coordinator.selected }
    var live: Bool {
        if case .active = coordinator.phase { return true }
        return false
    }
    var menuTitle: String { contextTarget?.displayName ?? "Pi Voice" }
    var compactState: String {
        if !connected { return busy ? "Connecting…" : "Disconnected" }
        switch coordinator.phase {
        case .disconnected: return "Disconnected"
        case .ready:
            if coordinator.lastEndGeneration != nil && !coordinator.lastEndConfirmed { return "Ended · usage unknown" }
            return selected == nil ? "Choose agent" : "Ready"
        case .starting: return "Starting…"
        case .stopping: return "Ending…"
        case .uncertain: return "Needs attention"
        case .active:
            if coordinator.activeMode == .continuous {
                return coordinator.continuousMicrophoneMuted ? "Muted" : "Listening"
            }
            if coordinator.pttHeld { return "Listening" }
            if coordinator.pttFinishing { return "Working" }
            return "Hold Right Option"
        }
    }
    var gatewayDisplay: String {
        guard let url = URL(string: origin), let gateway = try? GatewayConfiguration(baseURL: url) else { return origin }
        return gateway.origin
    }
    var closureStatusCheckAvailable: Bool {
        coordinator.closureRecoveryEpoch != nil && coordinator.activeGeneration != nil && !coordinator.hasUnknownStartAllocation
    }
    var closureStatusGuidance: String {
        if coordinator.hasUnknownStartAllocation {
            return "Startup allocation is unknown and no exact generation was returned. Local media is off. Do not start another conversation."
        }
        if closureStatusCheckAvailable {
            return "Local media is off and provider closure is unconfirmed. Check status queries only the retained generation; it never reconnects or starts voice."
        }
        return "Local media is off. Provider closure remains unconfirmed."
    }
    var microphoneLevel: Double { gatewayTransport?.microphoneLevel ?? 0 }
    var playbackLevel: Double { gatewayTransport?.playbackLevel ?? 0 }
    var microphoneMeterActive: Bool { gatewayTransport?.microphoneMeterActive ?? false }
    var playbackMeterActive: Bool { gatewayTransport?.playbackMeterActive ?? false }
    var microphoneSymbol: String {
        if coordinator.activeMode == .continuous, live, !coordinator.continuousMicrophoneMuted { return "mic.fill" }
        if coordinator.pttHeld { return "waveform" }
        return "mic.slash"
    }
    var status: String {
        switch coordinator.phase {
        case .disconnected: busy ? "Connecting…" : (savedDeviceAvailable ? "Connection unavailable" : "Connect in Settings")
        case .ready: coordinator.lastEndGeneration != nil && !coordinator.lastEndConfirmed
            ? "Microphone off · previous provider closure is unconfirmed"
            : "Ready — microphone and billing are off"
        case .starting: "Starting voice — permission and billing may begin"
        case .active(let authority): "Liaison live · hard stop \(authority.hardDeadline.formatted(date: .omitted, time: .shortened))"
        case .stopping: "Stopping…"
        case .uncertain(let message): message
        }
    }

    private func scheduleClosureRecovery(epoch: UInt64) {
        guard !simulatorMode, !systemInactive, closureRecoveryTask == nil,
              coordinator.hasProviderClosureRecoveryScope(epoch: epoch) else { return }
        if closureRecoveryCampaignEpoch != epoch {
            closureRecoveryCampaignEpoch = epoch
            closureRecoveryStartedAt = .now
        }
        guard let campaignStart = closureRecoveryStartedAt else { return }
        let taskID = UUID()
        closureRecoveryTaskID = taskID
        closureRecoveryTask = Task { [weak self] in
            defer {
                if self?.closureRecoveryTaskID == taskID {
                    self?.closureRecoveryTask = nil
                    self?.closureRecoveryTaskID = nil
                }
            }
            while !Task.isCancelled {
                guard let self, !systemInactive,
                      coordinator.hasProviderClosureRecoveryScope(epoch: epoch),
                      let offset = closureRecoveryBudget.claimDeadlineOffsetSeconds(epoch: epoch) else { return }
                let deadline = campaignStart.advanced(by: .seconds(offset))
                if ContinuousClock.now < deadline { try? await Task.sleep(until: deadline) }
                guard !Task.isCancelled, !systemInactive,
                      coordinator.mayCheckProviderClosure(epoch: epoch) else { return }
                do {
                    if try await coordinator.checkProviderClosure(epoch: epoch) { return }
                } catch {
                    guard coordinator.hasProviderClosureRecoveryScope(epoch: epoch) else { return }
                    formError = error.localizedDescription
                }
            }
        }
    }

    private func scheduleAutomaticConnection() {
        guard !simulatorMode, !systemInactive, wantsAutomaticConnection,
              !coordinator.explicitReconnectRequired, automaticConnectionTask == nil else { return }
        automaticConnectionTask = Task { [weak self] in
            guard let self else { return }
            defer { automaticConnectionTask = nil }
            // A failed in-flight Start may still be unwinding after socket loss.
            for _ in 0..<10 where busy {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            guard !busy, coordinator.phase == .disconnected,
                  let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            do { savedDeviceAvailable = try coordinator.hasSavedDevice(origin: url) }
            catch { formError = error.localizedDescription; return }
            guard savedDeviceAvailable else { return } // First pairing is always explicit.
            let expectedOrigin = origin
            lastAgentRestoration.begin(after: coordinator.rosterRevision)
            busy = true
            defer { busy = false }
            let connected = await AutomaticConnectionRetry.run(
                shouldContinue: { [weak self] in
                    guard let self else { return false }
                    return !systemInactive && wantsAutomaticConnection &&
                        !coordinator.explicitReconnectRequired && origin == expectedOrigin &&
                        coordinator.phase == .disconnected
                },
                reconnect: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await coordinator.reconnectSavedDevice(origin: url)
                },
                shouldRetry: { [weak self] error in
                    guard let self else { return false }
                    savedDeviceAvailable = (try? coordinator.hasSavedDevice(origin: url)) ?? false
                    return savedDeviceAvailable && gatewayTransport?.mayRetryConnection(error) == true
                },
                reportFailure: { [weak self] error in self?.formError = error.localizedDescription },
                sleep: { try await Task.sleep(for: $0) }
            )
            guard connected else { return }
            formError = nil
            if let canonicalOrigin = try? GatewayConfiguration(baseURL: url).origin {
                UserDefaults.standard.set(canonicalOrigin, forKey: "gatewayOrigin")
            }
            // Automatic connection renews authorization only; it never starts voice,
            // requests microphone access, or creates a provider session.
        }
    }

    func connect() async {
        guard !busy else { return }
        wantsAutomaticConnection = true
        formError = nil
        guard let token = PairingFormPolicy.normalizedToken(pairingToken) else {
            formError = "Enter the one-use pairing token."
            return
        }
        busy = true
        pairingToken = ""
        defer { busy = false }
        do {
            guard let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw VoiceFailure.invalidOrigin
            }
            let host = String(ProcessInfo.processInfo.hostName.prefix(56))
            lastAgentRestoration.begin(after: coordinator.rosterRevision)
            try await coordinator.connect(
                origin: url,
                pairingToken: token,
                deviceName: "Pi Voice — \(host)"
            )
            savedDeviceAvailable = true
            UserDefaults.standard.set(try GatewayConfiguration(baseURL: url).origin, forKey: "gatewayOrigin")
        } catch {
            formError = error.localizedDescription
        }
    }

    func checkProviderStatus() async {
        guard !busy, let epoch = coordinator.closureRecoveryEpoch,
              coordinator.hasProviderClosureRecoveryScope(epoch: epoch) else { return }
        busy = true
        formError = nil
        closureStatusMessage = nil
        wantsAutomaticConnection = false
        automaticConnectionTask?.cancel()
        defer { busy = false }
        do {
            if try await coordinator.checkProviderClosure(epoch: epoch) {
                closureStatusMessage = "Provider closure was confirmed. Voice was not restarted."
            } else if coordinator.hasProviderClosureRecoveryScope(epoch: epoch) {
                closureStatusMessage = "No exact closure receipt is available yet. Authority remains retained; nothing was restarted or replayed."
            }
        } catch {
            guard coordinator.hasProviderClosureRecoveryScope(epoch: epoch) else { return }
            closureStatusMessage = "The exact status check failed. Authority remains retained; nothing was restarted or replayed."
            formError = error.localizedDescription
        }
    }

    func reconnect() async {
        guard !busy else { return }
        closureStatusMessage = nil
        wantsAutomaticConnection = true
        busy = true
        formError = nil
        defer { busy = false }
        do {
            guard let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw VoiceFailure.invalidOrigin
            }
            lastAgentRestoration.begin(after: coordinator.rosterRevision)
            try await coordinator.reconnectSavedDevice(origin: url)
            savedDeviceAvailable = true
            UserDefaults.standard.set(try GatewayConfiguration(baseURL: url).origin, forKey: "gatewayOrigin")
        } catch {
            formError = error.localizedDescription
        }
    }

    func forgetOnThisMac() async {
        guard !busy else { return }
        wantsAutomaticConnection = false
        automaticConnectionTask?.cancel()
        busy = true
        formError = nil
        defer { busy = false }
        do {
            guard let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw VoiceFailure.invalidOrigin
            }
            if let canonical = try? GatewayConfiguration(baseURL: url).origin {
                lastAgentStore.clear(forOrigin: canonical)
            }
            lastAgentRestoration.cancel()
            try await coordinator.forgetSavedDevice(origin: url)
            savedDeviceAvailable = false
        } catch {
            formError = error.localizedDescription
        }
    }

    private func restoreLastAgentIfEligible() {
        guard let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)),
              let canonical = try? GatewayConfiguration(baseURL: url).origin,
              let candidate = lastAgentRestoration.candidate(
                hint: lastAgentStore.load(forOrigin: canonical),
                origin: canonical,
                phase: coordinator.phase,
                rosterConnected: coordinator.rosterConnected,
                rosterRevision: coordinator.rosterRevision,
                agents: coordinator.agents,
                selected: coordinator.selected
              ) else { return }
        try? coordinator.select(candidate)
    }

    func select(identityKey: String) {
        guard !busy, coordinator.phase == .ready || live,
              let target = coordinator.agents.first(where: { $0.identityKey == identityKey }),
              target.identityKey != selected?.identityKey else { return }
        let restart = live
        let oldGeneration = coordinator.activeGeneration
        if let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)),
           let canonical = try? GatewayConfiguration(baseURL: url).origin {
            try? lastAgentStore.save(origin: canonical, agentID: target.id)
        }
        lastAgentRestoration.cancel()
        let nextMode = mode, nextVoice = voice
        busy = true
        formError = nil
        Task {
            defer { busy = false }
            do {
                if restart {
                    await coordinator.stop()
                    guard coordinator.lastEndConfirmed, coordinator.lastEndGeneration == oldGeneration else {
                        formError = coordinator.lastError ?? "Provider closure is unconfirmed. The new conversation was not started."
                        return
                    }
                }
                guard let fresh = coordinator.agents.first(where: { $0.identityKey == target.identityKey }) else { throw VoiceFailure.staleTarget }
                try coordinator.select(fresh)
                if restart { try await coordinator.start(mode: nextMode, voice: nextVoice) }
            } catch { formError = error.localizedDescription }
        }
    }

    func setOutputGain(_ gain: Double) {
        coordinator.setOutputGain(gain)
        UserDefaults.standard.set(coordinator.outputGain, forKey: "replyVolume")
    }
    func setIdleTimeoutMinutes(_ minutes: Int) {
        coordinator.setIdleTimeoutMinutes(minutes)
        UserDefaults.standard.set(coordinator.idleTimeoutMinutes, forKey: "idleTimeoutMinutes")
    }
    func refreshAudioRoute() { audioRoute = AudioRouteInspector.current() }

    func start() async {
        guard !busy, selected != nil else { return }
        closureStatusMessage = nil
        busy = true
        formError = nil
        defer { busy = false }
        do { try await coordinator.start(mode: mode, voice: voice) }
        catch { formError = error.localizedDescription }
    }

    func stop() async {
        busy = true
        await coordinator.stop()
        busy = false
    }

    func toggleMute() {
        do { try coordinator.setUserMuted(!coordinator.userMuted) }
        catch { formError = error.localizedDescription }
    }

    func toggleContinuousMute() { toggleMute() }

    func beginPointerHold() {
        guard pointerToken == nil, coordinator.activeMode == .ptt,
              let generation = coordinator.activeGeneration else { return }
        let result = physicalHolds.press(.pointer, generation: generation)
        pointerToken = result.token
        applyPhysicalAction(result.action)
    }

    func endPointerHold() {
        guard let token = pointerToken else { return }
        pointerToken = nil
        applyPhysicalAction(physicalHolds.release(token))
    }

    func applicationResigned() {
        rightOptionMonitor.handleApplicationResign()
        cancelPointerInput()
    }

    func cancelPointerInput() {
        guard let token = pointerToken else { return }
        pointerToken = nil
        applyPhysicalAction(physicalHolds.cancel(token))
    }

    func safetyCancelAllPhysicalInput() {
        rightOptionMonitor.cancelActiveHold()
        guard coordinator.activeMode == .ptt, let generation = coordinator.activeGeneration else {
            physicalHolds.invalidate()
            pointerToken = nil
            rightOptionToken = nil
            return
        }
        pointerToken = nil
        rightOptionToken = nil
        applyPhysicalAction(physicalHolds.cancelAll(generation: generation))
    }

    func handleRightOption(_ action: GlobalOptionGestureAction) {
        let generation: String
        switch action {
        case .begin(let pinned), .end(let pinned, _): generation = pinned
        }
        guard live, coordinator.activeGeneration == generation, coordinator.activeMode == .ptt else { return }
        switch action {
        case .begin:
            let result = physicalHolds.press(.rightOption, generation: generation)
            rightOptionToken = result.token
            applyPhysicalAction(result.action)
        case .end(_, let cancel):
            if cancel {
                rightOptionToken = nil
                applyPhysicalAction(physicalHolds.cancelAll(generation: generation))
            } else if let token = rightOptionToken {
                rightOptionToken = nil
                applyPhysicalAction(physicalHolds.release(token))
            }
        }
    }

    private func applyPhysicalAction(_ action: PhysicalPTTAction?) {
        guard let action else { return }
        let generation: String
        switch action {
        case .begin(let pinned), .end(let pinned, _): generation = pinned
        }
        guard live, coordinator.activeGeneration == generation, coordinator.activeMode == .ptt else {
            physicalHolds.invalidate()
            rightOptionToken = nil
            return
        }
        do {
            switch action {
            case .begin: try coordinator.beginPushToTalkFromHardwareEvent()
            case .end(_, let cancel): try coordinator.endPushToTalkFromHardwareEvent(cancel: cancel)
            }
        } catch {
            physicalHolds.invalidate()
            rightOptionToken = nil
            formError = error.localizedDescription
        }
    }
    func terminateHelper() {
        safetyCancelAllPhysicalInput()
        rightOptionMonitor.remove()
        coordinator.abandonLocally()
    }

    private func systemBecameInactive() {
        systemInactive = true
        automaticConnectionTask?.cancel()
        if let epoch = coordinator.closureRecoveryEpoch {
            coordinator.cancelProviderClosureCheck(epoch: epoch)
        }
        closureRecoveryTask?.cancel()
        closureRecoveryTask = nil
        closureRecoveryTaskID = nil
        rightOptionMonitor.invalidateActiveHoldWithoutAction()
        physicalHolds.invalidate()
        pointerToken = nil
        rightOptionToken = nil
        let pendingStart = coordinator.isStartInFlight
        if pendingStart { coordinator.interruptPendingStart() }
        if coordinator.activeGeneration != nil {
            coordinator.retainAuthorityAfterConnectionLoss(
                "System sleep or lock gated local media. Provider closure remains unconfirmed."
            )
        } else if !pendingStart {
            coordinator.abandonLocally()
        }
    }

    private func installProcessLifecycleObservers() {
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.applicationResigned() }
            .store(in: &lifecycleCancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.terminateHelper() }
            .store(in: &lifecycleCancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification,
        ] {
            workspace.publisher(for: name)
                .sink { [weak self] _ in self?.systemBecameInactive() }
                .store(in: &lifecycleCancellables)
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            workspace.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self else { return }
                    systemInactive = false
                    let pending = automaticConnectionTask
                    Task { [weak self] in
                        await pending?.value
                        guard let self, !systemInactive else { return }
                        if let epoch = coordinator.closureRecoveryEpoch {
                            scheduleClosureRecovery(epoch: epoch)
                        } else {
                            scheduleAutomaticConnection() // Authorization only, never voice or microphone.
                        }
                    }
                }
                .store(in: &lifecycleCancellables)
        }
    }
}

extension AgentTarget {
    var identityKey: String { "\(id)\u{0}\(endpointEpoch)" }
}

struct HelperMenuLabel: View {
    @ObservedObject var model: VoiceModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: model.microphoneSymbol)
            if model.active {
                MenuAudioLevel(icon: "mic.fill", level: model.microphoneLevel, label: "Mic", color: .green)
                MenuAudioLevel(icon: "speaker.wave.1.fill", level: model.playbackLevel, label: "Pi audio", color: .blue)
            }
            Text(model.menuTitle)
        }
    }
}

private struct MenuAudioLevel: View {
    let icon: String
    let level: Double
    let label: String
    let color: Color

    var body: some View {
        let boundedLevel = min(1, max(0, level))
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .frame(width: 9)
            ZStack(alignment: .bottom) {
                Capsule().fill(.quaternary)
                if boundedLevel > 0 {
                    Capsule()
                        .fill(color)
                        .frame(height: max(1, 10 * boundedLevel))
                }
            }
            .frame(width: 3, height: 10)
        }
        .frame(width: 14)
        .accessibilityLabel("\(label) level \(Int((boundedLevel * 100).rounded())) percent")
    }
}

private struct AgentSearchPicker: View {
    @ObservedObject var model: VoiceModel
    let label: (AgentTarget) -> String
    @State private var showing = false
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [AgentTarget] {
        model.coordinator.agents.filter { query.isEmpty || label($0).localizedCaseInsensitiveContains(query) }
    }
    private var enterTarget: AgentTarget? {
        if query.isEmpty, let selected = model.selected,
           let current = matches.first(where: { $0.identityKey == selected.identityKey }) { return current }
        return matches.first
    }
    private func choose(_ target: AgentTarget) {
        showing = false
        model.select(identityKey: target.identityKey)
    }
    var body: some View {
        Button {
            query = ""
            showing.toggle()
        } label: {
            HStack {
                Text(model.selected.map(label) ?? "Choose agent…").lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(model.busy || !(model.coordinator.phase == .ready || model.live))
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Filter agents", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if let target = enterTarget { choose(target) } }
                if matches.isEmpty { Text("No matching agents").foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(matches) { target in
                            Button { choose(target) } label: {
                                Text(label(target)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                            .background(target.identityKey == enterTarget?.identityKey ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            .padding(12)
            .frame(width: 300)
            .onAppear { focused = true }
        }
    }
}

struct VoiceHelperMenu: View {
    private enum PairingField: Hashable { case origin, token }

    @ObservedObject var model: VoiceModel
    @ObservedObject var rightOptionMonitor: RightOptionPTTMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointerHeld = false
    @State private var showingForgetConfirmation = false
    @State private var showingSettings = false
    @State private var popoverVisible = false
    @State private var pointerOffset = CGSize.zero
    @FocusState private var pairingField: PairingField?

    var body: some View {
        ZStack {
            Color.voiceBackground

            VoiceWaveformField(
                isRunning: popoverVisible && !reduceMotion,
                levels: visualLevels,
                pointerOffset: reduceMotion ? .zero : pointerOffset
            )

            VStack(alignment: .leading, spacing: 14) {
                statusHeader

                if model.connected { connectedControls }
                else { disconnectedControls }

                if let message = model.closureStatusMessage {
                    Text(message)
                        .font(.voiceFont(12, weight: .bold))
                        .foregroundStyle(Color.voiceSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .voiceGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if !model.busy, let error = model.formError ?? model.coordinator.lastError {
                    Text(error)
                        .font(.voiceFont(12))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .voiceGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                footer
                if showingSettings { settingsPanel }
            }
            .padding(16)

            WindowVisibilityReader { visible in
                popoverVisible = visible
                if !visible { pointerOffset = .zero }
            }
            .frame(width: 0, height: 0)
        }
        .frame(width: 370)
        .foregroundStyle(Color.voiceSecondary)
        .preferredColorScheme(.dark)
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard !reduceMotion, popoverVisible else {
                pointerOffset = .zero
                return
            }
            switch phase {
            case .active(let location):
                pointerOffset = CGSize(
                    width: min(max((location.x / 370 - 0.5) * 10, -5), 5),
                    height: min(max((location.y / 520 - 0.5) * 7, -3.5), 3.5)
                )
            case .ended:
                pointerOffset = .zero
            }
        }
        .onDisappear {
            pointerHeld = false
            pointerOffset = .zero
            model.cancelPointerInput()
        }
        .confirmationDialog(
            "Forget this gateway on this Mac?",
            isPresented: $showingForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget on this Mac", role: .destructive) { Task { await model.forgetOnThisMac() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes only this gateway’s credential from this Mac. Server authorization remains until an administrator revokes it or it expires.")
        }
    }

    private var visualLevels: VoiceVisualLevels {
        let generation: String?
        if case .active = model.coordinator.phase,
           model.coordinator.mediaConnectionState == .connected {
            generation = model.coordinator.activeGeneration
        } else {
            generation = nil
        }
        return VoiceVisualLevels(
            generation: generation,
            outgoingLevel: model.microphoneLevel,
            playbackLevel: model.playbackLevel,
            outgoingAuthorized: generation != nil && model.microphoneMeterActive,
            playbackAuthorized: generation != nil && model.playbackMeterActive
        )
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(phaseTitle)
                        .font(.voiceFont(12, weight: .bold))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .voiceGlass(in: Capsule())

                Spacer()
                if model.simulatorMode {
                    Text("FAKE")
                        .font(.voiceFont(10, weight: .bold))
                        .foregroundStyle(Color.voiceBackground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.voiceForeground, in: Capsule())
                }
            }

            Text(model.contextTarget?.displayName ?? phaseTitle)
                .font(.voiceFont(27, weight: .thin))
                .foregroundStyle(Color.voiceForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(model.status)
                .font(.voiceFont(12))
                .foregroundStyle(Color.voiceForeground.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var phaseTitle: String {
        switch model.coordinator.phase {
        case .uncertain: return "Needs attention"
        case .stopping: return "Stopping"
        case .starting: return "Starting"
        case .disconnected: return model.busy ? "Connecting" : "Disconnected"
        case .ready:
            return model.coordinator.lastEndGeneration != nil && !model.coordinator.lastEndConfirmed
                ? "Ended · usage unknown"
                : "Ready"
        case .active:
            switch model.coordinator.mediaConnectionState {
            case .unknown: return "Connection unknown"
            case .reconnecting: return "Reconnecting"
            case .connected:
                if model.coordinator.userMuted { return "Muted" }
                if model.coordinator.activeMode == .ptt {
                    if model.coordinator.pttHeld { return "Listening" }
                    if model.coordinator.pttFinishing { return "Working" }
                    return "Hold Right Option"
                }
                return "Listening"
            }
        }
    }

    private var statusColor: Color {
        switch model.coordinator.phase {
        case .uncertain: return .orange
        case .stopping, .starting: return .voiceForeground
        case .active:
            switch model.coordinator.mediaConnectionState {
            case .unknown: return .orange
            case .reconnecting: return .yellow
            case .connected: return model.coordinator.userMuted ? .orange : .green
            }
        case .ready: return .voiceForeground
        case .disconnected: return .secondary
        }
    }

    private var disconnectedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.busy ? "Connecting…" : (model.savedDeviceAvailable
                ? "The saved connection could not be restored automatically."
                : "Connect this Mac from Settings."))
                .font(.voiceFont(12))
                .foregroundStyle(Color.voiceForeground.opacity(0.76))

            if model.savedDeviceAvailable && !model.busy {
                VoiceButton(prominent: true) {
                    pairingField = nil
                    Task {
                        await Task.yield()
                        await model.reconnect()
                    }
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                        .font(.voiceFont(13, weight: .bold))
                }
                .disabled(model.busy)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .voiceGlass(in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var pairingSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Gateway origin", text: $model.origin)
                .textFieldStyle(.roundedBorder)
                .focused($pairingField, equals: .origin)
            SecureField("One-use pairing token", text: $model.pairingToken)
                .textFieldStyle(.roundedBorder)
                .focused($pairingField, equals: .token)
                .onSubmit { submitPairing() }
            Button("Pair and save this Mac") { submitPairing() }
                .disabled(PairingFormPolicy.buttonDisabled(isBusy: model.busy))
            Text("The device credential stays in this Mac’s Keychain.")
                .font(.voiceFont(11))
                .foregroundStyle(Color.voiceForeground.opacity(0.68))
        }
    }

    private func submitPairing() {
        pairingField = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task {
            await Task.yield()
            await model.connect()
        }
    }

    private var connectedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            targetCard

            if !model.active { startControls }
            else { activeControls }
        }
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Agent")
                .font(.voiceFont(10, weight: .bold))
                .foregroundStyle(Color.voiceForeground.opacity(0.66))
            AgentSearchPicker(model: model, label: agentLabel)
            if let target = model.contextTarget {
                Text(URL(fileURLWithPath: target.cwd).lastPathComponent)
                    .font(.voiceFont(11))
                    .foregroundStyle(Color.voiceForeground.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .voiceGlass(in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var startControls: some View {
        HStack {
            Picker("", selection: $model.mode) {
                Text("Push to talk").tag(VoiceMode.ptt)
                Text("Continuous").tag(VoiceMode.continuous)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 210)

            Spacer()
            VoiceButton(prominent: true) {
                Task { await model.start() }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.voiceFont(13, weight: .bold))
                    .padding(.horizontal, 4)
            }
            .disabled(model.busy || model.selected == nil)
        }
    }

    private var activeControls: some View {
        VStack(spacing: 11) {
            if case .uncertain = model.coordinator.phase { closureRecoveryControls }
            if model.coordinator.activeMode == .ptt { talkSurface }

            HStack(spacing: 14) {
                compactControl(
                    title: model.coordinator.userMuted ? "Unmute" : "Mute",
                    symbol: model.coordinator.userMuted ? "mic.slash.fill" : "mic.fill",
                    prominent: false,
                    disabled: model.busy || !model.live
                ) { model.toggleMute() }

                Spacer()

                compactControl(
                    title: endControlBlocked ? "Blocked" : "End",
                    symbol: endControlBlocked ? "exclamationmark.shield.fill" : "phone.down.fill",
                    prominent: true,
                    disabled: model.busy || endControlBlocked
                ) { Task { await model.stop() } }
            }

            captionThread
        }
    }

    private var closureRecoveryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.closureStatusGuidance)
                .font(.voiceFont(11))
                .foregroundStyle(Color.voiceSecondary.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
            if model.closureStatusCheckAvailable {
                VoiceButton(prominent: false) {
                    Task { await model.checkProviderStatus() }
                } label: {
                    Label(model.busy ? "Checking…" : "Check status", systemImage: "checkmark.shield")
                        .font(.voiceFont(12, weight: .bold))
                }
                .disabled(model.busy)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .voiceGlass(in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func compactControl(
        title: String,
        symbol: String,
        prominent: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 4) {
            VoiceButton(prominent: prominent, action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 28)
            }
            .disabled(disabled)
            Text(title)
                .font(.voiceFont(10, weight: .bold))
                .foregroundStyle(Color.voiceForeground)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var captionThread: some View {
        let segments = model.coordinator.captionThread
        if !segments.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    captionRow(
                        segment,
                        age: segments.count - index - 1,
                        isNewest: index == segments.count - 1
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func captionRow(
        _ segment: VoiceCaptionSegment,
        age: Int,
        isNewest: Bool
    ) -> some View {
        let color: Color = segment.speaker == .user ? .voiceUser : .voiceAgent
        let opacity = isNewest ? 1.0 : (age == 1 ? 0.88 : 0.78)
        let role = segment.speaker == .user ? "You" : "Pi"
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(segment.isCurrent ? 1 : 0)
                .accessibilityHidden(true)
            Text(segment.text)
                .font(.voiceFont(isNewest ? 14 : 13))
                .foregroundStyle(color)
                .lineSpacing(2)
                .lineLimit(isNewest ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(role)\(segment.isCurrent ? ", current" : ""): \(segment.text)")
    }

    private func agentLabel(_ target: AgentTarget) -> String {
        let sameName = model.coordinator.agents.filter { $0.displayName == target.displayName }
        guard sameName.count > 1 else { return target.displayName }

        let workspace = URL(fileURLWithPath: target.cwd).lastPathComponent
        let sameWorkspace = sameName.filter {
            URL(fileURLWithPath: $0.cwd).lastPathComponent == workspace
        }
        guard sameWorkspace.count > 1 else { return "\(target.displayName) — \(workspace)" }

        let location = target.location ?? "gateway"
        let sameLocation = sameWorkspace.filter { ($0.location ?? "gateway") == location }
        guard sameLocation.count > 1 else {
            return "\(target.displayName) — \(workspace) — \(location)"
        }
        return "\(target.displayName) — \(workspace) — \(target.shortID)"
    }

    private var talkSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(model.coordinator.pttHeld ? Color.voiceForeground.opacity(0.9) : Color.voiceAccent.opacity(0.45))
            HStack(spacing: 10) {
                Image(systemName: model.coordinator.pttHeld ? "waveform" : "option")
                    .font(.system(size: 19, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(pttSurfaceTitle)
                        .font(.voiceFont(13, weight: .bold))
                    Text("Pointer fallback · Right Option remains authoritative")
                        .font(.voiceFont(10))
                        .opacity(0.72)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .foregroundStyle(model.coordinator.pttHeld ? Color.voiceBackground : Color.voiceSecondary)
        }
        .frame(height: 58)
        .opacity(pttSurfaceEnabled ? 1 : 0.58)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pttSurfaceEnabled, !pointerHeld else { return }
                pointerHeld = true
                model.beginPointerHold()
            }
            .onEnded { _ in
                guard pointerHeld else { return }
                pointerHeld = false
                model.endPointerHold()
            })
    }

    private var endControlBlocked: Bool {
        model.coordinator.hasUnknownStartAllocation || model.coordinator.activeGeneration == nil
    }

    private var pttSurfaceEnabled: Bool {
        model.live
            && !model.busy
            && model.coordinator.mediaConnectionState == .connected
            && !model.coordinator.userMuted
            && !model.coordinator.pttFinishing
    }

    private var pttSurfaceTitle: String {
        if model.coordinator.userMuted { return "Unmute before talking" }
        if model.coordinator.mediaConnectionState == .reconnecting { return "Reconnecting…" }
        if model.coordinator.mediaConnectionState == .unknown { return "Connection unknown" }
        if model.coordinator.pttFinishing { return "Working…" }
        if model.coordinator.pttHeld { return "Release to send" }
        return "Hold to talk"
    }

    private var footer: some View {
        HStack {
            Button(showingSettings ? "Hide settings" : "Settings…") {
                model.refreshAudioRoute()
                showingSettings.toggle()
            }
            .buttonStyle(.plain)
            .font(.voiceFont(11, weight: .bold))
            .foregroundStyle(Color.voiceForeground.opacity(0.8))
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.voiceFont(11))
                .foregroundStyle(Color.voiceForeground.opacity(0.62))
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.connected { pairingSettings }

            Picker("Input", selection: $model.mode) {
                Text("Push to talk").tag(VoiceMode.ptt)
                Text("Continuous").tag(VoiceMode.continuous)
            }
            .disabled(model.active)
            Picker("Voice", selection: $model.voice) {
                ForEach(VoiceName.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .disabled(model.active)

            HStack {
                Text("Reply volume")
                Slider(
                    value: Binding(
                        get: { model.coordinator.outputGain },
                        set: { model.setOutputGain($0) }
                    ),
                    in: 0 ... 1,
                    step: 0.01
                )
                Text("\(Int((model.coordinator.outputGain * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }

            Stepper("Idle timeout: \(model.coordinator.idleTimeoutMinutes) min", value: Binding(
                get: { model.coordinator.idleTimeoutMinutes },
                set: { model.setIdleTimeoutMinutes($0) }
            ), in: 1 ... 30)
            Text("Applies to the next conversation. Safety ceiling: 2 hours; the session may end earlier.")
                .font(.voiceFont(11))
                .foregroundStyle(Color.voiceForeground.opacity(0.68))

            Text(model.audioRoute.summary)
                .font(.voiceFont(11))
                .foregroundStyle(Color.voiceForeground.opacity(0.68))
            if model.audioRoute.isLowRateBluetoothDuplex, let output = model.audioRoute.output {
                Text("Bluetooth duplex output is currently \(Int(output.sampleRate.rounded())) Hz on \(output.name). Slow, low-pitched playback observed on this route is under investigation; this is diagnostic, not a block.")
                    .font(.voiceFont(11))
                    .foregroundStyle(Color.orange)
            }

            rightOptionStatus

            if let target = model.contextTarget {
                DisclosureGroup("Connection details") {
                    Text("Gateway: \(model.gatewayDisplay)")
                    Text("ID: \(target.id)").textSelection(.enabled)
                    Text("Epoch: \(target.endpointEpoch)").textSelection(.enabled)
                    Text("Automatic Herdr focus is unavailable; the Agent picker is authoritative.")
                }
                .font(.voiceFont(11))
            }

            if model.connected {
                Button("Forget this Mac…", role: .destructive) { showingForgetConfirmation = true }
                    .disabled(
                        model.busy
                            || model.coordinator.hasUnknownStartAllocation
                            || model.coordinator.isStartInFlight
                    )
            }
        }
        .padding(13)
        .voiceGlass(in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    @ViewBuilder
    private var rightOptionStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: rightOptionMonitor.globalStatus == .ready ? "keyboard" : "exclamationmark.triangle")
            Text(rightOptionMonitor.globalStatus == .ready
                 ? (rightOptionMonitor.observedGlobalRightOption
                    ? "Right Option event observed globally"
                    : "Right Option registered — press hardware key 61 in another app to verify")
                 : rightOptionMonitor.globalStatus.label)
            Spacer()
            Button("Recheck") { rightOptionMonitor.recheckGlobalAccess() }
        }
        .font(.voiceFont(11))
        .foregroundStyle(rightOptionMonitor.globalStatus == .ready ? Color.voiceForeground.opacity(0.7) : Color.orange)

        if let settingsName = rightOptionMonitor.globalStatus.settingsName {
            Text("Check System Settings › Privacy & Security › \(settingsName), then Recheck. No access is requested automatically.")
                .font(.voiceFont(11))
                .foregroundStyle(Color.voiceForeground.opacity(0.68))
        }
    }
}
