import Foundation
import XCTest
@testable import OpenRecApp

final class RecordingNotesTests: XCTestCase {
    func testClockFormatsMinutesAndHours() {
        XCTAssertEqual(RecordingNoteClock.format(0), "00:00")
        XCTAssertEqual(RecordingNoteClock.format(5), "00:05")
        XCTAssertEqual(RecordingNoteClock.format(65), "01:05")
        XCTAssertEqual(RecordingNoteClock.format(65.9), "01:05")
        XCTAssertEqual(RecordingNoteClock.format(3_600), "1:00:00")
        XCTAssertEqual(RecordingNoteClock.format(3_661), "1:01:01")
        XCTAssertEqual(RecordingNoteClock.format(-4), "00:00")
    }

    @MainActor
    func testLineStampLocksWhenTypingStarts() throws {
        let session = RecordingNotesSession()
        session.updateDraft("B", elapsed: 65)
        XCTAssertEqual(try XCTUnwrap(session.draftElapsed), 65, accuracy: 0.001)
        session.updateDraft("Budget question", elapsed: 80)
        XCTAssertEqual(try XCTUnwrap(session.draftElapsed), 65, accuracy: 0.001)

        session.commitDraft(elapsed: 90)
        XCTAssertEqual(session.notes.count, 1)
        XCTAssertEqual(session.notes[0].elapsedSeconds, 65, accuracy: 0.001)
        XCTAssertEqual(session.notes[0].text, "Budget question")
        XCTAssertNil(session.draftElapsed)
        XCTAssertTrue(session.draft.isEmpty)
    }

    @MainActor
    func testClearingTheDraftReleasesTheStamp() throws {
        let session = RecordingNotesSession()
        session.updateDraft("Hi", elapsed: 12)
        session.updateDraft("", elapsed: 20)
        XCTAssertNil(session.draftElapsed)

        session.updateDraft("Later", elapsed: 40)
        XCTAssertEqual(try XCTUnwrap(session.draftElapsed), 40, accuracy: 0.001)
        session.commitDraft(elapsed: 48)
        XCTAssertEqual(session.notes.map(\.elapsedSeconds), [40.0])
        XCTAssertEqual(session.notes.map(\.text), ["Later"])
    }

    @MainActor
    func testBlankDraftDoesNotCreateANote() {
        let session = RecordingNotesSession()
        session.updateDraft("   ", elapsed: 8)
        session.commitDraft(elapsed: 9)
        XCTAssertTrue(session.notes.isEmpty)
        XCTAssertNil(session.draftElapsed)
    }

    func testNearestCueUsesTheClosestStart() throws {
        let early = TranscriptCue(id: UUID(), speakerLabel: "Speaker A", text: "Hello", startSeconds: 10)
        let middle = TranscriptCue(id: UUID(), speakerLabel: "Speaker B", text: "Budget", startSeconds: 70)
        let late = TranscriptCue(id: UUID(), speakerLabel: "Speaker A", text: "Wrap", startSeconds: 200)
        let cues = [late, early, middle]

        XCTAssertEqual(TranscriptCues.nearest(to: 66, in: cues)?.id, middle.id)
        XCTAssertEqual(TranscriptCues.nearest(to: 0, in: cues)?.id, early.id)
        // 135 is equidistant from 70 and 200, so the earlier cue wins.
        XCTAssertEqual(TranscriptCues.nearest(to: 135, in: cues)?.id, middle.id)
        XCTAssertNil(TranscriptCues.nearest(to: 5, in: []))
    }

