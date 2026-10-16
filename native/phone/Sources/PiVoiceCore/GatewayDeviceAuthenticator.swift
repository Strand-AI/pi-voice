import Foundation

/// Converts one-use pairing or a durable exact-origin credential into a fresh, memory-only
/// short-session URLSession. It never returns or logs credential material.
@MainActor
public final class GatewayDeviceAuthenticator {
    public struct DurableCredentialSnapshot: @unchecked Sendable {
        fileprivate let origin: String
        fileprivate let value: String
    }
    private let credentialStore: DurableDeviceCredentialStore
    private let configurationFactory: @MainActor () -> URLSessionConfiguration
    private var authenticationRevision = 0
    private var pendingSession: URLSession?

    public init(credentialStore: DurableDeviceCredentialStore, configurationFactory: @escaping @MainActor () -> URLSessionConfiguration = GatewayDeviceAuthenticator.defaultConfiguration) {
        self.credentialStore = credentialStore
        self.configurationFactory = configurationFactory
    }

    public func authenticate(origin input: URL, pairingToken: String?, deviceName: String) async throws -> (origin: URL, session: URLSession) {
        let origin = try CanonicalGatewayOrigin(input)
        cancelPendingAuthentication()
        let revision = authenticationRevision
        let session = Self.makeEphemeralSession(configuration: configurationFactory())
        pendingSession = session
        do {
            if let token = pairingToken, !token.isEmpty {
                try await pair(origin: origin, token: token, deviceName: deviceName, session: session, revision: revision)
            } else {
                try await renew(origin: origin, session: session, revision: revision)
            }
            guard revision == authenticationRevision else { throw CancellationError() }
            if pendingSession === session { pendingSession = nil }
            return (origin.url, session)
        } catch {
            if pendingSession === session { pendingSession = nil }
            session.invalidateAndCancel()
            throw error
        }
    }

    public func cancelPendingAuthentication() {
        authenticationRevision &+= 1
        pendingSession?.invalidateAndCancel()
        pendingSession = nil
    }

    public func hasCredential(origin: URL) throws -> Bool {
        let canonical = try CanonicalGatewayOrigin(origin)
        return try credentialStore.load(origin: canonical.value) != nil
    }

    /// Opaque compare-delete authority for one credential actually about to be used.
    /// Its value is never exposed, persisted elsewhere, or logged.
    public func durableCredentialSnapshot(origin: URL) throws -> DurableCredentialSnapshot {
        let canonical = try CanonicalGatewayOrigin(origin)
        guard let credential = try credentialStore.load(origin: canonical.value) else { throw DeviceAuthenticationError.notPaired }
        return DurableCredentialSnapshot(origin: canonical.value, value: credential.value)
    }

    public func eraseCredentialIfUnchanged(_ snapshot: DurableCredentialSnapshot) {
        guard let current = try? credentialStore.load(origin: snapshot.origin), current.value == snapshot.value else { return }
        try? credentialStore.delete(origin: snapshot.origin)
    }

    public func forgetCredential(origin: URL) throws {
        let canonical = try CanonicalGatewayOrigin(origin)
        cancelPendingAuthentication()
        try credentialStore.delete(origin: canonical.value)
    }

    public func eraseRevokedCredential(origin: URL) {
        try? forgetCredential(origin: origin)
    }

    private func pair(origin: CanonicalGatewayOrigin, token: String, deviceName: String, session: URLSession, revision: Int) async throws {
        guard token.count == 32, token.utf8.allSatisfy(Self.isBase64URLByte) else { throw DeviceAuthenticationError.pairingInvalid }
        let storage = session.configuration.httpCookieStorage
        do {
            let response = try await post(path: "/api/browser-session/pair", origin: origin, session: session, body: ["pairingToken": token, "deviceName": deviceName])
            guard let echoedOrigin = (response["device"] as? [String: Any])?["origin"] as? String,
                  echoedOrigin == origin.value,
                  let deviceCookie = deviceCookie(in: storage, origin: origin.url),
                  shortSessionCookie(in: storage, origin: origin.url) != nil else {
                throw DeviceAuthenticationError.invalidResponse
            }
            let credential = try DurableDeviceCredential(origin: echoedOrigin, value: deviceCookie.value)
            guard revision == authenticationRevision else { throw CancellationError() }
            try credentialStore.save(credential)
            removeDeviceCookies(from: storage, origin: origin.url)
        } catch let error as AuthenticationHTTPError {
            storage?.removeCookies(since: .distantPast)
            guard revision == authenticationRevision else { throw CancellationError() }
            throw map(error)
        } catch {
            storage?.removeCookies(since: .distantPast)
            throw error
        }
    }

