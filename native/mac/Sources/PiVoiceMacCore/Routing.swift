import Foundation

public struct AgentTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let endpointEpoch: String
    public let name: String?
    public let cwd: String
    public let model: String?
    public let status: String?
    public let location: String?

    public init(
        id: String,
        endpointEpoch: String,
        name: String? = nil,
        cwd: String,
        model: String? = nil,
        status: String? = nil,
        location: String? = nil
    ) {
        self.id = id
        self.endpointEpoch = endpointEpoch
        self.name = name
        self.cwd = cwd
        self.model = model
        self.status = status
        self.location = location
    }

    public var displayName: String { name ?? "Unnamed agent" }
    public var shortID: String { String(id.prefix(8)) }
}

public struct RosterSnapshot: Equatable, Sendable {
    public let targets: [AgentTarget]
    public let receivedAt: Date

    public init(targets: [AgentTarget], receivedAt: Date) {
        self.targets = targets
        self.receivedAt = receivedAt
    }

    public func exact(_ target: AgentTarget) -> AgentTarget? {
        targets.first { $0.id == target.id && $0.endpointEpoch == target.endpointEpoch }
    }
}

public struct HerdrClientFocus: Equatable, Sendable {
    public let clientID: String
    public let machineID: String
    public let paneID: String
    public let targetID: String
    public let observedAt: Date

    public init(
        clientID: String,
        machineID: String,
        paneID: String,
        targetID: String,
        observedAt: Date
    ) {
        self.clientID = clientID
        self.machineID = machineID
        self.paneID = paneID
        self.targetID = targetID
        self.observedAt = observedAt
    }
}

public enum Selection: Equatable, Sendable {
    case focused(HerdrClientFocus)
    case manuallyConfirmed(AgentTarget)
}

public struct PinnedTurn: Equatable, Sendable {
    public let target: AgentTarget
    public let startedAt: Date
    public let source: Selection
}

public enum RoutingFailure: Error, Equatable, LocalizedError, Sendable {
    case noQualifiedClientFocus
    case focusEvidenceExpired
    case focusedTargetAbsent
    case manualTargetNotConfirmed
    case targetGenerationChanged
    case ambiguousName(String)

    public var errorDescription: String? {
        switch self {
        case .noQualifiedClientFocus:
            "No qualified per-client Herdr focus is available. Routing is stopped."
        case .focusEvidenceExpired:
            "The Herdr client focus evidence is stale. Routing is stopped."
        case .focusedTargetAbsent:
            "The focused pane is not a fresh exact gateway roster target."
        case .manualTargetNotConfirmed:
            "Confirm the exact manually selected agent before push to talk."
        case .targetGenerationChanged:
            "The pinned agent generation changed during the hold. Nothing was sent."
        case .ambiguousName(let name):
            "More than one live agent is named \(name). Select an exact ID."
        }
    }
}

/// Pure routing state. A turn pins an exact broker ID and endpoint epoch at press time.
/// It never resolves by name, carries an old target forward, or mutates Herdr focus.
public struct TurnRouter: Sendable {
    public static let maximumFocusAge: TimeInterval = 2
    public private(set) var pinned: PinnedTurn?

    public init() {}

    public mutating func begin(
        selection: Selection?,
        roster: RosterSnapshot,
        now: Date
    ) throws -> PinnedTurn {
        guard let selection else { throw RoutingFailure.noQualifiedClientFocus }

        let target: AgentTarget
        switch selection {
        case .focused(let focus):
            guard now.timeIntervalSince(focus.observedAt) >= 0,
                  now.timeIntervalSince(focus.observedAt) <= Self.maximumFocusAge else {
                throw RoutingFailure.focusEvidenceExpired
            }
            guard let exact = roster.targets.first(where: { $0.id == focus.targetID }) else {
                throw RoutingFailure.focusedTargetAbsent
            }
            target = exact
        case .manuallyConfirmed(let selected):
            guard let exact = roster.exact(selected) else {
                throw RoutingFailure.targetGenerationChanged
            }
            target = exact
        }

        let turn = PinnedTurn(target: target, startedAt: now, source: selection)
        pinned = turn
        return turn
    }

    public mutating func finish(using roster: RosterSnapshot) throws -> PinnedTurn {
        guard let pinned else { throw RoutingFailure.noQualifiedClientFocus }
        self.pinned = nil
        guard roster.exact(pinned.target) != nil else {
            throw RoutingFailure.targetGenerationChanged
        }
        return pinned
    }

    public mutating func cancel() { pinned = nil }
}

public enum NameResolution: Equatable, Sendable {
    case absent
    case exact(AgentTarget)
    case ambiguous([AgentTarget])
}

public func resolveDisplayName(_ name: String, in roster: RosterSnapshot) -> NameResolution {
    let matches = roster.targets.filter { $0.name == name }
    if matches.isEmpty { return .absent }
    if matches.count == 1 { return .exact(matches[0]) }
    return .ambiguous(matches)
}