    func testOldMeetingJSONWithoutNotesDecodes() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var record = makeNotedMeeting()
        record.notes = [
            RecordingNote(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, elapsedSeconds: 65, text: "Ask about the budget"),
        ]
        record.transcriptCues = [
            TranscriptCue(id: UUID(), speakerLabel: "Speaker A", text: "The budget is fine.", startSeconds: 70),
        ]
        let decoded = try decoder.decode(MeetingRecord.self, from: encoder.encode(record))
        let notes = try XCTUnwrap(decoded.notes)
        XCTAssertEqual(notes.map(\.text), ["Ask about the budget"])
        XCTAssertEqual(notes.map(\.elapsedSeconds), [65.0])
        XCTAssertEqual(try XCTUnwrap(decoded.transcriptCues).map(\.text), ["The budget is fine."])

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(makeNotedMeeting())) as? [String: Any])
        object.removeValue(forKey: "notes")
        object.removeValue(forKey: "transcriptCues")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let older = try decoder.decode(MeetingRecord.self, from: legacy)
        XCTAssertNil(older.notes)
        XCTAssertNil(older.transcriptCues)
        XCTAssertEqual(older.transcript, "[Speaker A] The budget is fine.")
        XCTAssertEqual(older.title, "Budget review")
    }

    func testNotesAreIncludedInBothMeetingMemoryPrompts() throws {
        let transcript = "[Ada] The budget is fine."
        let notes = "01:05 Ask about the budget"
        let plain = AIPromptStore.meetingMemoryUser(transcript: transcript, callTitle: "Launch")
        let withNotes = AIPromptStore.meetingMemoryUser(
            transcript: transcript,
            callTitle: "Launch",
            userNotes: notes
        )
        XCTAssertFalse(plain.contains("user's own notes"))
        XCTAssertFalse(plain.contains(notes))
        XCTAssertTrue(withNotes.hasPrefix(plain))
        XCTAssertTrue(withNotes.contains("The user's own notes"))
        XCTAssertTrue(withNotes.contains("not the transcript"))
        XCTAssertTrue(withNotes.contains(notes))

        let openAI = try OpenAIService(apiKey: "test-openai-key").makeInsightsRequest(
            transcript: transcript,
            callTitle: "Launch",
            userNotes: notes
        )
        let grok = try GrokService(apiKey: "test-xai-token").makeInsightsRequest(
            transcript: transcript,
            callTitle: "Launch",
            userNotes: notes
        )
        let openAIBody = try jsonBody(openAI)
        let grokBody = try jsonBody(grok)
        for body in [openAIBody, grokBody] {
            let content = try userContent(in: body)
            XCTAssertTrue(content.contains("The user's own notes"))
            XCTAssertTrue(content.contains(notes))
            XCTAssertTrue(content.contains(transcript))
            let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
            let schema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
            XCTAssertEqual(schema["name"] as? String, "meeting_insights")
            XCTAssertEqual(schema["strict"] as? Bool, true)
        }
        XCTAssertEqual(openAIBody["model"] as? String, "gpt-5-mini")
        XCTAssertEqual(grokBody["model"] as? String, "grok-4.7")
        XCTAssertNil(openAIBody["reasoning_effort"])
        XCTAssertEqual(grokBody["reasoning_effort"] as? String, "high")

        let without = try OpenAIService(apiKey: "test-openai-key").makeInsightsRequest(
            transcript: transcript,
            callTitle: "Launch"
        )
        let withoutContent = try userContent(in: try jsonBody(without))
        XCTAssertFalse(withoutContent.contains("user's own notes"))
        XCTAssertEqual(withoutContent, plain)
    }

    func testSearchHitsNoteText() throws {
        let index = MeetingSearchIndex()
        let id = UUID()
        var meeting = makeNotedMeeting(id: id)
        meeting.notes = [
            RecordingNote(id: UUID(), elapsedSeconds: 90, text: "Ping the vendor about acme-ledger"),
        ]
        meeting.transcript = "[Speaker A] Nothing about vendors."
        meeting.insights.summary = ""
        meeting.insights.aiNotes = ""
        index.upsert(meeting)

        let hit = try XCTUnwrap(index.search(query: "acme-ledger").first)
        XCTAssertEqual(hit.id, id)
        XCTAssertFalse(hit.matchesTitle)
        XCTAssertTrue(hit.snippet.text.localizedCaseInsensitiveContains("acme-ledger"))

        meeting.notes = nil
        index.upsert(meeting)
        XCTAssertTrue(index.search(query: "acme-ledger").isEmpty)
    }

    func testThisMacTextFolderWritesMyNotesBesideTheTranscript() throws {
        let meetingID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrec-notes-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(meetingID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = folder.appendingPathComponent("screen.mp4")
        try Data("screen".utf8).write(to: screen)

        var meeting = makeNotedMeeting(id: meetingID)
        meeting.storageMode = .local
        meeting.localScreenPath = screen.path
        meeting.hasScreenRecording = true
        meeting.insights.aiNotes = "AI summary notes"
        meeting.notes = [
            RecordingNote(id: UUID(), elapsedSeconds: 65, text: "Ask about the budget"),
        ]

        try LocalMeetingTextFiles.sync(meeting)
        let text = folder.appendingPathComponent(LocalMeetingTextFiles.directoryName, isDirectory: true)
        XCTAssertEqual(
            try String(contentsOf: text.appendingPathComponent(LocalMeetingTextFiles.transcriptFileName), encoding: .utf8),
            "[Speaker A] The budget is fine."
        )
        XCTAssertEqual(
            try String(contentsOf: text.appendingPathComponent(LocalMeetingTextFiles.myNotesFileName), encoding: .utf8),
            "01:05 Ask about the budget"
        )
        XCTAssertEqual(
            try String(contentsOf: text.appendingPathComponent(LocalMeetingTextFiles.notesFileName), encoding: .utf8),
            "AI summary notes"
        )

        meeting.notes = nil
        try LocalMeetingTextFiles.sync(meeting)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: text.appendingPathComponent(LocalMeetingTextFiles.myNotesFileName).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: text.appendingPathComponent(LocalMeetingTextFiles.transcriptFileName).path
        ))
    }

    private func makeNotedMeeting(id: UUID = UUID()) -> MeetingRecord {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return MeetingRecord(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            durationSeconds: 120,
            callApp: nil,
            callTitle: "Finance sync",
            transcript: "[Speaker A] The budget is fine.",
            insights: MeetingInsights(title: "Budget review", summary: "Reviewed the budget."),
            hasScreenRecording: false,
            hasAudioRecording: false,
            screenFileExtension: nil,
            audioFileExtension: nil,
            localScreenPath: nil,
            localAudioPath: nil,
            storageMode: .managed,
            preferences: CallPreferences(),
            saveStatus: .saved,
            saveStage: .complete,
            errorMessage: nil,
            createdAt: startedAt,
            updatedAt: startedAt
        )
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func userContent(in body: [String: Any]) throws -> String {
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        return try XCTUnwrap(messages.last?["content"] as? String)
    }
}
