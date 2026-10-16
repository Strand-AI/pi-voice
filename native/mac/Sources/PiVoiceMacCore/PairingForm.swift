import Foundation

public enum PairingFormPolicy {
    /// Pair remains clickable while idle even if macOS has not yet committed a focused
    /// secure field into SwiftUI state. Submission ends editing, yields, then validates.
    public static func buttonDisabled(isBusy: Bool) -> Bool {
        isBusy
    }

    public static func normalizedToken(_ rawValue: String) -> String? {
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
