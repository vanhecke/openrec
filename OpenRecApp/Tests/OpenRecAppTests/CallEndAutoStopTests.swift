import Foundation
import XCTest
@testable import OpenRecApp

final class CallEndAutoStopTests: XCTestCase {
    private let loud: Float = 0.4

    func testThresholdsMatchTheCountdownAndSilenceDefaults() {
        XCTAssertEqual(CallEndAutoStop.Thresholds.silenceDuration, 60)
        XCTAssertEqual(CallEndAutoStop.Thresholds.countdownDuration, 15)
        XCTAssertGreaterThan(CallEndAutoStop.Thresholds.callAbsenceConfirmation, 0)
        XCTAssertLessThan(
            CallEndAutoStop.Thresholds.callAbsenceConfirmation,
            CallEndAutoStop.Thresholds.silenceDuration
        )
        XCTAssertGreaterThan(CallEndAutoStop.Thresholds.silenceLevel, 0)
        XCTAssertLessThan(CallEndAutoStop.Thresholds.silenceLevel, loud)
    }

    func testCallAppEndTriggersCountdown() {
        var autoStop = CallEndAutoStop()
        autoStop.beginRecording(tracksCallApp: true)
        let start = Date(timeIntervalSince1970: 20_000)

        XCTAssertEqual(autoStop.ingest(input(call: true, system: loud, mic: 0.2), now: start), .none)

        let gone = start.addingTimeInterval(4)
        // Mic stays hot so the silence rule cannot be what arms the countdown.
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: loud), now: gone), .none)

        let almost = gone.addingTimeInterval(CallEndAutoStop.Thresholds.callAbsenceConfirmation - 1)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: loud), now: almost), .none)
        XCTAssertEqual(autoStop.phase, .watching)

        let due = gone.addingTimeInterval(CallEndAutoStop.Thresholds.callAbsenceConfirmation)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: loud), now: due), .countdownBegan)
        XCTAssertEqual(
            autoStop.remaining(at: due) ?? -1,
            CallEndAutoStop.Thresholds.countdownDuration,
            accuracy: 0.001
        )
    }

    func testSilenceThresholdTriggersCountdown() {
        var autoStop = CallEndAutoStop()
        autoStop.beginRecording(tracksCallApp: false)
        let start = Date(timeIntervalSince1970: 30_000)

        XCTAssertEqual(autoStop.ingest(input(system: loud, mic: loud), now: start), .none)

        let quiet = start.addingTimeInterval(2)
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: quiet), .none)

        let almost = quiet.addingTimeInterval(CallEndAutoStop.Thresholds.silenceDuration - 1)
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: almost), .none)
        XCTAssertEqual(autoStop.phase, .watching)

        let due = quiet.addingTimeInterval(CallEndAutoStop.Thresholds.silenceDuration)
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: due), .countdownBegan)
    }

    func testBriefSilenceDoesNotTrigger() {
        var autoStop = CallEndAutoStop()
        autoStop.beginRecording(tracksCallApp: true)
        let start = Date(timeIntervalSince1970: 40_000)

        XCTAssertEqual(autoStop.ingest(input(call: true, system: loud, mic: 0.1), now: start), .none)

        let quiet = start.addingTimeInterval(1)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: 0, mic: 0), now: quiet), .none)

        let stillBrief = quiet.addingTimeInterval(10)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: 0, mic: 0), now: stillBrief), .none)

        // A mic spike resets the quiet stretch. Another short gap still does not arm.
        let spoke = stillBrief.addingTimeInterval(1)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: 0, mic: loud), now: spoke), .none)
        let quietAgain = spoke.addingTimeInterval(1)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: 0, mic: 0), now: quietAgain), .none)
        let tenMore = quietAgain.addingTimeInterval(10)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: 0, mic: 0), now: tenMore), .none)
        XCTAssertEqual(autoStop.phase, .watching)
    }

    func testKeepRecordingSuppressesUntilActivityResumes() {
        var autoStop = CallEndAutoStop()
        autoStop.beginRecording(tracksCallApp: false)
        let start = Date(timeIntervalSince1970: 50_000)
        let due = silenceCountdownDue(autoStop: &autoStop, start: start)
        XCTAssertEqual(autoStop.phase, .countingDown(deadline: due.addingTimeInterval(CallEndAutoStop.Thresholds.countdownDuration)))

        autoStop.keepRecording()
        XCTAssertEqual(autoStop.phase, .suppressed)

        let stillQuiet = due.addingTimeInterval(CallEndAutoStop.Thresholds.silenceDuration * 3)
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: stillQuiet), .none)
        XCTAssertEqual(autoStop.phase, .suppressed)

        let resumed = stillQuiet.addingTimeInterval(1)
        XCTAssertEqual(autoStop.ingest(input(system: loud, mic: 0), now: resumed), .none)
        XCTAssertEqual(autoStop.phase, .watching)

        let quietAgain = resumed.addingTimeInterval(1)
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: quietAgain), .none)
        let almost = quietAgain.addingTimeInterval(CallEndAutoStop.Thresholds.silenceDuration - 1)
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: almost), .none)
        let again = quietAgain.addingTimeInterval(CallEndAutoStop.Thresholds.silenceDuration)
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: again), .countdownBegan)
    }

    func testKeepRecordingTreatsTheCallAppReturningAsActivity() {
        var autoStop = CallEndAutoStop()
        autoStop.beginRecording(tracksCallApp: true)
        let start = Date(timeIntervalSince1970: 60_000)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: loud, mic: 0), now: start), .none)
        let gone = start.addingTimeInterval(3)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: 0), now: gone), .none)
        let due = gone.addingTimeInterval(CallEndAutoStop.Thresholds.callAbsenceConfirmation)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: 0), now: due), .countdownBegan)

        autoStop.keepRecording()
        let held = due.addingTimeInterval(120)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: 0), now: held), .none)
        XCTAssertEqual(autoStop.phase, .suppressed)

        let back = held.addingTimeInterval(1)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: 0, mic: 0), now: back), .none)
        XCTAssertEqual(autoStop.phase, .watching)

        let left = back.addingTimeInterval(1)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: 0), now: left), .none)
        let endedAgain = left.addingTimeInterval(CallEndAutoStop.Thresholds.callAbsenceConfirmation)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: 0), now: endedAgain), .countdownBegan)
    }

    func testCountdownExpiryStops() {
        var autoStop = CallEndAutoStop()
        autoStop.beginRecording(tracksCallApp: false)
        let start = Date(timeIntervalSince1970: 70_000)
        let due = silenceCountdownDue(autoStop: &autoStop, start: start)
        let deadline = due.addingTimeInterval(CallEndAutoStop.Thresholds.countdownDuration)

        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: deadline.addingTimeInterval(-1)), .none)
        XCTAssertEqual(autoStop.remaining(at: deadline.addingTimeInterval(-1)) ?? -1, 1, accuracy: 0.001)

        // Sound during the last instant does not cancel a countdown already on screen.
        XCTAssertEqual(autoStop.ingest(input(system: loud, mic: loud), now: deadline), .stop)
        XCTAssertEqual(autoStop.phase, .idle)
        XCTAssertNil(autoStop.remaining(at: deadline))
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: deadline.addingTimeInterval(5)), .none)
    }

    func testToggleOffDisables() {
        var autoStop = CallEndAutoStop()
        autoStop.beginRecording(tracksCallApp: true)
        let start = Date(timeIntervalSince1970: 80_000)

        XCTAssertEqual(
            autoStop.ingest(input(enabled: false, call: true, system: loud, mic: loud), now: start),
            .none
        )
        let muchLater = start.addingTimeInterval(500)
        XCTAssertEqual(
            autoStop.ingest(input(enabled: false, call: false, system: 0, mic: 0), now: muchLater),
            .none
        )
        XCTAssertEqual(autoStop.phase, .watching)

        XCTAssertEqual(autoStop.ingest(input(call: true, system: loud, mic: 0.2), now: muchLater.addingTimeInterval(1)), .none)
        let gone = muchLater.addingTimeInterval(2)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: loud), now: gone), .none)
        let due = gone.addingTimeInterval(CallEndAutoStop.Thresholds.callAbsenceConfirmation)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: loud), now: due), .countdownBegan)

        let cancelled = due.addingTimeInterval(1)
        XCTAssertEqual(autoStop.ingest(input(enabled: false, call: false, system: 0, mic: 0), now: cancelled), .none)
        XCTAssertEqual(autoStop.phase, .watching)

        let deadline = due.addingTimeInterval(CallEndAutoStop.Thresholds.countdownDuration)
        XCTAssertEqual(
            autoStop.ingest(input(enabled: false, call: false, system: 0, mic: 0), now: deadline),
            .none
        )
        XCTAssertEqual(autoStop.phase, .watching)

        // Turning it back on starts a fresh confirmation. The old quiet stretch does not stop immediately.
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: loud), now: deadline), .none)
        let tooSoon = deadline.addingTimeInterval(CallEndAutoStop.Thresholds.callAbsenceConfirmation - 1)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: loud), now: tooSoon), .none)
        XCTAssertEqual(autoStop.phase, .watching)
    }

    func testSystemAudioKeepsAMissingCallWindowFromStopping() {
        var autoStop = CallEndAutoStop()
        autoStop.beginRecording(tracksCallApp: true)
        let start = Date(timeIntervalSince1970: 90_000)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: loud, mic: 0), now: start), .none)

        let gone = start.addingTimeInterval(2)
        let stillTalking = gone.addingTimeInterval(CallEndAutoStop.Thresholds.callAbsenceConfirmation + 30)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: loud, mic: 0), now: gone), .none)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: loud, mic: 0), now: stillTalking), .none)
        XCTAssertEqual(autoStop.phase, .watching)
    }

    func testManualRecordingIgnoresCallAppAbsence() {
        var autoStop = CallEndAutoStop()
        autoStop.beginRecording(tracksCallApp: false)
        let start = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(autoStop.ingest(input(system: loud, mic: 0.2), now: start), .none)

        let gone = start.addingTimeInterval(1)
        let pastConfirmation = gone.addingTimeInterval(CallEndAutoStop.Thresholds.callAbsenceConfirmation + 5)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: loud), now: gone), .none)
        XCTAssertEqual(autoStop.ingest(input(call: false, system: 0, mic: loud), now: pastConfirmation), .none)
        XCTAssertEqual(autoStop.phase, .watching)
    }

    func testSilenceBeforeAnyAudioDoesNotStop() {
        var autoStop = CallEndAutoStop()
        autoStop.beginRecording(tracksCallApp: false)
        let start = Date(timeIntervalSince1970: 110_000)
        let later = start.addingTimeInterval(CallEndAutoStop.Thresholds.silenceDuration * 3)
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: start), .none)
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: later), .none)
        XCTAssertEqual(autoStop.phase, .watching)
    }

    func testFullSilenceStopsEvenIfTheCallWindowRemains() {
        var autoStop = CallEndAutoStop()
        autoStop.beginRecording(tracksCallApp: true)
        let start = Date(timeIntervalSince1970: 120_000)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: loud, mic: loud), now: start), .none)

        let quiet = start.addingTimeInterval(1)
        let moment = quiet.addingTimeInterval(20)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: 0, mic: 0), now: quiet), .none)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: 0, mic: 0), now: moment), .none)
        XCTAssertEqual(autoStop.phase, .watching)

        let due = quiet.addingTimeInterval(CallEndAutoStop.Thresholds.silenceDuration)
        XCTAssertEqual(autoStop.ingest(input(call: true, system: 0, mic: 0), now: due), .countdownBegan)
    }

    private func silenceCountdownDue(autoStop: inout CallEndAutoStop, start: Date) -> Date {
        XCTAssertEqual(autoStop.ingest(input(system: loud, mic: loud), now: start), .none)
        let quiet = start.addingTimeInterval(2)
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: quiet), .none)
        let due = quiet.addingTimeInterval(CallEndAutoStop.Thresholds.silenceDuration)
        XCTAssertEqual(autoStop.ingest(input(system: 0, mic: 0), now: due), .countdownBegan)
        return due
    }

    private func input(
        enabled: Bool = true,
        call: Bool? = nil,
        system: Float = 0,
        mic: Float = 0
    ) -> CallEndAutoStop.Input {
        CallEndAutoStop.Input(
            enabled: enabled,
            callAppInCall: call,
            systemLevel: system,
            micLevel: mic
        )
    }
}

