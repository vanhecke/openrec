import AppKit
import SwiftUI

struct HomeView: View {
    let snapshot: HomeSnapshot
    var settingsEnabled: Bool
    var settingsDisabled: Bool
    var isRefreshing: Bool
    var recordDisabled: Bool
    var recordingStatus: String?
    var onShowPast: () -> Void
    var onOpenSettings: () -> Void
    var onRefresh: () -> Void
    var onOpenMeeting: (UUID) -> Void
    var onJoinAndRecord: (HomeScheduledEvent) -> Void
    var onRecord: (HomeScheduledEvent) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var palette: HomePalette { HomePalette(scheme: colorScheme) }

    var body: some View {
        let colors = palette
        VStack(spacing: 0) {
            topBar(colors)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heading(colors)
                    if let hint = snapshot.connectHint {
                        connectHint(hint, palette: colors)
                    }
                    schedule(colors)
                    if let recordingStatus, !recordingStatus.isEmpty {
                        Text(recordingStatus)
                            .font(.system(size: 12))
                            .foregroundColor(colors.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    recentSection(colors)
                }
                .padding(.horizontal, 28)
                .padding(.top, 6)
                .padding(.bottom, 32)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(colors.canvas.ignoresSafeArea())
    }

    private func topBar(_ palette: HomePalette) -> some View {
        HStack(spacing: 10) {
            Circle().fill(palette.accent).frame(width: 7, height: 7)
            Text("Meetings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(palette.primary)
            Spacer(minLength: 12)
            tabSwitch(palette)
            refreshButton(palette)
            if settingsEnabled {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(palette.secondary)
                .disabled(settingsDisabled)
                .opacity(settingsDisabled ? 0.4 : 1)
                .help("Settings")
            }
        }
        .padding(.leading, 78)
        .padding(.trailing, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func tabSwitch(_ palette: HomePalette) -> some View {
        HStack(spacing: 2) {
            tabLabel("Home", selected: true, palette: palette, action: {})
            tabLabel("Past", selected: false, palette: palette, action: onShowPast)
        }
        .padding(2)
        .background(palette.chip)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }

    private func tabLabel(_ title: String, selected: Bool, palette: HomePalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundColor(selected ? palette.primary : palette.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? palette.card : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func refreshButton(_ palette: HomePalette) -> some View {
        Button(action: onRefresh) {
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(palette.secondary)
        .disabled(isRefreshing)
        .help("Refresh meetings")
    }

    private func heading(_ palette: HomePalette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.greeting)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(palette.primary)
            Text(snapshot.dateLine)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.secondary)
        }
    }

    private func connectHint(_ hint: String, palette: HomePalette) -> some View {
        Button(action: onOpenSettings) {
            Text(hint)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(palette.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(!settingsEnabled)
        .help(hint)
    }

    @ViewBuilder
    private func schedule(_ palette: HomePalette) -> some View {
        if let nextUp = snapshot.agenda.nextUp {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Next up", palette: palette)
                hero(nextUp, palette: palette)
            }
        } else if snapshot.isLoadingEvents {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 28)
        } else {
            emptySchedule(palette)
        }

        if !snapshot.agenda.today.isEmpty {
            eventSection(
                title: todaySectionTitle,
                events: snapshot.agenda.today,
                palette: palette
            )
        }
        if !snapshot.agenda.tomorrow.isEmpty {
            eventSection(title: "Tomorrow", events: snapshot.agenda.tomorrow, palette: palette)
        }
    }

    private func emptySchedule(_ palette: HomePalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Today", palette: palette)
            Text("No events today")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(palette.primary)
            Text("When something is on the calendar, it will show up here ready to record.")
                .font(.system(size: 12))
                .foregroundColor(palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(palette))
    }

    private func hero(_ event: HomeScheduledEvent, palette: HomePalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(palette.primary)
                    .lineLimit(2)
                Spacer(minLength: 12)
                if let link = event.link, link.service != .other {
                    serviceChip(link.service, palette: palette)
                }
            }
            Text(timeLine(for: event))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.secondary)
            if !event.attendees.isEmpty {
                attendeeRow(event.attendees, palette: palette)
            }
            HStack {
                Spacer()
                recordButton(for: event, palette: palette)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(palette))
    }

    private func eventSection(title: String, events: [HomeScheduledEvent], palette: HomePalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title, palette: palette)
            VStack(spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 {
                        Rectangle()
                            .fill(palette.stroke)
                            .frame(height: 1)
                            .padding(.leading, 78)
                    }
                    compactRow(event, palette: palette)
                }
            }
            .background(cardBackground(palette))
        }
    }

