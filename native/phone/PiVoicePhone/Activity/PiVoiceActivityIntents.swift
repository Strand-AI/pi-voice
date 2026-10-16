import AppIntents
import Foundation

@MainActor
protocol PiVoiceActivityControlHandling: AnyObject {
    func activitySetMuted(ticket: String, desiredMuted: Bool)
    func activityEnd(ticket: String) async
}

@MainActor
enum PiVoiceActivityControlBridge {
    static weak var handler: PiVoiceActivityControlHandling?

    static func setMuted(ticket: String, desiredMuted: Bool) {
        handler?.activitySetMuted(ticket: ticket, desiredMuted: desiredMuted)
    }

    static func end(ticket: String) async {
        await handler?.activityEnd(ticket: ticket)
    }
}

struct PiVoiceSetMutedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Pi Voice microphone mute"
    static let isDiscoverable = false
    @available(iOS 26.0, *) static let supportedModes: IntentModes = .background

    @Parameter(title: "Activity ticket") var ticket: String
    @Parameter(title: "Muted") var desiredMuted: Bool

    init() {}
    init(ticket: String, desiredMuted: Bool) {
        self.ticket = ticket
        self.desiredMuted = desiredMuted
    }

    func perform() async throws -> some IntentResult {
        await PiVoiceActivityControlBridge.setMuted(ticket: ticket, desiredMuted: desiredMuted)
        return .result()
    }
}

struct PiVoiceEndIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Pi Voice"
    static let isDiscoverable = false
    @available(iOS 26.0, *) static let supportedModes: IntentModes = .background

    @Parameter(title: "Activity ticket") var ticket: String

    init() {}
    init(ticket: String) { self.ticket = ticket }

    func perform() async throws -> some IntentResult {
        await PiVoiceActivityControlBridge.end(ticket: ticket)
        return .result()
    }
}
