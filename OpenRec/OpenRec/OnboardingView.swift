import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

enum OpenRecOnboarding {
    static let completionKey = "OpenRecOnboardingCompletedV1"
    static let stepKey = "OpenRecOnboardingStepV1"
    /// Set only while unfinished setup is on the screen-permission step.
    static let screenPermissionRelaunchKey = "OpenRecOnboardingScreenPermissionRelaunchV1"
    static let assemblyKeychainAccount = "assemblyai-api-key"
    static let managedSessionKeychainAccount = "managed-session-token"
    static let r2AccessKeyIDAccount = "r2-access-key-id"
    static let r2SecretAccessKeyAccount = "r2-secret-access-key"

    static var isComplete: Bool {
        switch OnboardingLaunch.decide(currentLaunchInput()) {
        case .skip:
            return true
        case .wizard(_):
            return false
        }
    }

    /// Step to show when the wizard is on screen. A ready launch never gets here.
    static func presentationStep() -> OnboardingStep {
        switch OnboardingLaunch.decide(currentLaunchInput()) {
        case .skip:
            return .welcome
        case .wizard(let step):
            return step
        }
    }

    static func currentLaunchInput(defaults: UserDefaults = .standard) -> OnboardingLaunchInput {
        let readiness = currentReadiness(defaults: defaults)
        return OnboardingLaunchInput(
            markedComplete: readiness.markedComplete,
            persistedStep: persistedWizardStep(defaults: defaults),
            pendingScreenPermissionRelaunch: defaults.bool(forKey: screenPermissionRelaunchKey),
            microphone: microphonePermission(),
            screen: screenPermission(),
            transcription: readiness.transcription,
            meetingMemory: readiness.meetingMemory,
            storage: storageConfiguration(defaults: defaults)
        )
    }

    static func currentReadiness(defaults: UserDefaults = .standard) -> OnboardingReadiness {
        OnboardingReadiness(
            markedComplete: defaults.bool(forKey: completionKey),
            transcription: TranscriptionCredentials(
                provider: TranscriptionProvider.resolved(
                    from: defaults.string(forKey: TranscriptionProvider.defaultsKey)
                ),
                assemblyKey: KeychainStore.string(for: assemblyKeychainAccount),
                assemblyVerified: defaults.bool(forKey: "AssemblyAIKeyVerified"),
                grokKey: KeychainStore.string(for: MeetingMemoryProvider.grokKeychainAccount),
                grokVerified: defaults.bool(forKey: MeetingMemoryProvider.grokVerifiedDefaultsKey)
            ),
            meetingMemory: MeetingMemoryCredentials(
                provider: MeetingMemoryProvider.resolved(
                    from: defaults.string(forKey: MeetingMemoryProvider.defaultsKey)
                ),
                openAIKey: KeychainStore.string(for: MeetingMemoryProvider.openAIKeychainAccount),
                openAIVerified: defaults.bool(forKey: MeetingMemoryProvider.openAIVerifiedDefaultsKey),
                grokKey: KeychainStore.string(for: MeetingMemoryProvider.grokKeychainAccount),
                grokVerified: defaults.bool(forKey: MeetingMemoryProvider.grokVerifiedDefaultsKey)
            )
        )
    }

    /// Readiness of the mode `CloudStorageManager` already uses. Does not write a selection.
    static func storageConfiguration(defaults: UserDefaults = .standard) -> OnboardingStorageConfiguration {
        let mode = StorageMode.resolved(from: defaults.string(forKey: StorageMode.defaultsKey))
        let ready = mode.isReadyForRecording(
            managedSignedIn: !KeychainStore.string(for: managedSessionKeychainAccount).isEmpty,
            r2AccountID: defaults.string(forKey: "R2AccountID") ?? "",
            r2Bucket: defaults.string(forKey: "R2Bucket") ?? "",
            r2AccessKeyID: KeychainStore.string(for: r2AccessKeyIDAccount),
            r2SecretAccessKey: KeychainStore.string(for: r2SecretAccessKeyAccount)
        )
        return OnboardingStorageConfiguration(
            mode: mode,
            isReady: ready,
            r2ConnectionVerified: defaults.bool(forKey: "R2ConnectionVerified")
        )
    }

    static func microphonePermission() -> OnboardingPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .allowed
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// Screen Recording preflight does not prompt, and it does not separate
    /// "not yet asked" from "denied". Either result is not an allow.
    static func screenPermission() -> OnboardingPermissionState {
        CGPreflightScreenCaptureAccess() ? .allowed : .denied
    }

    static func persistedWizardStep(defaults: UserDefaults = .standard) -> OnboardingStep? {
        OnboardingStep.matchingPersistenceID(defaults.string(forKey: stepKey))
    }

    static func persistWizardStep(_ step: OnboardingStep, defaults: UserDefaults = .standard) {
        defaults.set(step.persistenceID, forKey: stepKey)
        switch step {
        case .permissions:
            // Quit & Reopen can kill the process from this step.
            defaults.set(true, forKey: screenPermissionRelaunchKey)
        case .ready:
            // Keep the relaunch pending until Finish. Clearing it here would
            // make the next readiness check skip the Ready page.
            break
        case .welcome, .assemblyAI, .meetingMemory, .storage, .calendar, .defaults, .webhook:
            defaults.set(false, forKey: screenPermissionRelaunchKey)
        }
    }

    static func markComplete(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completionKey)
        defaults.removeObject(forKey: stepKey)
        defaults.set(false, forKey: screenPermissionRelaunchKey)
    }
}

private enum OnboardingNavigationDirection {
    case forward
    case backward
}

