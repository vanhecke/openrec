import AppKit
import XCTest
@testable import OpenRecApp

@MainActor
final class StatusItemMenuTests: XCTestCase {
    func testClosingTheLastWindowDoesNotQuit() {
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testIdleMenuOffersOpenRecordingMeetingsSettingsAndQuit() {
        XCTAssertEqual(StatusItemMenu.entries(for: .readyHidden), [
            .action(title: "Open OpenRec", action: .showRecorder, isEnabled: true),
            .action(title: "Start Recording", action: .toggleRecording, isEnabled: true),
            .separator,
            .action(title: "Meetings…", action: .meetings, isEnabled: true),
            .action(title: "Settings…", action: .settings, isEnabled: true),
            .separator,
            .action(title: "Quit OpenRec", action: .quit, isEnabled: true)
        ])
    }

    func testVisibleRecordingMenuHidesTheWindowAndStops() {
        XCTAssertEqual(StatusItemMenu.entries(for: .recordingVisible), [
            .action(title: "Hide OpenRec", action: .hideRecorder, isEnabled: true),
            .action(title: "Stop Recording", action: .toggleRecording, isEnabled: true),
            .separator,
            .action(title: "Meetings…", action: .meetings, isEnabled: true),
            .action(title: "Settings…", action: .settings, isEnabled: false),
            .separator,
            .action(title: "Quit OpenRec", action: .quit, isEnabled: true)
        ])
    }

    func testRecordingCannotStartWhileBusyOrBeforeSetup() throws {
        XCTAssertEqual(
            try action(.toggleRecording, in: StatusItemMenu.entries(for: .processing)),
            .action(title: "Start Recording", action: .toggleRecording, isEnabled: false)
        )
        XCTAssertEqual(
            try action(.settings, in: StatusItemMenu.entries(for: .processing)),
            .action(title: "Settings…", action: .settings, isEnabled: false)
        )
        XCTAssertEqual(
            try action(.toggleRecording, in: StatusItemMenu.entries(for: .needsOnboarding)),
            .action(title: "Start Recording", action: .toggleRecording, isEnabled: false)
        )
        XCTAssertEqual(
            try action(.showRecorder, in: StatusItemMenu.entries(for: .needsOnboarding)),
            .action(title: "Open OpenRec", action: .showRecorder, isEnabled: true)
        )
        XCTAssertEqual(
            try action(.toggleRecording, in: StatusItemMenu.entries(for: .starting)),
            .action(title: "Start Recording", action: .toggleRecording, isEnabled: false)
        )
        XCTAssertEqual(
            try action(.settings, in: StatusItemMenu.entries(for: .starting)),
            .action(title: "Settings…", action: .settings, isEnabled: true)
        )
    }

    func testStatusMenuItemsInvokeTheExistingAppActions() {
        let owner = NSObject()
        let menu = StatusItemMenu.makeMenu(snapshot: .recordingVisible, target: owner)

        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.count, 7)

        assertAction(menu.items[0], title: "Hide OpenRec", selector: "hideControlWindow", target: owner, enabled: true)
        assertAction(menu.items[1], title: "Stop Recording", selector: "toggleRecordingFromStatusMenu", target: owner, enabled: true)
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        assertAction(menu.items[3], title: "Meetings…", selector: "showRecordingsLibrary", target: owner, enabled: true)
        assertAction(menu.items[4], title: "Settings…", selector: "openSettingsFromMenu", target: owner, enabled: false)
        XCTAssertTrue(menu.items[5].isSeparatorItem)
        assertAction(
            menu.items[6],
            title: "Quit OpenRec",
            selector: "terminate:",
            target: NSApplication.shared,
            enabled: true
        )

        StatusItemMenu.populate(menu, snapshot: .readyHidden, target: owner)
        assertAction(menu.items[0], title: "Open OpenRec", selector: "showControlWindow", target: owner, enabled: true)
        assertAction(menu.items[1], title: "Start Recording", selector: "toggleRecordingFromStatusMenu", target: owner, enabled: true)
        assertAction(menu.items[4], title: "Settings…", selector: "openSettingsFromMenu", target: owner, enabled: true)
    }

    private func action(
        _ action: StatusItemMenuAction,
        in entries: [StatusItemMenuEntry],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> StatusItemMenuEntry {
        let match = entries.first { entry in
            guard case .action(_, let entryAction, _) = entry else { return false }
            return entryAction == action
        }
        return try XCTUnwrap(match, file: file, line: line)
    }

    private func assertAction(
        _ item: NSMenuItem,
        title: String,
        selector: String,
        target: AnyObject,
        enabled: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(item.title, title, file: file, line: line)
        XCTAssertEqual(item.action, NSSelectorFromString(selector), file: file, line: line)
        XCTAssertTrue(item.target === target, file: file, line: line)
        XCTAssertEqual(item.isEnabled, enabled, file: file, line: line)
    }
}

private extension StatusItemMenuSnapshot {
    static let readyHidden = StatusItemMenuSnapshot(
        recorderVisible: false,
        isRecording: false,
        isStarting: false,
        isProcessing: false,
        onboardingComplete: true
    )

    static let recordingVisible = StatusItemMenuSnapshot(
        recorderVisible: true,
        isRecording: true,
        isStarting: false,
        isProcessing: false,
        onboardingComplete: true
    )

    static let processing = StatusItemMenuSnapshot(
        recorderVisible: true,
        isRecording: false,
        isStarting: false,
        isProcessing: true,
        onboardingComplete: true
    )

    static let starting = StatusItemMenuSnapshot(
        recorderVisible: true,
        isRecording: false,
        isStarting: true,
        isProcessing: false,
        onboardingComplete: true
    )

    static let needsOnboarding = StatusItemMenuSnapshot(
        recorderVisible: false,
        isRecording: false,
        isStarting: false,
        isProcessing: false,
        onboardingComplete: false
    )
}
