import Foundation

public struct LastAgentSelectionHint: Codable, Equatable, Sendable {
    public let origin: String
    public let agentID: String

    public init(origin: String, agentID: String) throws {
        guard let url = URL(string: origin),
              (try? GatewayConfiguration(baseURL: url).origin) == origin,
              !agentID.isEmpty, agentID.utf8.count <= 512 else {
            throw VoiceFailure.invalidOrigin
        }
        self.origin = origin
        self.agentID = agentID
    }
}

public final class LastAgentSelectionHintStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "piVoice.lastAgentSelection") {
        self.defaults = defaults
        self.key = key
    }

    public func load(forOrigin origin: String) -> LastAgentSelectionHint? {
        guard let data = defaults.data(forKey: key),
              let hint = try? JSONDecoder().decode(LastAgentSelectionHint.self, from: data),
              hint.origin == origin,
              let validated = try? LastAgentSelectionHint(origin: hint.origin, agentID: hint.agentID) else { return nil }
        return validated
    }

    public func save(origin: String, agentID: String) throws {
        defaults.set(try JSONEncoder().encode(LastAgentSelectionHint(origin: origin, agentID: agentID)), forKey: key)
    }

    public func clear(forOrigin origin: String) {
        guard load(forOrigin: origin) != nil else { return }
        defaults.removeObject(forKey: key)
    }

    public func clearAll() { defaults.removeObject(forKey: key) }
}

/// One fresh connected-roster evaluation is allowed after authorization. The
/// persisted stable ID can only resolve to the endpoint epoch in that fresh roster.
public struct LastAgentSelectionRestoration: Equatable, Sendable {
    public private(set) var pendingAfterRosterRevision: Int?

    public init() {}
    public mutating func begin(after rosterRevision: Int) { pendingAfterRosterRevision = rosterRevision }
    public mutating func cancel() { pendingAfterRosterRevision = nil }

    public mutating func candidate(
        hint: LastAgentSelectionHint?,
        origin: String,
        phase: CallPhase,
        rosterConnected: Bool,
        rosterRevision: Int,
        agents: [AgentTarget],
        selected: AgentTarget?
    ) -> AgentTarget? {
        guard let minimumRevision = pendingAfterRosterRevision,
              phase == .ready, rosterConnected,
              rosterRevision > minimumRevision else { return nil }
        pendingAfterRosterRevision = nil
        guard selected == nil, let hint, hint.origin == origin else { return nil }
        return agents.first { $0.id == hint.agentID }
    }
}
