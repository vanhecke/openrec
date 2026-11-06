import Foundation
import XCTest
@testable import OpenRecApp

final class SavedConfirmationTests: XCTestCase {
    func testDismissedSuccessRestoresIdlePromptAndKeepsMeetingID() {
        let meetingID = UUID()
        let saved = SavedConfirmation.HUDState(
            savePhase: .complete,
            statusMessage: nil,
            lastSavedMeetingID: meetingID
        )

        XCTAssertTrue(SavedConfirmation.showsViewMeeting(saved))

        let dismissed = SavedConfirmation.afterDismissal(saved)

        XCTAssertEqual(dismissed.savePhase, .idle)
        XCTAssertNil(dismissed.statusMessage)
        XCTAssertEqual(dismissed.lastSavedMeetingID, meetingID)
        XCTAssertFalse(SavedConfirmation.showsViewMeeting(dismissed))
    }

    func testDismissedWarningClearsBannerCopyAndKeepsMeetingID() {
        let meetingID = UUID()
        let saved = SavedConfirmation.HUDState(
            savePhase: .completeWithWarning("The meeting is safe, but webhook delivery failed"),
            statusMessage: "The meeting is safe, but webhook delivery failed",
            lastSavedMeetingID: meetingID
        )

        let dismissed = SavedConfirmation.afterDismissal(saved)

        XCTAssertEqual(dismissed.savePhase, .idle)
        XCTAssertNil(dismissed.statusMessage)
        XCTAssertEqual(dismissed.lastSavedMeetingID, meetingID)
        XCTAssertFalse(SavedConfirmation.showsViewMeeting(dismissed))
    }

    func testDismissalLeavesFailuresAndInProgressPhasesAlone() {
        let meetingID = UUID()
        let failed = SavedConfirmation.HUDState(
            savePhase: .failed("disk full"),
            statusMessage: "disk full",
            lastSavedMeetingID: meetingID
        )
        let uploading = SavedConfirmation.HUDState(
            savePhase: .uploading,
            statusMessage: nil,
            lastSavedMeetingID: meetingID
        )

        XCTAssertEqual(SavedConfirmation.afterDismissal(failed), failed)
        XCTAssertEqual(SavedConfirmation.afterDismissal(uploading), uploading)
        XCTAssertFalse(SavedConfirmation.showsViewMeeting(failed))
        XCTAssertFalse(SavedConfirmation.showsViewMeeting(uploading))
        XCTAssertFalse(
            SavedConfirmation.showsViewMeeting(
                SavedConfirmation.HUDState(savePhase: .complete, statusMessage: nil, lastSavedMeetingID: nil)
            )
        )
    }

    func testSavedBannerAutoDismissesAfterAFewSecondsUnlessANewerSaveReplacedIt() {
        let meetingID = UUID()
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let deadline = SavedConfirmation.autoDismissDeadline(savedAt: savedAt)
        let saved = SavedConfirmation.HUDState(
            savePhase: .complete,
            statusMessage: nil,
            lastSavedMeetingID: meetingID
        )

        XCTAssertGreaterThanOrEqual(SavedConfirmation.visibleDuration, 3)
        XCTAssertLessThanOrEqual(SavedConfirmation.visibleDuration, 6)
        XCTAssertEqual(deadline.timeIntervalSince(savedAt), SavedConfirmation.visibleDuration)

        XCTAssertFalse(
            SavedConfirmation.shouldAutoDismiss(
                scheduled: saved,
                current: saved,
                now: deadline.addingTimeInterval(-0.05),
                deadline: deadline
            )
        )
        XCTAssertTrue(
            SavedConfirmation.shouldAutoDismiss(
                scheduled: saved,
                current: saved,
                now: deadline.addingTimeInterval(-0.05),
                deadline: deadline,
                timerFired: true
            )
        )
        XCTAssertTrue(
            SavedConfirmation.shouldAutoDismiss(
                scheduled: saved,
                current: saved,
                now: deadline,
                deadline: deadline
            )
        )

        var replaced = saved
        replaced.lastSavedMeetingID = UUID()
        XCTAssertFalse(
            SavedConfirmation.shouldAutoDismiss(
                scheduled: saved,
                current: replaced,
                now: deadline,
                deadline: deadline,
                timerFired: true
            )
        )

        let warning = SavedConfirmation.HUDState(
            savePhase: .completeWithWarning("webhook"),
            statusMessage: "webhook",
            lastSavedMeetingID: meetingID
        )
        XCTAssertFalse(
            SavedConfirmation.shouldAutoDismiss(
                scheduled: saved,
                current: warning,
                now: deadline,
                deadline: deadline,
                timerFired: true
            )
        )
        XCTAssertTrue(
            SavedConfirmation.shouldAutoDismiss(
                scheduled: warning,
                current: warning,
                now: deadline,
                deadline: deadline,
                timerFired: true
            )
        )

        var cleared = saved
        cleared.savePhase = .idle
        XCTAssertFalse(
            SavedConfirmation.shouldAutoDismiss(
                scheduled: saved,
                current: cleared,
                now: deadline,
                deadline: deadline,
                timerFired: true
            )
        )
    }
}
