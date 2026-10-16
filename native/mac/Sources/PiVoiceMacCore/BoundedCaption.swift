import Foundation

/// One memory-only, grapheme-safe caption buffer with independent character and
/// UTF-8 byte bounds.
public struct BoundedCaption: Equatable, Sendable {
    public let characterLimit: Int
    public let utf8ByteLimit: Int
    public private(set) var text = ""

    public init(characterLimit: Int = 500, utf8ByteLimit: Int = 4_096) {
        precondition(characterLimit > 0 && utf8ByteLimit > 0)
        self.characterLimit = characterLimit
        self.utf8ByteLimit = utf8ByteLimit
    }

    public mutating func append(_ delta: String) {
        for character in delta {
            guard String(character).utf8.count <= utf8ByteLimit else { continue }
            text.append(character)
            while text.count > characterLimit || text.utf8.count > utf8ByteLimit {
                text.removeFirst()
            }
        }
    }

    public mutating func replace(with value: String) {
        clear()
        append(value)
    }

    public mutating func clear() {
        text.removeAll(keepingCapacity: false)
    }
}
