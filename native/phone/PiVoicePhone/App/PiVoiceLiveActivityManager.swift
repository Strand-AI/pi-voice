@preconcurrency import ActivityKit
import Foundation
import PiVoiceCore

/// ActivityKit's Activity handle is safe for its own async update/end methods but
/// is not annotated Sendable in the current SDK. Keep that unchecked boundary
/// local rather than weakening isolation for the app model.
private struct ActivityKitTransfer<Value>: @unchecked Sendable {
    let value: Value
}

@MainActor
final class PiVoiceLiveActivityManager {
    typealias Ticket = LiveActivityReconciliationFence.Ticket

    private struct Snapshot {
        let generation: String
        let agentDisplayName: String
        let phase: String
        let microphoneActive: Bool
        let userMuted: Bool
        let hardDeadline: Date
    }

    private var fence = LiveActivityReconciliationFence()
    private var activityID: String?
    private var generation: String?
    private var startedAt: Date?
    private var controlTicket: String?
    private var controlAuthority = LiveActivityControlAuthority()
    private var lastState: PiVoiceActivityAttributes.ContentState?

    func issueTicket(for coordinator: VoiceSessionCoordinator) -> Ticket {
        fence.begin(desiredGeneration: Self.activeGeneration(of: coordinator))
    }

    func issueEndTicket() -> Ticket {
        fence.begin(desiredGeneration: nil)
    }

    func synchronize(with coordinator: VoiceSessionCoordinator, ticket: Ticket) async {
        guard let snapshot = Self.snapshot(of: coordinator) else {
            guard fence.mayCommit(ticket, currentGeneration: nil) else { return }
            await endCurrentActivity()
            return
        }
        guard fence.mayCommit(ticket, currentGeneration: snapshot.generation) else { return }

        if generation != snapshot.generation {
            await endCurrentActivity()
            // End suspends. Re-read exact active authority after it completes;
            // a queued End/replacement ticket invalidates this older create.
            guard let fresh = Self.snapshot(of: coordinator),
                  fresh.generation == snapshot.generation,
                  fence.mayCommit(ticket, currentGeneration: fresh.generation),
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            createActivity(from: fresh, ticket: ticket, coordinator: coordinator)
            return
        }

        guard let activityID, let startedAt, let controlTicket,
              let activity = Activity<PiVoiceActivityAttributes>.activities.first(where: { $0.id == activityID }) else { return }
        let state = PiVoiceActivityAttributes.ContentState(
            phase: snapshot.phase,
            microphoneActive: snapshot.microphoneActive,
            userMuted: snapshot.userMuted,
            startedAt: startedAt,
            hardDeadline: snapshot.hardDeadline,
            controlTicket: controlTicket
        )
        guard state != lastState else { return }
        let expectedActivityID = activityID
        let transfer = ActivityKitTransfer(value: (
            activity,
            ActivityContent(state: state, staleDate: snapshot.hardDeadline)
        ))
        await Task.detached {
            await transfer.value.0.update(transfer.value.1)
        }.value
        guard self.activityID == expectedActivityID,
              fence.mayCommit(ticket, currentGeneration: Self.activeGeneration(of: coordinator)) else { return }
        lastState = state
    }

    func end(with coordinator: VoiceSessionCoordinator, ticket: Ticket) async {
        guard fence.mayCommit(ticket, currentGeneration: Self.activeGeneration(of: coordinator)) else { return }
        await endCurrentActivity()
    }

    func controlsMatch(ticket: String, coordinator: VoiceSessionCoordinator) -> Bool {
        controlAuthority.matches(
            ticket: ticket,
            currentGeneration: Self.activeGeneration(of: coordinator),
            currentActivityID: activityID
        )
    }

    private func createActivity(from snapshot: Snapshot, ticket: Ticket, coordinator: VoiceSessionCoordinator) {
        let start = Date()
        let controlTicket = UUID().uuidString.lowercased()
        let state = PiVoiceActivityAttributes.ContentState(
            phase: snapshot.phase,
            microphoneActive: snapshot.microphoneActive,
            userMuted: snapshot.userMuted,
            startedAt: start,
            hardDeadline: snapshot.hardDeadline,
            controlTicket: controlTicket
        )
        do {
            let activity = try Activity.request(
                attributes: PiVoiceActivityAttributes(agentDisplayName: snapshot.agentDisplayName),
                content: ActivityContent(state: state, staleDate: snapshot.hardDeadline),
                pushType: nil
            )
            guard fence.mayCommit(ticket, currentGeneration: Self.activeGeneration(of: coordinator)) else {
                let transfer = ActivityKitTransfer(value: activity)
                Task.detached { await transfer.value.end(nil, dismissalPolicy: .immediate) }
                return
            }
            activityID = activity.id
            generation = snapshot.generation
            startedAt = start
            self.controlTicket = controlTicket
            controlAuthority.bind(ticket: controlTicket, generation: snapshot.generation, activityID: activity.id)
            lastState = state
        } catch {
            activityID = nil
            generation = nil
            startedAt = nil
            self.controlTicket = nil
            controlAuthority.clear()
            lastState = nil
        }
    }

    private func endCurrentActivity() async {
        guard let activityID,
              let activity = Activity<PiVoiceActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
            clearAuthority()
            return
        }
        // Release local authority before suspension so an old completion cannot
        // clear or update a replacement generation.
        clearAuthority()
        let transfer = ActivityKitTransfer(value: activity)
        await Task.detached {
            await transfer.value.end(nil, dismissalPolicy: .immediate)
        }.value
    }

    private func clearAuthority() {
        activityID = nil
        generation = nil
        startedAt = nil
        controlTicket = nil
        controlAuthority.clear()
        lastState = nil
    }

    private static func activeGeneration(of coordinator: VoiceSessionCoordinator) -> String? {
        guard case let .active(authority) = coordinator.phase else { return nil }
        return authority.generation
    }

    private static func snapshot(of coordinator: VoiceSessionCoordinator) -> Snapshot? {
        guard case let .active(authority) = coordinator.phase,
              let target = coordinator.activeTarget,
              let mode = coordinator.activeMode else { return nil }
        let mediaConnected = coordinator.mediaConnectionState == .connected
        let microphoneActive = mediaConnected && !coordinator.audioInterrupted && !coordinator.userMuted &&
            (mode == .continuous || (mode == .ptt && coordinator.pttHeld))
        let phase: String
        switch coordinator.mediaConnectionState {
        case .reconnecting: phase = "Reconnecting audio"
        case .unknown: phase = "Audio connection unknown"
        case .connected:
            phase = coordinator.audioInterrupted
                ? "Audio interrupted"
                : coordinator.userMuted ? "Microphone muted" : microphoneActive ? "Listening" : "Voice active"
        }
        return Snapshot(
            generation: authority.generation,
            agentDisplayName: target.displayName,
            phase: phase,
            microphoneActive: microphoneActive,
            userMuted: coordinator.userMuted,
            hardDeadline: authority.hardDeadline
        )
    }
}
