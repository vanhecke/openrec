import AppKit
import SwiftUI
import XCTest
@testable import OpenRecApp

@MainActor
final class WindowChromeTests: XCTestCase {
    func testCloseSlotSitsInsideTheHeaderAndNotAboveTheWindow() {
        let windowSize = CGSize(width: 240, height: 320)
        let frame = CloseButtonPlacement.frame(windowHeight: windowSize.height)
        let hit = frame.insetBy(dx: -CloseButtonPlacement.hitOutset, dy: -CloseButtonPlacement.hitOutset)

        XCTAssertGreaterThan(hit.minX, 0)
        XCTAssertLessThanOrEqual(hit.maxX, CloseButtonPlacement.headerLeadingClearance)
        XCTAssertTrue(CloseButtonPlacement.isInsideWindow(frame, windowSize: windowSize))
        XCTAssertTrue(CloseButtonPlacement.isInsideWindow(hit, windowSize: windowSize))

        // The reported bug: the red disc draws just above the rounded corner.
        let detached = frame.offsetBy(dx: 0, dy: frame.height + CloseButtonPlacement.topInset)
        XCTAssertFalse(CloseButtonPlacement.isInsideWindow(detached, windowSize: windowSize))
        XCTAssertFalse(CloseButtonPlacement.isInsideWindow(.zero, windowSize: windowSize))
    }

    func testOrdinaryWindowsUseNormalStacking() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        // The old recorder and onboarding behavior. canJoinAllSpaces together
        // with moveToActiveSpace is rejected by AppKit before the policy runs.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = true
        window.ignoresMouseEvents = true

        WindowChrome.apply(.ordinary, to: window)

        XCTAssertEqual(window.level, .normal)
        XCTAssertLessThan(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.managed))
        XCTAssertTrue(window.collectionBehavior.contains(.participatesInCycle))
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(window.collectionBehavior.contains(.stationary))
        XCTAssertFalse(window.collectionBehavior.contains(.transient))
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertFalse(window.ignoresMouseEvents)
    }

    func testOnboardingUsesOrdinaryLevelAndSpacesOnly() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        WindowChrome.applyOnboardingStacking(to: window)

        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.level, WindowStackingPolicy.ordinary.level)
        XCTAssertLessThan(window.level, .floating)
        XCTAssertEqual(window.collectionBehavior, WindowStackingPolicy.ordinary.collectionBehavior)
        XCTAssertTrue(window.collectionBehavior.contains(.managed))
        XCTAssertTrue(window.collectionBehavior.contains(.participatesInCycle))
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(window.collectionBehavior.contains(.stationary))
        XCTAssertFalse(window.collectionBehavior.contains(.transient))
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertFalse(window.isReleasedWhenClosed)

        let recorder = makeRecorder()
        XCTAssertEqual(window.level, recorder.level)
        XCTAssertEqual(window.collectionBehavior, recorder.collectionBehavior)
    }

    func testRecordingBorderStaysAboveEverySpace() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .normal
        window.ignoresMouseEvents = false

        WindowChrome.apply(.recordingOverlay, to: window)

        XCTAssertEqual(window.level, .statusBar)
        XCTAssertGreaterThan(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.stationary))
        XCTAssertFalse(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.hidesOnDeactivate)
    }

    func testRecorderWindowIsAnOrdinaryMovablePanel() {
        let window = makeRecorder()

        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.sharingType, .readOnly)
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.contentView is RecorderPanelHostingView<Color>)
    }

    func testNativeCloseButtonIsInsideTheWindowAndPassesClicksThrough() throws {
        let window = makeRecorder()
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        WindowChrome.placeRecorderCloseButton(on: window)

        let button = window.standardWindowButton(.closeButton)
        let miniaturize = window.standardWindowButton(.miniaturizeButton)
        let zoom = window.standardWindowButton(.zoomButton)
        XCTAssertNotNil(button)
        XCTAssertEqual(button?.isHidden, false)
        XCTAssertEqual(button?.isEnabled, true)
        XCTAssertEqual(button?.toolTip, "Hide OpenRec")
        if let target = button?.target as? NSWindow {
            XCTAssertTrue(target === window)
        }
        XCTAssertEqual(miniaturize?.isHidden, true)
        XCTAssertEqual(zoom?.isHidden, true)

        let frame = button?.convert(button?.bounds ?? .zero, to: nil) ?? .zero
        XCTAssertTrue(
            CloseButtonPlacement.isInsideWindow(frame, windowSize: window.frame.size),
            "close button \(frame) is outside window \(window.frame.size)"
        )

        let host = try XCTUnwrap(window.contentView)
        let theme = try XCTUnwrap(host.superview)
        let buttonInTheme = theme.convert(CGPoint(x: frame.midX, y: frame.midY), from: nil)
        XCTAssertNil(host.hitTest(buttonInTheme))

        let bodyInTheme = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: theme)
        XCTAssertNotEqual(buttonInTheme.x, bodyInTheme.x, accuracy: 1)
        XCTAssertNotNil(host.hitTest(bodyInTheme))

        let contentIndex = try XCTUnwrap(theme.subviews.firstIndex(of: host))
        let titlebarIndex = try XCTUnwrap(titlebarChildIndex(of: button, in: theme))
        XCTAssertGreaterThan(titlebarIndex, contentIndex)
    }

    func testClosingTheRecorderHidesItAndLeavesItReopenable() {
        let recorder = makeRecorder()
        let meetings = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        recorder.orderFrontRegardless()
        XCTAssertTrue(recorder.isVisible)

        XCTAssertTrue(WindowChrome.recorderShouldClose(meetings, recorder: recorder))
        XCTAssertTrue(recorder.isVisible)

        XCTAssertFalse(WindowChrome.recorderShouldClose(recorder, recorder: recorder))
        XCTAssertFalse(recorder.isVisible)
        XCTAssertFalse(recorder.isReleasedWhenClosed)

        recorder.makeKeyAndOrderFront(nil)
        XCTAssertTrue(recorder.isVisible)
    }

    func testNativeCloseButtonHidesTheRecorderInsteadOfClosingIt() {
        let recorder = makeRecorder()
        let delegate = RecorderCloseDelegate()
        recorder.delegate = delegate
        recorder.orderFrontRegardless()
        recorder.layoutIfNeeded()
        WindowChrome.placeRecorderCloseButton(on: recorder)

        recorder.standardWindowButton(.closeButton)?.performClick(nil)

        XCTAssertEqual(delegate.shouldCloseResult, false)
        XCTAssertFalse(recorder.isVisible)
        XCTAssertFalse(recorder.isReleasedWhenClosed)
        recorder.makeKeyAndOrderFront(nil)
        XCTAssertTrue(recorder.isVisible)
    }

    private func titlebarChildIndex(of button: NSButton?, in theme: NSView) -> Int? {
        var ancestor: NSView? = button
        while let current = ancestor, current !== theme {
            if current.superview === theme {
                return theme.subviews.firstIndex(of: current)
            }
            ancestor = current.superview
        }
        return nil
    }

    private func makeRecorder() -> NSWindow {
        WindowChrome.makeRecorderWindow(
            size: NSSize(width: 240, height: 320),
            rootView: Color.black
        )
    }
}

@MainActor
private final class RecorderCloseDelegate: NSObject, NSWindowDelegate {
    var shouldCloseResult: Bool?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let result = WindowChrome.recorderShouldClose(sender, recorder: sender)
        shouldCloseResult = result
        return result
    }
}
