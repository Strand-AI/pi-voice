import Foundation

/// Runs only the saved-device authorization reconnect operation. Voice start,
/// microphone access, and provider session creation are intentionally outside
/// this retry surface.
@MainActor
public enum AutomaticConnectionRetry {
    public static let maximumAttempts = 3

    @discardableResult
    public static func run(
        shouldContinue: () -> Bool,
        reconnect: () async throws -> Void,
        shouldRetry: (Error) -> Bool,
        reportFailure: (Error) -> Void,
        sleep: (Duration) async throws -> Void
    ) async -> Bool {
        for attempt in 0..<maximumAttempts {
            guard !Task.isCancelled, shouldContinue() else { return false }
            do {
                try await reconnect()
                return true
            } catch {
                reportFailure(error)
                let retryable = shouldRetry(error)
                guard !Task.isCancelled, shouldContinue(), retryable,
                      attempt + 1 < maximumAttempts else { return false }
                do {
                    try await sleep(.seconds(attempt + 1))
                } catch {
                    return false
                }
            }
        }
        return false
    }
}
