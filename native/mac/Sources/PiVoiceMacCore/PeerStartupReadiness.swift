/// A peer cannot accept application input until its own ICE offer and primary startup are ready.
public struct PeerStartupReadiness: Sendable {
    private var revision: Int?
    private var gathered = false
    private var started = false
    public init() {}
    public mutating func begin(_ revision: Int) {
        self.revision = revision
        gathered = false
        started = false
    }
    public mutating func iceGathered(_ revision: Int) {
        guard self.revision == revision else { return }
        gathered = true
    }
    public mutating func observe(type: String, revision: Int) {
        guard self.revision == revision, type == "session.started" else { return }
        started = true
    }
    public func ready(_ revision: Int) -> Bool {
        self.revision == revision && gathered && started
    }
    public mutating func invalidate() { revision = nil; gathered = false; started = false }
}
