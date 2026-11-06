import Foundation

/// Finder copies of retained meeting text for This Mac storage.
///
/// New recordings land in `{recordings}/{meeting-id}/` as `screen.mp4` and
/// `audio.m4a`. Retained text is written beside those files:
///
/// ```
/// {meeting-id}/
///   screen.mp4
///   audio.m4a
///   text/
///     transcript.txt
///     summary.txt
///     notes.txt
///     participants.txt
///     next-steps.txt
///     decisions.txt
/// ```
///
/// A file is written only when that text is retained, and deleted when it is
/// cleared. Speaker labels in `transcript.txt` use the names shown in Meetings.
/// OpenRec Cloud and My R2 meetings are skipped, and nothing here is uploaded.
/// The Application Support meeting JSON stays the library index.
enum LocalMeetingTextFiles {
    static let directoryName = "text"
    static let transcriptFileName = "transcript.txt"
    static let summaryFileName = "summary.txt"
    static let notesFileName = "notes.txt"
    static let participantsFileName = "participants.txt"
    static let nextStepsFileName = "next-steps.txt"
    static let decisionsFileName = "decisions.txt"

    /// Updates the Finder copy after a This Mac meeting is saved. No-op for
    /// other storage modes, and no-op when this meeting has no `screen.mp4`
    /// / `audio.m4a` session on disk.
    static func sync(
        _ meeting: MeetingRecord,
        recordingsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        guard let session = sessionDirectory(
            for: meeting,
            recordingsDirectory: recordingsDirectory,
            fileManager: fileManager
        ), fileManager.fileExists(atPath: session.path) else { return }

        let directory = session.appendingPathComponent(directoryName, isDirectory: true)
        let files = renderedFiles(for: meeting)
        if files.allSatisfy({ $0.text == nil }) {
            try removeManagedFiles(in: directory, fileManager: fileManager)
            removeDirectoryIfEmpty(directory, fileManager: fileManager)
            return
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            let url = directory.appendingPathComponent(file.name)
            if let text = file.text {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    /// Removes the Finder text folder for a deleted This Mac meeting.
    /// Returns the session directory when one was found, so the caller can
    /// drop that folder once its media files are gone too.
    @discardableResult
    static func remove(
        for meeting: MeetingRecord,
        recordingsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let session = sessionDirectory(
            for: meeting,
            recordingsDirectory: recordingsDirectory,
            fileManager: fileManager
        ) else { return nil }
        let directory = session.appendingPathComponent(directoryName, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        return session
    }

    /// Parent folder of this meeting's `screen.mp4` or `audio.m4a`.
    /// The screen folder wins when it is on disk; otherwise the audio folder
    /// is used. When those paths have been cleared, an existing
    /// `{recordings}/{meeting-id}/` session that already holds media or text
    /// is used so a later name edit can still rewrite `transcript.txt`.
    static func sessionDirectory(
        for meeting: MeetingRecord,
        recordingsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard meeting.storageMode == .local else { return nil }
        if let parent = streamingMediaParent(meeting.localScreenPath),
           fileManager.fileExists(atPath: parent.path) {
            return parent
        }
        if let parent = streamingMediaParent(meeting.localAudioPath),
           fileManager.fileExists(atPath: parent.path) {
            return parent
        }
        guard let recordingsDirectory else { return nil }
        let candidate = LocalMediaStreamingTransport.meetingDirectory(
            directory: recordingsDirectory,
            meetingID: meeting.id
        )
        guard fileManager.fileExists(atPath: candidate.path) else { return nil }
        let markers = ["screen.mp4", "audio.m4a", directoryName]
        guard markers.contains(where: {
            fileManager.fileExists(atPath: candidate.appendingPathComponent($0).path)
        }) else { return nil }
        return candidate
    }

    private struct RenderedFile {
        let name: String
        let text: String?
    }

    /// Same plain text the Meetings window copies, one file per retained field.
    private static func renderedFiles(for meeting: MeetingRecord) -> [RenderedFile] {
        [
            RenderedFile(name: transcriptFileName, text: MeetingClipboardText.transcript(for: meeting)),
            RenderedFile(name: summaryFileName, text: MeetingClipboardText.summary(for: meeting)),
            RenderedFile(name: notesFileName, text: MeetingClipboardText.aiNotes(for: meeting)),
            RenderedFile(name: participantsFileName, text: MeetingClipboardText.participants(for: meeting)),
            RenderedFile(name: nextStepsFileName, text: MeetingClipboardText.nextSteps(for: meeting)),
            RenderedFile(name: decisionsFileName, text: MeetingClipboardText.decisions(for: meeting)),
        ]
    }

    private static func streamingMediaParent(_ path: String?) -> URL? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed)
        switch url.lastPathComponent.lowercased() {
        case "screen.mp4", "audio.m4a":
            return url.deletingLastPathComponent()
        default:
            return nil
        }
    }

    private static func removeManagedFiles(in directory: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for name in [
            transcriptFileName,
            summaryFileName,
            notesFileName,
            participantsFileName,
            nextStepsFileName,
            decisionsFileName,
        ] {
            let url = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private static func removeDirectoryIfEmpty(_ directory: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let remaining = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? ["occupied"]
        guard remaining.isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }
}
