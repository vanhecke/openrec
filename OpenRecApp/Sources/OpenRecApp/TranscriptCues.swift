import Foundation

/// A retained transcript line and the recording time it started.
/// Absent on meetings saved before cues existed, and omitted when the transcript itself is not retained.
struct TranscriptCue: Codable, Equatable, Identifiable {
    var id: UUID
    var speakerLabel: String
    var text: String
    var startSeconds: TimeInterval
}

enum TranscriptCues {
    static func captured(from segments: [DisplaySegment]) -> [TranscriptCue] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptCue(
                id: UUID(),
                speakerLabel: segment.speakerLabel,
                text: text,
                startSeconds: max(0, segment.timestamp ?? 0)
            )
        }
    }

    /// The cue whose start is closest to `elapsed`. Ties keep the earlier cue.
    static func nearest(to elapsed: TimeInterval, in cues: [TranscriptCue]) -> TranscriptCue? {
        let target = max(0, elapsed)
        return cues.min { lhs, rhs in
            let left = abs(lhs.startSeconds - target)
            let right = abs(rhs.startSeconds - target)
            if left != right { return left < right }
            if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
