import Foundation

/// Runs only saved-device authorization. It cannot select a target, open the
/// microphone, or create a provider session.
@MainActor
public enum AutomaticConnectionRetry {
    public static let maximumAttempts = 3

    @discardableResult
    public static func run(
        shouldContinue: () -> Bool,
        reconnect: () async throws -> Void,
        shouldRetry: (Error) -> Bool,
        reportFailure: (Error) -> Void,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> Bool {
        for attempt in 0..<maximumAttempts {
            guard !Task.isCancelled, shouldContinue() else { return false }
            do {
                try await reconnect()
                return true
            } catch {
                reportFailure(error)
                guard !Task.isCancelled, shouldContinue(), shouldRetry(error),
                      attempt + 1 < maximumAttempts else { return false }
                do { try await sleep(.seconds(attempt + 1)) }
                catch { return false }
            }
        }
        return false
    }
}

public enum SavedDeviceReconnectPolicy {
    public static func shouldRetry(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .secureConnectionFailed,
        ].contains(urlError.code)
    }

    public static func requiresRepair(_ error: Error) -> Bool {
        guard let authentication = error as? DeviceAuthenticationError else { return false }
        return authentication == .notPaired || authentication == .invalidCredential || authentication.mustEraseCredential
    }
}
