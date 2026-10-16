import AppKit
import PiVoiceMacCore
import SwiftUI

extension Color {
    static let voiceBackground = Color(nsColor: .windowBackgroundColor)
    static let voiceAccent = Color.accentColor
    static let voiceForeground = Color.primary
    static let voiceSecondary = Color.secondary
    static let voiceUser = Color.blue
    static let voiceAgent = Color.teal
}

extension Font {
    static func voiceFont(_ size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Ephemeral presentation inputs from the existing meter pipeline. These levels
/// never start capture, infer audibility, persist data, or transport samples.
struct VoiceVisualLevels: Equatable {
    let generation: String?
    let outgoingLevel: Double
    let playbackLevel: Double
    let outgoingAuthorized: Bool
    let playbackAuthorized: Bool

    init(
        generation: String?,
        outgoingLevel: Double,
        playbackLevel: Double,
        outgoingAuthorized: Bool,
        playbackAuthorized: Bool
    ) {
        self.generation = generation
        self.outgoingLevel = Self.normalized(outgoingLevel)
        self.playbackLevel = Self.normalized(playbackLevel)
        self.outgoingAuthorized = outgoingAuthorized
        self.playbackAuthorized = playbackAuthorized
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

struct VoiceWaveformField: View {
    let isRunning: Bool
    let levels: VoiceVisualLevels
    let pointerOffset: CGSize

    @State private var outgoingEnvelope = VisualEnvelopeChannel()
    @State private var playbackEnvelope = VisualEnvelopeChannel()
    @State private var envelopeGeneration: String?

    var body: some View {
        Group {
            if isRunning {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    field(at: ProcessInfo.processInfo.systemUptime)
                }
            } else {
                field(at: 0)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onChange(of: levels, initial: true) { _, newValue in
            updateEnvelope(for: newValue)
        }
        .onChange(of: isRunning) { _, running in
            if running { updateEnvelope(for: levels) }
            else { clearEnvelope() }
        }
        .offset(pointerOffset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func field(at time: TimeInterval) -> some View {
        let envelope = VisualEnvelopeRenderSelection.select(
            isRunning: isRunning,
            levelGeneration: levels.generation,
            envelopeGeneration: envelopeGeneration,
            outgoingAuthorized: levels.outgoingAuthorized,
            playbackAuthorized: levels.playbackAuthorized,
            outgoingSample: outgoingEnvelope.value(at: time),
            playbackSample: playbackEnvelope.value(at: time)
        )
        return ZStack {
            activityGlow(at: time, envelope: envelope)
            waveformCanvas(at: time, envelope: envelope, indices: Array(0 ..< 8), rearLayer: true)
                .scaleEffect(1.07)
                .blur(radius: 10)
                .opacity(0.5)
            waveformCanvas(at: time, envelope: envelope, indices: [0, 2, 4, 6], rearLayer: false)
        }
    }

    private func activityGlow(at time: TimeInterval, envelope: VisualEnvelopeRenderSelection) -> some View {
        GeometryReader { geometry in
            let energy = envelope.outgoing * 0.44 + envelope.playback * 0.56
            ZStack {
                Circle()
                    .fill(Color.voiceUser.opacity(0.08 + envelope.outgoing * 0.12))
                    .frame(width: geometry.size.width * 0.72)
                    .offset(
                        x: -geometry.size.width * 0.24 + CGFloat(sin(time * 0.11)) * 12,
                        y: -geometry.size.height * 0.12
                    )
                Circle()
                    .fill(Color.voiceAgent.opacity(0.06 + envelope.playback * 0.15))
                    .frame(width: geometry.size.width * 0.68)
                    .offset(
                        x: geometry.size.width * 0.25 + CGFloat(cos(time * 0.095)) * 11,
                        y: geometry.size.height * 0.02
                    )
            }
            .scaleEffect(1 + CGFloat(energy) * 0.035)
            .blur(radius: 34)
        }
    }

    private func waveformCanvas(
        at time: TimeInterval,
        envelope: VisualEnvelopeRenderSelection,
        indices: [Int],
        rearLayer: Bool
    ) -> some View {
        Canvas { context, size in
            let energy = envelope.outgoing * 0.44 + envelope.playback * 0.56
            for index in indices {
                let isUserWave = index % 4 < 2
                let speakerLevel = isUserWave ? envelope.outgoing : envelope.playback
                var wave = Path()
                let phase = Double(index) * .pi * 2 / 8 + time * 0.09 + speakerLevel * 0.16
                let centerY = size.height * 0.37 + CGFloat(index - 4) * 6
                let baseAmplitude = size.height * 0.065
                let amplitude = baseAmplitude * (1 + CGFloat(energy) * 0.16 + CGFloat(speakerLevel) * 0.15)
                wave.move(to: CGPoint(x: -28, y: centerY))
                for step in 1 ... 96 {
                    let progress = CGFloat(step) / 96
                    let x = progress * (size.width + 56) - 28
                    let primary = sin(Double(progress) * .pi * 2 + phase) * Double(amplitude)
                    let secondary = sin(Double(progress) * .pi * 4.4 - phase * 0.62 + Double(index))
                        * Double(amplitude) * 0.16
                    let drift = cos(Double(progress) * .pi * 2.7 + time * 0.075 + Double(index)) * 5
                    wave.addLine(to: CGPoint(x: x, y: centerY + CGFloat(primary + secondary + drift)))
                }

                let speakerColor = isUserWave ? Color.voiceUser : Color.voiceAgent
                let idleColor = Color.voiceForeground.opacity(rearLayer ? 0.3 : 0.42)
                let activityOpacity = rearLayer ? 0.26 + speakerLevel * 0.2 : 0.48 + speakerLevel * 0.34
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [idleColor, speakerColor.opacity(activityOpacity), idleColor]),
                    startPoint: CGPoint(x: 0, y: centerY),
                    endPoint: CGPoint(x: size.width, y: centerY)
                )
                context.stroke(
                    wave,
                    with: shading,
                    style: StrokeStyle(lineWidth: rearLayer ? 3.2 : 2, lineCap: .round)
                )
            }
        }
    }

    private func updateEnvelope(for newLevels: VoiceVisualLevels) {
        guard isRunning, let generation = newLevels.generation else {
            envelopeGeneration = nil
            clearEnvelope()
            return
        }
        if envelopeGeneration != generation {
            envelopeGeneration = generation
            clearEnvelope()
        }
        let now = ProcessInfo.processInfo.systemUptime
        updateOutgoing(to: newLevels.outgoingLevel, authorized: newLevels.outgoingAuthorized, at: now)
        updatePlayback(to: newLevels.playbackLevel, authorized: newLevels.playbackAuthorized, at: now)
    }

    private func updateOutgoing(to rawLevel: Double, authorized: Bool, at time: TimeInterval) {
        guard authorized else {
            outgoingEnvelope.reset(at: time)
            return
        }
        outgoingEnvelope.retarget(
            to: shaped(rawLevel),
            at: time,
            attackDuration: 0.14,
            releaseDuration: 0.28
        )
    }

    private func updatePlayback(to rawLevel: Double, authorized: Bool, at time: TimeInterval) {
        guard authorized else {
            playbackEnvelope.reset(at: time)
            return
        }
        playbackEnvelope.retarget(
            to: shaped(rawLevel),
            at: time,
            attackDuration: 0.14,
            releaseDuration: 0.3
        )
    }

    private func clearEnvelope() {
        let now = ProcessInfo.processInfo.systemUptime
        outgoingEnvelope.reset(at: now)
        playbackEnvelope.reset(at: now)
    }

    private func shaped(_ rawLevel: Double) -> Double {
        let bounded = min(max(rawLevel, 0), 1)
        guard bounded > 0.012 else { return 0 }
        return pow((bounded - 0.012) / 0.988, 0.72)
    }
}

struct WindowVisibilityReader: NSViewRepresentable {
    let didChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        VisibilityView(didChange: didChange)
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.didChange = didChange
        view.publishVisibility()
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.stopObserving()
        view.didChange(false)
    }

    final class VisibilityView: NSView {
        var didChange: (Bool) -> Void
        private var observations: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?
        private var lastPublished: Bool?

        init(didChange: @escaping (Bool) -> Void) {
            self.didChange = didChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWindow()
            publishVisibility()
        }

        func publishVisibility() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let visible = window?.isVisible == true
                    && window?.occlusionState.contains(.visible) == true
                guard lastPublished != visible else { return }
                lastPublished = visible
                didChange(visible)
            }
        }

        func stopObserving() {
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
            observedWindow = nil
        }

        private func observeWindow() {
            guard observedWindow !== window else { return }
            stopObserving()
            observedWindow = window
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.willCloseNotification,
            ]
            observations = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.publishVisibility() }
                }
            }
        }
    }
}

extension View {
    @ViewBuilder
    func voiceGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.voiceForeground.opacity(0.16), lineWidth: 1))
        }
    }
}

struct VoiceButton<Label: View>: View {
    let prominent: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(macOS 26.0, *) {
            if prominent {
                Button(action: action, label: label)
                    .buttonStyle(.glassProminent)
                    .tint(.voiceForeground)
                    .foregroundStyle(Color.voiceBackground)
            } else {
                Button(action: action, label: label)
                    .buttonStyle(.glass)
                    .foregroundStyle(Color.voiceForeground)
            }
        } else if prominent {
            Button(action: action, label: label)
                .buttonStyle(.borderedProminent)
                .tint(.voiceForeground)
                .foregroundStyle(Color.voiceBackground)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.bordered)
                .tint(.voiceAccent)
                .foregroundStyle(Color.voiceForeground)
        }
    }
}
