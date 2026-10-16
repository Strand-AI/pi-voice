import Foundation

/// Fences asynchronous local Live Activity work to the newest desired voice
/// generation. It carries no provider or endpoint identifier.
public struct LiveActivityReconciliationFence: Sendable {
    public struct Ticket: Equatable, Sendable {
        fileprivate let revision: UInt64
        public let generation: String?
    }

    private var revision: UInt64 = 0

    public init() {}

    public mutating func begin(desiredGeneration: String?) -> Ticket {
        revision &+= 1
        return Ticket(revision: revision, generation: desiredGeneration)
    }

    public func mayCommit(_ ticket: Ticket, currentGeneration: String?) -> Bool {
        ticket.revision == revision && ticket.generation == currentGeneration
    }
}
