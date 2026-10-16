public struct DeferredStartupReconnect: Equatable, Sendable {
    private let waitsForForeground: Bool
    public private(set) var claimed = false

    public init(launchedInBackground: Bool) {
        waitsForForeground = launchedInBackground
    }

    public mutating func claimAtInitialization(eligible: Bool) -> Bool {
        guard !waitsForForeground else { return false }
        return claim(eligible: eligible)
    }

    public mutating func claimOnForeground(eligible: Bool) -> Bool {
        guard waitsForForeground else { return false }
        return claim(eligible: eligible)
    }

    private mutating func claim(eligible: Bool) -> Bool {
        guard eligible, !claimed else { return false }
        claimed = true
        return true
    }
}
