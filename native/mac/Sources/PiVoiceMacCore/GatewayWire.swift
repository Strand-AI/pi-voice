import Foundation

public struct GatewayConfiguration: Equatable, Sendable {
    public let baseURL: URL

    public init(baseURL: URL) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else {
            throw GatewayWireError.invalidBaseURL
        }
        self.baseURL = baseURL
    }

    public var origin: String {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        return components.url!.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func httpURL(path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    public var webSocketURL: URL {
        var components = URLComponents(url: httpURL(path: "/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return components.url!
    }
}

public enum GatewayWireError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseURL
    case invalidPairingToken
    case invalidDeviceName
    case invalidEvent
    case unauthenticated(Int)
    case rejected(Int)
    case deliveryUnknown

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Use an exact http(s) origin with no path, credentials, query, or fragment."
        case .invalidPairingToken: "Use the 32-character one-use pairing token issued by the gateway."
        case .invalidDeviceName: "Use a device name between 1 and 80 characters."
        case .invalidEvent: "The gateway returned an unrecognized event."
        case .unauthenticated(let status): "Gateway authentication failed (HTTP \(status))."
        case .rejected(let status): "The gateway rejected the request (HTTP \(status))."
        case .deliveryUnknown: "Delivery outcome is unknown. The message will not be retried."
        }
    }
}

public func exactResponseURL(_ responseURL: URL?, matches requestedURL: URL?) -> Bool {
    guard let responseURL, let requestedURL else { return false }
    return responseURL.absoluteString == requestedURL.absoluteString
}

public enum DeviceCredentialFailureDisposition: Equatable, Sendable {
    case deleteSavedCredential
    case retainSavedCredential
}

public func deviceCredentialFailureDisposition(
    httpStatus: Int,
    code: String
) -> DeviceCredentialFailureDisposition {
    guard httpStatus == 401,
          code == "invalid_device" || code == "expired_device" || code == "revoked_device" else {
        return .retainSavedCredential
    }
    return .deleteSavedCredential
}

public struct BrowserPairingRequest: Encodable, Equatable, Sendable {
    public let pairingToken: String
    public let deviceName: String

    public init(pairingToken: String, deviceName: String) throws {
        guard pairingToken.count == 32,
              pairingToken.utf8.allSatisfy({
                  ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                      || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
              }) else {
            throw GatewayWireError.invalidPairingToken
        }
        let scrubbedName = deviceName.unicodeScalars
            .map { $0.value <= 31 || $0.value == 127 ? " " : String($0) }
            .joined()
        let normalizedName = scrubbedName
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalizedName.isEmpty, normalizedName.unicodeScalars.count <= 80 else {
            throw GatewayWireError.invalidDeviceName
        }
        self.pairingToken = pairingToken
        self.deviceName = normalizedName
    }
}

public struct RelaySnapshot: Decodable, Equatable, Sendable {
    public let connected: Bool
    public let sessions: [AgentTarget]

    public init(connected: Bool, sessions: [AgentTarget]) {
        self.connected = connected
        self.sessions = sessions
    }
}

public struct RelayMessageParty: Decodable, Equatable, Sendable {
    public let id: String
    public let endpointEpoch: String
    public let name: String?
}

public struct RelayMessageBody: Decodable, Equatable, Sendable {
    public struct Content: Decodable, Equatable, Sendable { public let text: String }
    public let id: String
    public let replyTo: String?
    public let expectsReply: Bool?
    public let content: Content
}

public struct RelayMessageEntry: Decodable, Equatable, Sendable {
    public let direction: String
    public let from: RelayMessageParty
    public let message: RelayMessageBody
}

public enum GatewayEvent: Equatable, Sendable {
    case snapshot(RelaySnapshot)
    case roster([AgentTarget])
    case message(RelayMessageEntry)
    case connection(Bool)
    case error(code: String, message: String)
}

public enum GatewayEventDecoder {
    private struct Kind: Decodable { let type: String }
    private struct SnapshotEnvelope: Decodable { let snapshot: RelaySnapshot }
    private struct RosterEnvelope: Decodable { let sessions: [AgentTarget] }
    private struct MessageEnvelope: Decodable { let entry: RelayMessageEntry }
    private struct ConnectionEnvelope: Decodable { let connected: Bool }
    private struct ErrorEnvelope: Decodable { let code: String; let message: String }

