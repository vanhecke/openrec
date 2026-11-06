import AppKit
import SwiftUI
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recorderManager: RecorderManager!
    private var controlWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var recordingsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let recordingsNavigation = RecordingLibraryNavigation()
    private let callDetector = CallDetectionManager()
    private let callDetectionWindow = CallDetectionWindow()
    private let windowState = WindowState()
    private let mainWidth: CGFloat = 240
    private let transcriptWidth: CGFloat = 281
    // Keep the idle panel compact: sized so the error state still fits while
    // leaving only a small gap between the record action and call controls.
    // (360 dates from when the panel also held the Live/After mode picker.)
    private let expandedHeight: CGFloat = 320
    private let recordingHeight: CGFloat = 84
    private let recordingExpandedHeight: CGFloat = 320
    private let collapsedHeight: CGFloat = 86
    private var pendingTerminate = false
    private var cancellables = Set<AnyCancellable>()
    private var resizeWorkItem: DispatchWorkItem?
    private var callDetectorStarted = false
#if canImport(Sparkle)
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        recorderManager = RecorderManager()
#if canImport(Sparkle)
        recorderManager.onInstallReadyUpdate = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
#endif

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        updateStatusIcon(isRecording: false)
        installStatusMenu()

        // Observe recording state changes to update icon and resize
        recorderManager.onRecordingStateChange = { [weak self] isRecording in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateStatusIcon(isRecording: isRecording)
                if isRecording {
                    self.callDetectionWindow.hide()
                    self.settingsWindow?.orderOut(nil)
                }
                // Don't auto-show transcript panel — user controls it via expand button
                self.recalculateWindowSize(animated: true)
            }
        }
        recorderManager.onProcessingComplete = { [weak self] in
            guard let self else { return }
            if case .failed = self.recorderManager.savePhase {
                self.windowState.isCollapsed = false
                self.showRecorderWindow()
            }
            self.finishPendingTerminationIfNeeded()
        }

        // Keep post-call progress and results visible.
        recorderManager.transcriptionManager.$isTranscribing
            .removeDuplicates()
            .sink { [weak self] isTranscribing in
                guard let self else { return }
                if isTranscribing && !self.recorderManager.isRecording {
                    self.recorderManager.transcriptionManager.showPanel = true
                }
                DispatchQueue.main.async {
                    self.recalculateWindowSize(animated: true)
                }
            }
            .store(in: &cancellables)

        // Observe showPanel changes — user-initiated, skip debounce
        recorderManager.transcriptionManager.$showPanel
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.performResize(animated: true)
            }
            .store(in: &cancellables)

        recorderManager.$callDetectionEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self, OpenRecOnboarding.isComplete else { return }
                if enabled { self.startCallDetectionIfNeeded() }
                else { self.stopCallDetection() }
            }
            .store(in: &cancellables)

        recorderManager.$isStarting
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsWindow?.orderOut(nil) }
            .store(in: &cancellables)

        // The idle panel grows to fit the Update button when one is ready.
        recorderManager.$readyUpdate
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recalculateWindowSize(animated: true) }
            .store(in: &cancellables)

        windowState.onCollapseChange = { [weak self] _ in
            // Collapse is user-initiated — skip debounce for instant response
            self?.performResize(animated: true)
        }

        setupEditMenu()
        setupControlWindow()

        callDetector.isRecording = { [weak self] in self?.recorderManager.isRecording == true }
        callDetector.onCallDetected = { [weak self] call in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let calendar = try? await self.recorderManager.cloudStorage.currentCalendarCall()
                let calendarParticipants = calendar?.participants ?? []
                let enriched = DetectedCall(
                    appName: call.appName,
                    title: call.title ?? calendar?.title,
                    participants: calendarParticipants.isEmpty ? call.participants : calendarParticipants
                )
                self.callDetectionWindow.show(call: enriched, onStart: { [weak self] in
                    guard let self else { return }
                    self.recorderManager.detectedCall = enriched
                    self.showControlWindow()
                    Task { await self.recorderManager.startRecording() }
                }, onDismiss: { [weak self] in
                    self?.callDetector.snooze()
                })
            }
        }
        if OpenRecOnboarding.isComplete {
            startCallDetectionIfNeeded()
        }

        checkForUpdatesOnLaunch()

        // First launch is a focused setup flow. The compact recorder only
        // appears after every required service and permission is ready.
        DispatchQueue.main.async {
            if OpenRecOnboarding.isComplete {
                self.showControlWindow()
            } else {
                self.showOnboarding(isSettings: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        callDetector.stop()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showControlWindow()
        return false
    }

    /// The recorder hides into the menu bar, so closing the last window must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorderManager.isStarting {
            pendingTerminate = true
            recorderManager.cancelStartingRecordingForTermination()
            return .terminateLater
        }

        if recorderManager.isRecording {
            pendingTerminate = true
            recorderManager.stopRecording()
            return .terminateLater
        }

        if recorderManager.isProcessing {
            pendingTerminate = true
            return .terminateLater
        }

        return .terminateNow
    }

    private func installStatusMenu() {
        let menu = StatusItemMenu.makeMenu(snapshot: currentStatusSnapshot(), target: self)
        menu.delegate = self
        statusItem.menu = menu
    }

    private func currentStatusSnapshot() -> StatusItemMenuSnapshot {
        StatusItemMenuSnapshot(
            recorderVisible: controlWindow?.isVisible == true && controlWindow?.isMiniaturized != true,
            isRecording: recorderManager.isRecording,
            isStarting: recorderManager.isStarting,
            isProcessing: recorderManager.isProcessing,
            onboardingComplete: OpenRecOnboarding.isComplete
        )
    }

    private func updateStatusIcon(isRecording: Bool) {
        guard let button = statusItem.button else { return }

        let description = isRecording ? "OpenRec is recording" : "OpenRec"
        button.image = OpenRecBrandIcon.statusItemImage(
            accessibilityDescription: description
        )
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = isRecording ? .systemRed : nil
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc fileprivate func showControlWindow() {
        guard OpenRecOnboarding.isComplete else {
            showOnboarding(isSettings: false)
            return
        }
        showRecorderWindow()
    }

    private func showRecorderWindow() {
        guard let window = controlWindow else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        configureTrafficLights(for: window)
        recorderManager.refreshMeetingNameSuggestion()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc fileprivate func hideControlWindow() {
        controlWindow?.orderOut(nil)
    }

    @objc fileprivate func toggleRecordingFromStatusMenu() {
        guard OpenRecOnboarding.isComplete else {
            showOnboarding(isSettings: false)
            return
        }
        showRecorderWindow()
        if recorderManager.isRecording {
            recorderManager.stopRecording()
            return
        }
        guard !recorderManager.isProcessing, !recorderManager.isStarting else { return }
        Task { await recorderManager.startRecording() }
    }

    /// Cmd-W. Hiding the recorder orders it out; every other window closes normally.
    @objc private func closeFrontWindow(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        if window === controlWindow {
            window.orderOut(nil)
            return
        }
        window.performClose(sender)
    }

    private func setupControlWindow() {
        let size = NSSize(width: mainWidth, height: expandedHeight)
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenRec"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // Keep the recorder visible to normal macOS screenshots. The app's
        // own ScreenCaptureKit stream excludes OpenRec windows explicitly, so
        // this does not burn the controls into call recordings.
        window.sharingType = .readOnly

        window.contentView = NSHostingView(
            rootView: FloatingPanelView(
                recorderManager: recorderManager,
                windowState: windowState,
                onOpenSettings: { [weak self] in
                    self?.showSettingsWindow()
                },
                onOpenLibrary: { [weak self] focusLastSaved in
                    self?.presentRecordingsLibrary(focusLastSaved: focusLastSaved)
                }
            )
        )

        controlWindow = window
        window.delegate = self
        configureTrafficLights(for: window)
        window.center()
    }

    private func showOnboarding(isSettings: Bool) {
        if let window = onboardingWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if !isSettings {
            controlWindow?.orderOut(nil)
        }

        let size = NSSize(width: 520, height: 600)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = isSettings ? "OpenRec Settings" : "Welcome to OpenRec"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // The setup window can be shared for support; secrets remain secure
        // fields and Settings cannot be opened during a recording. The
        // recorder window itself stays excluded from captured calls.
        window.sharingType = .readOnly
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.closeButton)?.isHidden = false

        let hostingView = NSHostingView(
            rootView: OpenRecOnboardingView(
                recorderManager: recorderManager,
                isSettings: isSettings,
                onFinish: { [weak self, weak window] in
                    guard let self else { return }
                    OpenRecOnboarding.markComplete()
                    window?.orderOut(nil)
                    self.onboardingWindow = nil
                    self.startCallDetectionIfNeeded()
                    self.showRecorderWindow()
                }
            )
        )
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size

        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startCallDetectionIfNeeded() {
        guard recorderManager.callDetectionEnabled, !callDetectorStarted else { return }
        callDetectorStarted = true
        callDetector.start()
    }

    private func stopCallDetection() {
        callDetector.stop()
        callDetectionWindow.hide()
        callDetectorStarted = false
    }

    @objc fileprivate func showRecordingsLibrary() {
        presentRecordingsLibrary(focusLastSaved: false)
    }

    private func presentRecordingsLibrary(focusLastSaved: Bool) {
        if focusLastSaved, let meetingID = recorderManager.lastSavedMeetingID {
            // A selection request carries a fresh token, so clicking “View meeting”
            // selects the saved call even when the library window already exists
            // and the user previously browsed to a different meeting. Plain opens
            // skip this so the window can lead with Coming up.
            recordingsNavigation.select(meetingID)
        }
        if let window = recordingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { await recorderManager.cloudStorage.refreshLibrary() }
            return
        }

        let size = NSSize(width: 980, height: 680)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenRec Meetings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        window.minSize = NSSize(width: 860, height: 580)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Meeting details should remain available in screenshots for sharing
        // and support. Secure credentials only live in SecureFields elsewhere.
        window.sharingType = .readOnly
        window.contentView = NSHostingView(
            rootView: RecordingLibraryView(
                recorderManager: recorderManager,
                navigation: recordingsNavigation,
                onOpenSettings: { [weak self] in self?.showSettingsWindow() }
            )
        )
        window.center()
        recordingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettingsWindow() {
        guard !recorderManager.isRecording, !recorderManager.isProcessing else { return }
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let size = NSSize(width: 760, height: 560)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenRec Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        window.minSize = NSSize(width: 720, height: 520)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.sharingType = .readOnly
        window.contentView = NSHostingView(rootView: OpenRecSettingsView(recorderManager: recorderManager))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Single method that computes window size from all relevant state.
    /// Debounced so rapid-fire observer callbacks coalesce into one smooth resize.
    private func recalculateWindowSize(animated: Bool) {
        resizeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performResize(animated: animated)
        }
        resizeWorkItem = item
        if animated {
            // Tiny delay to coalesce multiple state changes into one animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: item)
        } else {
            DispatchQueue.main.async(execute: item)
        }
    }

    private func performResize(animated: Bool) {
        guard let window = controlWindow else { return }
        let collapsed = windowState.isCollapsed

        let (targetWidth, targetHeight) = MainActor.assumeIsolated { () -> (CGFloat, CGFloat) in
            let isRecording = recorderManager.isRecording

            let showingRightPanel = !collapsed && recorderManager.transcriptionManager.showPanel

            let baseHeight: CGFloat
            if isRecording {
                baseHeight = showingRightPanel ? recordingExpandedHeight : recordingHeight
            } else {
                // Room for the blue Update button when a new version is ready.
                baseHeight = expandedHeight + (recorderManager.readyUpdate != nil ? 34 : 0)
            }
            let w = mainWidth + (showingRightPanel ? transcriptWidth : 0)
            let h = collapsed ? collapsedHeight : baseHeight
            return (w, h)
        }

        let frame = window.frame
        let newFrame = NSRect(
            x: frame.origin.x,
            y: frame.origin.y + frame.height - targetHeight,
            width: targetWidth,
            height: targetHeight
        )

        // Skip if already at target size
        guard !frame.equalTo(newFrame) else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
                window.animator().setFrame(newFrame, display: true)
            }
        } else {
            window.setFrame(newFrame, display: true)
        }
    }

    private func finishPendingTerminationIfNeeded() {
        guard pendingTerminate else { return }
        pendingTerminate = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func setupEditMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About OpenRec", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        let meetings = appMenu.addItem(withTitle: "Meetings…", action: #selector(showRecordingsLibrary), keyEquivalent: "m")
        meetings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OpenRec", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let closeWindow = windowMenu.addItem(
            withTitle: "Close",
            action: #selector(closeFrontWindow),
            keyEquivalent: "w"
        )
        closeWindow.target = self
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc fileprivate func openSettingsFromMenu() {
        showSettingsWindow()
    }

    /// Close stays visible so hiding the recorder into the menu bar is a normal
    /// window action. Miniaturize and zoom stay hidden on this compact panel.
    private func configureTrafficLights(for window: NSWindow) {
        let closeButton = window.standardWindowButton(.closeButton)
        closeButton?.isHidden = false
        closeButton?.toolTip = "Hide OpenRec"
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func checkForUpdatesOnLaunch() {
        guard let currentVersion = Bundle.main.shortVersionString else { return }

        UpdateManager.checkForUpdate(currentVersion: currentVersion) { [weak self] info in
            guard let self else { return }
            guard let info else { return }

            UpdateManager.downloadUpdate(from: info) { [weak self] localURL in
                guard let self else { return }
                guard let localURL else { return }

                DispatchQueue.main.async {
                    // Quietly downloaded; the recorder panel shows a blue
                    // Update button instead of a modal alert.
                    let versionLabel = info.tag.hasPrefix("v") ? String(info.tag.dropFirst()) : info.tag
                    self.recorderManager.readyUpdate = RecorderManager.ReadyUpdate(
                        version: versionLabel,
                        localURL: localURL
                    )
                }
            }
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let statusMenu = statusItem.menu, menu === statusMenu else { return }
        StatusItemMenu.populate(menu, snapshot: currentStatusSnapshot(), target: self)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === controlWindow else { return true }
        sender.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === controlWindow else { return }
        configureTrafficLights(for: window)
    }
}

struct StatusItemMenuSnapshot: Equatable {
    var recorderVisible: Bool
    var isRecording: Bool
    var isStarting: Bool
    var isProcessing: Bool
    var onboardingComplete: Bool
}

enum StatusItemMenuAction: Equatable {
    case showRecorder
    case hideRecorder
    case toggleRecording
    case meetings
    case settings
    case quit
}

enum StatusItemMenuEntry: Equatable {
    case action(title: String, action: StatusItemMenuAction, isEnabled: Bool)
    case separator
}

@MainActor
enum StatusItemMenu {
    static func entries(for snapshot: StatusItemMenuSnapshot) -> [StatusItemMenuEntry] {
        var entries: [StatusItemMenuEntry] = []
        if snapshot.recorderVisible {
            entries.append(.action(title: "Hide OpenRec", action: .hideRecorder, isEnabled: true))
        } else {
            entries.append(.action(title: "Open OpenRec", action: .showRecorder, isEnabled: true))
        }

        if snapshot.isRecording {
            entries.append(.action(title: "Stop Recording", action: .toggleRecording, isEnabled: true))
        } else {
            let canStart = snapshot.onboardingComplete && !snapshot.isStarting && !snapshot.isProcessing
            entries.append(.action(title: "Start Recording", action: .toggleRecording, isEnabled: canStart))
        }

        entries.append(.separator)
        entries.append(.action(title: "Meetings…", action: .meetings, isEnabled: true))
        let settingsEnabled = !snapshot.isRecording && !snapshot.isProcessing
        entries.append(.action(title: "Settings…", action: .settings, isEnabled: settingsEnabled))
        entries.append(.separator)
        entries.append(.action(title: "Quit OpenRec", action: .quit, isEnabled: true))
        return entries
    }

    static func makeMenu(snapshot: StatusItemMenuSnapshot, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        populate(menu, snapshot: snapshot, target: target)
        return menu
    }

    static func populate(_ menu: NSMenu, snapshot: StatusItemMenuSnapshot, target: AnyObject) {
        menu.removeAllItems()
        for entry in entries(for: snapshot) {
            menu.addItem(makeItem(for: entry, target: target))
        }
    }

    private static func makeItem(for entry: StatusItemMenuEntry, target: AnyObject) -> NSMenuItem {
        switch entry {
        case .separator:
            return .separator()
        case .action(let title, let action, let isEnabled):
            let item = NSMenuItem(title: title, action: selector(for: action), keyEquivalent: "")
            item.target = itemTarget(for: action, owner: target)
            item.isEnabled = isEnabled
            return item
        }
    }

    private static func selector(for action: StatusItemMenuAction) -> Selector {
        switch action {
        case .showRecorder:
            return #selector(AppDelegate.showControlWindow)
        case .hideRecorder:
            return #selector(AppDelegate.hideControlWindow)
        case .toggleRecording:
            return #selector(AppDelegate.toggleRecordingFromStatusMenu)
        case .meetings:
            return #selector(AppDelegate.showRecordingsLibrary)
        case .settings:
            return #selector(AppDelegate.openSettingsFromMenu)
        case .quit:
            return #selector(NSApplication.terminate(_:))
        }
    }

    private static func itemTarget(for action: StatusItemMenuAction, owner: AnyObject) -> AnyObject {
        switch action {
        case .quit:
            return NSApp
        case .showRecorder, .hideRecorder, .toggleRecording, .meetings, .settings:
            return owner
        }
    }
}
