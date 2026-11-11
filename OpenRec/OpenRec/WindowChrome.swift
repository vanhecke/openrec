import AppKit
import SwiftUI

/// How an OpenRec window participates in macOS ordering and Spaces.
enum WindowStacking: Equatable {
    /// Document-style window: normal z-order, only the Space it was opened on.
    case ordinary
    /// The mouse-transparent border drawn around the display being recorded.
    case recordingOverlay
}

struct WindowStackingPolicy: Equatable {
    var level: NSWindow.Level
    var collectionBehavior: NSWindow.CollectionBehavior
    var hidesOnDeactivate: Bool
    var ignoresMouseEvents: Bool

    /// Normal windows. Not floating, not on every Space, not over fullscreen apps.
    static let ordinary = WindowStackingPolicy(
        level: .normal,
        collectionBehavior: [.managed, .participatesInCycle],
        hidesOnDeactivate: false,
        ignoresMouseEvents: false
    )

    /// Recording chrome has to stay visible on the captured display, including
    /// fullscreen Spaces, and must not steal clicks from the app underneath.
    static let recordingOverlay = WindowStackingPolicy(
        level: .statusBar,
        collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary],
        hidesOnDeactivate: false,
        ignoresMouseEvents: true
    )

    static func policy(for stacking: WindowStacking) -> WindowStackingPolicy {
        switch stacking {
        case .ordinary:
            return .ordinary
        case .recordingOverlay:
            return .recordingOverlay
        }
    }
}

/// Native close-button slot in the recorder's transparent titlebar.
///
/// The system control is a 14×14 traffic light. The header reserves
/// `headerLeadingClearance` so the title starts to the right of that slot.
enum CloseButtonPlacement {
    static let leadingInset: CGFloat = 12
    static let topInset: CGFloat = 8
    static let buttonSize = CGSize(width: 14, height: 14)
    /// Points added around the drawn disc. Still inside the header's leading padding.
    static let hitOutset: CGFloat = 4
    static let headerLeadingClearance: CGFloat = 36

    static func frame(windowHeight: CGFloat, buttonSize: CGSize = buttonSize) -> CGRect {
        CGRect(
            x: leadingInset,
            y: windowHeight - topInset - buttonSize.height,
            width: buttonSize.width,
            height: buttonSize.height
        )
    }

    /// Window-base coordinates, origin at the bottom-left of the window frame.
    static func isInsideWindow(_ frame: CGRect, windowSize: CGSize) -> Bool {
        guard frame.width >= 8, frame.height >= 8 else { return false }
        return frame.minX >= -0.5
            && frame.minY >= -0.5
            && frame.maxX <= windowSize.width + 0.5
            && frame.maxY <= windowSize.height + 0.5
    }
}

enum WindowChrome {
    private static var isPlacingCloseButton = false

    static func apply(_ stacking: WindowStacking, to window: NSWindow) {
        let policy = WindowStackingPolicy.policy(for: stacking)
        window.level = policy.level
        window.collectionBehavior = policy.collectionBehavior
        window.hidesOnDeactivate = policy.hidesOnDeactivate
        window.ignoresMouseEvents = policy.ignoresMouseEvents
    }

    /// Onboarding is an ordinary window. Only level and Spaces behavior
    /// change here; readiness and resume stay in the onboarding flow.
    static func applyOnboardingStacking(to window: NSWindow) {
        let policy = WindowStackingPolicy.policy(for: .ordinary)
        window.level = policy.level
        window.collectionBehavior = policy.collectionBehavior
    }

    static func makeRecorderWindow<Content: View>(size: NSSize, rootView: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenRec"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        // Keep the recorder visible to normal macOS screenshots. The app's
        // own ScreenCaptureKit stream excludes OpenRec windows explicitly, so
        // this does not burn the controls into call recordings.
        window.sharingType = .readOnly
        apply(.ordinary, to: window)

        let host = RecorderPanelHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        placeRecorderCloseButton(on: window)
        return window
    }

