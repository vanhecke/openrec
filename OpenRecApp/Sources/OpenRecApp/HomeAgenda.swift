import Foundation

/// A calendar event reduced to the fields Home needs. Sources (Google and the
/// Mac's calendars) map into this before any selection happens.
struct HomeCalendarInput: Equatable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [String]
    var linkTexts: [String]
}

enum MeetingService: String, Equatable {
    case meet
    case zoom
    case teams
    case webex
    case other

    var label: String {
        switch self {
        case .meet: return "Google Meet"
        case .zoom: return "Zoom"
        case .teams: return "Teams"
        case .webex: return "Webex"
        case .other: return "Meeting link"
        }
    }
}

struct HomeMeetingLink: Equatable {
    var url: URL
    var service: MeetingService
}

struct HomeScheduledEvent: Equatable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [String]
    var link: HomeMeetingLink?
}

struct HomeAgenda: Equatable {
    var nextUp: HomeScheduledEvent?
    /// Today's events after the hero. Ended events are already gone.
    var today: [HomeScheduledEvent]
    var tomorrow: [HomeScheduledEvent]

    var hasEventsToday: Bool { nextUp != nil || !today.isEmpty }
}

struct HomePastMeeting: Equatable, Identifiable {
    var id: UUID
    var title: String
    var summary: String
    var startedAt: Date
}

struct HomeRecentMeeting: Equatable, Identifiable {
    var id: UUID
    var title: String
    var summaryLine: String?
    var startedAt: Date
}

enum HomeCalendarNotice: Equatable {
    case none
    case settingsHint
}

struct HomeCalendarAccess: Equatable {
    var notice: HomeCalendarNotice
    /// Home never raises the automatic connect sheet.
    var showsAutomaticPrompt: Bool

    var hint: String? {
        switch notice {
        case .none:
            return nil
        case .settingsHint:
            return HomeAgendaPlanner.settingsHint
        }
    }
}

/// Pure selection for the calendar-first Home: next up, today/tomorrow
/// grouping, relative times, and join-link extraction.
enum HomeAgendaPlanner {
    static let settingsHint = "Connect calendar in Settings"
    static let recentMeetingLimit = 4

