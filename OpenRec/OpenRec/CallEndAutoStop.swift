import Foundation
import Combine
import UserNotifications

/// Decides when a live recording should count down to a stop because the call ended.
///
/// Callers feed audio levels, call-app presence, the settings toggle, and a clock.
/// The type never reads the system clock or capture devices.
///
/// A countdown arms from either signal:
/// - The call app that started the recording was seen in a call, has since stayed
///   gone, and system audio has stayed quiet, for `Thresholds.callAbsenceConfirmation`.
///   System audio that is still flowing blocks this path, so a window-title glitch
///   during a live call does not stop the take.
/// - System audio and the microphone have both stayed quiet for
///   `Thresholds.silenceDuration` after sound was heard. A shorter gap is a quiet
///   moment. This is the only path for a recording started manually, with no
///   detected call app (`tracksCallApp == false`). Silence does not accumulate
///   before the first sound, so a take that is still waiting for people is left alone.
///
/// Keep Recording leaves the countdown and ignores further end signals until audio
/// returns or the tracked call app is seen in a call again.
struct CallEndAutoStop: Equatable {
    enum Thresholds {
        /// System audio and the mic both quiet, after sound has been heard.
        static let silenceDuration: TimeInterval = 60
        /// HUD countdown before the recording stops and saves.
        static let countdownDuration: TimeInterval = 15
        /// Tracked call app gone, with system audio quiet, before that path arms.
        /// Longer than one call-detection pass so a single missed scan does not fire.
        static let callAbsenceConfirmation: TimeInterval = 18
        /// `ScreenRecorder` publishes `min(1, rms * 12)`. Speech sits above this.
        /// Digital silence, comfort noise, and a quiet capture floor sit below it,
        /// so a hushed live call is not treated as silence.
        static let silenceLevel: Float = 0.08
        /// How often the live session rechecks the tracked call app.
        static let callPresenceInterval: TimeInterval = 6
    }

    enum Phase: Equatable {
        case idle
        case watching
        case suppressed
        case countingDown(deadline: Date)
    }

    struct Input: Equatable {
        var enabled: Bool = true
        /// `nil` when this recording has no tracked call app, or presence is not known yet.
        var callAppInCall: Bool?
        var systemLevel: Float = 0
        var micLevel: Float = 0
    }

    enum Decision: Equatable {
        case none
        case countdownBegan
        case stop
    }

    private(set) var phase: Phase = .idle
    private var tracksCallApp = false
    private var hasHeardAudio = false
    private var hasSeenCallActive = false
    private var silenceBeganAt: Date?
    private var callQuietAbsenceBeganAt: Date?

    mutating func beginRecording(tracksCallApp: Bool) {
        self = CallEndAutoStop()
        self.tracksCallApp = tracksCallApp
        phase = .watching
    }

    mutating func endRecording() {
        self = CallEndAutoStop()
    }

    /// Drops the countdown. End signals stay ignored until activity resumes.
    mutating func keepRecording() {
        guard case .countingDown = phase else { return }
        phase = .suppressed
        silenceBeganAt = nil
        callQuietAbsenceBeganAt = nil
    }

    func remaining(at now: Date) -> TimeInterval? {
        guard case .countingDown(let deadline) = phase else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }

    mutating func ingest(_ input: Input, now: Date) -> Decision {
        guard phase != .idle else { return .none }

        guard input.enabled else {
            silenceBeganAt = nil
            callQuietAbsenceBeganAt = nil
            if case .countingDown = phase {
                phase = .watching
            }
            return .none
        }

        if case .countingDown(let deadline) = phase {
            if now >= deadline {
                phase = .idle
                return .stop
            }
            return .none
        }

        if case .suppressed = phase {
            guard activityResumed(input) else { return .none }
            noteActivity(input)
            phase = .watching
            silenceBeganAt = nil
            callQuietAbsenceBeganAt = nil
            return .none
        }

        noteActivity(input)
        let systemQuiet = input.systemLevel <= Thresholds.silenceLevel
        let micQuiet = input.micLevel <= Thresholds.silenceLevel

        if systemQuiet && micQuiet {
            if hasHeardAudio, silenceBeganAt == nil {
                silenceBeganAt = now
            }
        } else {
            silenceBeganAt = nil
        }

        if tracksCallApp, hasSeenCallActive, input.callAppInCall == false, systemQuiet {
            if callQuietAbsenceBeganAt == nil { callQuietAbsenceBeganAt = now }
        } else {
            callQuietAbsenceBeganAt = nil
        }

        if let began = callQuietAbsenceBeganAt,
           now.timeIntervalSince(began) >= Thresholds.callAbsenceConfirmation {
            return beginCountdown(at: now)
        }

        if let began = silenceBeganAt,
           now.timeIntervalSince(began) >= Thresholds.silenceDuration {
            return beginCountdown(at: now)
        }

        return .none
    }

