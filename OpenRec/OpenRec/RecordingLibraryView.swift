import SwiftUI
import AVKit
import AppKit
import Combine
import CoreMedia

struct RecordingLibrarySelectionRequest: Equatable {
    let meetingID: UUID
    let token = UUID()
}

@MainActor
final class RecordingLibraryNavigation: ObservableObject {
    @Published private(set) var request: RecordingLibrarySelectionRequest?
    @Published private(set) var focusSearchToken: UUID?

    func select(_ meetingID: UUID) {
        request = RecordingLibrarySelectionRequest(meetingID: meetingID)
    }

    func focusSearch() {
        focusSearchToken = UUID()
    }
}

enum MeetingLibraryPresentation {
    static func emptyTranscriptMessage(for meeting: MeetingRecord) -> String {
        meeting.preferences.storeTranscriptInCloud
            ? "Transcript storage was enabled, but no transcript is available for this meeting."
            : "No transcript was stored for this call."
    }
}

enum AppVersionPresentation {
    static var current: String {
        label(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static func label(infoDictionary: [String: Any]) -> String {
        let version = (infoDictionary["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (infoDictionary["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (version?, build?): return "v\(version) (\(build))"
        case let (version?, nil): return "v\(version)"
        case let (nil, build?): return "build \(build)"
        case (nil, nil): return "dev build"
        }
    }
}

enum MeetingClipboardText {
    static func participants(for meeting: MeetingRecord) -> String? {
        nonEmpty(meeting.insights.participants.joined(separator: ", "))
    }

    static func summary(for meeting: MeetingRecord) -> String? {
        nonEmpty(meeting.insights.summary)
    }

    static func aiNotes(for meeting: MeetingRecord) -> String? {
        nonEmpty(meeting.insights.aiNotes)
    }

    static func userNotes(for meeting: MeetingRecord) -> String? {
        RecordingNotesText.lines(meeting.notes ?? [])
    }

    static func nextSteps(for meeting: MeetingRecord) -> String? {
        guard !meeting.insights.actionItems.isEmpty else { return nil }
        return meeting.insights.actionItems.map { item in
            let owner = item.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            var line = owner.isEmpty ? item.task : "\(owner): \(item.task)"
            if let dueDate = nonEmpty(item.dueDate ?? "") { line += " — \(dueDate)" }
            return "• \(line)"
        }.joined(separator: "\n")
    }

    static func decisions(for meeting: MeetingRecord) -> String? {
        guard !meeting.insights.decisions.isEmpty else { return nil }
        return meeting.insights.decisions.map { "• \($0)" }.joined(separator: "\n")
    }

    static func transcript(for meeting: MeetingRecord) -> String? {
        let named = SpeakerNames.apply(meeting.speakerNames ?? [:], to: meeting.transcript ?? "")
        return nonEmpty(named)
    }

    static func meeting(_ meeting: MeetingRecord) -> String {
        var sections = [meeting.title]
        if let participants = participants(for: meeting) { sections.append("Participants\n\(participants)") }
        if let summary = summary(for: meeting) { sections.append("Summary\n\(summary)") }
        if let userNotes = userNotes(for: meeting) { sections.append("My Notes\n\(userNotes)") }
        if let aiNotes = aiNotes(for: meeting) { sections.append("AI Notes\n\(aiNotes)") }
        if let nextSteps = nextSteps(for: meeting) { sections.append("Next steps\n\(nextSteps)") }
        if let decisions = decisions(for: meeting) { sections.append("Decisions\n\(decisions)") }
        if let transcript = transcript(for: meeting) { sections.append("Transcript\n\(transcript)") }
        return sections.joined(separator: "\n\n")
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum MeetingDetailTab: String, CaseIterable, Identifiable {
    case summary = "AI Notes"
    case transcript = "Transcript"

    var id: String { rawValue }
}

private enum LibraryTab: Int, CaseIterable {
    case home
    case past

    var label: String {
        switch self {
        case .home: return "Home"
        case .past: return "Past"
        }
    }
}

struct RecordingLibraryView: View {
    @ObservedObject var recorderManager: RecorderManager
    @ObservedObject var navigation: RecordingLibraryNavigation
    var onOpenSettings: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Home is the landing view. Opening a meeting or Find switches to Past.
    @State private var tab: LibraryTab = .home
    @State private var googleCalendarConnectDeclined = GoogleCalendarConnectPrompt.isDeclined()
    @State private var searchText = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var pendingSearchFocus = false
    @State private var handledSearchFocusToken: UUID?
    @State private var selectedID: UUID?
    @State private var detail: MeetingRecord?
    @State private var selectedTab: MeetingDetailTab = .summary
    @State private var isLoadingDetail = false
    @State private var detailError: String?
    @State private var mediaError: String?
    @State private var loadingMedia: MeetingMediaKind?
    @State private var player: AVPlayer?
    @State private var playerKind: MeetingMediaKind?
    @State private var copied = false
    @State private var detailTask: Task<Void, Never>?
    @State private var mediaTask: Task<Void, Never>?
    @State private var handledSelectionToken: UUID?
    @State private var deletingMeetingID: UUID?
    @State private var highlightedCueID: UUID?
    @State private var transcriptScrollToken = UUID()

    private let background = Color(red: 0.105, green: 0.11, blue: 0.115)
    private let sidebar = Color(red: 0.13, green: 0.135, blue: 0.14)
    private let card = Color.white.opacity(0.055)
    private let primary = Color.white.opacity(0.92)
    private let secondary = Color.white.opacity(0.58)
    private let accent = Color(red: 1, green: 0.25, blue: 0.28)
    private let calendarRefreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private struct LibraryListEntry: Identifiable {
        let meeting: MeetingRecord
        let titleSnippet: MeetingSearchSnippet?
        let bodySnippet: MeetingSearchSnippet?
        var id: UUID { meeting.id }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An empty field is the normal recency list. A query is ranked by the
    /// in-memory index, which is the same for every storage mode.
    private var visibleMeetings: [LibraryListEntry] {
        let meetings = recorderManager.cloudStorage.libraryMeetings
        guard !trimmedSearch.isEmpty else {
            return meetings.map { LibraryListEntry(meeting: $0, titleSnippet: nil, bodySnippet: nil) }
        }
        let hits = recorderManager.cloudStorage.librarySearchResults(matching: trimmedSearch)
        var byID: [UUID: MeetingRecord] = [:]
        byID.reserveCapacity(meetings.count)
        for meeting in meetings { byID[meeting.id] = meeting }
        return hits.compactMap { hit in
            guard let meeting = byID[hit.id] else { return nil }
            if hit.snippetReplacesTitle {
                return LibraryListEntry(meeting: meeting, titleSnippet: hit.snippet, bodySnippet: nil)
            }
            let snippet = hit.snippet.text.isEmpty ? nil : hit.snippet
            return LibraryListEntry(meeting: meeting, titleSnippet: nil, bodySnippet: snippet)
        }
    }

    var body: some View {
        ZStack {
            if tab == .home {
                homeScreen
            } else {
                background.ignoresSafeArea()
                HStack(spacing: 0) {
                    librarySidebar
                        .frame(width: 300)
                    Color.white.opacity(0.08).frame(width: 1)
                    detailPane
                }
            }
        }
        // The titlebar is hidden and the window uses fullSizeContentView, so
        // reclaim its safe-area strip; the header row leaves room for the
        // traffic lights instead.
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 580)
        .task {
            focusSearchIfRequested()
            recorderManager.refreshUpcomingEvents()
            await recorderManager.cloudStorage.refreshLibrary()
            selectInitialMeeting()
        }
        .onChange(of: navigation.focusSearchToken) { _ in
            focusSearchIfRequested()
        }
        .onChange(of: tab) { newTab in
            guard newTab == .past, pendingSearchFocus else { return }
            pendingSearchFocus = false
            DispatchQueue.main.async { searchFieldFocused = true }
        }
        .onChange(of: navigation.request) { _ in
            if !applyPendingSelection() {
                Task { await recorderManager.cloudStorage.refreshLibrary() }
            }
        }
        .onChange(of: recorderManager.cloudStorage.isManagedSignedIn) { _ in
            recorderManager.refreshUpcomingEvents()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            googleCalendarConnectDeclined = GoogleCalendarConnectPrompt.isDeclined()
            if tab == .home { recorderManager.refreshUpcomingEvents() }
        }
        .onChange(of: recorderManager.cloudStorage.calendarEmails) { _ in
            googleCalendarConnectDeclined = GoogleCalendarConnectPrompt.isDeclined()
        }
        .onReceive(calendarRefreshTimer) { _ in
            if tab == .home { recorderManager.refreshUpcomingEvents() }
        }
        .onChange(of: recorderManager.cloudStorage.libraryMeetings) { _ in
            selectInitialMeeting()
            if let id = selectedID, let updated = recorderManager.cloudStorage.libraryMeetings.first(where: { $0.id == id }) {
                detail = mergeVisibleDetail(updated)
            }
        }
        .onChange(of: selectedID) { id in
            guard let id else { return }
            guard let meeting = visibleMeetings.first(where: { $0.id == id })?.meeting
                    ?? recorderManager.cloudStorage.libraryMeetings.first(where: { $0.id == id }) else {
                detail = nil
                return
            }
            loadDetail(meeting)
        }
        .onDisappear {
            detailTask?.cancel()
            mediaTask?.cancel()
            player?.pause()
        }
    }

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text("Meetings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(primary)
                Spacer()
                if let onOpenSettings {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(secondary)
                    .disabled(recorderManager.isRecording || recorderManager.isProcessing)
                    .opacity(recorderManager.isRecording || recorderManager.isProcessing ? 0.4 : 1)
                    .help("Settings")
                }
                Button {
                    Task { await recorderManager.cloudStorage.refreshLibrary() }
                    recorderManager.refreshUpcomingEvents()
                } label: {
                    if recorderManager.cloudStorage.isLoadingLibrary {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(secondary)
                .disabled(recorderManager.cloudStorage.isLoadingLibrary)
                .help("Refresh meetings")
            }
            // The window titlebar is reclaimed as content, so the header sits
            // beside the traffic lights instead of below an empty bar.
            .padding(.leading, 74)
            .padding(.trailing, 14)
            .padding(.top, 9)
            .padding(.bottom, 8)

            libraryTabBar
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            searchField
            if let error = recorderManager.cloudStorage.libraryError {
                Label(error, systemImage: "icloud.slash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.orange.opacity(0.9))
                    .lineLimit(4)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            ScrollView {
                pastListContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipped()

            HStack(spacing: 6) {
                Image(systemName: recorderManager.cloudStorage.mode == .managed ? "icloud" : "shippingbox")
                Text(recorderManager.cloudStorage.mode.label)
                Text("•")
                Text(AppVersionPresentation.current)
                Spacer()
                Text(libraryCountLabel)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color.white.opacity(0.4))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Color.black.opacity(0.12))
        }
        .background(sidebar)
    }

    private var libraryTabBar: some View {
        HStack(spacing: 2) {
            ForEach(LibraryTab.allCases, id: \.rawValue) { candidate in
                let isSelected = candidate == tab
                Button {
                    switchTab(to: candidate)
                } label: {
                    Text(candidate.label)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? primary : secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var homeScreen: some View {
        HomeView(
            snapshot: HomeViewModel.snapshot(
                from: recorderManager,
                declined: googleCalendarConnectDeclined
            ),
            settingsEnabled: onOpenSettings != nil,
            settingsDisabled: recorderManager.isRecording || recorderManager.isProcessing,
            isRefreshing: recorderManager.cloudStorage.isLoadingLibrary,
            recordDisabled: recorderManager.isRecording || recorderManager.isProcessing || recorderManager.isStarting,
            recordingStatus: recorderManager.lastErrorMessage,
            onShowPast: { switchTab(to: .past) },
            onOpenSettings: { onOpenSettings?() },
            onRefresh: {
                Task { await recorderManager.cloudStorage.refreshLibrary() }
                recorderManager.refreshUpcomingEvents()
            },
            onOpenMeeting: { navigation.select($0) },
            onJoinAndRecord: { HomeViewModel.joinAndRecord($0, recorder: recorderManager) },
            onRecord: { HomeViewModel.record($0, recorder: recorderManager) }
        )
        .onAppear {
            googleCalendarConnectDeclined = GoogleCalendarConnectPrompt.isDeclined()
            recorderManager.refreshUpcomingEvents()
            Task { await recorderManager.cloudStorage.refreshCalendarConnectionStatus() }
        }
    }

    private func switchTab(to newTab: LibraryTab) {
        guard newTab != tab else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.2)) {
            tab = newTab
        }
        if newTab == .home { recorderManager.refreshUpcomingEvents() }
    }

    private var libraryCountLabel: String {
        let total = recorderManager.cloudStorage.libraryMeetings.count
        guard !trimmedSearch.isEmpty else { return "\(total)" }
        return "\(visibleMeetings.count) of \(total)"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(secondary)
            TextField(
                "",
                text: $searchText,
                prompt: Text("Search meetings").foregroundColor(Color.white.opacity(0.34))
            )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(primary)
                .focused($searchFieldFocused)
                .accessibilityLabel("Search meetings")
            if !trimmedSearch.isEmpty {
                Button {
                    searchText = ""
                    searchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .help("Search meetings (⌘F)")
    }

    @ViewBuilder
    private var pastListContent: some View {
        if visibleMeetings.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.22))
                Text(trimmedSearch.isEmpty ? "Your calls will appear here" : "No matching meetings")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(secondary)
                if trimmedSearch.isEmpty {
                    Text("Record a call and OpenRec will keep its transcript, next steps, and selected recordings together.")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.38))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 210)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
        } else {
            LazyVStack(spacing: 4) {
                ForEach(visibleMeetings) { entry in
                    MeetingRow(
                        meeting: entry.meeting,
                        selected: selectedID == entry.id,
                        accent: accent,
                        titleSnippet: entry.titleSnippet,
                        bodySnippet: entry.bodySnippet
                    ) {
                        selectMeeting(entry.meeting, forceReload: true)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            confirmAndDelete(entry.meeting)
                        } label: {
                            Label("Delete Meeting…", systemImage: "trash")
                        }
                        .disabled(entry.meeting.saveStatus == .processing || deletingMeetingID != nil)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let meeting = detail {
            VStack(spacing: 0) {
                detailHeader(meeting)
                Color.white.opacity(0.08).frame(height: 1)
                if isLoadingDetail {
                    ProgressView("Loading meeting…")
                        .controlSize(.small)
                        .foregroundColor(secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    detailContent(meeting)
                        .id(meeting.id)
                        .transition(.opacity)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "waveform.and.magnifyingglass")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.2))
                Text("Choose a meeting")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ meeting: MeetingRecord) -> some View {
        let recovery = MeetingSaveRecovery.live(for: meeting)
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(meeting.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(primary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: meeting.startedAt))
                    Text("·")
                    Text(formatDuration(meeting.durationSeconds))
                    if let app = meeting.callApp, !app.isEmpty {
                        Text("·")
                        Text(app)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(secondary)
            }
            Spacer()
            if meeting.saveStatus == .failed, recovery.canRetry {
                Button("Retry processing") { recorderManager.retryFailedMeeting(meeting) }
                    .buttonStyle(LibraryButtonStyle(prominent: false))
                    .disabled(recorderManager.isRecording || recorderManager.isProcessing || recorderManager.isStarting)
                    .help(
                        recovery.cloudMediaAvailable
                            ? "Retry transcription and meeting processing from the cloud recording"
                            : "Retry transcription, upload, and webhook delivery using the legacy recovery file"
                    )
            }
            if meeting.webhookDeliveryStatus == .failed {
                Button("Retry webhook") { recorderManager.retryWebhook(for: meeting) }
                    .buttonStyle(LibraryButtonStyle(prominent: false))
                    .disabled(recorderManager.isRecording || recorderManager.isProcessing || recorderManager.isStarting)
                    .help("Retry only the external webhook; the OpenRec meeting is already safe")
            }
            Button {
                copyMeeting(meeting)
            } label: {
                Label(copied ? "Copied all" : "Copy all", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(LibraryButtonStyle(prominent: false))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private func detailContent(_ meeting: MeetingRecord) -> some View {
        ScrollViewReader { proxy in
            detailScroll(meeting, proxy: proxy)
        }
    }

    private func detailScroll(_ meeting: MeetingRecord, proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if meeting.saveStatus == .processing {
                    StatusBanner(
                        message: "Processing this meeting: \(meeting.saveStage.label)…",
                        icon: "arrow.triangle.2.circlepath",
                        color: .blue
                    )
                }
                if let error = detailError ?? meeting.errorMessage {
                    StatusBanner(message: error, icon: "exclamationmark.triangle.fill", color: .orange)
                }
                if let recoveryIssue = MeetingSaveRecovery.live(for: meeting).unavailableReason {
                    StatusBanner(message: recoveryIssue, icon: "externaldrive.badge.xmark", color: .orange)
                }
                if let webhookError = meeting.webhookErrorMessage {
                    StatusBanner(
                        message: "Meeting saved. Webhook delivery needs attention: \(webhookError)",
                        icon: "arrow.triangle.2.circlepath.circle.fill",
                        color: .orange
                    )
                }
                if let mediaError {
                    StatusBanner(message: mediaError, icon: "play.slash.fill", color: .orange)
                }
                if meeting.screenDeletionScheduledAt != nil || meeting.audioDeletionScheduledAt != nil {
                    StatusBanner(
                        message: "Temporary recording access remains available for webhook delivery, then clears automatically.",
                        icon: "clock.badge.checkmark.fill",
                        color: .blue
                    )
                }

                mediaCard(meeting)
                speakerNamesSection(meeting)
                myNotesSection(meeting)

                HStack(spacing: 4) {
                    ForEach(MeetingDetailTab.allCases) { tab in
                        Button(tab.rawValue) {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { selectedTab = tab }
                        }
                        .buttonStyle(LibraryTabStyle(selected: selectedTab == tab))
                    }
                    Spacer()
                }

                if selectedTab == .summary {
                    summaryContent(meeting)
                } else {
                    transcriptContent(meeting)
                }
            }
            .padding(22)
        }
        .onChange(of: transcriptScrollToken) { _ in
            scrollToHighlightedCue(proxy)
        }
        .onChange(of: selectedTab) { tab in
            guard tab == .transcript, highlightedCueID != nil else { return }
            scrollToHighlightedCue(proxy)
        }
    }

    private func scrollToHighlightedCue(_ proxy: ScrollViewProxy) {
        guard let id = highlightedCueID else { return }
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func mediaCard(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let player {
                NativePlayerView(player: player)
                    .frame(height: playerKind == .screen ? 260 : 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 8) {
                if meeting.hasPlayableScreen {
                    mediaButton(meeting, kind: .screen, title: playerKind == .screen ? "Playing screen" : "Play screen")
                }
                if meeting.hasPlayableAudio {
                    mediaButton(meeting, kind: .audio, title: playerKind == .audio ? "Playing audio" : "Play audio")
                }
                if !meeting.hasPlayableScreen && !meeting.hasPlayableAudio {
                    Label("No recording was retained for this call", systemImage: "nosign")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(secondary)
                }
                Spacer()
                if let local = meeting.localScreenURL ?? meeting.localAudioURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([local])
                    } label: {
                        Label("Reveal local copy", systemImage: "finder")
                    }
                    .buttonStyle(LibraryButtonStyle(prominent: false))
                }
            }
        }
        .padding(14)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.06)))
    }

    private func mediaButton(_ meeting: MeetingRecord, kind: MeetingMediaKind, title: String) -> some View {
        Button {
            play(meeting, kind: kind)
        } label: {
            if loadingMedia == kind {
                HStack(spacing: 7) { ProgressView().controlSize(.small); Text("Loading…") }
            } else {
                Label(title, systemImage: kind == .screen ? "play.rectangle.fill" : "waveform.circle.fill")
            }
        }
        .buttonStyle(LibraryButtonStyle(prominent: playerKind != kind))
        .disabled(loadingMedia != nil)
    }

    @ViewBuilder
    private func summaryContent(_ meeting: MeetingRecord) -> some View {
        let insights = meeting.insights
        if !insights.participants.isEmpty {
            MeetingSection(
                title: "Participants",
                icon: "person.2.fill",
                copyText: MeetingClipboardText.participants(for: meeting)
            ) {
                FlowLayout(spacing: 6) {
                    ForEach(insights.participants, id: \.self) { participant in
                        Text(participant)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }
                }
            }
        }

        if !insights.summary.isEmpty {
            MeetingSection(
                title: "Summary",
                icon: "text.alignleft",
                copyText: MeetingClipboardText.summary(for: meeting)
            ) {
                Text(insights.summary)
                    .font(.system(size: 12))
                    .foregroundColor(primary.opacity(0.82))
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }

        if !insights.aiNotes.isEmpty {
            MeetingSection(
                title: "AI Notes",
                icon: "sparkles",
                copyText: MeetingClipboardText.aiNotes(for: meeting)
            ) {
                MarkdownNotesView(markdown: insights.aiNotes, textColor: primary, secondaryColor: secondary)
            }
        } else if insights.summary.isEmpty {
            MeetingSection(title: "AI Notes", icon: "sparkles") {
                Text("OpenRec could not generate notes for this call.")
                    .font(.system(size: 12))
                    .foregroundColor(secondary)
            }
        }

        MeetingSection(
            title: "Next steps",
            icon: "arrow.up.right.circle.fill",
            copyText: MeetingClipboardText.nextSteps(for: meeting)
        ) {
            if insights.actionItems.isEmpty {
                Text("No concrete next steps were detected.")
                    .font(.system(size: 12))
                    .foregroundColor(secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(insights.actionItems) { item in
                        HStack(alignment: .top, spacing: 9) {
                            Circle().fill(accent.opacity(0.9)).frame(width: 5, height: 5).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.task)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(primary.opacity(0.88))
                                let metadata = [item.owner.isEmpty ? nil : item.owner, item.dueDate].compactMap { $0 }.joined(separator: " · ")
                                if !metadata.isEmpty {
                                    Text(metadata)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(secondary)
                                }
                            }
                        }
                    }
                }
            }
        }

        MeetingSection(
            title: "Decisions",
            icon: "checkmark.seal.fill",
            copyText: MeetingClipboardText.decisions(for: meeting)
        ) {
            if insights.decisions.isEmpty {
                Text("No explicit decisions were detected.")
                    .font(.system(size: 12))
                    .foregroundColor(secondary)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(insights.decisions, id: \.self) { decision in
                        Label(decision, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(primary.opacity(0.82))
                    }
                }
            }
        }
    }

    private func myNotesSection(_ meeting: MeetingRecord) -> some View {
        MeetingSection(
            title: "My Notes",
            icon: "note.text",
            copyText: MeetingClipboardText.userNotes(for: meeting)
        ) {
            MeetingNotesEditor(
                notes: meeting.notes ?? [],
                primary: primary,
                secondary: secondary,
                accent: accent,
                playbackElapsed: { playbackElapsed() },
                onJump: { jumpToNote($0, in: meeting) },
                onUpdate: { commitNotes($0, on: meeting) }
            )
        }
    }

    private func transcriptContent(_ meeting: MeetingRecord) -> some View {
        MeetingSection(
            title: "Transcript",
            icon: "text.quote",
            copyText: MeetingClipboardText.transcript(for: meeting)
        ) {
            if let cues = meeting.transcriptCues, !cues.isEmpty {
                TranscriptCueList(
                    cues: cues,
                    speakerNames: meeting.speakerNames ?? [:],
                    highlightedID: highlightedCueID,
                    primary: primary,
                    secondary: secondary,
                    accent: accent
                )
            } else if let transcript = MeetingClipboardText.transcript(for: meeting) {
                Text(transcript)
                    .font(.system(size: 12))
                    .foregroundColor(primary.opacity(0.82))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(MeetingLibraryPresentation.emptyTranscriptMessage(for: meeting))
                    .font(.system(size: 12))
                    .foregroundColor(secondary)
            }
        }
    }

    private func focusSearchIfRequested() {
        guard let token = navigation.focusSearchToken, handledSearchFocusToken != token else { return }
        handledSearchFocusToken = token
        focusSearchField()
    }

    private func focusSearchField() {
        if tab != .past {
            pendingSearchFocus = true
            switchTab(to: .past)
        } else {
            searchFieldFocused = true
        }
    }

    private func selectInitialMeeting() {
        if applyPendingSelection() { return }
        if let selectedID, visibleMeetings.contains(where: { $0.id == selectedID }) { return }
        selectedID = visibleMeetings.first?.id
        if selectedID == nil { detail = nil }
    }

    @discardableResult
    private func applyPendingSelection() -> Bool {
        guard let request = navigation.request,
              handledSelectionToken != request.token,
              let meeting = recorderManager.cloudStorage.libraryMeetings.first(where: { $0.id == request.meetingID }) else {
            return false
        }
        handledSelectionToken = request.token
        searchText = ""
        switchTab(to: .past)
        selectMeeting(meeting, forceReload: true)
        return true
    }

    private func selectMeeting(_ meeting: MeetingRecord, forceReload: Bool) {
        if selectedID == meeting.id {
            if forceReload { loadDetail(meeting) }
        } else {
            selectedID = meeting.id
        }
    }

    private func loadDetail(_ meeting: MeetingRecord) {
        detailTask?.cancel()
        mediaTask?.cancel()
        player?.pause()
        player = nil
        playerKind = nil
        loadingMedia = nil
        selectedTab = .summary
        detail = meeting
        detailError = nil
        mediaError = nil
        let shouldLoadCloudDetail = meeting.storageMode == .managed
            && meeting.saveStatus == .saved
            && recorderManager.cloudStorage.isManagedSignedIn
        isLoadingDetail = shouldLoadCloudDetail
        guard shouldLoadCloudDetail else { return }
        let requestedID = meeting.id
        detailTask = Task { @MainActor in
            do {
                let loaded = try await recorderManager.cloudStorage.meetingDetail(for: meeting)
                guard !Task.isCancelled, selectedID == requestedID else { return }
                detail = loaded
            } catch {
                guard !Task.isCancelled, selectedID == requestedID else { return }
                detailError = error.localizedDescription
            }
            if selectedID == requestedID { isLoadingDetail = false }
        }
    }

    private func mergeVisibleDetail(_ updated: MeetingRecord) -> MeetingRecord {
        guard var current = detail, current.id == updated.id else { return updated }
        current.saveStatus = updated.saveStatus
        current.saveStage = updated.saveStage
        current.errorMessage = updated.errorMessage
        current.webhookDeliveryStatus = updated.webhookDeliveryStatus
        current.webhookErrorMessage = updated.webhookErrorMessage
        current.screenDeletionScheduledAt = updated.screenDeletionScheduledAt
        current.audioDeletionScheduledAt = updated.audioDeletionScheduledAt
        current.localScreenPath = updated.localScreenPath
        current.localAudioPath = updated.localAudioPath
        current.hasScreenRecording = updated.hasScreenRecording
        current.hasAudioRecording = updated.hasAudioRecording
        if updated.speakerNames != nil {
            current.speakerNames = updated.speakerNames
        }
        if updated.notes != nil {
            current.notes = updated.notes
        }
        if updated.transcriptCues != nil {
            current.transcriptCues = updated.transcriptCues
        }
        return current
    }

    @ViewBuilder
    private func speakerNamesSection(_ meeting: MeetingRecord) -> some View {
        let rows = SpeakerNames.rows(transcript: meeting.transcript ?? "", mapping: meeting.speakerNames ?? [:])
        if !rows.isEmpty {
            MeetingSection(title: "Speakers", icon: "person.crop.rectangle.stack") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Correct a name if it is wrong. The next meeting analysis uses these names.")
                        .font(.system(size: 11))
                        .foregroundColor(secondary)
                    ForEach(rows) { row in
                        SpeakerNameRowEditor(
                            label: row.label,
                            name: row.name,
                            primary: primary,
                            onCommit: { commitSpeakerName($0, for: row.label, on: meeting) }
                        )
                    }
                }
            }
        }
    }

    private func commitNotes(_ notes: [RecordingNote], on meeting: MeetingRecord) {
        var updated = meeting
        updated.notes = notes.nilIfEmpty
        updated.updatedAt = Date()
        do {
            try recorderManager.cloudStorage.upsertLocalMeeting(updated)
            detail = updated
        } catch {
            detailError = error.localizedDescription
        }
    }

    private func jumpToNote(_ seconds: TimeInterval, in meeting: MeetingRecord) {
        if let cue = TranscriptCues.nearest(to: seconds, in: meeting.transcriptCues ?? []) {
            highlightedCueID = cue.id
            if selectedTab != .transcript {
                selectedTab = .transcript
            }
            transcriptScrollToken = UUID()
        }
        guard meeting.hasPlayableScreen || meeting.hasPlayableAudio else { return }
        let kind: MeetingMediaKind
        if let playerKind {
            kind = playerKind
        } else if meeting.hasPlayableScreen {
            kind = .screen
        } else {
            kind = .audio
        }
        play(meeting, kind: kind, at: seconds)
    }

    private func playbackElapsed() -> TimeInterval {
        guard let time = player?.currentTime(), time.isNumeric else { return 0 }
        let seconds = time.seconds
        guard seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    private func commitSpeakerName(_ name: String, for label: String, on meeting: MeetingRecord) {
        var updated = meeting
        var mapping = updated.speakerNames ?? [:]
        if let normalized = SpeakerNames.normalizedUserName(name) {
            guard mapping[label] != normalized else { return }
            mapping[label] = normalized
        } else {
            guard mapping[label] != nil else { return }
            mapping.removeValue(forKey: label)
        }
        updated.speakerNames = mapping
        updated.updatedAt = Date()
        do {
            try recorderManager.cloudStorage.upsertLocalMeeting(updated)
            detail = updated
        } catch {
            detailError = error.localizedDescription
        }
    }

    private func play(_ meeting: MeetingRecord, kind: MeetingMediaKind, at seconds: TimeInterval? = nil) {
        if let seconds, let player, playerKind == kind, loadingMedia == nil {
            seek(player, to: seconds)
            return
        }
        mediaTask?.cancel()
        player?.pause()
        loadingMedia = kind
        mediaError = nil
        let requestedID = meeting.id
        mediaTask = Task { @MainActor in
            do {
                let url = try await recorderManager.cloudStorage.mediaURL(for: meeting, kind: kind)
                guard !Task.isCancelled, selectedID == requestedID else { return }
                player?.pause()
                let next = AVPlayer(url: url)
                player = next
                playerKind = kind
                if let seconds {
                    seek(next, to: seconds)
                } else {
                    next.play()
                }
            } catch {
                guard !Task.isCancelled, selectedID == requestedID else { return }
                mediaError = error.localizedDescription
            }
            if selectedID == requestedID { loadingMedia = nil }
        }
    }

    private func seek(_ player: AVPlayer, to seconds: TimeInterval) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else { return }
            Task { @MainActor in
                player.play()
            }
        }
    }

    /// Deleting is permanent across every copy of the meeting, so spell out
    /// exactly what will be removed before doing anything.
    private func confirmAndDelete(_ meeting: MeetingRecord) {
        var removals = ["its transcript and AI notes"]
        if meeting.storageMode == .local {
            if meeting.hasScreenRecording || meeting.hasAudioRecording
                || meeting.localScreenPath != nil || meeting.localAudioPath != nil {
                removals.append("the recording on this Mac")
            }
        } else {
            if meeting.hasScreenRecording || meeting.hasAudioRecording { removals.append("the cloud recording") }
            if meeting.localScreenPath != nil || meeting.localAudioPath != nil { removals.append("the local recording file") }
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete “\(meeting.title)”?"
        alert.informativeText = "This permanently deletes the meeting, including \(removals.joined(separator: ", ")). It cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Meeting")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        deletingMeetingID = meeting.id
        Task {
            defer { deletingMeetingID = nil }
            do {
                try await recorderManager.cloudStorage.deleteMeeting(meeting)
                if selectedID == meeting.id {
                    player?.pause()
                    player = nil
                    playerKind = nil
                    selectedID = nil
                    detail = nil
                    selectInitialMeeting()
                }
            } catch {
                let failure = NSAlert()
                failure.messageText = "Could not delete “\(meeting.title)”"
                failure.informativeText = error.localizedDescription
                failure.alertStyle = .warning
                failure.addButton(withTitle: "OK")
                failure.runModal()
            }
        }
    }

    private func copyMeeting(_ meeting: MeetingRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MeetingClipboardText.meeting(meeting), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remainder) : String(format: "%d:%02d", minutes, remainder)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct SpeakerNameRowEditor: View {
    let label: String
    let name: String
    let primary: Color
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(primary.opacity(0.55))
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
            TextField(
                "",
                text: $draft,
                prompt: Text("Add name").foregroundColor(Color.white.opacity(0.34))
            )
            .focused($focused)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(primary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onSubmit { commit() }
        }
        .onAppear { draft = name }
        .onChange(of: name) { value in
            if !focused { draft = value }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard !name.isEmpty else { return }
            onCommit("")
            return
        }
        guard let normalized = SpeakerNames.normalizedUserName(draft) else {
            draft = name
            return
        }
        guard normalized != name else {
            draft = name
            return
        }
        onCommit(normalized)
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord
    let selected: Bool
    let accent: Color
    var titleSnippet: MeetingSearchSnippet? = nil
    var bodySnippet: MeetingSearchSnippet? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(selected ? accent : Color.white.opacity(0.16))
                    .frame(width: 3, height: 34)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if let titleSnippet {
                            MeetingSearchSnippetText(
                                snippet: titleSnippet,
                                size: 12,
                                weight: .semibold,
                                color: Color.white.opacity(selected ? 0.94 : 0.78),
                                matchColor: accent,
                                lineLimit: 1
                            )
                        } else {
                            Text(meeting.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color.white.opacity(selected ? 0.94 : 0.78))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if meeting.saveStatus == .failed {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        } else if meeting.webhookDeliveryStatus == .failed {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundColor(.orange)
                        } else if meeting.saveStatus == .processing {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(Self.rowDate.string(from: meeting.startedAt))
                        if let names = rowSpeakerNames {
                            Text("·")
                            Text(names)
                        }
                        Spacer(minLength: 2)
                        if meeting.hasPlayableScreen { Image(systemName: "rectangle.inset.filled.and.person.filled") }
                        if meeting.hasPlayableAudio { Image(systemName: "waveform") }
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.4))
                    .lineLimit(1)
                    if let bodySnippet {
                        MeetingSearchSnippetText(
                            snippet: bodySnippet,
                            size: 11,
                            color: Color.white.opacity(0.55),
                            matchColor: accent,
                            lineLimit: 2
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .background(selected ? Color.white.opacity(0.085) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(LibraryPressStyle())
    }

    private var rowSpeakerNames: String? {
        let identified = SpeakerNames.identifiedNames(
            transcript: meeting.transcript ?? "",
            mapping: meeting.speakerNames ?? [:]
        )
        if !identified.isEmpty { return identified.prefix(2).joined(separator: ", ") }
        if !meeting.insights.participants.isEmpty {
            return meeting.insights.participants.prefix(2).joined(separator: ", ")
        }
        return nil
    }

    private static let rowDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d · h:mm a"
        return formatter
    }()
}

private struct MeetingSection<Content: View>: View {
    let title: String
    let icon: String
    let copyText: String?
    let content: Content
    @State private var copied = false
    @State private var copyFeedbackGeneration = 0

    init(title: String, icon: String, copyText: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.copyText = copyText
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(title, systemImage: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.54))
                    .textCase(.uppercase)
                Spacer()
                if let copyText {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyText, forType: .string)
                        copyFeedbackGeneration &+= 1
                        let generation = copyFeedbackGeneration
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if copyFeedbackGeneration == generation { copied = false }
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color.white.opacity(copied ? 0.78 : 0.5))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Color.white.opacity(copied ? 0.1 : 0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(LibraryPressStyle())
                    .help("Copy \(title.lowercased())")
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.055)))
    }
}

private struct StatusBanner: View {
    let message: String
    let icon: String
    let color: Color

