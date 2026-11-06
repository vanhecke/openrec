import Foundation
import XCTest
@testable import OpenRecApp

final class LocalMeetingTextFilesTests: XCTestCase {
    func testThisMacMeetingWritesRetainedTextBesideScreenAndAudio() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let screen = try writeMedia(session.folder, "screen.mp4", bytes: "screen-bytes")
        let audio = try writeMedia(session.folder, "audio.m4a", bytes: "audio-bytes")
        let meeting = makeMeeting(
            id: session.meetingID,
            mode: .local,
            screenPath: screen.path,
            audioPath: audio.path,
            transcript: "[Speaker A] We should ship it.\n[Speaker B] Maya will send notes.",
            speakerNames: ["Speaker A": "Maya"],
            insights: sampleInsights()
        )

        try LocalMeetingTextFiles.sync(meeting)

        let text = session.folder.appendingPathComponent(LocalMeetingTextFiles.directoryName, isDirectory: true)
        XCTAssertEqual(
            try read(text, LocalMeetingTextFiles.transcriptFileName),
            "[Maya] We should ship it.\n[Speaker B] Maya will send notes."
        )
        XCTAssertEqual(try read(text, LocalMeetingTextFiles.summaryFileName), "Agreed to ship the export.")
        XCTAssertEqual(try read(text, LocalMeetingTextFiles.notesFileName), "## Notes\n\nShip the export.")
        XCTAssertEqual(try read(text, LocalMeetingTextFiles.participantsFileName), "Maya, Jordan")
        XCTAssertEqual(
            try read(text, LocalMeetingTextFiles.nextStepsFileName),
            MeetingClipboardText.nextSteps(for: meeting)
        )
        XCTAssertEqual(try read(text, LocalMeetingTextFiles.decisionsFileName), "• Ship the export")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.folder.appendingPathComponent("transcript.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.folder.appendingPathComponent("screen_transcript.txt").path))
        XCTAssertEqual(try Data(contentsOf: screen), Data("screen-bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: audio), Data("audio-bytes".utf8))
    }

    func testAudioOnlySessionWritesTextNextToTheAudioFile() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let audio = try writeMedia(session.folder, "audio.m4a", bytes: "audio-only")
        let meeting = makeMeeting(
            id: session.meetingID,
            mode: .local,
            screenPath: nil,
            audioPath: audio.path,
            transcript: "[Speaker 0] Hello",
            speakerNames: ["Speaker 0": "Jordan"],
            insights: MeetingInsights(title: "Audio only")
        )

        try LocalMeetingTextFiles.sync(meeting)

        let text = session.folder.appendingPathComponent(LocalMeetingTextFiles.directoryName)
        XCTAssertEqual(try read(text, LocalMeetingTextFiles.transcriptFileName), "[Jordan] Hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.appendingPathComponent(LocalMeetingTextFiles.summaryFileName).path))
        XCTAssertEqual(try Data(contentsOf: audio), Data("audio-only".utf8))
    }

    func testSpeakerNameEditsRewriteTheOnDiskTranscript() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let screen = try writeMedia(session.folder, "screen.mp4", bytes: "video")
        var meeting = makeMeeting(
            id: session.meetingID,
            mode: .local,
            screenPath: screen.path,
            audioPath: nil,
            transcript: "[Speaker A] We should ship it.\n[Speaker B] Maya will send notes.",
            speakerNames: ["Speaker A": "Maya"],
            insights: MeetingInsights(title: "Design review", summary: "Agreed to ship the export.")
        )

        try LocalMeetingTextFiles.sync(meeting)
        let transcriptURL = session.folder
            .appendingPathComponent(LocalMeetingTextFiles.directoryName)
            .appendingPathComponent(LocalMeetingTextFiles.transcriptFileName)
        XCTAssertEqual(
            try String(contentsOf: transcriptURL, encoding: .utf8),
            "[Maya] We should ship it.\n[Speaker B] Maya will send notes."
        )

        meeting.speakerNames = ["Speaker A": "Maya", "Speaker B": "Jordan"]
        try LocalMeetingTextFiles.sync(meeting)
        XCTAssertEqual(
            try String(contentsOf: transcriptURL, encoding: .utf8),
            "[Maya] We should ship it.\n[Jordan] Maya will send notes."
        )

        meeting.speakerNames = ["Speaker B": "Jordan"]
        try LocalMeetingTextFiles.sync(meeting)
        XCTAssertEqual(
            try String(contentsOf: transcriptURL, encoding: .utf8),
            "[Speaker A] We should ship it.\n[Jordan] Maya will send notes."
        )
        XCTAssertEqual(try read(session.folder.appendingPathComponent("text"), "summary.txt"), "Agreed to ship the export.")
    }

    func testClearingTranscriptAndNotesRemovesThoseFiles() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let screen = try writeMedia(session.folder, "screen.mp4", bytes: "video")
        let text = session.folder.appendingPathComponent(LocalMeetingTextFiles.directoryName, isDirectory: true)
        var meeting = makeMeeting(
            id: session.meetingID,
            mode: .local,
            screenPath: screen.path,
            audioPath: nil,
            transcript: "[Speaker A] Hello",
            speakerNames: ["Speaker A": "Maya"],
            insights: sampleInsights()
        )
        try LocalMeetingTextFiles.sync(meeting)
        try "keep".write(to: text.appendingPathComponent("keep-me.txt"), atomically: true, encoding: .utf8)

        meeting.transcript = nil
        meeting.insights.summary = "   "
        meeting.insights.aiNotes = ""
        meeting.insights.participants = []
        meeting.insights.actionItems = []
        try LocalMeetingTextFiles.sync(meeting)

        XCTAssertFalse(FileManager.default.fileExists(atPath: text.appendingPathComponent(LocalMeetingTextFiles.transcriptFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.appendingPathComponent(LocalMeetingTextFiles.summaryFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.appendingPathComponent(LocalMeetingTextFiles.notesFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.appendingPathComponent(LocalMeetingTextFiles.participantsFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.appendingPathComponent(LocalMeetingTextFiles.nextStepsFileName).path))
        XCTAssertEqual(try read(text, LocalMeetingTextFiles.decisionsFileName), "• Ship the export")
        XCTAssertEqual(try read(text, "keep-me.txt"), "keep")

        meeting.insights.decisions = []
        try LocalMeetingTextFiles.sync(meeting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.appendingPathComponent(LocalMeetingTextFiles.decisionsFileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path))
        XCTAssertEqual(try read(text, "keep-me.txt"), "keep")
        XCTAssertEqual(try Data(contentsOf: screen), Data("video".utf8))
    }

    func testEmptyTextFolderIsRemovedWhenNothingIsRetained() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let screen = try writeMedia(session.folder, "screen.mp4", bytes: "video")
        var meeting = makeMeeting(
            id: session.meetingID,
            mode: .local,
            screenPath: screen.path,
            audioPath: nil,
            transcript: "Hello",
            speakerNames: nil,
            insights: MeetingInsights(title: "Untitled call")
        )
        try LocalMeetingTextFiles.sync(meeting)
        let text = session.folder.appendingPathComponent(LocalMeetingTextFiles.directoryName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.appendingPathComponent("transcript.txt").path))

        meeting.transcript = nil
        try LocalMeetingTextFiles.sync(meeting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: screen.path))
    }

    func testCloudAndR2MeetingsDoNotCreateATextFolder() throws {
        for mode in [StorageMode.managed, .ownR2] {
            let session = try makeSession()
            defer { try? FileManager.default.removeItem(at: session.root) }
            let screen = try writeMedia(session.folder, "screen.mp4", bytes: "cloud-video")
            let audio = try writeMedia(session.folder, "audio.m4a", bytes: "cloud-audio")
            let meeting = makeMeeting(
                id: session.meetingID,
                mode: mode,
                screenPath: screen.path,
                audioPath: audio.path,
                transcript: "[Speaker A] Secret meeting text",
                speakerNames: ["Speaker A": "Maya"],
                insights: sampleInsights()
            )

            try LocalMeetingTextFiles.sync(meeting, recordingsDirectory: session.root)

            let names = try FileManager.default.contentsOfDirectory(atPath: session.folder.path)
            XCTAssertEqual(names.sorted(), ["audio.m4a", "screen.mp4"])
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: session.folder.appendingPathComponent(LocalMeetingTextFiles.directoryName).path
                )
            )
            XCTAssertEqual(try Data(contentsOf: screen), Data("cloud-video".utf8))
            XCTAssertEqual(try Data(contentsOf: audio), Data("cloud-audio".utf8))
        }
    }

    func testLegacyRecordingSidecarIsNotReplacedByATextFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrec-legacy-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = try writeMedia(root, "recording_2026-01-01_120000.mp4", bytes: "legacy")
        let meeting = makeMeeting(
            id: UUID(),
            mode: .local,
            screenPath: screen.path,
            audioPath: nil,
            transcript: "Imported transcript",
            speakerNames: nil,
            insights: MeetingInsights(title: "Legacy", summary: "Old notes")
        )

        try LocalMeetingTextFiles.sync(meeting, recordingsDirectory: root)

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, ["recording_2026-01-01_120000.mp4"])
    }

    func testStaleScreenPathUsesTheAudioSessionInstead() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let audio = try writeMedia(session.folder, "audio.m4a", bytes: "audio")
        let missingScreen = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrec-missing-screen-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("screen.mp4")
        let meeting = makeMeeting(
            id: session.meetingID,
            mode: .local,
            screenPath: missingScreen.path,
            audioPath: audio.path,
            transcript: "Hello from audio",
            speakerNames: nil,
            insights: MeetingInsights(title: "Audio")
        )

        try LocalMeetingTextFiles.sync(meeting)

        XCTAssertEqual(
            try read(session.folder.appendingPathComponent("text"), LocalMeetingTextFiles.transcriptFileName),
            "Hello from audio"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingScreen.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: audio), Data("audio".utf8))
    }

    func testMissingSessionDirectoryIsNotCreated() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrec-absent-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("screen.mp4")
        let meeting = makeMeeting(
            id: UUID(),
            mode: .local,
            screenPath: missing.path,
            audioPath: nil,
            transcript: "Hello",
            speakerNames: nil,
            insights: sampleInsights()
        )

        try LocalMeetingTextFiles.sync(meeting)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    func testSpeakerNameEditRewritesTranscriptAfterMediaPathsWereCleared() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let screen = try writeMedia(session.folder, "screen.mp4", bytes: "video")
        var meeting = makeMeeting(
            id: session.meetingID,
            mode: .local,
            screenPath: screen.path,
            audioPath: nil,
            transcript: "[Speaker A] Hello",
            speakerNames: ["Speaker A": "Maya"],
            insights: MeetingInsights(title: "Design review")
        )
        try LocalMeetingTextFiles.sync(meeting)

        meeting.localScreenPath = nil
        meeting.speakerNames = ["Speaker A": "Ada"]
        try LocalMeetingTextFiles.sync(meeting, recordingsDirectory: session.root)

        XCTAssertEqual(
            try read(session.folder.appendingPathComponent("text"), LocalMeetingTextFiles.transcriptFileName),
            "[Ada] Hello"
        )
        XCTAssertEqual(try Data(contentsOf: screen), Data("video".utf8))
    }

    private func read(_ directory: URL, _ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func makeSession() throws -> (root: URL, folder: URL, meetingID: UUID) {
        let meetingID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrec-text-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(meetingID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, folder, meetingID)
    }

    private func writeMedia(_ folder: URL, _ name: String, bytes: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func sampleInsights() -> MeetingInsights {
        MeetingInsights(
            title: "Design review",
            summary: "Agreed to ship the export.",
            aiNotes: "## Notes\n\nShip the export.",
            participants: ["Maya", "Jordan"],
            actionItems: [MeetingActionItem(owner: "Maya", task: "Send notes", dueDate: "Friday")],
            decisions: ["Ship the export"]
        )
    }

    private func makeMeeting(
        id: UUID,
        mode: StorageMode,
        screenPath: String?,
        audioPath: String?,
        transcript: String?,
        speakerNames: [String: String]?,
        insights: MeetingInsights
    ) -> MeetingRecord {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return MeetingRecord(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            durationSeconds: 90,
            callApp: "FaceTime",
            callTitle: "Design review",
            transcript: transcript,
            speakerNames: speakerNames,
            insights: insights,
            hasScreenRecording: screenPath != nil,
            hasAudioRecording: audioPath != nil,
            screenFileExtension: screenPath == nil ? nil : "mp4",
            audioFileExtension: audioPath == nil ? nil : "m4a",
            localScreenPath: screenPath,
            localAudioPath: audioPath,
            storageMode: mode,
            preferences: CallPreferences(
                keepScreenRecording: true,
                keepAudioRecording: true,
                storeTranscriptInCloud: transcript != nil,
                sendToWebhook: false
            ),
            saveStatus: .saved,
            saveStage: .complete,
            errorMessage: nil,
            createdAt: startedAt,
            updatedAt: startedAt
        )
    }
}
