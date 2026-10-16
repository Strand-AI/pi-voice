public struct LiveActivityControlAuthority: Equatable, Sendable {
    private var ticket: String?
    private var generation: String?
    private var activityID: String?

    public init() {}

    public mutating func bind(ticket: String, generation: String, activityID: String) {
        self.ticket = ticket
        self.generation = generation
        self.activityID = activityID
    }

    public func matches(ticket: String, currentGeneration: String?, currentActivityID: String?) -> Bool {
        guard ticket.utf8.count <= 64 else { return false }
        return self.ticket == ticket && generation == currentGeneration && activityID == currentActivityID
    }

    public mutating func clear() {
        ticket = nil
        generation = nil
        activityID = nil
    }
}
