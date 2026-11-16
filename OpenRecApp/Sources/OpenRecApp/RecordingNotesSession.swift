import Combine
import Foundation

/// Notes typed on the recorder HUD for the recording that is in progress.
/// The stamp on a line locks when the draft goes from empty to non-empty and
/// stays put while that line is edited. Clearing the draft releases it.
@MainActor
final class RecordingNotesSession: ObservableObject {
    @Published private(set) var notes: [RecordingNote] = []
    @Published private(set) var draft = ""
    @Published var isOpen = false
    /// Elapsed recording time captured when the current draft started. Nil while the field is empty.
    @Published private(set) var draftElapsed: TimeInterval?

    func reset() {
        notes = []
        draft = ""
        draftElapsed = nil
        isOpen = false
    }

    func updateDraft(_ text: String, elapsed: TimeInterval) {
        if text.isEmpty {
            draftElapsed = nil
        } else if draft.isEmpty {
            draftElapsed = max(0, elapsed)
        }
        draft = text
    }

    /// Keeps the line only when it has non-whitespace text. The stamp is the
    /// moment typing started, not the moment Return was pressed.
    func commitDraft(elapsed: TimeInterval) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = draftElapsed ?? max(0, elapsed)
        draft = ""
        draftElapsed = nil
        guard !text.isEmpty else { return }
        notes.append(RecordingNote(id: UUID(), elapsedSeconds: stamp, text: text))
    }
}