private enum OnboardingConnectionCheck: Equatable {
    case idle
    case running
    case success(String)
    case failure(String)
}

private let onboardingPlaceholderColor = Color.white.opacity(0.38)
private let onboardingEaseOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
private let onboardingQuickEaseOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)

struct OpenRecOnboardingView: View {
    @ObservedObject var recorderManager: RecorderManager
    let isSettings: Bool
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: OnboardingStep
    @State private var navigationDirection: OnboardingNavigationDirection = .forward
    @State private var microphoneGranted = false
    @State private var screenGranted = false
    @State private var assemblyAICheck: OnboardingConnectionCheck = .idle
    @State private var openAICheck: OnboardingConnectionCheck = .idle
    @State private var grokCheck: OnboardingConnectionCheck = .idle
    @State private var r2Check: OnboardingConnectionCheck = .idle
    @StateObject private var assemblyAIKeyVerifier = APIKeyAutoVerifier()
    @StateObject private var openAIKeyVerifier = APIKeyAutoVerifier()
    @StateObject private var grokKeyVerifier = APIKeyAutoVerifier()
    @State private var localCalendarGranted = CalendarMeetingSuggester.accessGranted
    @State private var isRequestingLocalCalendar = false
    @State private var googleCalendarConnectDeclined = GoogleCalendarConnectPrompt.isDeclined()