    private mutating func noteActivity(_ input: Input) {
        if input.systemLevel > Thresholds.silenceLevel || input.micLevel > Thresholds.silenceLevel {
            hasHeardAudio = true
        }
        if tracksCallApp, input.callAppInCall == true {
            hasSeenCallActive = true
        }
    }

    private func activityResumed(_ input: Input) -> Bool {
        if input.systemLevel > Thresholds.silenceLevel || input.micLevel > Thresholds.silenceLevel {
            return true
        }
        return tracksCallApp && input.callAppInCall == true
    }

    private mutating func beginCountdown(at now: Date) -> Decision {
        phase = .countingDown(deadline: now.addingTimeInterval(Thresholds.countdownDuration))
        silenceBeganAt = nil
        callQuietAbsenceBeganAt = nil
        return .countdownBegan
    }
}

/// Drives `CallEndAutoStop` from the live recording. The state machine stays free of timers.
@MainActor
final class CallEndAutoStopMonitor: ObservableObject {
    @Published private(set) var countdownDeadline: Date?

    var currentLevels: () -> (system: Float, mic: Float) = { (system: 0, mic: 0) }
    var callAppStillInCall: ((String) async -> Bool)?
    var onRequestStop: (() -> Void)?

    private var machine = CallEndAutoStop()
    private var timer: Timer?
    private var sessionID = UUID()
    private var trackedAppName: String?
    private var callAppInCall: Bool?
    private var lastCallCheckAt: Date?
    private var callCheckInFlight = false
    private var enabled = true

    private static let tickInterval: TimeInterval = 0.5

    func recordingDidStart(trackedCallAppName: String?, enabled: Bool) {
        sessionID = UUID()
        let session = sessionID
        self.enabled = enabled
        let trimmed = trackedCallAppName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        trackedAppName = trimmed.isEmpty ? nil : trimmed
        callAppInCall = nil
        lastCallCheckAt = nil
        callCheckInFlight = false
        countdownDeadline = nil
        machine.beginRecording(tracksCallApp: trackedAppName != nil)
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sessionID == session else { return }
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func recordingDidStop() {
        sessionID = UUID()
        timer?.invalidate()
        timer = nil
        callCheckInFlight = false
        trackedAppName = nil
        callAppInCall = nil
        machine.endRecording()
        countdownDeadline = nil
    }

    func keepRecording() {
        machine.keepRecording()
        publishCountdown()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        guard timer != nil else { return }
        evaluate(now: Date())
    }

    private func tick() {
        let now = Date()
        if enabled {
            pollCallPresenceIfNeeded(now: now)
        }
        evaluate(now: now)
    }

    private func pollCallPresenceIfNeeded(now: Date) {
        guard let appName = trackedAppName, !callCheckInFlight else { return }
        if let lastCallCheckAt,
           now.timeIntervalSince(lastCallCheckAt) < CallEndAutoStop.Thresholds.callPresenceInterval {
            return
        }
        lastCallCheckAt = now
        callCheckInFlight = true
        let session = sessionID
        Task { @MainActor in
            let active = await self.callAppStillInCall?(appName) ?? true
            guard self.sessionID == session else { return }
            self.callCheckInFlight = false
            self.callAppInCall = active
            self.evaluate(now: Date())
        }
    }

    private func evaluate(now: Date) {
        guard timer != nil else { return }
        let levels = currentLevels()
        let decision = machine.ingest(
            CallEndAutoStop.Input(
                enabled: enabled,
                callAppInCall: trackedAppName == nil ? nil : callAppInCall,
                systemLevel: levels.system,
                micLevel: levels.mic
            ),
            now: now
        )
        switch decision {
        case .none, .countdownBegan:
            publishCountdown()
        case .stop:
            countdownDeadline = nil
            timer?.invalidate()
            timer = nil
            sessionID = UUID()
            onRequestStop?()
        }
    }

    private func publishCountdown() {
        let deadline: Date?
        if case .countingDown(let value) = machine.phase {
            deadline = value
        } else {
            deadline = nil
        }
        guard countdownDeadline != deadline else { return }
        countdownDeadline = deadline
    }
}

enum CallEndAttentionNotification {
    private static let identifier = "openrec.call-end-autostop"

    /// Banner for a countdown the user cannot see because the recorder was hidden.
    /// Posted only when notification permission was already granted.
    static func post() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Call ended"
            let seconds = Int(CallEndAutoStop.Thresholds.countdownDuration)
            content.body = "OpenRec stops recording in \(seconds) seconds. Open OpenRec to keep recording."
            content.sound = UNNotificationSound.default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request)
        }
    }

    static func withdraw() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
