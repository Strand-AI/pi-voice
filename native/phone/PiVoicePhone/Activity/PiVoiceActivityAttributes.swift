import ActivityKit
import Foundation

struct PiVoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let phase: String
        let microphoneActive: Bool
        let userMuted: Bool
        let startedAt: Date
        let hardDeadline: Date
        /// Random, generation-scoped local action authority. It is not a provider,
        /// endpoint, target, credential, transcript, or task identifier.
        let controlTicket: String
    }

    /// User-visible roster name only. No endpoint IDs, generations, transcripts,
    /// task text, provider metadata, or credentials enter the Live Activity.
    let agentDisplayName: String
}