    init(
        recorderManager: RecorderManager,
        isSettings: Bool,
        onFinish: @escaping () -> Void
    ) {
        self.recorderManager = recorderManager
        self.isSettings = isSettings
        self.onFinish = onFinish
        _step = State(initialValue: isSettings ? .assemblyAI : OpenRecOnboarding.presentationStep())
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            Color.black.opacity(0.54)

            VStack(spacing: 0) {
                topBar

                if step.configurationIndex != nil {
                    progressDots
                        .padding(.top, 6)
                        .transition(.opacity)
                }

                ZStack {
                    page
                        .id(step)
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if step != .welcome && step != .ready {
                    footer
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 26)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        // The window uses .fullSizeContentView with a hidden titlebar; without
        // this the titlebar becomes a top safe-area inset and the card drops
        // below the traffic lights.
        .ignoresSafeArea()
        .onAppear(perform: prepareOnboarding)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Text(isSettings ? "OpenRec Settings" : "OpenRec")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            Spacer()
            if let index = step.configurationIndex {
                Text("\(index + 1) of \(OnboardingStep.configurationSteps.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.42))
            }
        }
        .frame(height: 42)
        .padding(.leading, 52)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.configurationSteps.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= (step.configurationIndex ?? -1) ? Color.white.opacity(0.8) : Color.white.opacity(0.14))
                    .frame(width: 18, height: 4)
                    .scaleEffect(x: index == step.configurationIndex ? 1 : 0.34, y: 1)
                    .frame(width: 18)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : onboardingEaseOut, value: step)
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome:
            welcomePage
        case .assemblyAI:
            transcriptionPage
        case .meetingMemory:
            meetingMemoryPage
        case .storage:
            storagePage
        case .calendar:
            calendarPage
        case .defaults:
            defaultsPage
        case .webhook:
            webhookPage
        case .permissions:
            permissionsPage
        case .ready:
            readyPage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer()

            OpenRecWaveformBadge(diameter: 82)
            .padding(.bottom, 22)

            Text("OpenRec saves and transcribes your calls without extra subscriptions")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.94))
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Text("Setup takes about two minutes.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.56))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 350)
                .padding(.top, 10)

            OnboardingPrimaryButton(title: "Set up OpenRec") {
                move(to: .assemblyAI)
            }
            .frame(width: 168)
            .padding(.top, 26)

            Spacer()
        }
    }

    private var transcriptionPage: some View {
        let provider = recorderManager.transcriptionManager.transcriptionProvider
        return OnboardingPageLayout(
            icon: "waveform",
            title: "Connect transcription",
            body: "Pick AssemblyAI or Grok to create the transcript with speaker diarization. Your key stays in your Mac’s Keychain."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                StorageChoiceRow(
                    icon: "waveform",
                    title: "AssemblyAI",
                    detail: "\(TranscriptionProvider.assemblyAI.modelLabel) · speaker diarization",
                    selected: provider == .assemblyAI
                ) {
                    recorderManager.transcriptionManager.transcriptionProvider = .assemblyAI
                }
                StorageChoiceRow(
                    icon: "waveform",
                    title: "Grok",
                    detail: "\(TranscriptionProvider.grok.modelLabel) · speaker diarization",
                    selected: provider == .grok
                ) {
                    recorderManager.transcriptionManager.transcriptionProvider = .grok
                }

                if provider == .grok {
                    Text("Language")
                        .onboardingLabel()
                        .padding(.top, 4)
                    GrokLanguageOnboardingMenu(
                        language: Binding(
                            get: { recorderManager.transcriptionManager.grokTranscriptionLanguage },
                            set: { recorderManager.transcriptionManager.grokTranscriptionLanguage = $0 }
                        )
                    )
                }

                Text("\(provider.displayName) API key")
                    .onboardingLabel()
                    .padding(.top, 4)

                SecureField(
                    "",
                    text: transcriptionKeyBinding,
                    prompt: Text(transcriptionKeyPlaceholder).foregroundColor(onboardingPlaceholderColor)
                )
                .onboardingField()
                .id(provider)

                HStack(spacing: 10) {
                    OnboardingCheckStatus(
                        state: transcriptionCheck,
                        idleText: "Paste a key to verify automatically"
                    )
                    Spacer()
                    Button("Test key") { testTranscriptionKey() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .disabled(!transcriptionHasKey || transcriptionCheck == .running)
                    Button("Create an API key") {
                        NSWorkspace.shared.open(transcriptionConsoleURL)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                }
            }
        }
    }

    private var transcriptionKeyBinding: Binding<String> {
        switch recorderManager.transcriptionManager.transcriptionProvider {
        case .assemblyAI:
            return Binding(
                get: { recorderManager.transcriptionManager.assemblyAIAPIKey },
                set: { assemblyAIKeyChanged(to: $0) }
            )
        case .grok:
            return Binding(
                get: { recorderManager.transcriptionManager.xaiAPIKey },
                set: { grokKeyChanged(to: $0) }
            )
        }
    }

    private var transcriptionKeyPlaceholder: String {
        switch recorderManager.transcriptionManager.transcriptionProvider {
        case .assemblyAI: return "AssemblyAI API key"
        case .grok: return MeetingMemoryProvider.grok.keyPlaceholder
        }
    }

    private var transcriptionConsoleURL: URL {
        switch recorderManager.transcriptionManager.transcriptionProvider {
        case .assemblyAI: return URL(string: "https://www.assemblyai.com/dashboard/signup")!
        case .grok: return MeetingMemoryProvider.grok.consoleURL
        }
    }

    private var transcriptionCheck: OnboardingConnectionCheck {
        switch recorderManager.transcriptionManager.transcriptionProvider {
        case .assemblyAI: return assemblyAICheck
        case .grok: return grokCheck
        }
    }

    private var transcriptionHasKey: Bool {
        switch recorderManager.transcriptionManager.transcriptionProvider {
        case .assemblyAI: return recorderManager.transcriptionManager.hasAssemblyAIAPIKey
        case .grok: return recorderManager.transcriptionManager.hasXAIAPIKey
        }
    }

    private func testTranscriptionKey() {
        switch recorderManager.transcriptionManager.transcriptionProvider {
        case .assemblyAI:
            testAssemblyAIKey()
        case .grok:
            verifyGrokKey(
                recorderManager.transcriptionManager.xaiAPIKey,
                trigger: .immediate
            )
        }
    }

    private var meetingMemoryPage: some View {
        let provider = recorderManager.transcriptionManager.meetingMemoryProvider
        return OnboardingPageLayout(
            icon: "key.fill",
            title: "Connect meeting memory",
            body: "Pick OpenAI or Grok to turn the diarized transcript into summaries, decisions, and next steps."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                StorageChoiceRow(
                    icon: "sparkles",
                    title: "OpenAI",
                    detail: "\(MeetingMemoryProvider.openai.modelID) · summaries, decisions, next steps",
                    selected: provider == .openai
                ) {
                    recorderManager.transcriptionManager.meetingMemoryProvider = .openai
                }
                StorageChoiceRow(
                    icon: "sparkles",
                    title: "Grok",
                    detail: "\(MeetingMemoryProvider.grok.modelID) · summaries, decisions, next steps",
                    selected: provider == .grok
                ) {
                    recorderManager.transcriptionManager.meetingMemoryProvider = .grok
                }

                if reusesTranscriptionGrokKey {
                    Text("Uses the Grok API key you verified for transcription.")
                        .onboardingLabel()
                        .padding(.top, 4)
                    OnboardingCheckStatus(
                        state: grokCheck == .idle ? .success("Key verified with Grok") : grokCheck,
                        idleText: "Paste a key to verify automatically"
                    )
                } else {
                    Text("\(provider.displayName) API key")
                        .onboardingLabel()
                        .padding(.top, 4)

                    SecureField(
                        "",
                        text: meetingMemoryKeyBinding,
                        prompt: Text(provider.keyPlaceholder).foregroundColor(onboardingPlaceholderColor)
                    )
                    .onboardingField()
                    .id(provider)

                    HStack(spacing: 10) {
                        OnboardingCheckStatus(
                            state: meetingMemoryCheck,
                            idleText: "Paste a key to verify automatically"
                        )
                        Spacer()
                        Button("Test key") { testMeetingMemoryKey() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .disabled(!meetingMemoryHasKey || meetingMemoryCheck == .running)
                        Button("Create an API key") {
                            NSWorkspace.shared.open(provider.consoleURL)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                    }
                }
            }
        }
    }

    private var reusesTranscriptionGrokKey: Bool {
        recorderManager.transcriptionManager.transcriptionProvider == .grok
            && recorderManager.transcriptionManager.meetingMemoryProvider == .grok
            && recorderManager.transcriptionManager.isXAIAPIKeyVerified
    }

    private var meetingMemoryKeyBinding: Binding<String> {
        switch recorderManager.transcriptionManager.meetingMemoryProvider {
        case .openai:
            return Binding(
                get: { recorderManager.transcriptionManager.openAIAPIKey },
                set: { openAIKeyChanged(to: $0) }
            )
        case .grok:
            return Binding(
                get: { recorderManager.transcriptionManager.xaiAPIKey },
                set: { grokKeyChanged(to: $0) }
            )
        }
    }

    private var meetingMemoryCheck: OnboardingConnectionCheck {
        switch recorderManager.transcriptionManager.meetingMemoryProvider {
        case .openai: return openAICheck
        case .grok: return grokCheck
        }
    }

    private var meetingMemoryHasKey: Bool {
        switch recorderManager.transcriptionManager.meetingMemoryProvider {
        case .openai: return recorderManager.transcriptionManager.hasOpenAIAPIKey
        case .grok: return recorderManager.transcriptionManager.hasXAIAPIKey
        }
    }

    private var storagePage: some View {
        OnboardingPageLayout(
            icon: "cloud.fill",
            title: "Choose where calls live",
            body: "Use OpenRec Cloud for searchable meeting memory, send recordings to your own Cloudflare R2 bucket, or keep everything on this Mac."
        ) {
            VStack(spacing: 10) {
                StorageChoiceRow(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "OpenRec Cloud",
                    detail: "Google sign-in · transcript database · private media",
                    selected: recorderManager.cloudStorage.mode == .managed
                ) {
                    selectStorage(.managed)
                }

                StorageChoiceRow(
                    icon: "shippingbox.fill",
                    title: "My Cloudflare R2",
                    detail: "Your bucket · live media streaming · private meeting index",
                    selected: recorderManager.cloudStorage.mode == .ownR2
                ) {
                    selectStorage(.ownR2)
                }

                StorageChoiceRow(
                    icon: "internaldrive",
                    title: "This Mac",
                    detail: "Recordings and meeting memory stay on this computer",
                    selected: recorderManager.cloudStorage.mode == .local
                ) {
                    selectStorage(.local)
                }

                storageConfiguration
                    .id(recorderManager.cloudStorage.mode)
                    .transition(storageConfigurationTransition)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var storageConfiguration: some View {
        switch recorderManager.cloudStorage.mode {
        case .managed:
            VStack(spacing: 10) {
                if recorderManager.cloudStorage.isManagedSignedIn {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green.opacity(0.9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connected")
                                .font(.system(size: 11, weight: .semibold))
                            Text(recorderManager.cloudStorage.managedEmail ?? "Google account")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.48))
                        }
                        Spacer()
                        Button("Sign out") { recorderManager.cloudStorage.signOut() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.52))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    .background(Color.white.opacity(0.065))
                    .cornerRadius(8)
                } else {
                    OnboardingPrimaryButton(
                        title: recorderManager.cloudStorage.isSigningIn ? "Opening Google…" : "Continue with Google",
                        icon: "person.crop.circle.badge.plus",
                        disabled: recorderManager.cloudStorage.isSigningIn
                    ) {
                        Task { await recorderManager.cloudStorage.signInWithGoogle() }
                    }
                }

                if let message = recorderManager.cloudStorage.statusMessage {
                    Text(message)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(recorderManager.cloudStorage.isReady ? .green.opacity(0.85) : .orange.opacity(0.9))
                        .multilineTextAlignment(.center)
                }
            }
        case .ownR2:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField(
                        "",
                        text: Binding(
                            get: { recorderManager.cloudStorage.r2AccountID },
                            set: { recorderManager.cloudStorage.r2AccountID = $0; resetR2Check() }
                        ),
                        prompt: Text("R2 account ID").foregroundColor(onboardingPlaceholderColor)
                    )
                    .onboardingField()
                    TextField(
                        "",
                        text: Binding(
                            get: { recorderManager.cloudStorage.r2Bucket },
                            set: { recorderManager.cloudStorage.r2Bucket = $0; resetR2Check() }
                        ),
                        prompt: Text("Bucket name").foregroundColor(onboardingPlaceholderColor)
                    )
                    .onboardingField()
                }

                SecureField(
                    "",
                    text: Binding(
                        get: { recorderManager.cloudStorage.r2AccessKeyID },
                        set: { recorderManager.cloudStorage.r2AccessKeyID = $0; resetR2Check() }
                    ),
                    prompt: Text("Access key ID").foregroundColor(onboardingPlaceholderColor)
                )
                .onboardingField()

                SecureField(
                    "",
                    text: Binding(
                        get: { recorderManager.cloudStorage.r2SecretAccessKey },
                        set: { recorderManager.cloudStorage.r2SecretAccessKey = $0; resetR2Check() }
                    ),
                    prompt: Text("Secret access key").foregroundColor(onboardingPlaceholderColor)
                )
                .onboardingField()

                HStack {
                    OnboardingCheckStatus(
                        state: r2Check,
                        idleText: recorderManager.cloudStorage.isReady ? "Test this bucket before continuing" : "All four values are required"
                    )
                    Spacer()
                    Button("Test connection") { testR2Connection() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .disabled(!recorderManager.cloudStorage.isReady || r2Check == .running)
                }
            }
        case .local:
            VStack(spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "internaldrive")
                        .foregroundColor(.white.opacity(0.7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready on this Mac")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                        Text((recorderManager.cloudStorage.recordingsDirectoryPath as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.48))
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(Color.white.opacity(0.065))
                .cornerRadius(8)

                Text("No Google sign-in or R2 credentials. Change the folder later in Settings.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.42))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var calendarPage: some View {
        OnboardingPageLayout(
            icon: "calendar",
            title: "Name calls after your meetings",
            body: "Optional. With calendar access, each call starts pre-named after the meeting you're in, and the Meetings window shows what's coming up."
        ) {
            VStack(spacing: 10) {
                if recorderManager.cloudStorage.mode == .managed {
                    if let calendarEmail = recorderManager.cloudStorage.calendarEmail {
                        calendarStatusRow(
                            icon: "checkmark.circle.fill",
                            tint: .green.opacity(0.9),
                            title: "Google Calendar connected",
                            detail: calendarEmail
                        )
                    } else if showsGoogleCalendarConnectPrompt {
                        HStack(spacing: 8) {
                            OnboardingPrimaryButton(
                                title: recorderManager.cloudStorage.isConnectingCalendar ? "Opening Google…" : "Connect Google Calendar",
                                icon: "calendar.badge.plus",
                                disabled: recorderManager.cloudStorage.isConnectingCalendar
                            ) {
                                Task {
                                    if await recorderManager.cloudStorage.connectGoogleCalendar() {
                                        googleCalendarConnectDeclined = GoogleCalendarConnectPrompt.isDeclined()
                                    }
                                }
                            }
                            Button("No Thanks") {
                                declineGoogleCalendarConnect()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.78))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    } else if recorderManager.cloudStorage.isManagedSignedIn {
                        calendarStatusRow(
                            icon: "calendar",
                            tint: .white.opacity(0.5),
                            title: "Google Calendar not connected",
                            detail: "Connect it later in Settings"
                        )
                    } else {
                        calendarStatusRow(
                            icon: "info.circle",
                            tint: .white.opacity(0.5),
                            title: "Sign in first",
                            detail: "Calendar connections attach to the OpenRec Cloud account from the previous step"
                        )
                    }
                }

                if localCalendarGranted {
                    calendarStatusRow(
                        icon: "checkmark.circle.fill",
                        tint: .green.opacity(0.9),
                        title: "Mac calendars connected",
                        detail: "Accounts synced to the macOS Calendar app are included"
                    )
                } else {
                    Button {
                        guard !isRequestingLocalCalendar else { return }
                        isRequestingLocalCalendar = true
                        Task {
                            localCalendarGranted = await recorderManager.requestLocalCalendarAccess()
                            isRequestingLocalCalendar = false
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "desktopcomputer")
                                .foregroundColor(.white.opacity(0.6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use the Mac's calendars")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.88))
                                Text("Also covers Google accounts synced to the macOS Calendar app")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.48))
                            }
                            Spacer()
                            Text(isRequestingLocalCalendar ? "Asking…" : "Allow")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(Color.white.opacity(0.065))
                        .cornerRadius(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRequestingLocalCalendar)
                }

                Text("You can skip this — recording works without a calendar, and it can be connected later in Settings.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.42))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func calendarStatusRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.48))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Color.white.opacity(0.065))
        .cornerRadius(8)
    }

    private var defaultsPage: some View {
        OnboardingPageLayout(
            icon: "slider.horizontal.3",
            title: "Set your call defaults",
            body: "These are only defaults. You can change every choice from the recorder while a call is running."
        ) {
            VStack(spacing: 0) {
                OnboardingToggleRow(
                    icon: "rectangle.on.rectangle",
                    title: "Keep screen recording",
                    detail: recorderManager.cloudStorage.mode == .local
                        ? "Keep the call video in the recordings folder on this Mac"
                        : "Stream the call video directly to cloud storage",
                    value: preference(\.keepScreenRecording)
                )
                rowDivider
                OnboardingToggleRow(
                    icon: "waveform",
                    title: "Keep audio recording",
                    detail: recorderManager.cloudStorage.mode == .local
                        ? "Keep a separate call-audio file on this Mac"
                        : "Stream a separate call-audio file to cloud storage",
                    value: preference(\.keepAudioRecording)
                )
                rowDivider
                OnboardingToggleRow(
                    icon: "text.quote",
                    title: "Store transcript",
                    detail: "Make the transcript searchable in Meetings",
                    value: preference(\.storeTranscriptInCloud),
                    enabled: true
                )
            }
            .background(Color.white.opacity(0.055))
            .cornerRadius(10)
        }
    }

    private var webhookPage: some View {
        OnboardingPageLayout(
            icon: "arrow.up.right",
            title: "Send recordings elsewhere",
            body: recorderManager.cloudStorage.mode == .local
                ? "Optionally post each completed call’s metadata to your own HTTPS endpoint. Recordings stay on this Mac."
                : "Optionally post each completed call to your own HTTPS endpoint with short-lived private recording links."
        ) {
            VStack(spacing: 14) {
                OnboardingToggleRow(
                    icon: "link",
                    title: "External webhook",
                    detail: "Deliver after transcription and analysis",
                    value: preference(\.sendToWebhook)
                )
                .padding(.horizontal, 2)

                if recorderManager.callPreferences.sendToWebhook {
                    VStack(spacing: 8) {
                        TextField(
                            "",
                            text: Binding(
                                get: { recorderManager.webhookSettings.url },
                                set: { recorderManager.webhookSettings.url = $0 }
                            ),
                            prompt: Text("https://example.com/openrec").foregroundColor(onboardingPlaceholderColor)
                        )
                        .onboardingField()

                        SecureField(
                            "",
                            text: Binding(
                                get: { recorderManager.webhookSettings.secret },
                                set: { recorderManager.webhookSettings.secret = $0 }
                            ),
                            prompt: Text("Bearer secret (optional)").foregroundColor(onboardingPlaceholderColor)
                        )
                        .onboardingField()

                        SetupStatus(
                            ready: recorderManager.webhookSettings.isConfigured,
                            readyText: "Webhook ready",
                            pendingText: "Enter a valid HTTPS URL"
                        )
                    }
                    .transition(storageConfigurationTransition)
                } else {
                    Text("You can add one later from Settings.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.42))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : onboardingQuickEaseOut, value: recorderManager.callPreferences.sendToWebhook)
        }
    }

    private var permissionsPage: some View {
        OnboardingPageLayout(
            icon: "hand.raised.fill",
            title: "Allow recording",
            body: "OpenRec needs microphone and screen access only while you’re recording. macOS keeps both permissions under your control."
        ) {
            VStack(spacing: 10) {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Your voice in the conversation",
                    granted: microphoneGranted,
                    actionTitle: microphoneActionTitle,
                    action: requestMicrophone
                )

                PermissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen & system audio",
                    detail: "The call window and everyone else",
                    granted: screenGranted,
                    actionTitle: screenGranted ? "Allowed" : "Allow",
                    action: requestScreen
                )

                if !microphoneGranted || !screenGranted {
                    Button("Open Privacy & Security") {
                        openMissingPrivacySettings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.top, 2)
                }
            }
        }
    }

    private var readyPage: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 76, height: 76)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.green.opacity(0.9))
            }
            .padding(.bottom, 20)

            Text(isSettings ? "Settings saved" : "You’re ready to record")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.94))

            Text(isSettings
                 ? "Your next call will use these choices."
                 : "OpenRec will sit quietly in your menu bar and appear when it detects a call.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.54))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 350)
                .padding(.top, 9)

            OnboardingPrimaryButton(title: isSettings ? "Done" : "Open recorder") {
                OpenRecOnboarding.markComplete()
                onFinish()
            }
            .frame(width: 160)
            .padding(.top, 24)

            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { goBack() }
                .buttonStyle(OnboardingPressButtonStyle(pressedScale: 0.96))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.52))
                .disabled(isSettings && step == .assemblyAI)
                .opacity(isSettings && step == .assemblyAI ? 0 : 1)

            Spacer()

            OnboardingPrimaryButton(title: primaryTitle, disabled: !canContinue) {
                goForward()
            }
            .frame(width: 118)
        }
        .frame(height: 42)
    }

    private var primaryTitle: String {
        switch step {
        case .permissions: return "Finish"
        case .calendar: return calendarConnected ? "Continue" : "Skip for now"
        default: return "Continue"
        }
    }

    private var calendarConnected: Bool {
        localCalendarGranted || recorderManager.cloudStorage.calendarEmail != nil
    }

    private var canContinue: Bool {
        switch step {
        case .assemblyAI:
            recorderManager.transcriptionManager.isSelectedTranscriptionKeyVerified
        case .meetingMemory:
            recorderManager.transcriptionManager.isSelectedMeetingMemoryKeyVerified
        case .storage:
            recorderManager.cloudStorage.mode.onboardingCanContinue(
                isReady: recorderManager.cloudStorage.isReady,
                r2ConnectionVerified: UserDefaults.standard.bool(forKey: "R2ConnectionVerified")
            )
        case .webhook:
            !recorderManager.callPreferences.sendToWebhook || recorderManager.webhookSettings.isConfigured
        case .permissions:
            microphoneGranted && screenGranted
        default:
            true
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }

        let insertionOffset: CGFloat = navigationDirection == .forward ? 24 : -24
        let removalOffset: CGFloat = navigationDirection == .forward ? -14 : 14

        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: insertionOffset))
                .combined(with: .scale(scale: 0.985)),
            removal: .opacity
                .combined(with: .offset(x: removalOffset))
                .combined(with: .scale(scale: 0.992))
        )
    }

    private var storageConfigurationTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity
            .combined(with: .offset(y: 5))
            .combined(with: .scale(scale: 0.992))
    }

    private var rowDivider: some View {
        Color.white.opacity(0.08)
            .frame(height: 1)
            .padding(.leading, 48)
    }

    private var microphoneActionTitle: String {
        if microphoneGranted { return "Allowed" }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .denied ? "Open Settings" : "Allow"
    }

    private func goForward() {
        switch step {
        case .welcome: move(to: .assemblyAI)
        case .assemblyAI: move(to: .meetingMemory)
        case .meetingMemory: move(to: .storage)
        case .storage: move(to: .calendar)
        case .calendar:
            if !calendarConnected {
                declineGoogleCalendarConnectIfOffered()
            }
            move(to: .defaults)
        case .defaults: move(to: .webhook)
        case .webhook: move(to: .permissions)
        case .permissions: move(to: .ready)
        case .ready: break
        }
    }

    private func goBack() {
        switch step {
        case .assemblyAI: move(to: isSettings ? .assemblyAI : .welcome)
        case .meetingMemory: move(to: .assemblyAI)
        case .storage: move(to: .meetingMemory)
        case .calendar: move(to: .storage)
        case .defaults: move(to: .calendar)
        case .webhook: move(to: .defaults)
        case .permissions: move(to: .webhook)
        case .ready: move(to: .permissions)
        case .welcome: break
        }
    }

    private func move(to nextStep: OnboardingStep) {
        navigationDirection = nextStep.rawValue >= step.rawValue ? .forward : .backward
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : onboardingEaseOut) {
            step = nextStep
        }
        if !isSettings {
            OpenRecOnboarding.persistWizardStep(nextStep)
        }
        if nextStep == .permissions { refreshPermissions() }
        if nextStep == .calendar {
            googleCalendarConnectDeclined = GoogleCalendarConnectPrompt.isDeclined()
        }
    }

    private var showsGoogleCalendarConnectPrompt: Bool {
        recorderManager.cloudStorage.mode == .managed
            && recorderManager.cloudStorage.isManagedSignedIn
            && GoogleCalendarConnectPrompt.shouldShowAutomaticPrompt(
                declined: googleCalendarConnectDeclined,
                googleCalendarConnected: recorderManager.cloudStorage.calendarEmail != nil
            )
    }

    private func declineGoogleCalendarConnect() {
        GoogleCalendarConnectPrompt.decline()
        googleCalendarConnectDeclined = true
    }

    /// Skip for now records the same decline as No Thanks when OpenRec Cloud
    /// offered Google Calendar and it is still not connected.
    private func declineGoogleCalendarConnectIfOffered() {
        guard GoogleCalendarConnectPrompt.shouldDeclineWhenSkippingCalendarStep(
            offersGoogleCalendarConnect: recorderManager.cloudStorage.mode == .managed
                && recorderManager.cloudStorage.isManagedSignedIn,
            googleCalendarConnected: recorderManager.cloudStorage.calendarEmail != nil
        ) else { return }
        declineGoogleCalendarConnect()
    }

    private func selectStorage(_ mode: StorageMode) {
        guard recorderManager.cloudStorage.mode != mode else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : onboardingQuickEaseOut) {
            recorderManager.cloudStorage.mode = mode
        }
    }

    private func preference(_ path: WritableKeyPath<CallPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { recorderManager.callPreferences[keyPath: path] },
            set: { setPreference(path, to: $0) }
        )
    }

    private func setPreference(_ path: WritableKeyPath<CallPreferences, Bool>, to value: Bool) {
        var preferences = recorderManager.callPreferences
        preferences[keyPath: path] = value
        recorderManager.callPreferences = preferences
    }

    private func prepareOnboarding() {
        if !isSettings {
            OpenRecOnboarding.persistWizardStep(step)
        }
        refreshPermissions()
        if recorderManager.transcriptionManager.isAssemblyAIAPIKeyVerified {
            assemblyAICheck = .success("Key verified with AssemblyAI")
        }
        if recorderManager.transcriptionManager.isOpenAIAPIKeyVerified {
            openAICheck = .success("Key verified with OpenAI")
        }
        if recorderManager.transcriptionManager.isXAIAPIKeyVerified {
            grokCheck = .success("Key verified with Grok")
        }
        if UserDefaults.standard.bool(forKey: "R2ConnectionVerified"), recorderManager.cloudStorage.isReady {
            r2Check = .success("Upload and cleanup succeeded")
        }
        googleCalendarConnectDeclined = GoogleCalendarConnectPrompt.isDeclined()
    }

    private func assemblyAIKeyChanged(to key: String) {
        recorderManager.transcriptionManager.assemblyAIAPIKey = key
        assemblyAICheck = .idle
        verifyAssemblyAIKey(key, trigger: .automatic)
    }

    private func testAssemblyAIKey() {
        verifyAssemblyAIKey(
            recorderManager.transcriptionManager.assemblyAIAPIKey,
            trigger: .immediate
        )
    }

    private func verifyAssemblyAIKey(
        _ key: String,
        trigger: APIKeyAutoVerifier.Trigger
    ) {
        assemblyAIKeyVerifier.submit(
            key: key,
            trigger: trigger,
            currentKey: { recorderManager.transcriptionManager.assemblyAIAPIKey },
            onRunning: { assemblyAICheck = .running },
            validate: { try await AssemblyAIService(apiKey: $0).validateAccess() },
            onCompletion: { normalizedKey, result in
                switch result {
                case .success:
                    recorderManager.transcriptionManager.assemblyAIAPIKey = normalizedKey
                    UserDefaults.standard.set(true, forKey: "AssemblyAIKeyVerified")
                    assemblyAICheck = .success("Key verified with AssemblyAI")
                case .failure(let error):
                    if AssemblyAIService.isAuthenticationFailure(error) {
                        UserDefaults.standard.set(false, forKey: "AssemblyAIKeyVerified")
                    }
                    assemblyAICheck = .failure(error.localizedDescription)
                }
            }
        )
    }

    private func openAIKeyChanged(to key: String) {
        recorderManager.transcriptionManager.openAIAPIKey = key
        openAICheck = .idle
        verifyOpenAIKey(key, trigger: .automatic)
    }

    private func testOpenAIKey() {
        verifyOpenAIKey(
            recorderManager.transcriptionManager.openAIAPIKey,
            trigger: .immediate
        )
    }

    private func verifyOpenAIKey(
        _ key: String,
        trigger: APIKeyAutoVerifier.Trigger
    ) {
        openAIKeyVerifier.submit(
            key: key,
            trigger: trigger,
            currentKey: { recorderManager.transcriptionManager.openAIAPIKey },
            onRunning: { openAICheck = .running },
            validate: { try await OpenAIService(apiKey: $0).validateAccess() },
            onCompletion: { normalizedKey, result in
                switch result {
                case .success:
                    recorderManager.transcriptionManager.openAIAPIKey = normalizedKey
                    UserDefaults.standard.set(true, forKey: MeetingMemoryProvider.openAIVerifiedDefaultsKey)
                    openAICheck = .success("Key verified with OpenAI")
                case .failure(let error):
                    if OpenAIService.isCredentialOrModelAccessFailure(error) {
                        UserDefaults.standard.set(false, forKey: MeetingMemoryProvider.openAIVerifiedDefaultsKey)
                    }
                    openAICheck = .failure(error.localizedDescription)
                }
            }
        )
    }

    private func grokKeyChanged(to key: String) {
        recorderManager.transcriptionManager.xaiAPIKey = key
        grokCheck = .idle
        verifyGrokKey(key, trigger: .automatic)
    }

    private func testMeetingMemoryKey() {
        switch recorderManager.transcriptionManager.meetingMemoryProvider {
        case .openai:
            testOpenAIKey()
        case .grok:
            verifyGrokKey(
                recorderManager.transcriptionManager.xaiAPIKey,
                trigger: .immediate
            )
        }
    }

    private func verifyGrokKey(
        _ key: String,
        trigger: APIKeyAutoVerifier.Trigger
    ) {
        grokKeyVerifier.submit(
            key: key,
            trigger: trigger,
            currentKey: { recorderManager.transcriptionManager.xaiAPIKey },
            onRunning: { grokCheck = .running },
            validate: { try await GrokService(apiKey: $0).validateAccess() },
            onCompletion: { normalizedKey, result in
                switch result {
                case .success:
                    recorderManager.transcriptionManager.xaiAPIKey = normalizedKey
                    UserDefaults.standard.set(true, forKey: MeetingMemoryProvider.grokVerifiedDefaultsKey)
                    grokCheck = .success("Key verified with Grok")
                case .failure(let error):
                    if GrokService.isCredentialOrModelAccessFailure(error) {
                        UserDefaults.standard.set(false, forKey: MeetingMemoryProvider.grokVerifiedDefaultsKey)
                    }
                    grokCheck = .failure(error.localizedDescription)
                }
            }
        )
    }

    private func resetR2Check() {
        r2Check = .idle
        UserDefaults.standard.set(false, forKey: "R2ConnectionVerified")
    }

    private func testR2Connection() {
        r2Check = .running
        Task {
            do {
                try await recorderManager.cloudStorage.validateR2Connection()
                UserDefaults.standard.set(true, forKey: "R2ConnectionVerified")
                r2Check = .success("Upload and cleanup succeeded")
            } catch {
                UserDefaults.standard.set(false, forKey: "R2ConnectionVerified")
                r2Check = .failure(error.localizedDescription)
            }
        }
    }

    private func refreshPermissions() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenGranted = CGPreflightScreenCaptureAccess()
    }

    private func requestMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            openPrivacySettings(anchor: "Privacy_Microphone")
            return
        }
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run { refreshPermissions() }
        }
    }

    private func requestScreen() {
        if CGPreflightScreenCaptureAccess() {
            refreshPermissions()
            return
        }
        let granted = CGRequestScreenCaptureAccess()
        refreshPermissions()
        if !granted {
            openPrivacySettings(anchor: "Privacy_ScreenCapture")
        }
    }

    private func openMissingPrivacySettings() {
        if !microphoneGranted {
            openPrivacySettings(anchor: "Privacy_Microphone")
        } else if !screenGranted {
            openPrivacySettings(anchor: "Privacy_ScreenCapture")
        }
    }

    private func openPrivacySettings(anchor: String = "Privacy_ScreenCapture") {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct OnboardingPressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.975

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(onboardingQuickEaseOut, value: configuration.isPressed)
    }
}

