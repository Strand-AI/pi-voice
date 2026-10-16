import Foundation

/// Only exact-generation provider closure, not HTTP close acceptance, permits a handoff.
public struct ProviderClosureDiagnostic: Decodable, Sendable {
    private let current: Current?
    private struct Current: Decodable, Sendable {
        let generation: String
        let active: Bool
        let control: Control
    }
    private struct Control: Decodable, Sendable {
        let state: String
        let events: Events
    }
    private struct Events: Decodable, Sendable { let sessionClosed: Int }

    public func isSameGeneration(_ generation: String) -> Bool {
        current?.generation == generation
    }
    public func confirmsClosure(_ generation: String) -> Bool {
        guard let current else { return false }
        return current.generation == generation && !current.active &&
            current.control.state == "closed" && current.control.events.sessionClosed > 0
    }
}