    private func renew(origin: CanonicalGatewayOrigin, session: URLSession, revision: Int) async throws {
        guard let credential = try credentialStore.load(origin: origin.value) else { throw DeviceAuthenticationError.notPaired }
        let storage = session.configuration.httpCookieStorage
        guard let cookie = HTTPCookie(properties: [
            .originURL: origin.url,
            .path: "/",
            .name: origin.url.scheme == "https" ? "__Host-pi_voice_device" : "pi_voice_device",
            .value: credential.value,
            .secure: origin.url.scheme == "https" ? "TRUE" : "FALSE",
        ]) else { throw DeviceAuthenticationError.invalidCredential }
        storage?.setCookie(cookie)
        defer { removeDeviceCookies(from: storage, origin: origin.url) }
        do {
            let response = try await post(path: "/api/browser-session/renew", origin: origin, session: session, body: [:])
            guard let echoedOrigin = (response["device"] as? [String: Any])?["origin"] as? String,
                  echoedOrigin == credential.origin,
                  shortSessionCookie(in: storage, origin: origin.url) != nil else {
                throw DeviceAuthenticationError.invalidResponse
            }
            guard revision == authenticationRevision else { throw CancellationError() }
        } catch let error as AuthenticationHTTPError {
            guard revision == authenticationRevision else { throw CancellationError() }
            let mapped = map(error)
            if mapped.mustEraseCredential,
               let current = try? credentialStore.load(origin: origin.value), current.value == credential.value {
                try? credentialStore.delete(origin: origin.value)
            }
            throw mapped
        }
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        return configuration
    }

    public static func makeEphemeralSession(configuration: URLSessionConfiguration? = nil) -> URLSession {
        let configuration = configuration ?? defaultConfiguration()
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        return URLSession(configuration: configuration, delegate: RejectRedirectsURLSessionDelegate(), delegateQueue: nil)
    }

    private func post(path: String, origin: CanonicalGatewayOrigin, session: URLSession, body: Any) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: origin.url)?.absoluteURL else { throw DeviceAuthenticationError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin.value, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url,
              finalURL.absoluteString == url.absoluteString,
              Self.origin(of: finalURL) == origin else { throw DeviceAuthenticationError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw AuthenticationHTTPError(status: http.statusCode, code: object["error"] as? String ?? "request_failed")
        }
        return object
    }

    private static func origin(of url: URL) -> CanonicalGatewayOrigin? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url.flatMap { try? CanonicalGatewayOrigin($0) }
    }

    private func deviceCookie(in storage: HTTPCookieStorage?, origin: URL) -> HTTPCookie? {
        storage?.cookies(for: origin)?.first { $0.name == "__Host-pi_voice_device" || $0.name == "pi_voice_device" }
    }

    private func shortSessionCookie(in storage: HTTPCookieStorage?, origin: URL) -> HTTPCookie? {
        storage?.cookies(for: origin)?.first { $0.name == "__Host-pi_voice_session" || $0.name == "pi_voice_session" }
    }

    private func removeDeviceCookies(from storage: HTTPCookieStorage?, origin: URL) {
        storage?.cookies(for: origin)?.filter { $0.name == "__Host-pi_voice_device" || $0.name == "pi_voice_device" }.forEach { storage?.deleteCookie($0) }
    }

    private static func isBase64URLByte(_ value: UInt8) -> Bool {
        (value >= 65 && value <= 90) || (value >= 97 && value <= 122) || (value >= 48 && value <= 57) || value == 45 || value == 95
    }

    private func map(_ error: AuthenticationHTTPError) -> DeviceAuthenticationError {
        switch error.code {
        case "invalid_device": return .deviceInvalid
        case "expired_device": return .deviceExpired
        case "revoked_device": return .deviceRevoked
        case "wrong_origin": return .wrongOrigin
        case "device_limit_reached": return .deviceLimitReached
        case "invalid_or_expired_pairing": return .pairingInvalid
        default: return .gateway(status: error.status, code: error.code)
        }
    }
}

public enum GatewayHTTPRedirectPolicy {
    /// Pairing tokens and device/session cookies must never be replayed to a redirected URL.
    public static func redirectedRequest(response: HTTPURLResponse, proposedRequest: URLRequest) -> URLRequest? {
        nil
    }
}

public final class RejectRedirectsURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(GatewayHTTPRedirectPolicy.redirectedRequest(response: response, proposedRequest: request))
    }
}

private struct AuthenticationHTTPError: Error {
    let status: Int
    let code: String
}