private struct OnboardingPageLayout<Content: View>: View {
    let icon: String
    let title: String
    let bodyText: String
    let content: Content

    init(
        icon: String,
        title: String,
        body: String,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.bodyText = body
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            pageIcon
                .frame(width: 54, height: 54)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
                .padding(.bottom, 17)

            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white.opacity(0.94))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(bodyText)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.white.opacity(0.54))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 390)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            content
                .frame(maxWidth: 410)
                .padding(.top, 24)

            Spacer(minLength: 12)
        }
    }

    @ViewBuilder
    private var pageIcon: some View {
        if icon == "waveform" {
            OpenRecWaveformShape()
                .fill(Color.white.opacity(0.86))
                .frame(width: 22.5, height: 25)
                .accessibilityHidden(true)
        } else {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(0.86))
        }
    }
}

private struct GrokLanguageOnboardingMenu: View {
    @Binding var language: GrokTranscriptionLanguage

    var body: some View {
        Menu {
            ForEach(GrokTranscriptionLanguage.allCases) { option in
                Button {
                    language = option
                } label: {
                    if option == language {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.displayName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                    Text(language.pickerDetail)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.44))
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 52)
            .background(Color.white.opacity(0.1))
            .cornerRadius(9)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Grok transcription language")
    }
}

private struct StorageChoiceRow: View {
    let icon: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(selected ? 0.9 : 0.52))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.44))
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(selected ? .red.opacity(0.9) : .white.opacity(0.24))
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(Color.white.opacity(selected ? 0.1 : 0.045))
            .cornerRadius(9)
            .contentShape(Rectangle())
        }
        .buttonStyle(OnboardingPressButtonStyle(pressedScale: 0.985))
    }
}