    public static func decode(_ data: Data) throws -> GatewayEvent {
        let decoder = JSONDecoder()
        switch try decoder.decode(Kind.self, from: data).type {
        case "relay_snapshot": return .snapshot(try decoder.decode(SnapshotEnvelope.self, from: data).snapshot)
        case "relay_roster": return .roster(try decoder.decode(RosterEnvelope.self, from: data).sessions)
        case "relay_message": return .message(try decoder.decode(MessageEnvelope.self, from: data).entry)
        case "relay_connection": return .connection(try decoder.decode(ConnectionEnvelope.self, from: data).connected)
        case "relay_error":
            let value = try decoder.decode(ErrorEnvelope.self, from: data)
            return .error(code: value.code, message: value.message)
        default: throw GatewayWireError.invalidEvent
        }
    }
}

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

    public mutating func clear(revision candidate: Int) {
        guard candidate == revision else { return }
        boundConnectionID = nil
    }

    public mutating func invalidate() {
        revision += 1
        boundConnectionID = nil
    }

    public func connectionID(for candidate: Int) -> String? {
        candidate == revision ? boundConnectionID : nil
    }
}

public enum VoiceGatewayEventDecoder {
    public static func decode(_ data: Data) -> VoiceGatewayEvent? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = value["type"] as? String else { return nil }
        let generation = value["generation"] as? String
        switch type {
        case "relay_snapshot":
            guard let snapshot = value["snapshot"] as? [String: Any] else { return nil }
            return .roster(connected: snapshot["connected"] as? Bool ?? false, agents: agents(snapshot["sessions"]))
        case "relay_roster":
            return .roster(connected: true, agents: agents(value["sessions"]))
        case "relay_connection":
            guard value["connected"] as? Bool != true else { return nil }
            return .roster(connected: false, agents: [])
        case "voice_state":
            guard let generation, let state = value["state"] as? String else { return nil }
            return .voiceState(generation: generation, state: state, reason: value["reason"] as? String)
        case "voice_ptt_ready":
            guard let generation else { return nil }
            return .pttReady(generation: generation)
        case "voice_caption":
            guard let generation, let speaker = value["speaker"] as? String,
                  let delta = value["delta"] as? String else { return nil }
            return .caption(
                generation: generation,
                speaker: speaker,
                delta: delta,
                groupID: value["groupId"] as? String
            )
        case "voice_caption_stable":
            guard let generation, let speaker = value["speaker"] as? String,
                  let groupID = value["groupId"] as? String else { return nil }
            return .captionStable(generation: generation, speaker: speaker, groupID: groupID)
        case "voice_utterance", "voice_liaison_request":
            guard let generation, let text = value["text"] as? String else { return nil }
            return .utterance(generation: generation, text: text)
        case "voice_error", "relay_error":
            return .error(
                generation: generation,
                code: value["code"] as? String ?? type,
                message: value["message"] as? String ?? "Unknown error"
            )
        default:
            return nil
        }
    }

    private static func agents(_ value: Any?) -> [AgentTarget] {
        guard let records = value as? [[String: Any]] else { return [] }
        return records.compactMap { item in
            guard item["kind"] as? String == "agent",
                  let id = item["id"] as? String,
                  let epoch = item["endpointEpoch"] as? String,
                  let cwd = item["cwd"] as? String else { return nil }
            return AgentTarget(
                id: id,
                endpointEpoch: epoch,
                name: item["name"] as? String,
                cwd: cwd,
                model: item["model"] as? String,
                status: item["status"] as? String,
                location: item["location"] as? String
            )
        }
    }
}

public struct ExactSendRequest: Encodable, Equatable, Sendable {
    public let targetId: String
    public let targetEpoch: String
    public let text: String
    public let messageId: String
    public let replyTo: String?

    public init(target: AgentTarget, text: String, messageID: UUID, replyTo: String? = nil) {
        targetId = target.id
        targetEpoch = target.endpointEpoch
        self.text = text
        messageId = messageID.uuidString.lowercased()
        self.replyTo = replyTo
    }
}

public struct RelayDelivery: Decodable, Equatable, Sendable {
    public let delivered: Bool
    public let delivery: String
    public let retryable: Bool
    public let outcomeKnown: Bool

    public init(delivered: Bool, delivery: String, retryable: Bool, outcomeKnown: Bool) {
        self.delivered = delivered
        self.delivery = delivery
        self.retryable = retryable
        self.outcomeKnown = outcomeKnown
    }

    public func requireKnownDelivery() throws {
        if !outcomeKnown || delivery == "unknown" { throw GatewayWireError.deliveryUnknown }
    }
}
