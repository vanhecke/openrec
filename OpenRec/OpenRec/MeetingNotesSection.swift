import SwiftUI

/// My Notes in the meeting detail: edit lines after the call, and jump from a timestamp.
struct MeetingNotesEditor: View {
    let notes: [RecordingNote]
    let primary: Color
    let secondary: Color
    let accent: Color
    var playbackElapsed: () -> TimeInterval
    let onJump: (TimeInterval) -> Void
    let onUpdate: ([RecordingNote]) -> Void

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if notes.isEmpty {
                Text("Notes taken during the recording show up here. Add one to keep it with this meeting.")
                    .font(.system(size: 12))
                    .foregroundColor(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(notes) { note in
                MeetingNoteRow(
                    note: note,
                    primary: primary,
                    accent: accent,
                    onJump: { onJump(note.elapsedSeconds) },
                    onCommit: { commit($0, for: note) },
                    onDelete: { onUpdate(notes.filter { $0.id != note.id }) }
                )
            }
            TextField(
                "",
                text: $draft,
                prompt: Text("Add a note").foregroundColor(Color.white.opacity(0.34))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(primary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onSubmit(addDraft)
        }
    }

    private func addDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let note = RecordingNote(id: UUID(), elapsedSeconds: max(0, playbackElapsed()), text: text)
        draft = ""
        onUpdate(notes + [note])
    }

    private func commit(_ text: String, for note: RecordingNote) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            onUpdate(notes.filter { $0.id != note.id })
            return
        }
        guard trimmed != note.text else { return }
        onUpdate(notes.map { existing in
            guard existing.id == note.id else { return existing }
            var updated = existing
            updated.text = trimmed
            return updated
        })
    }
}

private struct MeetingNoteRow: View {
    let note: RecordingNote
    let primary: Color
    let accent: Color
    let onJump: () -> Void
    let onCommit: (String) -> Void
    let onDelete: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onJump) {
                Text(RecordingNoteClock.format(note.elapsedSeconds))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(accent)
            }
            .buttonStyle(.plain)
            .help("Jump to this moment")
            .frame(width: 58, alignment: .leading)

            TextField("", text: $draft)
                .focused($focused)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(primary)
                .onSubmit { onCommit(draft) }

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Delete note")
        }
        .onAppear { draft = note.text }
        .onChange(of: note.text) { value in
            if !focused { draft = value }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused { onCommit(draft) }
        }
    }
}

/// Transcript lines that can be scrolled to from a note timestamp.
struct TranscriptCueList: View {
    let cues: [TranscriptCue]
    let speakerNames: [String: String]
    let highlightedID: UUID?
    let primary: Color
    let secondary: Color
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(cues) { cue in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(RecordingNoteClock.format(cue.startSeconds))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(secondary)
                        Text(SpeakerNames.displayName(for: cue.speakerLabel, mapping: speakerNames))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(primary.opacity(0.7))
                    }
                    Text(cue.text)
                        .font(.system(size: 12))
                        .foregroundColor(primary.opacity(0.82))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(highlightedID == cue.id ? accent.opacity(0.16) : Color.clear)
                )
                .id(cue.id)
            }
        }
    }
}