    /// The hero is the in-progress event, otherwise the next event that still
    /// starts today. Ended events are dropped. Tomorrow stays in the compact
    /// list and never becomes the hero on its own.
    static func plan(events: [HomeCalendarInput], now: Date, calendar: Calendar) -> HomeAgenda {
        let sorted = events.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.id < rhs.id
        }
        let active = sorted.filter { $0.end > now }
        let inProgress = active.filter { $0.start <= now }
        let nextSource = inProgress.first ?? active.first { calendar.isDate($0.start, inSameDayAs: now) }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        let nextID = nextSource?.id
        let rest = active.filter { event in
            guard let nextID else { return true }
            return event.id != nextID
        }
        let today = rest.filter { calendar.isDate($0.start, inSameDayAs: now) }
        let tomorrowEvents: [HomeCalendarInput]
        if let tomorrow {
            tomorrowEvents = rest.filter { calendar.isDate($0.start, inSameDayAs: tomorrow) }
        } else {
            tomorrowEvents = []
        }
        return HomeAgenda(
            nextUp: nextSource.map(scheduled),
            today: today.map(scheduled),
            tomorrow: tomorrowEvents.map(scheduled)
        )
    }

    /// "Now" while the event is underway, otherwise a short "in 12 min" style
    /// offset from `now` to `start`.
    static func relativeStart(now: Date, start: Date, end: Date) -> String {
        if end <= now { return "Ended" }
        if start <= now { return "Now" }
        let minutes = max(1, Int((start.timeIntervalSince(now) / 60).rounded()))
        if minutes < 60 {
            return minutes == 1 ? "in 1 min" : "in \(minutes) min"
        }
        let hours = minutes / 60
        let leftover = minutes % 60
        if leftover == 0 {
            return hours == 1 ? "in 1 hr" : "in \(hours) hr"
        }
        let hourLabel = hours == 1 ? "1 hr" : "\(hours) hr"
        return "in \(hourLabel) \(leftover) min"
    }

    /// First recognized Meet, Zoom, Teams, or Webex URL in `texts`. A field
    /// that is itself a URL still counts when the service is unknown. A link
    /// buried in a sentence only counts for those four services.
    static func meetingLink(from texts: [String]) -> HomeMeetingLink? {
        var bareFallback: HomeMeetingLink?
        for text in texts {
            let bare = isBareLink(text)
            for url in urls(in: text) {
                let service = service(for: url)
                if service != .other {
                    return HomeMeetingLink(url: url, service: service)
                }
                if bare, bareFallback == nil {
                    bareFallback = HomeMeetingLink(url: url, service: .other)
                }
            }
        }
        return bareFallback
    }

    static func initials(for attendee: String) -> String {
        let trimmed = attendee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let local = trimmed.split(separator: "@", maxSplits: 1).first.map(String.init) ?? trimmed
        let parts = local.split { character in
            character.isWhitespace || character == "." || character == "_" || character == "-"
        }.map(String.init).filter { !$0.isEmpty }
        guard let first = parts.first?.first else { return "?" }
        if parts.count >= 2, let last = parts.last?.first {
            return String([first, last]).uppercased()
        }
        return String(first).uppercased()
    }

    /// Connected calendars show events with no extra chrome. A missing
    /// connection and an explicit No Thanks both stay a one-line hint.
    static func calendarAccess(googleCalendarConnected: Bool, declined: Bool) -> HomeCalendarAccess {
        if googleCalendarConnected {
            return HomeCalendarAccess(notice: .none, showsAutomaticPrompt: false)
        }
        switch declined {
        case true:
            return HomeCalendarAccess(notice: .settingsHint, showsAutomaticPrompt: false)
        case false:
            return HomeCalendarAccess(notice: .settingsHint, showsAutomaticPrompt: false)
        }
    }

    static func greeting(at date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }

    static func dateLine(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
    }

    /// The first non-empty line of a meeting summary, with internal whitespace collapsed.
    static func summaryLine(_ summary: String) -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let first = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let collapsed = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func recentMeetings(_ meetings: [HomePastMeeting], limit: Int = recentMeetingLimit) -> [HomeRecentMeeting] {
        meetings
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(max(0, limit))
            .map { meeting in
                HomeRecentMeeting(
                    id: meeting.id,
                    title: meeting.title,
                    summaryLine: summaryLine(meeting.summary),
                    startedAt: meeting.startedAt
                )
            }
    }

    private static func scheduled(_ input: HomeCalendarInput) -> HomeScheduledEvent {
        HomeScheduledEvent(
            id: input.id,
            title: input.title,
            start: input.start,
            end: input.end,
            attendees: input.attendees,
            link: meetingLink(from: input.linkTexts)
        )
    }

    private static func service(for url: URL) -> MeetingService {
        guard let host = url.host?.lowercased() else { return .other }
        if host == "meet.google.com" || host.hasSuffix(".meet.google.com") { return .meet }
        if host == "zoom.us" || host.hasSuffix(".zoom.us")
            || host == "zoom.com" || host.hasSuffix(".zoom.com")
            || host == "zoomgov.com" || host.hasSuffix(".zoomgov.com") { return .zoom }
        if host == "teams.microsoft.com" || host.hasSuffix(".teams.microsoft.com")
            || host == "teams.live.com" || host.hasSuffix(".teams.live.com") { return .teams }
        if host == "webex.com" || host.hasSuffix(".webex.com") { return .webex }
        return .other
    }

    private static func isBareLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return false }
        return !trimmed.contains(where: \.isWhitespace)
    }

    private static func urls(in text: String) -> [URL] {
        var found: [URL] = []
        var search = text.startIndex
        while search < text.endIndex {
            guard let range = nextURLStart(in: text, from: search) else { break }
            var end = range.lowerBound
            while end < text.endIndex {
                let character = text[end]
                if character.isWhitespace || "<>\"'".contains(character) { break }
                end = text.index(after: end)
            }
            var raw = String(text[range.lowerBound..<end])
            while let last = raw.last, ".,;)]".contains(last) {
                raw.removeLast()
            }
            if let url = URL(string: raw), let host = url.host, !host.isEmpty {
                found.append(url)
            }
            search = end
        }
        return found
    }

    private static func nextURLStart(in text: String, from start: String.Index) -> Range<String.Index>? {
        let http = text.range(of: "http://", options: [.caseInsensitive], range: start..<text.endIndex)
        let https = text.range(of: "https://", options: [.caseInsensitive], range: start..<text.endIndex)
        switch (http, https) {
        case let (http?, https?):
            return http.lowerBound <= https.lowerBound ? http : https
        case let (http?, nil):
            return http
        case let (nil, https?):
            return https
        case (nil, nil):
            return nil
        }
    }
}
