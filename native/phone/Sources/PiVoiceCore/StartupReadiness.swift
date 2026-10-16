import Foundation

public enum VoiceConnectionAnnouncement: Equatable, Sendable {
    case notAnnouncement
    case valid(connectionID: String)
    case invalid

    public static func decode(_ data: Data) -> VoiceConnectionAnnouncement {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = value["type"] as? String else { return .notAnnouncement }
        guard type == "voice_connection" else { return .notAnnouncement }
        guard let connectionID = value["connectionId"] as? String,
              isOpaqueVoiceConnectionID(connectionID) else { return .invalid }
        return .valid(connectionID: connectionID)
    }
}

public func isOpaqueVoiceConnectionID(_ value: String) -> Bool {
    value.utf8.count == 22 && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
            ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
    }
}

/// Binds application commands to the exact authenticated event socket that
/// announced their connection authority first.
public struct VoiceConnectionFence: Equatable, Sendable {
    public private(set) var revision = 0
    private var boundConnectionID: String?

    public init() {}

    public mutating func beginSocket() -> Int {
        revision += 1
        boundConnectionID = nil
        return revision
    }

    public mutating func acceptFirst(
        _ announcement: VoiceConnectionAnnouncement,
        revision candidate: Int
    ) -> Bool {
        guard case .valid(let connectionID) = announcement else { return false }
        return bind(connectionID: connectionID, revision: candidate)
    }

    public mutating func bind(connectionID: String, revision candidate: Int) -> Bool {
        guard candidate == revision, boundConnectionID == nil,
              isOpaqueVoiceConnectionID(connectionID) else { return false }
        boundConnectionID = connectionID
        return true
    }

    public mutating func invalidate() {
        revision += 1
        boundConnectionID = nil
    }

    public func connectionID(for candidate: Int) -> String? {
        candidate == revision ? boundConnectionID : nil
    }
}

/// A peer cannot accept application input until its own gathered ICE offer and
/// primary provider startup are both ready.
public struct PeerStartupReadiness: Equatable, Sendable {
    private var revision: Int?
    private var gathered = false
    private var started = false

    public init() {}

    public mutating func begin(_ revision: Int) {
        self.revision = revision
        gathered = false
        started = false
    }

    public mutating func iceGathered(_ revision: Int) {
        guard self.revision == revision else { return }
        gathered = true
    }

    public mutating func observe(type: String, revision: Int) {
        guard self.revision == revision, type == "session.started" else { return }
        started = true
    }

    public func ready(_ revision: Int) -> Bool {
        self.revision == revision && gathered && started
    }

    public mutating func invalidate() {
        revision = nil
        gathered = false
        started = false
    }
}
