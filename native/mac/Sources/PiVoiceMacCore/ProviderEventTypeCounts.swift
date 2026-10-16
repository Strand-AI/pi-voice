import Foundation

public struct ProviderEventTypeCount: Equatable, Sendable {
    public let type: String
    public let count: Int

    public init(type: String, count: Int) {
        self.type = type
        self.count = count
    }
}

public struct ProviderEventTypeSnapshot: Equatable, Sendable {
    public let observations: [ProviderEventTypeCount]
    public let overflow: Int

    public init(observations: [ProviderEventTypeCount], overflow: Int) {
        self.observations = observations
        self.overflow = overflow
    }
}

/// Bounded, content-free diagnostics for provider event envelopes.
public struct ProviderEventTypeCounts: Equatable, Sendable {
    public static let maximumUniqueTypes = 32
    public static let maximumSafeInteger = 9_007_199_254_740_991

    private var counts: [String: Int] = [:]
    private var overflow = 0
    public private(set) var revision = 0

    public init() {}

    public static func isValidType(_ type: String) -> Bool {
        let bytes = type.utf8
        guard (1...80).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) ||
                (65...90).contains(byte) ||
                (97...122).contains(byte) ||
                byte == 46 || byte == 95 || byte == 45
        }
    }

    @discardableResult
    public mutating func observe(type: String) -> Bool {
        guard Self.isValidType(type), revision < Self.maximumSafeInteger else { return false }
        if let count = counts[type] {
            guard count < Self.maximumSafeInteger else { return false }
            counts[type] = count + 1
        } else if counts.count < Self.maximumUniqueTypes {
            counts[type] = 1
        } else {
            guard overflow < Self.maximumSafeInteger else { return false }
            overflow += 1
        }
        revision += 1
        return true
    }

    @discardableResult
    public mutating func observeUnparsedFrame() -> Bool {
        guard revision < Self.maximumSafeInteger,
              overflow < Self.maximumSafeInteger else { return false }
        overflow += 1
        revision += 1
        return true
    }

    public var snapshot: ProviderEventTypeSnapshot {
        ProviderEventTypeSnapshot(
            observations: counts
                .map { ProviderEventTypeCount(type: $0.key, count: $0.value) }
                .sorted { $0.type < $1.type },
            overflow: overflow
        )
    }
}
