import PiVoiceCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.voiceVisualLevels) private var voiceVisualLevels
    @State private var touchingPTT = false
    @State private var confirmingForget = false

    var body: some View {
        ZStack {
            Color.voiceBackground.ignoresSafeArea()
            WaveformParallax(enabled: visualMotionEnabled, amount: 6) {
                VoiceWaveformField(
                    isRunning: visualMotionEnabled,
                    levels: displayedVisualLevels
                )
            }
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    header
                    phaseSummary

                    if !model.connected {
                        pairingCard
                    } else if model.active {
                        liveControls
                    } else {
                        readyControls
                    }

                    feedback
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(Color.voiceForeground)
        .tint(.voiceForeground)
        .preferredColorScheme(.dark)
        .animation(.smooth(duration: 0.45), value: model.active)
        .animation(.snappy(duration: 0.25), value: model.coordinator.userMuted)
        .confirmationDialog("Forget this phone's local pairing?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget Local Pairing", role: .destructive) { Task { await model.forgetDevice() } }
        } message: {
            Text("This deletes only this phone's Keychain credential. Server authorization remains until local-owner revocation or expiry.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            statusPill
            Spacer(minLength: 8)

            if model.simulatorMode {
                Text("FAKE")
                    .font(.voiceFont(10, weight: .bold))
                    .foregroundStyle(Color.voiceBackground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.voiceForeground, in: Capsule())
                    .accessibilityIdentifier("fakeModeBadge")
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(phaseTitle)
                .font(.voiceFont(11, weight: .bold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .voiceGlass(in: Capsule())
    }

    private var phaseSummary: some View {
        VStack(spacing: 9) {
            Spacer(minLength: model.active ? 172 : 142)

            Text(phaseTitle)
                .font(.voiceFont(43, weight: .ultraLight))
                .tracking(-1.1)
                .multilineTextAlignment(.center)
                .contentTransition(.interpolate)

            Text(model.status)
                .font(.voiceFont(15))
                .foregroundStyle(Color.voiceForeground.opacity(0.76))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("connectionStatus")
        }
        .frame(maxWidth: .infinity)
    }

    private var phaseTitle: String {
        switch model.coordinator.phase {
        case .disconnected:
            return "Pair this phone"
        case .ready:
            return "Ready"
        case .starting:
            return "Connecting"
        case .active:
            switch model.coordinator.mediaConnectionState {
            case .connected:
                if model.coordinator.userMuted { return "Muted" }
                return model.coordinator.selected?.displayName ?? "Connected"
            case .reconnecting: return "Reconnecting"
            case .unknown: return "Connection unknown"
            }
        case .stopping:
            return "Stopping"
        case .uncertain:
            return "Needs attention"
        }
    }

    private var statusColor: Color {
        switch model.coordinator.phase {
        case .active:
            switch model.coordinator.mediaConnectionState {
            case .connected: return model.coordinator.userMuted ? .orange : .green
            case .reconnecting: return .yellow
            case .unknown: return .orange
            }
        case .starting, .stopping: return .yellow
        case .uncertain: return .orange
        case .ready: return .voiceForeground
        case .disconnected: return Color.voiceForeground.opacity(0.45)
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(model.hasStoredCredential && !model.repairPairing ? "Reconnect this phone" : "Pair this phone")
                .font(.voiceFont(18, weight: .bold))

            TextField("https://private-gateway.example", text: $model.originText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .textContentType(.URL)
                .accessibilityIdentifier("gatewayOriginField")
                .onChange(of: model.originText) { _, _ in model.originDidChange() }

            if model.repairPairing || !model.hasStoredCredential {
                SecureField("New one-use pairing token", text: $model.pairingToken)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("pairingTokenField")
            }

            HStack(spacing: 10) {
                let reconnecting = model.hasStoredCredential && !model.repairPairing
                VoiceButton(prominent: true, action: { Task { await model.connect() } }) {
                    Label(reconnecting ? "Reconnect" : "Pair", systemImage: "link")
                        .font(.voiceFont(13, weight: .bold))
                        .frame(height: 36)
                }
                .disabled(model.busy || model.originText.isEmpty || (!reconnecting && model.pairingToken.isEmpty))
                .accessibilityIdentifier("connectButton")

                Button("Forget Device", role: .destructive) { confirmingForget = true }
                    .buttonStyle(.bordered)
                    .disabled(model.busy || model.originText.isEmpty)
                    .accessibilityIdentifier("forgetDeviceButton")
            }

            if model.hasStoredCredential {
                Button(model.repairPairing ? "Use saved pairing" : "Re-pair with a new code") {
                    if model.repairPairing { model.useSavedPairing() } else { model.requestRepairPairing() }
                }
                .disabled(model.busy)
                .accessibilityIdentifier("repairPairingButton")
            }

            Text(model.hasStoredCredential && !model.repairPairing
                 ? "Reconnect uses only this phone's exact-origin Keychain credential. It cannot start voice, select an agent, open the microphone, or create a paid provider session."
                 : "A new one-use code is required only for first pair, expiry, revocation, or an explicit re-pair. The gateway root capability is never stored here.")
                .font(.voiceFont(11))
                .foregroundStyle(Color.voiceForeground.opacity(0.66))
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .voiceGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var readyControls: some View {
        VStack(spacing: 14) {
            VoiceGlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Picker("Exact endpoint", selection: Binding(
                        get: { model.coordinator.selected?.identityKey ?? "" },
                        set: { key in model.select(model.coordinator.agents.first { $0.identityKey == key }) }
                    )) {
                        Text("Agent").tag("")
                        ForEach(model.coordinator.agents) { agent in
                            Text(agent.displayName).tag(agent.identityKey)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.voiceFont(12, weight: .bold))
                    .lineLimit(1)
                    .frame(height: 40)
                    .padding(.horizontal, 3)
                    .voiceGlass(in: Capsule())
                    .disabled(model.active)
                    .accessibilityIdentifier("agentPicker")

                    Picker("Voice", selection: $model.voice) {
                        ForEach(VoiceName.allCases, id: \.self) { voice in
                            Text(voice.rawValue.capitalized).tag(voice)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.voiceFont(12, weight: .bold))
                    .lineLimit(1)
                    .frame(height: 40)
                    .padding(.horizontal, 3)
                    .voiceGlass(in: Capsule())

                    VoiceButton(prominent: true, action: { Task { await model.start() } }) {
                        Label("Start", systemImage: "play.fill")
                            .font(.voiceFont(13, weight: .bold))
                            .padding(.horizontal, 2)
                            .frame(height: 36)
                    }
                    .disabled(model.busy || model.coordinator.selected == nil)
                    .accessibilityIdentifier("startVoiceButton")
                }
            }

            Picker("Mode", selection: $model.mode) {
                Text("Continuous").tag(VoiceMode.continuous)
                Text("Push to talk").tag(VoiceMode.ptt)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            if let selected = model.coordinator.selected {
                Text("Selected: \(selected.displayName) · exact endpoint pinned on Start")
                    .font(.voiceFont(11))
                    .foregroundStyle(Color.voiceForeground.opacity(0.66))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var liveControls: some View {
        VStack(spacing: 16) {
            VoiceGlassGroup(spacing: 18) {
                HStack(spacing: 18) {
                    roundButton(
                        title: model.coordinator.userMuted ? "Unmute" : "Mute",
                        systemImage: model.coordinator.userMuted ? "mic.slash.fill" : "mic.fill",
                        enabled: model.mediaControlsEnabled,
                        identifier: "microphoneMuteButton"
                    ) {
                        model.setUserMuted(!model.coordinator.userMuted)
                    }

                    roundButton(
                        title: model.speakerphoneEnabled ? "Receiver" : "Speaker",
                        systemImage: model.speakerphoneEnabled ? "iphone" : "speaker.wave.2.fill",
                        enabled: model.mediaControlsEnabled && !model.simulatorMode,
                        identifier: "audioRouteButton"
                    ) {
                        model.setSpeakerphoneEnabled(!model.speakerphoneEnabled)
                    }

                    roundButton(title: "End", systemImage: "phone.down.fill", prominent: true, enabled: !model.busy, identifier: "stopVoiceButton") {
                        Task { await model.stop() }
                    }
                }
            }

            if model.mode == .ptt {
                pttSurface
            }

            captionThreadView

            if model.coordinator.closureRecoveryEpoch != nil {
                Button("Check provider closure") { Task { await model.retryClosureCheck() } }
                    .buttonStyle(.bordered)
                    .disabled(model.busy)
                    .accessibilityIdentifier("retryClosureCheckButton")
            }
        }
    }

    private func roundButton(
        title: String,
        systemImage: String,
        prominent: Bool = false,
        enabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 6) {
            VoiceButton(prominent: prominent, action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .disabled(!enabled)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .accessibilityLabel(title == "Mute" ? "Mute microphone" : title == "Unmute" ? "Unmute microphone" : title)
            .accessibilityIdentifier(identifier)

            Text(title)
                .font(.voiceFont(11, weight: .bold))
        }
        .frame(width: 66)
    }

    private var pttSurface: some View {
        HStack(spacing: 10) {
            Image(systemName: model.coordinator.pttHeld ? "waveform" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
            Text(!model.pttControlsEnabled
                 ? "Unavailable while audio reconnects"
                 : model.coordinator.pttHeld ? "Release to send" : "Hold to talk")
                .font(.voiceFont(14, weight: .bold))
        }
        .frame(maxWidth: 260, minHeight: 54)
        .foregroundStyle(model.coordinator.pttHeld ? Color.voiceBackground : Color.voiceForeground)
        .background(model.coordinator.pttHeld ? Color.voiceForeground : Color.voiceAccent.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(Color.voiceForeground.opacity(0.22)))
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard model.pttControlsEnabled, !touchingPTT else { return }
                touchingPTT = true
                let gestureEpoch = model.coordinator.pttGestureEpoch
                Task { await model.pressPTT(gestureEpoch: gestureEpoch) }
            }
            .onEnded { _ in
                guard touchingPTT else { return }
                touchingPTT = false
                Task { await model.releasePTT() }
            })
        .opacity(model.pttControlsEnabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pttSurface")
        .accessibilityLabel("Hold to talk, release to send")
        .accessibilityValue(model.pttControlsEnabled ? "Ready" : "Unavailable while audio reconnects")
    }

    @ViewBuilder
    private var captionThreadView: some View {
        let captions = model.coordinator.captionThread
        if !captions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(captions.enumerated()), id: \.offset) { offset, caption in
                    let age = captions.count - 1 - offset
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(caption.speaker.color)
                            .frame(width: 6, height: 6)
                            .opacity(caption.isCurrent ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(caption.text)
                            .font(.voiceFont(age == 0 ? 17 : 16))
                            .lineSpacing(3)
                            .lineLimit(age == 0 ? 4 : 2)
                            .accessibilityLabel(
                                "\(caption.speaker.title)\(caption.isCurrent ? ", current caption" : ""): \(caption.text)"
                            )
                            .accessibilityIdentifier(caption.speaker.accessibilityIdentifier)
                    }
                    .foregroundStyle(caption.speaker.color)
                    .opacity(caption.opacity(forAge: age))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = model.formError {
            Text(error)
                .foregroundStyle(Color.orange)
                .font(.voiceFont(11, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("formErrorText")
        }
        if let notice = model.notice {
            Text(notice)
                .foregroundStyle(Color.voiceForeground.opacity(0.74))
                .font(.voiceFont(11))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var visualMotionEnabled: Bool {
        scenePhase == .active && !reduceMotion
    }

    private var displayedVisualLevels: VoiceVisualLevels {
        guard visualMotionEnabled,
              case .active = model.coordinator.phase,
              model.coordinator.mediaConnectionState == .connected,
              let activeGeneration = model.coordinator.activeGeneration,
              voiceVisualLevels.generation == activeGeneration else {
            return .silent
        }

        let pttAllowsOutgoing = model.mode != .ptt || model.coordinator.pttHeld
        let outgoingAllowed = voiceVisualLevels.outgoingAuthorized
            && !model.coordinator.userMuted
            && pttAllowsOutgoing
        let playbackAllowed = voiceVisualLevels.playbackAuthorized
            && (model.mode != .ptt || !model.coordinator.pttHeld)

        return VoiceVisualLevels(
            generation: activeGeneration,
            outgoingLevel: outgoingAllowed ? voiceVisualLevels.outgoingLevel : 0,
            playbackLevel: playbackAllowed ? voiceVisualLevels.playbackLevel : 0,
            speakerActive: playbackAllowed && voiceVisualLevels.speakerActive,
            outgoingAuthorized: outgoingAllowed,
            playbackAuthorized: playbackAllowed
        )
    }
}

private extension VoiceCaptionSegment {
    func opacity(forAge age: Int) -> Double {
        switch age {
        case 0: 1
        case 1: 0.88
        default: 0.78
        }
    }
}

private extension VoiceCaptionSegment.Speaker {
    var color: Color {
        switch self {
        case .user: return .voiceUser
        case .agent: return .voiceAgent
        }
    }

    var title: String {
        switch self {
        case .user: return "You"
        case .agent: return "Pi"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .user: return "recentUserCaption"
        case .agent: return "recentPiCaption"
        }
    }
}
