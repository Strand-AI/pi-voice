import Foundation

public struct VoiceUIPreferences: Equatable, Sendable {
    public let mode: VoiceMode
    public let voice: VoiceName

    public init(mode: VoiceMode, voice: VoiceName) {
        self.mode = mode
        self.voice = voice
    }
}

/// Persists UI choices only. Loading these values never selects an endpoint,
/// opens media, or starts a provider session.
public enum VoicePreferencePolicy {
    public static let modeKey = "voiceMode"
    public static let voiceKey = "voiceName"
    public static let defaultMode: VoiceMode = .ptt
    public static let defaultVoice: VoiceName = .marin

    /// Invalid, deleted, or wrongly typed values are replaced with safe defaults
    /// so a later launch observes the same validated state.
    public static func restore(from defaults: UserDefaults = .standard) -> VoiceUIPreferences {
        let mode = defaults.string(forKey: modeKey).flatMap(VoiceMode.init(rawValue:)) ?? defaultMode
        let voice = defaults.string(forKey: voiceKey).flatMap(VoiceName.init(rawValue:)) ?? defaultVoice
        defaults.set(mode.rawValue, forKey: modeKey)
        defaults.set(voice.rawValue, forKey: voiceKey)
        return VoiceUIPreferences(mode: mode, voice: voice)
    }

    public static func save(mode: VoiceMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    public static func save(voice: VoiceName, to defaults: UserDefaults = .standard) {
        defaults.set(voice.rawValue, forKey: voiceKey)
    }
}
