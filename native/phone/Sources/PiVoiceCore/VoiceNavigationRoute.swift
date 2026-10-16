import Foundation

public enum VoiceNavigationRoute: Equatable, Sendable {
    case live

    /// Navigation only. No URL component is accepted as session, generation, target,
    /// credential, or action authority.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "pivoice",
              components.host?.lowercased() == "live",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              (components.path.isEmpty || components.path == "/"),
              components.query == nil,
              components.fragment == nil else { return nil }
        self = .live
    }

    public static let liveURL = URL(string: "pivoice://live")!
}