    private func compactRow(_ event: HomeScheduledEvent, palette: HomePalette) -> some View {
        HStack(spacing: 12) {
            Text(Self.timeFormatter.string(from: event.start))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(palette.secondary)
                .frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(palette.primary)
                    .lineLimit(1)
                if let link = event.link, link.service != .other {
                    Text(link.service.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(palette.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            recordButton(for: event, palette: palette)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func recentSection(_ palette: HomePalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recent", palette: palette)
            if snapshot.recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No past meetings yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(palette.primary)
                    Text("Record a call and its summary will show up here.")
                        .font(.system(size: 12))
                        .foregroundColor(palette.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground(palette))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.recent.enumerated()), id: \.element.id) { index, meeting in
                        if index > 0 {
                            Rectangle()
                                .fill(palette.stroke)
                                .frame(height: 1)
                                .padding(.leading, 14)
                        }
                        recentRow(meeting, palette: palette)
                    }
                }
                .background(cardBackground(palette))
            }
        }
    }

    private func recentRow(_ meeting: HomeRecentMeeting, palette: HomePalette) -> some View {
        Button {
            onOpenMeeting(meeting.id)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(palette.primary)
                        .lineLimit(1)
                    Text(meeting.summaryLine ?? "No summary yet")
                        .font(.system(size: 12))
                        .foregroundColor(meeting.summaryLine == nil ? palette.tertiary : palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Self.recentDateFormatter.string(from: meeting.startedAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(palette.tertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(palette.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this meeting")
    }

    private func recordButton(for event: HomeScheduledEvent, palette: HomePalette) -> some View {
        let hasLink = event.link != nil
        return Button(hasLink ? "Join & Record" : "Record") {
            if hasLink {
                onJoinAndRecord(event)
            } else {
                onRecord(event)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(hasLink ? .white : palette.primary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hasLink ? palette.accent : palette.chip)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(hasLink ? Color.clear : palette.stroke, lineWidth: 1)
        )
        .disabled(recordDisabled)
        .opacity(recordDisabled ? 0.45 : 1)
        .help(hasLink ? "Open the meeting link and start recording" : "Start recording with this title")
    }

    private func serviceChip(_ service: MeetingService, palette: HomePalette) -> some View {
        Text(service.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(palette.primary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.chip)
            )
    }

    private func attendeeRow(_ attendees: [String], palette: HomePalette) -> some View {
        let shown = Array(attendees.prefix(5))
        let extra = attendees.count - shown.count
        return HStack(spacing: -6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, name in
                Text(HomeAgendaPlanner.initials(for: name))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(avatarColor(for: name)))
                    .overlay(Circle().stroke(palette.canvas, lineWidth: 1.5))
                    .help(name)
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(palette.secondary)
                    .padding(.leading, 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attendees.joined(separator: ", "))
    }

    private func sectionTitle(_ title: String, palette: HomePalette) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(palette.tertiary)
            .tracking(0.4)
    }

    private func cardBackground(_ palette: HomePalette) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(palette.card)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(palette.stroke, lineWidth: 1)
            )
    }

    private var todaySectionTitle: String {
        guard let nextUp = snapshot.agenda.nextUp, Calendar.current.isDateInToday(nextUp.start) else {
            return "Today"
        }
        return "Later today"
    }

    private func timeLine(for event: HomeScheduledEvent) -> String {
        let clock = "\(Self.timeFormatter.string(from: event.start)) – \(Self.timeFormatter.string(from: event.end))"
        let relative = HomeAgendaPlanner.relativeStart(now: Date(), start: event.start, end: event.end)
        return "\(clock) · \(relative)"
    }

    private func avatarColor(for name: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.78, green: 0.32, blue: 0.32),
            Color(red: 0.33, green: 0.46, blue: 0.70),
            Color(red: 0.28, green: 0.52, blue: 0.42),
            Color(red: 0.70, green: 0.46, blue: 0.24),
            Color(red: 0.46, green: 0.38, blue: 0.64),
        ]
        let total = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[total % palette.count]
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let recentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d · h:mm a"
        return formatter
    }()
}

private struct HomePalette {
    var canvas: Color
    var card: Color
    var primary: Color
    var secondary: Color
    var tertiary: Color
    var stroke: Color
    var chip: Color
    var accent = Color(red: 1, green: 0.25, blue: 0.28)

    init(scheme: ColorScheme) {
        if scheme == .dark {
            canvas = Color(red: 0.105, green: 0.11, blue: 0.115)
            card = Color.white.opacity(0.055)
            primary = Color.white.opacity(0.92)
            secondary = Color.white.opacity(0.58)
            tertiary = Color.white.opacity(0.38)
            stroke = Color.white.opacity(0.08)
            chip = Color.white.opacity(0.08)
        } else {
            canvas = Color(nsColor: .windowBackgroundColor)
            card = Color(nsColor: .controlBackgroundColor)
            primary = Color(nsColor: .labelColor)
            secondary = Color(nsColor: .secondaryLabelColor)
            tertiary = Color(nsColor: .tertiaryLabelColor)
            stroke = Color(nsColor: .separatorColor)
            chip = Color.black.opacity(0.05)
        }
    }
}
