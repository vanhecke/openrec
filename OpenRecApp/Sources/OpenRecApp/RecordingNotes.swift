import Foundation

/// One line the user typed during a recording.
/// `elapsedSeconds` is the recording clock at the moment typing of this line began.
struct RecordingNote: Codable, Equatable, Identifiable {
    var id: UUID
    var elapsedSeconds: TimeInterval
    var text: String
}

extension Array where Element == RecordingNote {
    /// Empty stays absent so meetings without notes keep the older JSON shape.
    var nilIfEmpty: [RecordingNote]? { isEmpty ? nil : self }
}

/// `mm:ss` until an hour, then `h:mm:ss`. Fractional seconds are dropped.
enum RecordingNoteClock {
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

/// Plain-text rendering shared by search, the This Mac text folder, and the memory prompt.
enum RecordingNotesText {
    /// One line per note, `mm:ss text`. Nil when nothing was kept.
    static func lines(_ notes: [RecordingNote]) -> String? {
        let rendered = notes.compactMap { note -> String? in
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(RecordingNoteClock.format(note.elapsedSeconds)) \(text)"
        }
        guard !rendered.isEmpty else { return nil }
        return rendered.joined(separator: "\n")
    }
}

/// Appends the user's notes to the shared meeting-memory prompt.
/// An empty value leaves the prompt unchanged.
enum RecordingNotesPrompt {
    static func append(_ notes: String?, to prompt: String) -> String {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return prompt }
        let block = """
        The user's own notes, written by the user during the recording. Each line starts with the elapsed time when the user started typing it. These are the user's notes, not the transcript. Use them as extra context.

        \(trimmed)
        """
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return block
        }
        return prompt + "\n\n" + block
    }
}
