import Foundation

public enum ProviderClosureReceiptResult: Equatable, Sendable {
    case providerClosed
    case unconfirmed
}

public struct ProviderClosureRecoveryRequest: Equatable, Sendable {
    public let epoch: UInt64
    public let token: UInt64
    public let origin: String
    public let generation: String
}

/// Exact authority for one retained-generation closure-recovery campaign.
/// A result is usable only while every field still matches the current request.
public struct ProviderClosureRecoveryFence: Equatable, Sendable {
    public private(set) var epoch: UInt64 = 0
    private var token: UInt64 = 0
    private var origin: String?
    private var generation: String?
    private var activeRequest: ProviderClosureRecoveryRequest?

    public init() {}

    @discardableResult
    public mutating func begin(origin: String, generation: String) -> UInt64? {
        guard let url = URL(string: origin),
              (try? GatewayConfiguration(baseURL: url).origin) == origin,
              !generation.isEmpty, generation.utf8.count <= 512 else { return nil }
        epoch &+= 1
        token &+= 1
        self.origin = origin
        self.generation = generation
        activeRequest = nil
        return epoch
    }

    public func canBeginRequest(epoch candidate: UInt64) -> Bool {
        candidate == epoch && activeRequest == nil && origin != nil && generation != nil
    }

    public mutating func beginRequest(epoch candidate: UInt64) -> ProviderClosureRecoveryRequest? {
        guard canBeginRequest(epoch: candidate), let origin, let generation else { return nil }
        token &+= 1
        let request = ProviderClosureRecoveryRequest(
            epoch: epoch,
            token: token,
            origin: origin,
            generation: generation
        )
        activeRequest = request
        return request
    }

    public func owns(_ request: ProviderClosureRecoveryRequest) -> Bool {
        request == activeRequest && request.epoch == epoch &&
            request.origin == origin && request.generation == generation
    }

    @discardableResult
    public mutating func finish(_ request: ProviderClosureRecoveryRequest) -> Bool {
        guard owns(request) else { return false }
        activeRequest = nil
        return true
    }

    public mutating func invalidateRequest() {
        token &+= 1
        activeRequest = nil
    }

    public mutating func clear() {
        epoch &+= 1
        token &+= 1
        origin = nil
        generation = nil
        activeRequest = nil
    }

}

/// Memory-only 0/5/15-second absolute campaign deadlines. Re-observing network
/// availability cannot reset the origin or limit for the same exact loss epoch.
public struct ProviderClosureRecoveryBudget: Equatable, Sendable {
    public static let delaysSeconds = [0, 5, 15]
    public private(set) var epoch: UInt64?
    public private(set) var attempts = 0

    public init() {}

    public mutating func claimDeadlineOffsetSeconds(epoch: UInt64) -> Int? {
        if self.epoch != epoch {
            self.epoch = epoch
            attempts = 0
        }
        guard attempts < Self.delaysSeconds.count else { return nil }
        defer { attempts += 1 }
        return Self.delaysSeconds[attempts]
    }

    public mutating func clear() {
        epoch = nil
        attempts = 0
    }
}