    var body: some View {
        // Errors recorded before body sanitation existed can be entire web
        // pages; never let a banner grow past a few lines.
        Label(message, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color.opacity(0.95))
            .lineLimit(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private struct LibraryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct LibraryButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(prominent ? .white : Color.white.opacity(0.72))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(prominent ? Color(red: 1, green: 0.25, blue: 0.28) : Color.white.opacity(0.075))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct LibraryTabStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: selected ? .semibold : .medium))
            .foregroundColor(Color.white.opacity(selected ? 0.92 : 0.46))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(selected ? Color.white.opacity(0.09) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Compact wrapping layout for participant pills (macOS 13+).
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Renders Granola-style markdown meeting notes: section headers, bullet and
/// numbered lists, and inline emphasis. Intentionally small — it covers the
/// markdown the insights prompt asks for rather than the full spec.
struct MarkdownNotesView: View {
    let markdown: String
    var textColor: Color = .white
    var secondaryColor: Color = Color.white.opacity(0.55)

    private enum Block: Identifiable {
        case header(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case numbered(label: String, text: String)
        case paragraph(text: String)
        case divider

        var id: UUID { UUID() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let blocks = Self.parse(markdown)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .header(let level, let text):
            inlineText(text)
                .font(.system(size: level <= 1 ? 14 : (level == 2 ? 13 : 12), weight: .semibold))
                .foregroundColor(textColor.opacity(0.95))
                .padding(.top, 7)
        case .bullet(let indent, let text):
            HStack(alignment: .top, spacing: 7) {
                Text("•")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(secondaryColor)
                inlineText(text)
                    .font(.system(size: 12))
                    .foregroundColor(textColor.opacity(0.82))
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let label, let text):
            HStack(alignment: .top, spacing: 7) {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(secondaryColor)
                inlineText(text)
                    .font(.system(size: 12))
                    .foregroundColor(textColor.opacity(0.82))
                    .lineSpacing(3)
            }
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 12))
                .foregroundColor(textColor.opacity(0.82))
                .lineSpacing(3)
        case .divider:
            Color.white.opacity(0.1)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func inlineText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "---" || line == "***" {
                blocks.append(.divider)
                continue
            }
            if let headerMatch = line.range(of: #"^#{1,4} "#, options: .regularExpression) {
                let level = line.prefix(upTo: headerMatch.upperBound).filter { $0 == "#" }.count
                blocks.append(.header(level: level, text: String(line[headerMatch.upperBound...])))
                continue
            }
            if let bulletMatch = rawLine.range(of: #"^\s*[-*•] "#, options: .regularExpression) {
                let leadingSpaces = rawLine.prefix { $0 == " " || $0 == "\t" }.count
                blocks.append(.bullet(indent: min(leadingSpaces / 2, 3), text: String(rawLine[bulletMatch.upperBound...])))
                continue
            }
            if let numberMatch = line.range(of: #"^\d{1,2}[.)] "#, options: .regularExpression) {
                let label = line.prefix(upTo: numberMatch.upperBound).trimmingCharacters(in: .whitespaces)
                blocks.append(.numbered(label: label, text: String(line[numberMatch.upperBound...])))
                continue
            }
            blocks.append(.paragraph(text: line))
        }
        return blocks
    }
}
