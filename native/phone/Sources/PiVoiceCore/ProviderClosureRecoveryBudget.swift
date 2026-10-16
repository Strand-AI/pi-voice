/// Memory-only authorization-query budget. Network availability may pause and resume a
/// campaign, but it cannot reset the three-attempt limit for the same loss epoch.
public struct ProviderClosureRecoveryBudget: Equatable, Sendable {
    public static let maximumAutomaticAttempts = 3
    public private(set) var epoch: UInt64?
    public private(set) var attempts = 0

    public init() {}

    public mutating func claimAutomaticAttempt(epoch: UInt64) -> Bool {
        if self.epoch != epoch {
            self.epoch = epoch
            attempts = 0
        }
        guard attempts < Self.maximumAutomaticAttempts else { return false }
        attempts += 1
        return true
    }
}
