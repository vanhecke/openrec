import SwiftUI

/// Compact notes composer shown on the recorder HUD only after the notes button is pressed.
struct RecordingNotesPanel: View {
    @ObservedObject var session: RecordingNotesSession
    var elapsed: () -> TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.white.opacity(0.12).frame(height: 1)

            HStack(spacing: 6) {
                Text("My notes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
                Spacer(minLength: 0)
                Button { session.isOpen = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Close notes")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if session.notes.isEmpty {
                        Text("Each line is stamped when you start typing it.")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(session.notes) { note in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(RecordingNoteClock.format(note.elapsedSeconds))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.45))
                                Text(note.text)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.88))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            HStack(spacing: 6) {
                Text(session.draftElapsed.map(RecordingNoteClock.format) ?? "––:––")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(session.draftElapsed == nil ? 0.28 : 0.7))
                    .frame(width: 52, alignment: .leading)
                TextField(
                    "Note",
                    text: Binding(
                        get: { session.draft },
                        set: { session.updateDraft($0, elapsed: elapsed()) }
                    ),
                    prompt: Text("Type a note").foregroundColor(.white.opacity(0.32))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .onSubmit { session.commitDraft(elapsed: elapsed()) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}