final class CallWindowClassifierTests: XCTestCase {
    func testMeetChromeWindowIsACallAndMatchesTheTrackedApp() {
        let window = CallWindowSnapshot(
            appName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            title: "Weekly sync - Google Meet - Google Chrome",
            isOnScreen: true
        )

        let call = CallWindowClassifier.detectedCall(in: window)
        XCTAssertEqual(call?.appName, "Google Chrome")
        XCTAssertEqual(call?.title, "Weekly sync - Google Meet")
        XCTAssertTrue(CallWindowClassifier.isTrackedCallStillActive([window], appName: "Google Chrome"))
        XCTAssertFalse(CallWindowClassifier.isTrackedCallStillActive([window], appName: "zoom.us"))
    }

    func testGenericZoomWindowIsNotALiveCall() {
        let window = CallWindowSnapshot(
            appName: "zoom.us",
            bundleIdentifier: "us.zoom.xos",
            title: "Zoom Workplace",
            isOnScreen: true
        )

        XCTAssertNil(CallWindowClassifier.detectedCall(in: window))
        XCTAssertFalse(CallWindowClassifier.isTrackedCallStillActive([window], appName: "zoom.us"))
    }

    func testOnScreenFaceTimeWithAPersonTitleIsACall() {
        let live = CallWindowSnapshot(
            appName: "FaceTime",
            bundleIdentifier: "com.apple.facetime",
            title: "Ada Lovelace",
            isOnScreen: true
        )
        let idle = CallWindowSnapshot(
            appName: "FaceTime",
            bundleIdentifier: "com.apple.facetime",
            title: "FaceTime",
            isOnScreen: true
        )

        XCTAssertEqual(CallWindowClassifier.detectedCall(in: live)?.appName, "FaceTime")
        XCTAssertNil(CallWindowClassifier.detectedCall(in: idle))
        XCTAssertTrue(CallWindowClassifier.isTrackedCallStillActive([idle, live], appName: "FaceTime"))
    }

    func testSlackHuddleMatchesSlackOnly() {
        let window = CallWindowSnapshot(
            appName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            title: "Slack huddle with Design",
            isOnScreen: true
        )

        XCTAssertEqual(CallWindowClassifier.detectedCall(in: window)?.appName, "Slack")
        XCTAssertTrue(CallWindowClassifier.isTrackedCallStillActive([window], appName: "slack"))
        XCTAssertFalse(CallWindowClassifier.isTrackedCallStillActive([window], appName: "Microsoft Teams"))
    }
}
