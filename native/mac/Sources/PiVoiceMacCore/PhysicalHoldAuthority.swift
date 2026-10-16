import Foundation

public enum PhysicalPTTSource: String, Hashable, Sendable {
    case pointer
    case rightOption
}

public struct PhysicalPTTHoldToken: Equatable, Sendable {
    public let source: PhysicalPTTSource
    public let generation: String
    fileprivate let nonce: Int
}

public enum PhysicalPTTAction: Equatable, Sendable {
    case begin(generation: String)
    case end(generation: String, cancel: Bool)
}

/// Arbitrates multiple physical controls over one provider PTT turn.
/// The first matching hold begins; only the last matching release ends.
public struct PhysicalHoldAuthority: Sendable {
    private var generation: String?
    private var holds: [PhysicalPTTSource: PhysicalPTTHoldToken] = [:]
    private var nextNonce = 0

    public init() {}

    public mutating func press(
        _ source: PhysicalPTTSource,
        generation: String
    ) -> (token: PhysicalPTTHoldToken, action: PhysicalPTTAction?) {
        if self.generation != generation {
            holds.removeAll()
            self.generation = generation
        }
        if let existing = holds[source] { return (existing, nil) }
        nextNonce += 1
        let token = PhysicalPTTHoldToken(source: source, generation: generation, nonce: nextNonce)
        let beginsTurn = holds.isEmpty
        holds[source] = token
        return (token, beginsTurn ? .begin(generation: generation) : nil)
    }

    public mutating func release(_ token: PhysicalPTTHoldToken) -> PhysicalPTTAction? {
        finish(token, cancel: false)
    }

    public mutating func cancel(_ token: PhysicalPTTHoldToken) -> PhysicalPTTAction? {
        finish(token, cancel: true)
    }

    public mutating func cancelAll(generation: String) -> PhysicalPTTAction? {
        guard self.generation == generation, !holds.isEmpty else { return nil }
        holds.removeAll()
        self.generation = nil
        return .end(generation: generation, cancel: true)
    }

    public mutating func invalidate() {
        holds.removeAll()
        generation = nil
    }

    private mutating func finish(_ token: PhysicalPTTHoldToken, cancel: Bool) -> PhysicalPTTAction? {
        guard generation == token.generation, holds[token.source] == token else { return nil }
        holds[token.source] = nil
        guard holds.isEmpty else { return nil }
        generation = nil
        return .end(generation: token.generation, cancel: cancel)
    }
}
