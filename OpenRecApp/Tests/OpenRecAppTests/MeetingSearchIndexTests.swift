import Foundation
import XCTest
@testable import OpenRecApp

final class MeetingSearchIndexTests: XCTestCase {
    func testTokenizerFoldsCaseDiacriticsAndApostrophes() {
        let terms = MeetingSearchTokenizer.tokens(in: "Café, RÉSUMÉ — don't naïve").map(\.term)
        XCTAssertEqual(terms, ["cafe", "resume", "dont", "naive"])
    }

    func testSearchIsCaseAndDiacriticInsensitive() throws {
        let index = MeetingSearchIndex()
        let id = UUID()
        index.upsert(makeMeeting(
            id: id,
            title: "Café sync",
            transcript: "We compared the résumé."
        ))

        let fromQuery = try XCTUnwrap(index.search(query: "CAFÉ").first)
        XCTAssertEqual(fromQuery.id, id)
        XCTAssertTrue(fromQuery.matchesTitle)
        XCTAssertTrue(fromQuery.snippetReplacesTitle)
        XCTAssertEqual(fromQuery.snippet.segments.filter(\.isMatch).map(\.text), ["Café"])

        let fromBody = try XCTUnwrap(index.search(query: "resume").first)
        XCTAssertEqual(fromBody.id, id)
        XCTAssertFalse(fromBody.matchesTitle)
        XCTAssertEqual(fromBody.snippet.segments.filter(\.isMatch).map(\.text), ["résumé"])
    }

    func testAndMatchesEveryWordAndPrefixMatchesOnlyTheLastWord() {
        let index = MeetingSearchIndex()
        let review = UUID()
        let budgetOnly = UUID()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        index.upsert(makeMeeting(
            id: review,
            title: "Standup",
            transcript: "The budget review is tomorrow.",
            startedAt: older
        ))
        index.upsert(makeMeeting(
            id: budgetOnly,
            title: "Standup",
            transcript: "The budget only.",
            startedAt: older.addingTimeInterval(3_600)
        ))

        XCTAssertEqual(index.search(query: "budget rev").map(\.id), [review])
        XCTAssertEqual(index.search(query: "  Budget   REVIEW ").map(\.id), [review])
        XCTAssertTrue(index.search(query: "rev budget").isEmpty)
        XCTAssertTrue(index.search(query: "budg review").isEmpty)
        XCTAssertEqual(index.search(query: "bud").map(\.id), [budgetOnly, review])
        XCTAssertTrue(index.search(query: "   ").isEmpty)
        XCTAssertTrue(index.search(query: "...").isEmpty)
    }

    func testTitleMatchesRankAboveBodyMatchesThenRecency() {
        let index = MeetingSearchIndex()
        let olderTitle = UUID()
        let newerTitle = UUID()
        let olderBody = UUID()
        let newerBody = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        index.upsert(makeMeeting(
            id: olderTitle,
            title: "Budget review",
            transcript: "Unrelated notes.",
            startedAt: base
        ))
        index.upsert(makeMeeting(
            id: newerBody,
            title: "Standup",
            transcript: "We circled back to the budget.",
            startedAt: base.addingTimeInterval(86_400)
        ))
        index.upsert(makeMeeting(
            id: olderBody,
            title: "Other",
            transcript: "budget mentioned once",
            startedAt: base.addingTimeInterval(3_600)
        ))
        index.upsert(makeMeeting(
            id: newerTitle,
            title: "Budget sync",
            transcript: "",
            startedAt: base.addingTimeInterval(172_800)
        ))

        let hits = index.search(query: "budget")
        XCTAssertEqual(hits.map(\.id), [newerTitle, olderTitle, newerBody, olderBody])
        XCTAssertEqual(hits.map(\.matchesTitle), [true, true, false, false])
    }

    func testSnippetUsesTheFirstMatchAndHighlightsEveryTermInTheWindow() throws {
        let index = MeetingSearchIndex()
        let id = UUID()
        let filler = String(repeating: "xxxx ", count: 40)
        let tail = String(repeating: "yyyy ", count: 40)
        index.upsert(makeMeeting(
            id: id,
            title: "Standup",
            summary: "Nothing about money.",
            transcript: filler + "quarterly budget approved " + tail
        ))

        let hit = try XCTUnwrap(index.search(query: "quarterly bud").first)
        XCTAssertEqual(hit.id, id)
        XCTAssertFalse(hit.matchesTitle)
        XCTAssertFalse(hit.snippetReplacesTitle)
        XCTAssertTrue(hit.snippet.text.hasPrefix("…"))
        XCTAssertTrue(hit.snippet.text.hasSuffix("…"))
        XCTAssertTrue(hit.snippet.text.contains("quarterly budget"))
        XCTAssertFalse(hit.snippet.text.contains(String(repeating: "xxxx ", count: 20)))
        XCTAssertEqual(hit.snippet.segments.filter(\.isMatch).map(\.text), ["quarterly", "budget"])
        XCTAssertFalse(hit.snippet.text.contains("Nothing about money"))
    }

