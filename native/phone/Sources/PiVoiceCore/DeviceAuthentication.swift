import Foundation

public struct CanonicalGatewayOrigin: Equatable, Hashable, Sendable {
    public let value: String

    public init(_ input: URL) throws {
        guard input.user == nil, input.password == nil, input.query == nil, input.fragment == nil,
              input.path.isEmpty || input.path == "/",
              var components = URLComponents(url: input, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme, let rawHost = components.host else {
            throw VoiceError.invalidOrigin
        }
        let scheme = rawScheme.lowercased(), host = rawHost.lowercased()
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        guard scheme == "https" || (scheme == "http" && loopback) else { throw VoiceError.invalidOrigin }
        components.scheme = scheme
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) { components.port = nil }
        guard let canonicalURL = components.url,
              let roundTrip = URLComponents(url: canonicalURL, resolvingAgainstBaseURL: false),
              roundTrip.scheme == scheme, roundTrip.host != nil else { throw VoiceError.invalidOrigin }
        value = canonicalURL.absoluteString
    }

    public var url: URL { URL(string: value)! }
}

public struct DurableDeviceCredential: Equatable, Sendable {
    public let origin: String
    public let value: String

    public init(origin: String, value: String) throws {
        guard let url = URL(string: origin), try CanonicalGatewayOrigin(url).value == origin,
              value.count == 43, value.utf8.allSatisfy({
                  ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
              }) else { throw DeviceAuthenticationError.invalidCredential }
        self.origin = origin
        self.value = value
    }
}

public protocol DurableDeviceCredentialStore: AnyObject {
    func load(origin: String) throws -> DurableDeviceCredential?
    func save(_ credential: DurableDeviceCredential) throws
    func delete(origin: String) throws
}

public enum GatewaySocketEventPolicy {
    /// A WebSocket result may affect UI or credentials only while its exact task and
    /// authenticated connection revision are still current.
    public static func mayAccept(isCancelled: Bool, isCurrentTask: Bool, revisionMatches: Bool) -> Bool {
        !isCancelled && isCurrentTask && revisionMatches
    }
}

public enum DeviceAuthenticationError: Error, Equatable, LocalizedError {
    case notPaired
    case invalidCredential
    case invalidResponse
    case wrongOrigin
    case deviceInvalid
    case deviceExpired
    case deviceRevoked
    case deviceLimitReached
    case pairingInvalid
    case gateway(status: Int, code: String)

    public var mustEraseCredential: Bool {
        switch self {
        case .deviceInvalid, .deviceExpired, .deviceRevoked: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notPaired: "Enter a one-use pairing token to pair this phone."
        case .invalidCredential: "The stored device credential is invalid. Pair this phone again."
        case .invalidResponse: "The gateway returned an invalid authentication response."
        case .wrongOrigin: "This device is paired to a different exact gateway origin."
        case .deviceInvalid: "This device pairing is invalid. Pair this phone again."
        case .deviceExpired: "This device pairing expired. Pair this phone again."
        case .deviceRevoked: "This device was revoked. Pair this phone again."
        case .deviceLimitReached: "The gateway already has the maximum number of active devices."
        case .pairingInvalid: "The one-use pairing token is invalid or expired. Request a new token."
        case let .gateway(status, code): "Gateway \(status): \(code)"
        }
    }
}
