import Foundation

/// One accepted display segment in exact arrival order. It is presentation-only:
/// neither a group nor a stable marker proves a provider final turn.
public struct VoiceCaptionSegment: Equatable, Sendable {
    public enum Speaker: Equatable, Sendable {
        case user
        case agent
    }

    public let generation: String
    public let speaker: Speaker
    public let text: String
    public let isCurrent: Bool

    public init(generation: String, speaker: Speaker, text: String, isCurrent: Bool) {
        self.generation = generation
        self.speaker = speaker
        self.text = text
        self.isCurrent = isCurrent
    }
}

/// Memory-only, bounded display projection of accepted caption events.
/// A segment is extended only while it remains the tail with the same speaker
/// and group. Interleaving therefore preserves actual display order even when
/// a speaker later returns with the same provider group identifier.
public struct BoundedCaptionThread: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let generation: String
        let speaker: VoiceCaptionSegment.Speaker
        let groupID: String?
        var caption: BoundedCaption
        var isStreaming: Bool
    }

    public let segmentLimit: Int
    public let speakerCharacterLimit: Int
    public let speakerUTF8ByteLimit: Int
    private var entries: [Entry] = []

    public init(segmentLimit: Int = 3, speakerCharacterLimit: Int = 500, speakerUTF8ByteLimit: Int = 4_096) {
        precondition(segmentLimit > 0 && speakerCharacterLimit > 0 && speakerUTF8ByteLimit > 0)
        self.segmentLimit = segmentLimit
        self.speakerCharacterLimit = speakerCharacterLimit
        self.speakerUTF8ByteLimit = speakerUTF8ByteLimit
    }

    public var segments: [VoiceCaptionSegment] {
        entries.map {
            VoiceCaptionSegment(
                generation: $0.generation,
                speaker: $0.speaker,
                text: $0.caption.text,
                isCurrent: $0.isStreaming
            )
        }
    }

    public mutating func accept(
        generation: String,
        speaker: VoiceCaptionSegment.Speaker,
        delta: String,
        groupID: String?
    ) {
        guard !generation.isEmpty, !delta.isEmpty else { return }
        if let last = entries.indices.last,
           entries[last].generation == generation,
           entries[last].speaker == speaker,
           entries[last].groupID == groupID {
            if groupID == nil { entries[last].caption.replace(with: delta) }
            else { entries[last].caption.append(delta) }
            entries[last].isStreaming = groupID != nil
        } else {
            if let last = entries.indices.last { entries[last].isStreaming = false }
            var caption = BoundedCaption(
                characterLimit: speakerCharacterLimit,
                utf8ByteLimit: speakerUTF8ByteLimit
            )
            caption.append(delta)
            entries.append(Entry(
                generation: generation,
                speaker: speaker,
                groupID: groupID,
                caption: caption,
                isStreaming: groupID != nil
            ))
        }
        enforceBounds(for: speaker)
        if entries.count > segmentLimit {
            entries.removeFirst(entries.count - segmentLimit)
        }
    }

    public mutating func markStable(
        generation: String,
        speaker: VoiceCaptionSegment.Speaker,
        groupID: String
    ) -> Bool {
        guard let index = entries.lastIndex(where: {
            $0.generation == generation && $0.speaker == speaker && $0.groupID == groupID
        }) else { return false }
        entries[index].isStreaming = false
        return true
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: false)
    }

    private mutating func enforceBounds(for speaker: VoiceCaptionSegment.Speaker) {
        while aggregate(for: speaker).characters > speakerCharacterLimit ||
                aggregate(for: speaker).bytes > speakerUTF8ByteLimit {
            guard let index = entries.firstIndex(where: { $0.speaker == speaker }) else { return }
            var text = entries[index].caption.text
            guard !text.isEmpty else {
                entries.remove(at: index)
                continue
            }
            text.removeFirst()
            if text.isEmpty {
                entries.remove(at: index)
            } else {
                entries[index].caption.replace(with: text)
            }
        }
    }

    private func aggregate(for speaker: VoiceCaptionSegment.Speaker) -> (characters: Int, bytes: Int) {
        entries.lazy.filter { $0.speaker == speaker }.reduce(into: (characters: 0, bytes: 0)) {
            $0.characters += $1.caption.text.count
            $0.bytes += $1.caption.text.utf8.count
        }
    }
}
