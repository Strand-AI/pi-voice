import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PiVoiceActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        PiVoiceActivityWidget()
    }
}

struct PiVoiceActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PiVoiceActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.microphoneActive ? "mic.fill" : "waveform")
                    .foregroundStyle(context.state.microphoneActive ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pi Voice · \(context.attributes.agentDisplayName)")
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.phase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(timerInterval: context.state.startedAt...context.state.hardDeadline, countsDown: false)
                    .font(.caption.monospacedDigit())
                Button(intent: PiVoiceSetMutedIntent(ticket: context.state.controlTicket, desiredMuted: !context.state.userMuted)) {
                    Image(systemName: context.state.userMuted ? "mic.fill" : "mic.slash.fill")
                }
                .buttonStyle(.bordered)
                Button(intent: PiVoiceEndIntent(ticket: context.state.controlTicket)) {
                    Image(systemName: "phone.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal)
            .widgetURL(URL(string: "pivoice://live")!)
            .activityBackgroundTint(Color.black.opacity(0.88))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.microphoneActive ? "mic.fill" : "waveform")
                        .foregroundStyle(context.state.microphoneActive ? .green : .secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.agentDisplayName).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startedAt...context.state.hardDeadline, countsDown: false)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.phase).font(.caption)
                        Spacer()
                        Button(intent: PiVoiceSetMutedIntent(ticket: context.state.controlTicket, desiredMuted: !context.state.userMuted)) {
                            Label(context.state.userMuted ? "Unmute" : "Mute", systemImage: context.state.userMuted ? "mic.fill" : "mic.slash.fill")
                        }
                        .buttonStyle(.bordered)
                        Button(intent: PiVoiceEndIntent(ticket: context.state.controlTicket)) {
                            Label("End", systemImage: "phone.down.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.microphoneActive ? "mic.fill" : "waveform")
                    .foregroundStyle(context.state.microphoneActive ? .green : .secondary)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...context.state.hardDeadline, countsDown: false)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.state.microphoneActive ? "mic.fill" : "waveform")
                    .foregroundStyle(context.state.microphoneActive ? .green : .secondary)
            }
            .widgetURL(URL(string: "pivoice://live")!)
        }
    }
}
