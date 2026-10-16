import Foundation

/// Bounded, memory-only correlation for CallKit mute actions. Actual timeout
/// identities stay quarantined until registration reset/rotation or independent
/// `isComplete` evidence; elapsed time alone never retires them.
public struct CallKitMuteIntentLedger: Sendable {
    public enum State: Equatable, Sendable {
        case unresolved
        case timedOut
    }

    public enum Origin: Equatable, Sendable {
        case app(CallKitAttemptPolicy.MuteRequest)
        case native(muted: Bool)
    }

    public struct Record: Equatable, Sendable {
        public let actionUUID: UUID
        public let callUUID: UUID
        public let providerEpoch: UInt64
        public let origin: Origin
        public fileprivate(set) var state: State

        public var appRequest: CallKitAttemptPolicy.MuteRequest? {
            guard case let .app(request) = origin else { return nil }
            return request
        }
    }

    public let capacity: Int
    private var records: [UUID: Record] = [:]

    public init(capacity: Int = 32) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { records.count }
    public var isFull: Bool { records.count >= capacity }

    @discardableResult
    public mutating func issueApp(
        actionUUID: UUID,
        callUUID: UUID,
        providerEpoch: UInt64,
        request: CallKitAttemptPolicy.MuteRequest
    ) -> Bool {
        insert(
            Record(
                actionUUID: actionUUID,
                callUUID: callUUID,
                providerEpoch: providerEpoch,
                origin: .app(request),
                state: .unresolved
            )
        )
    }

    public func record(actionUUID: UUID, providerEpoch: UInt64) -> Record? {
        guard let record = records[actionUUID], record.providerEpoch == providerEpoch else { return nil }
        return record
    }

    /// Quarantines both app-issued and previously unknown/native timeout UUIDs.
    /// Returns nil only when a new unknown identity cannot fit in the bound.
    @discardableResult
    public mutating func quarantineTimeout(
        actionUUID: UUID,
        callUUID: UUID,
        providerEpoch: UInt64,
        muted: Bool
    ) -> Record? {
        if var record = record(actionUUID: actionUUID, providerEpoch: providerEpoch) {
            record.state = .timedOut
            records[actionUUID] = record
            return record
        }
        let record = Record(
            actionUUID: actionUUID,
            callUUID: callUUID,
            providerEpoch: providerEpoch,
            origin: .native(muted: muted),
            state: .timedOut
        )
        guard insert(record) else { return nil }
        return record
    }

    /// `CXAction.isComplete` proves fulfill/fail and may retire any state.
    @discardableResult
    public mutating func retireCompleted(actionUUID: UUID, providerEpoch: UInt64) -> Record? {
        remove(actionUUID: actionUUID, providerEpoch: providerEpoch)
    }

    /// A definite transaction submission error can retire only an unresolved
    /// app action. A timeout observed first keeps its UUID quarantined.
    @discardableResult
    public mutating func retireDefiniteSubmissionFailure(
        actionUUID: UUID,
        providerEpoch: UInt64
    ) -> Record? {
        guard let record = record(actionUUID: actionUUID, providerEpoch: providerEpoch),
              record.state == .unresolved,
              case .app = record.origin else { return nil }
        records.removeValue(forKey: actionUUID)
        return record
    }

    /// Exact fulfill/fail performed by this provider is terminal only for an
    /// unresolved record. Timed-out actions must never reach this operation.
    @discardableResult
    public mutating func retirePerformed(actionUUID: UUID, providerEpoch: UInt64) -> Record? {
        guard let record = record(actionUUID: actionUUID, providerEpoch: providerEpoch),
              record.state == .unresolved else { return nil }
        records.removeValue(forKey: actionUUID)
        return record
    }

    /// Reset/eligible provider rotation is terminal for callbacks belonging to
    /// that immutable provider registration, but says nothing about allocation.
    @discardableResult
    public mutating func retireRegistration(providerEpoch: UInt64) -> [Record] {
        let retired = records.values.filter { $0.providerEpoch == providerEpoch }
        for record in retired { records.removeValue(forKey: record.actionUUID) }
        return retired
    }

    private mutating func insert(_ record: Record) -> Bool {
        guard !isFull, records[record.actionUUID] == nil else { return false }
        records[record.actionUUID] = record
        return true
    }

    private mutating func remove(actionUUID: UUID, providerEpoch: UInt64) -> Record? {
        guard let record = record(actionUUID: actionUUID, providerEpoch: providerEpoch) else { return nil }
        records.removeValue(forKey: actionUUID)
        return record
    }
}
