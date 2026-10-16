import Foundation

public struct PeerConnectionAuthority: Equatable, Hashable, Sendable {
    public let revision: Int
    public let peerIdentifier: String

    public init(revision: Int, peerIdentifier: String) {
        self.revision = revision
        self.peerIdentifier = peerIdentifier
    }
}

public enum PeerConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case completed
    case disconnected
    case failed
    case closed
}

public enum PeerMediaBeforeDisconnect: Equatable, Sendable {
    case continuous
    case pttIdle
    case pttHeld
    case gated
}

public enum PeerConnectionRecoveryAction: Equatable, Sendable {
    case none
    case gateMediaAndArmGrace(graceSequence: Int, deadlineMilliseconds: Int64)
    case restoreContinuousSameSession
    case restorePTTIdleSameSession
    case cancelPTTHoldBeforePlayback(generation: String)
    case recoveredButRemainGated
    case retainUnknown(generation: String?)
}

/// Exact-peer five-second ICE grace. It never creates a peer, provider session,
/// or physical PTT authority. Terminal outcomes retain generation authority.
public struct PeerConnectionRecoveryPolicy: Sendable {
    public static let defaultGraceMilliseconds: Int64 = 5_000

    private struct Grace: Equatable, Sendable {
        let sequence: Int
        let deadlineMilliseconds: Int64
        let media: PeerMediaBeforeDisconnect
    }

    private let graceMilliseconds: Int64
    private var authority: PeerConnectionAuthority?
    private var generation: String?
    private var grace: Grace?
    private var nextGraceSequence = 0

    public init(graceMilliseconds: Int64 = Self.defaultGraceMilliseconds) {
        precondition(graceMilliseconds > 0)
        self.graceMilliseconds = graceMilliseconds
    }

    public mutating func begin(_ authority: PeerConnectionAuthority) {
        self.authority = authority
        generation = nil
        grace = nil
        nextGraceSequence = 0
    }

    @discardableResult
    public mutating func bind(generation: String, to incoming: PeerConnectionAuthority) -> Bool {
        guard authority == incoming, !generation.isEmpty else { return false }
        self.generation = generation
        return true
    }

    public mutating func invalidate() {
        authority = nil
        generation = nil
        grace = nil
    }

    public mutating func observe(
        _ state: PeerConnectionState,
        authority incoming: PeerConnectionAuthority,
        nowMilliseconds: Int64,
        mediaBeforeDisconnect: PeerMediaBeforeDisconnect
    ) -> PeerConnectionRecoveryAction {
        guard authority == incoming else { return .none }
        switch state {
        case .connecting, .disconnected:
            guard grace == nil else { return .none }
            nextGraceSequence += 1
            let pending = Grace(
                sequence: nextGraceSequence,
                deadlineMilliseconds: nowMilliseconds + graceMilliseconds,
                media: mediaBeforeDisconnect
            )
            grace = pending
            return .gateMediaAndArmGrace(
                graceSequence: pending.sequence,
                deadlineMilliseconds: pending.deadlineMilliseconds
            )
        case .connected, .completed:
            guard let pending = grace else { return .none }
            guard nowMilliseconds < pending.deadlineMilliseconds else { return terminalAction() }
            grace = nil
            switch pending.media {
            case .continuous: return .restoreContinuousSameSession
            case .pttIdle: return .restorePTTIdleSameSession
            case .pttHeld:
                guard let generation else { return terminalAction() }
                return .cancelPTTHoldBeforePlayback(generation: generation)
            case .gated: return .recoveredButRemainGated
            }
        case .failed, .closed:
            return terminalAction()
        }
    }

    public mutating func graceExpired(
        authority incoming: PeerConnectionAuthority,
        graceSequence: Int,
        nowMilliseconds: Int64
    ) -> PeerConnectionRecoveryAction {
        guard authority == incoming, let pending = grace,
              pending.sequence == graceSequence,
              nowMilliseconds >= pending.deadlineMilliseconds else { return .none }
        return terminalAction()
    }

    private mutating func terminalAction() -> PeerConnectionRecoveryAction {
        let action = PeerConnectionRecoveryAction.retainUnknown(generation: generation)
        invalidate()
        return action
    }
}
