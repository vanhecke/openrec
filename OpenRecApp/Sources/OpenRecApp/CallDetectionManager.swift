import Foundation
import AppKit
import ScreenCaptureKit

struct DetectedCall: Equatable {
    let appName: String
    let title: String?
    let participants: [String]

    init(appName: String, title: String?, participants: [String] = []) {
        self.appName = appName
        self.title = title
        self.participants = participants
    }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Call detected" : trimmed
    }
}

/// One shareable window, detached from ScreenCaptureKit so call matching can be tested.
struct CallWindowSnapshot: Equatable {
    var appName: String
    var bundleIdentifier: String
    var title: String?
    var isOnScreen: Bool
}

/// Shared call-window rules for the side prompt and for end-of-call checks.
enum CallWindowClassifier {
    private static let meetingTitleMarkers = [
        "meet.google.com", "google meet", "zoom meeting", "zoom webinar",
        "microsoft teams meeting", "teams call", "slack huddle", "webex meeting",
        "around call", "whereby", "riverside studio",
    ]

    private static let dedicatedBundles = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
        "com.apple.facetime", "com.cisco.webexmeetingsapp",
    ]

    private static let genericDedicatedTitles = [
        "zoom", "zoom workplace", "zoom.us", "microsoft teams", "teams",
        "facetime", "webex", "webex meetings",
    ]

    private static let titleSuffixes = [
        " - Google Chrome", " — Mozilla Firefox", " - Zoom", " | Microsoft Teams",
    ]

    static func detectedCall(in window: CallWindowSnapshot) -> DetectedCall? {
        let bundle = window.bundleIdentifier.lowercased()
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let haystack = "\(window.appName) \(title ?? "") \(bundle)".lowercased()

        let meetingTitleMatch = meetingTitleMarkers.contains(where: haystack.contains)
        let dedicatedApp = dedicatedBundles.contains(bundle)
        let cleaned = cleanedTitle(title, appName: window.appName)
        let hasCallSpecificDedicatedWindow = dedicatedApp
            && window.isOnScreen
            && cleaned.map { !genericDedicatedTitles.contains($0.lowercased()) } == true

        guard meetingTitleMatch || hasCallSpecificDedicatedWindow else { return nil }
        return DetectedCall(appName: window.appName, title: cleaned)
    }

    /// True when a window of `appName` still matches the same call rules that armed the prompt.
    static func isTrackedCallStillActive(_ windows: [CallWindowSnapshot], appName: String) -> Bool {
        let needle = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return windows.contains { window in
            window.appName.lowercased() == needle && detectedCall(in: window) != nil
        }
    }

    private static func cleanedTitle(_ title: String?, appName: String) -> String? {
        guard var title, !title.isEmpty else { return nil }
        for suffix in titleSuffixes where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        if title.lowercased() == appName.lowercased() { return nil }
        return title
    }
}

@MainActor
final class CallDetectionManager {
    var onCallDetected: ((DetectedCall) -> Void)?
    var isRecording: (() -> Bool)?

    private var timer: Timer?
    private var lastDetected: DetectedCall?
    private var dismissedUntil = Date.distantPast

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        Task { await scan() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func snooze() {
        dismissedUntil = Date().addingTimeInterval(15 * 60)
        // Let the same still-active call prompt again when snooze expires.
        lastDetected = nil
    }

    /// Whether `appName` still has a call window. A failed capture read counts as still active
    /// so a ScreenCaptureKit blip does not end a recording.
    func isCallActive(appName: String) async -> Bool {
        guard let windows = await currentWindows() else { return true }
        return CallWindowClassifier.isTrackedCallStillActive(windows, appName: appName)
    }

    private func scan() async {
        guard isRecording?() != true, Date() >= dismissedUntil else { return }
        guard let windows = await currentWindows() else { return }

        let candidates = windows.compactMap { CallWindowClassifier.detectedCall(in: $0) }
        guard let detected = candidates.first else {
            lastDetected = nil
            return
        }
        guard detected != lastDetected else { return }
        lastDetected = detected
        onCallDetected?(detected)
    }

    private func currentWindows() async -> [CallWindowSnapshot]? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return nil
        }
        return content.windows.compactMap { window in
            guard let app = window.owningApplication else { return nil }
            return CallWindowSnapshot(
                appName: app.applicationName,
                bundleIdentifier: app.bundleIdentifier,
                title: window.title,
                isOnScreen: window.isOnScreen
            )
        }
    }
}
