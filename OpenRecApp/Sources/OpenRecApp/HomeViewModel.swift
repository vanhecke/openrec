import AppKit
import Foundation

struct HomeSnapshot: Equatable {
    var greeting: String
    var dateLine: String
    var agenda: HomeAgenda
    var recent: [HomeRecentMeeting]
    var connectHint: String?
    var isLoadingEvents: Bool
}

/// Builds the Home snapshot from the recorder's calendar and library, and
/// starts a recording through the existing path.
@MainActor
enum HomeViewModel {
    static func snapshot(
        from recorder: RecorderManager,
        declined: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HomeSnapshot {
        let connected = !recorder.cloudStorage.calendarEmails.isEmpty || recorder.googleCalendarActive
        return makeSnapshot(
            now: now,
            calendar: calendar,
            events: recorder.upcomingEvents.map(calendarInput),
            meetings: recorder.cloudStorage.libraryMeetings.map(pastMeeting),
            googleCalendarConnected: connected,
            declined: declined,
            isLoadingEvents: recorder.isLoadingUpcomingEvents && recorder.upcomingEvents.isEmpty
        )
    }

    static func makeSnapshot(
        now: Date,
        calendar: Calendar,
        events: [HomeCalendarInput],
        meetings: [HomePastMeeting],
        googleCalendarConnected: Bool,
        declined: Bool,
        isLoadingEvents: Bool
    ) -> HomeSnapshot {
        let access = HomeAgendaPlanner.calendarAccess(
            googleCalendarConnected: googleCalendarConnected,
            declined: declined
        )
        return HomeSnapshot(
            greeting: HomeAgendaPlanner.greeting(at: now, calendar: calendar),
            dateLine: HomeAgendaPlanner.dateLine(for: now, calendar: calendar),
            agenda: HomeAgendaPlanner.plan(events: events, now: now, calendar: calendar),
            recent: HomeAgendaPlanner.recentMeetings(meetings),
            connectHint: access.hint,
            isLoadingEvents: isLoadingEvents
        )
    }

    /// Open the event's join link and start recording under its title.
    static func joinAndRecord(
        _ event: HomeScheduledEvent,
        recorder: RecorderManager,
        openURL: (URL) -> Void = { url in _ = NSWorkspace.shared.open(url) }
    ) {
        nameRecording(after: event, recorder: recorder)
        if let url = event.link?.url {
            openURL(url)
        }
        Task { await recorder.startRecording() }
    }

    /// Start recording under the event's title when it has no join link.
    static func record(_ event: HomeScheduledEvent, recorder: RecorderManager) {
        nameRecording(after: event, recorder: recorder)
        Task { await recorder.startRecording() }
    }

    private static func nameRecording(after event: HomeScheduledEvent, recorder: RecorderManager) {
        recorder.adoptUpcomingEvent(UpcomingCalendarEvent(
            id: event.id,
            title: event.title,
            start: event.start,
            end: event.end,
            attendees: event.attendees,
            linkTexts: event.link.map { [$0.url.absoluteString] } ?? []
        ))
    }

    private static func calendarInput(_ event: UpcomingCalendarEvent) -> HomeCalendarInput {
        HomeCalendarInput(
            id: event.id,
            title: event.title,
            start: event.start,
            end: event.end,
            attendees: event.attendees,
            linkTexts: event.linkTexts
        )
    }

    private static func pastMeeting(_ meeting: MeetingRecord) -> HomePastMeeting {
        HomePastMeeting(
            id: meeting.id,
            title: meeting.title,
            summary: meeting.insights.summary,
            startedAt: meeting.startedAt
        )
    }
}