    func testSearchCoversSummaryDecisionsNextStepsNamesTranscriptAndNotes() throws {
        let index = MeetingSearchIndex()
        let id = UUID()
        index.upsert(makeMeeting(
            id: id,
            title: "Q3 Budget",
            callTitle: "Finance sync",
            summary: "We aligned on headcount.",
            aiNotes: "Roadmap stays in the notes.",
            decisions: ["Freeze hiring"],
            actionItems: [MeetingActionItem(owner: "Priya", task: "Send the forecast", dueDate: "Friday")],
            participants: ["Priya", "Luis"],
            transcript: "[Speaker A] The runway looks fine.",
            speakerNames: ["Speaker A": "Luis"]
        ))

        let queries = [
            "q3", "finance", "headcount", "roadmap", "freeze", "forecast", "friday", "priya", "runway", "luis",
        ]
        for query in queries {
            XCTAssertEqual(index.search(query: query).map(\.id), [id], query)
        }
        XCTAssertTrue(try XCTUnwrap(index.search(query: "finance").first).matchesTitle)
        XCTAssertFalse(try XCTUnwrap(index.search(query: "runway").first).matchesTitle)

        let titleHit = try XCTUnwrap(index.search(query: "budget").first)
        XCTAssertTrue(titleHit.snippetReplacesTitle)
        XCTAssertEqual(titleHit.snippet.text, "Q3 Budget")
        XCTAssertEqual(titleHit.snippet.segments.filter(\.isMatch).map(\.text), ["Budget"])
    }

    func testIndexUpdatesOnSaveEditAndDelete() {
        let index = MeetingSearchIndex()
        let id = UUID()
        let other = UUID()
        var meeting = makeMeeting(
            id: id,
            title: "Planning",
            transcript: "[Speaker A] Ship the budget."
        )
        index.upsert(meeting)
        index.upsert(meeting)
        XCTAssertEqual(index.search(query: "budget").map(\.id), [id])

        meeting.transcript = "[Speaker A] Ship the forecast."
        meeting.speakerNames = ["Speaker A": "Renée"]
        meeting.insights.summary = "Renamed the plan"
        index.upsert(meeting)

        XCTAssertTrue(index.search(query: "budget").isEmpty)
        XCTAssertEqual(index.search(query: "forecast").map(\.id), [id])
        XCTAssertEqual(index.search(query: "renee").map(\.id), [id])

        let kept = makeMeeting(
            id: other,
            title: "Kept",
            transcript: "The forecast stays.",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        index.upsert(kept)
        index.remove(id: id)
        XCTAssertTrue(index.search(query: "renee").isEmpty)
        XCTAssertEqual(index.search(query: "forecast").map(\.id), [other])

        index.replaceAll([kept])
        XCTAssertEqual(index.search(query: "forecast").map(\.id), [other])
        index.replaceAll([])
        XCTAssertTrue(index.search(query: "forecast").isEmpty)
    }
}

private func makeMeeting(
    id: UUID = UUID(),
    title: String = "Untitled call",
    callTitle: String? = nil,
    summary: String = "",
    aiNotes: String = "",
    decisions: [String] = [],
    actionItems: [MeetingActionItem] = [],
    participants: [String] = [],
    transcript: String? = nil,
    speakerNames: [String: String]? = nil,
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> MeetingRecord {
    MeetingRecord(
        id: id,
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(60),
        durationSeconds: 60,
        callApp: nil,
        callTitle: callTitle,
        transcript: transcript,
        speakerNames: speakerNames,
        insights: MeetingInsights(
            title: title,
            summary: summary,
            aiNotes: aiNotes,
            participants: participants,
            actionItems: actionItems,
            decisions: decisions
        ),
        hasScreenRecording: false,
        hasAudioRecording: false,
        screenFileExtension: nil,
        audioFileExtension: nil,
        localScreenPath: nil,
        localAudioPath: nil,
        storageMode: .local,
        preferences: CallPreferences(),
        saveStatus: .saved,
        saveStage: .complete,
        errorMessage: nil,
        createdAt: startedAt,
        updatedAt: startedAt
    )
}