    /// Closing the recorder hides it. The process and any in-progress
    /// recording keep running; Dock and the menu bar order the same window
    /// front again. Every other window uses the normal close path.
    static func recorderShouldClose(_ window: NSWindow, recorder: NSWindow?) -> Bool {
        guard window === recorder else { return true }
        window.orderOut(nil)
        return false
    }

    static func placeRecorderCloseButton(on window: NSWindow, reordersTitlebar: Bool = true) {
        guard !isPlacingCloseButton else { return }
        isPlacingCloseButton = true
        defer { isPlacingCloseButton = false }

        guard let button = window.standardWindowButton(.closeButton) else { return }
        button.isHidden = false
        button.isEnabled = true
        button.toolTip = "Hide OpenRec"
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        if reordersTitlebar {
            orderTitlebarAboveContent(of: window, button: button)
        }

        guard let container = button.superview else { return }
        let windowSize = window.frame.size
        guard windowSize.width > 40, windowSize.height > 40 else { return }
        let current = button.convert(button.bounds, to: nil)
        guard !CloseButtonPlacement.isInsideWindow(current, windowSize: windowSize) else { return }

        let buttonSize = button.bounds.size.width >= 8 ? button.bounds.size : CloseButtonPlacement.buttonSize
        let target = CloseButtonPlacement.frame(windowHeight: windowSize.height, buttonSize: buttonSize)
        let origin = container.convert(target.origin, from: nil)
        guard origin.x.isFinite, origin.y.isFinite else { return }
        button.setFrameOrigin(origin)
    }

    /// The hosting view fills the frame and can end up in front of the
    /// traffic lights. Keep the titlebar container above it so the native
    /// close button, not the SwiftUI root, receives the click.
    private static func orderTitlebarAboveContent(of window: NSWindow, button: NSButton) {
        guard let content = window.contentView, let theme = content.superview else { return }
        var ancestor: NSView? = button
        while let current = ancestor, current !== theme {
            if current.superview === theme {
                let siblings = theme.subviews
                guard let contentIndex = siblings.firstIndex(of: content),
                      let titlebarIndex = siblings.firstIndex(of: current),
                      contentIndex > titlebarIndex else { return }
                theme.addSubview(current, positioned: .above, relativeTo: content)
                return
            }
            ancestor = current.superview
        }
    }
}

/// Hosts the recorder panel and keeps the native close button clickable.
///
/// `NSHostingView` treats the transparent titlebar as a safe-area inset, so
/// the rounded card lays out below the close button. The button then draws
/// in the clear strip above the corner and the hosting view swallows the
/// click. Clearing that inset lets the card fill the window under the
/// traffic light. Hits in the button's slot pass through to the real
/// `NSButton`, whose action is still the window's `performClose:`.
final class RecorderPanelHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
        clearTitlebarSafeArea()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearTitlebarSafeArea()
        if let window {
            WindowChrome.placeRecorderCloseButton(on: window)
        }
    }

    override func layout() {
        super.layout()
        guard let window else { return }
        // Reordering the titlebar from inside layout faults AppKit. Placement
        // only moves the button; viewDidMoveToWindow orders the titlebar.
        WindowChrome.placeRecorderCloseButton(on: window, reordersTitlebar: false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates.
        let local = convert(point, from: superview)
        if let window, let button = window.standardWindowButton(.closeButton), !button.isHidden {
            let slot = button.convert(button.bounds, to: self)
                .insetBy(dx: -CloseButtonPlacement.hitOutset, dy: -CloseButtonPlacement.hitOutset)
            if slot.width > 1, slot.contains(local) {
                return nil
            }
        }
        return super.hitTest(point)
    }

    private func clearTitlebarSafeArea() {
        if #available(macOS 13.3, *) {
            safeAreaRegions = []
        }
    }
}