private struct OnboardingToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var value: Bool
    var enabled = true

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.43))
            }
            Spacer()
            Toggle("", isOn: $value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.red)
                .disabled(!enabled)
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .opacity(enabled ? 1 : 0.46)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.58))
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.43))
            }
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(OnboardingPressButtonStyle(pressedScale: 0.96))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(granted ? .green.opacity(0.86) : .white.opacity(0.82))
                .padding(.horizontal, 10)
                .frame(height: 27)
                .background(Color.white.opacity(granted ? 0.055 : 0.1))
                .cornerRadius(6)
                .disabled(granted)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(Color.white.opacity(0.05))
        .cornerRadius(9)
    }
}

private struct SetupStatus: View {
    let ready: Bool
    let readyText: String
    let pendingText: String

    var body: some View {
        Label(ready ? readyText : pendingText, systemImage: ready ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(ready ? .green.opacity(0.85) : .white.opacity(0.42))
    }
}

private struct OnboardingCheckStatus: View {
    let state: OnboardingConnectionCheck
    let idleText: String

    var body: some View {
        Group {
            switch state {
            case .idle:
                Label(idleText, systemImage: "circle.dashed")
                    .foregroundColor(.white.opacity(0.42))
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Testing…")
                }
                .foregroundColor(.white.opacity(0.5))
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green.opacity(0.85))
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange.opacity(0.9))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(2)
    }
}

private struct OnboardingPrimaryButton: View {
    let title: String
    var icon: String?
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(Color.red.opacity(disabled ? 0.32 : (hovering ? 1 : 0.88)))
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(OnboardingPressButtonStyle())
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(onboardingQuickEaseOut, value: hovering)
    }
}

private extension View {
    func onboardingField() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundColor(.white.opacity(0.88))
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(Color.white.opacity(0.075))
            .cornerRadius(8)
    }

    func onboardingLabel() -> some View {
        self
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(.white.opacity(0.56))
    }
}
