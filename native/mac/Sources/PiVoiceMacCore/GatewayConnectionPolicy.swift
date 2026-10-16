import Foundation

/// Fail promptly when the local gateway is unavailable; never park authorization
/// behind URLSession's default multi-day connectivity/resource deadline.
public enum GatewayConnectionPolicy {
    public static let waitsForConnectivity = false
    public static let requestTimeoutSeconds: Double = 20
    public static let resourceTimeoutSeconds: Double = 20
    // The server's short browser session is capped at one hour. Keep the event
    // transport alive slightly longer so the authenticated server expiry/close,
    // rather than URLSession's ordinary HTTP resource deadline, is authoritative.
    public static let webSocketResourceTimeoutSeconds: Double = 65 * 60

    /// The production configuration for pairing, renewal, and ordinary requests.
    public static func makeEphemeralConfiguration(
        requestTimeout: Double = requestTimeoutSeconds,
        resourceTimeout: Double = resourceTimeoutSeconds
    ) -> URLSessionConfiguration {
        precondition(requestTimeout > 0 && resourceTimeout > 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = waitsForConnectivity
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    public static func makeWebSocketConfiguration(
        cookieStorage: HTTPCookieStorage,
        requestTimeout: Double = requestTimeoutSeconds,
        resourceTimeout: Double = webSocketResourceTimeoutSeconds
    ) -> URLSessionConfiguration {
        let configuration = makeEphemeralConfiguration(
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout
        )
        // Share only this exact ephemeral origin-bound session's cookie jar. Never
        // use the process-global store or copy a durable device credential here.
        configuration.httpCookieStorage = cookieStorage
        return configuration
    }
}
