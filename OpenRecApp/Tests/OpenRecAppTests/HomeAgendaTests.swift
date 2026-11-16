import XCTest
@testable import OpenRecApp

final class HomeAgendaTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
    }

    func testNextUpSkipsEndedEventsAndKeepsAnInProgressOne() throws {
        let now = try date(16, 15, 0)
        let agenda = HomeAgendaPlanner.plan(
            events: [
                event("ended", day: 16, startHour: 13, startMinute: 0, endHour: 14, endMinute: 0),
                event("live", day: 16, startHour: 14, startMinute: 30, endHour: 15, endMinute: 30),
                event("later", day: 16, startHour: 16, startMinute: 0, endHour: 16, endMinute: 30),
                event("tomorrow", day: 17, startHour: 9, startMinute: 0, endHour: 9, endMinute: 30),
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(agenda.nextUp?.id, "live")
        XCTAssertEqual(agenda.today.map(\.id), ["later"])
        XCTAssertEqual(agenda.tomorrow.map(\.id), ["tomorrow"])
        XCTAssertEqual(
            HomeAgendaPlanner.relativeStart(now: now, start: try date(16, 14, 30), end: try date(16, 15, 30)),
            "Now"
        )
    }

    func testNextUpIsTheNextEventTodayWhenNothingIsInProgress() throws {
        let now = try date(16, 15, 0)
        let agenda = HomeAgendaPlanner.plan(
            events: [
                event("ended-now", day: 16, startHour: 14, startMinute: 0, endHour: 15, endMinute: 0),
                event("soon", day: 16, startHour: 15, startMinute: 12, endHour: 15, endMinute: 42),
                event("after", day: 16, startHour: 18, startMinute: 0, endHour: 18, endMinute: 30),
                event("day-after", day: 18, startHour: 10, startMinute: 0, endHour: 11, endMinute: 0),
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(agenda.nextUp?.id, "soon")
        XCTAssertEqual(agenda.today.map(\.id), ["after"])
        XCTAssertTrue(agenda.tomorrow.isEmpty)
        XCTAssertFalse(agenda.today.contains { $0.id == "day-after" })
        XCTAssertFalse(agenda.tomorrow.contains { $0.id == "day-after" })
        XCTAssertEqual(
            HomeAgendaPlanner.relativeStart(now: now, start: try date(16, 15, 12), end: try date(16, 15, 42)),
            "in 12 min"
        )
    }

    func testTodayAndTomorrowGroupingLeavesEndedEventsOut() throws {
        let now = try date(16, 11, 0)
        let agenda = HomeAgendaPlanner.plan(
            events: [
                event("morning", day: 16, startHour: 9, startMinute: 0, endHour: 10, endMinute: 0),
                event("afternoon", day: 16, startHour: 15, startMinute: 0, endHour: 15, endMinute: 45),
                event("tomorrow-early", day: 17, startHour: 8, startMinute: 30, endHour: 9, endMinute: 0),
                event("tomorrow-late", day: 17, startHour: 16, startMinute: 0, endHour: 17, endMinute: 0),
                event("later-week", day: 18, startHour: 12, startMinute: 0, endHour: 13, endMinute: 0),
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(agenda.nextUp?.id, "afternoon")
        XCTAssertTrue(agenda.today.isEmpty)
        XCTAssertEqual(agenda.tomorrow.map(\.id), ["tomorrow-early", "tomorrow-late"])
        XCTAssertTrue(agenda.hasEventsToday)
    }

    func testEmptyTodayWhenEveryEventTodayHasEnded() throws {
        let now = try date(16, 18, 0)
        let agenda = HomeAgendaPlanner.plan(
            events: [
                event("done", day: 16, startHour: 9, startMinute: 0, endHour: 10, endMinute: 0),
                event("tomorrow", day: 17, startHour: 9, startMinute: 0, endHour: 9, endMinute: 30),
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertNil(agenda.nextUp)
        XCTAssertTrue(agenda.today.isEmpty)
        XCTAssertFalse(agenda.hasEventsToday)
        XCTAssertEqual(agenda.tomorrow.map(\.id), ["tomorrow"])
    }

    func testRelativeStartStrings() throws {
        let now = try date(16, 15, 0)
        XCTAssertEqual(
            HomeAgendaPlanner.relativeStart(now: now, start: try date(16, 15, 0).addingTimeInterval(30), end: try date(16, 16, 0)),
            "in 1 min"
        )
        XCTAssertEqual(
            HomeAgendaPlanner.relativeStart(now: now, start: try date(16, 16, 0), end: try date(16, 17, 0)),
            "in 1 hr"
        )
        XCTAssertEqual(
            HomeAgendaPlanner.relativeStart(now: now, start: try date(16, 16, 30), end: try date(16, 17, 30)),
            "in 1 hr 30 min"
        )
        XCTAssertEqual(
            HomeAgendaPlanner.relativeStart(now: now, start: try date(16, 17, 0), end: try date(16, 18, 0)),
            "in 2 hr"
        )
        XCTAssertEqual(
            HomeAgendaPlanner.relativeStart(now: now, start: try date(16, 14, 0), end: try date(16, 15, 0)),
            "Ended"
        )
    }

    func testMeetingLinkExtractionForKnownServices() throws {
        let meet = try XCTUnwrap(HomeAgendaPlanner.meetingLink(from: [
            "Join here: https://meet.google.com/abc-defg-hij.",
        ]))
        XCTAssertEqual(meet.service, .meet)
        XCTAssertEqual(meet.url.absoluteString, "https://meet.google.com/abc-defg-hij")

        let zoom = try XCTUnwrap(HomeAgendaPlanner.meetingLink(from: [
            "https://us02web.zoom.us/j/123456789?pwd=abc",
        ]))
        XCTAssertEqual(zoom.service, .zoom)

        let teams = try XCTUnwrap(HomeAgendaPlanner.meetingLink(from: [
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting",
        ]))
        XCTAssertEqual(teams.service, .teams)

        let teamsLive = try XCTUnwrap(HomeAgendaPlanner.meetingLink(from: [
            "https://teams.live.com/meet/123",
        ]))
        XCTAssertEqual(teamsLive.service, .teams)

        let webex = try XCTUnwrap(HomeAgendaPlanner.meetingLink(from: [
            "https://acme.webex.com/meet/ada",
        ]))
        XCTAssertEqual(webex.service, .webex)

        let preferred = try XCTUnwrap(HomeAgendaPlanner.meetingLink(from: [
            "Agenda: https://example.com/notes",
            "Call https://zoom.us/j/999999999",
        ]))
        XCTAssertEqual(preferred.service, .zoom)
        XCTAssertEqual(try XCTUnwrap(preferred.url.host), "zoom.us")
    }

    func testBareUnknownLinkIsKeptAndProseWithoutAMeetingLinkIsNot() throws {
        let bare = try XCTUnwrap(HomeAgendaPlanner.meetingLink(from: [
            "https://example.com/room",
        ]))
        XCTAssertEqual(bare.service, .other)
        XCTAssertEqual(bare.url.absoluteString, "https://example.com/room")

        XCTAssertNil(HomeAgendaPlanner.meetingLink(from: [
            "See https://example.com/agenda for the doc",
            "Conference room B",
        ]))
        XCTAssertNil(HomeAgendaPlanner.meetingLink(from: ["no link in this event"]))
    }

    func testDeclinedCalendarYieldsHintNotPrompt() {
        let declined = HomeAgendaPlanner.calendarAccess(googleCalendarConnected: false, declined: true)
        XCTAssertEqual(declined.notice, .settingsHint)
        XCTAssertEqual(declined.hint, "Connect calendar in Settings")
        XCTAssertFalse(declined.showsAutomaticPrompt)

        let notAsked = HomeAgendaPlanner.calendarAccess(googleCalendarConnected: false, declined: false)
        XCTAssertEqual(notAsked.notice, .settingsHint)
        XCTAssertFalse(notAsked.showsAutomaticPrompt)
        XCTAssertTrue(GoogleCalendarConnectPrompt.shouldShowAutomaticPrompt(
            declined: false,
            googleCalendarConnected: false
        ))

        let connected = HomeAgendaPlanner.calendarAccess(googleCalendarConnected: true, declined: true)
        XCTAssertEqual(connected.notice, .none)
        XCTAssertNil(connected.hint)
        XCTAssertFalse(connected.showsAutomaticPrompt)
    }

    func testRecentMeetingsUseTheNewestSummaries() throws {
        let older = try date(10, 9, 0)
        let newest = try date(16, 9, 0)
        let middle = try date(14, 9, 0)
        let meetings = [
            HomePastMeeting(id: UUID(), title: "Older", summary: "First line\nSecond line", startedAt: older),
            HomePastMeeting(id: UUID(), title: "Newest", summary: "  Shipped   the notes  ", startedAt: newest),
            HomePastMeeting(id: UUID(), title: "Middle", summary: "", startedAt: middle),
            HomePastMeeting(id: UUID(), title: "Fourth", summary: "Kept", startedAt: try date(12, 9, 0)),
            HomePastMeeting(id: UUID(), title: "Fifth", summary: "Dropped", startedAt: try date(11, 9, 0)),
        ]

        let recent = HomeAgendaPlanner.recentMeetings(meetings)
        XCTAssertEqual(recent.map(\.title), ["Newest", "Middle", "Fourth", "Fifth"])
        XCTAssertEqual(recent[0].summaryLine, "Shipped the notes")
        XCTAssertNil(recent[1].summaryLine)
        XCTAssertEqual(HomeAgendaPlanner.summaryLine("First line\nSecond line"), "First line")
        XCTAssertNil(HomeAgendaPlanner.summaryLine("   \n  "))
    }

    func testPlanKeepsTheJoinLinkAndAttendeesOnTheHero() throws {
        let now = try date(16, 15, 0)
        let agenda = HomeAgendaPlanner.plan(
            events: [
                HomeCalendarInput(
                    id: "review",
                    title: "Design review",
                    start: try date(16, 15, 12),
                    end: try date(16, 16, 0),
                    attendees: ["Ada Lovelace", "Sam"],
                    linkTexts: ["Room https://meet.google.com/abc-defg-hij"]
                )
            ],
            now: now,
            calendar: calendar
        )
        let next = try XCTUnwrap(agenda.nextUp)
        XCTAssertEqual(next.link?.service, .meet)
        XCTAssertEqual(next.attendees, ["Ada Lovelace", "Sam"])
        XCTAssertEqual(
            HomeAgendaPlanner.relativeStart(now: now, start: next.start, end: next.end),
            "in 12 min"
        )
    }

    func testAttendeeInitials() {
        XCTAssertEqual(HomeAgendaPlanner.initials(for: "Ada Lovelace"), "AL")
        XCTAssertEqual(HomeAgendaPlanner.initials(for: "Mary Jane Watson"), "MW")
        XCTAssertEqual(HomeAgendaPlanner.initials(for: "ada.lovelace@example.com"), "AL")
        XCTAssertEqual(HomeAgendaPlanner.initials(for: "Sam"), "S")
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 11,
            day: day,
            hour: hour,
            minute: minute
        )))
    }

    private func event(
        _ id: String,
        day: Int,
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int,
        links: [String] = []
    ) -> HomeCalendarInput {
        let start = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 11, day: day, hour: startHour, minute: startMinute
        ))!
        let end = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 11, day: day, hour: endHour, minute: endMinute
        ))!
        return HomeCalendarInput(
            id: id,
            title: id,
            start: start,
            end: end,
            attendees: [],
            linkTexts: links
        )
    }
}
