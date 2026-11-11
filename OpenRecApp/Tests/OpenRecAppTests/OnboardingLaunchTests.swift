import Security
import XCTest
@testable import OpenRecApp

final class OnboardingLaunchTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "openrec.onboarding-launch.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let defaults, let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshInstallStartsAtWelcome() {
        let input = OnboardingLaunchInput(
            markedComplete: false,
            persistedStep: nil,
            pendingScreenPermissionRelaunch: false,
            microphone: .notDetermined,
            screen: .notDetermined,
            transcription: credentials(provider: .assemblyAI, assemblyKey: "", assemblyVerified: false),
            meetingMemory: memory(provider: .openai, openAIKey: "", openAIVerified: false),
            storage: OnboardingStorageConfiguration(
                mode: StorageMode.resolved(from: nil),
                isReady: true,
                r2ConnectionVerified: false
            )
        )

        XCTAssertEqual(input.storage.mode, .local)
        XCTAssertTrue(input.storage.canContinue)
        XCTAssertEqual(OnboardingLaunch.decide(input), .wizard(.welcome))
    }

    func testUnsetStorageOnTheLaunchPathMatchesTheAppDefault() {
        let operations = KeychainStore.Operations(
            copyMatching: { _ in (errSecItemNotFound, nil) },
            update: { _, _ in errSecParam },
            delete: { _ in errSecParam },
            add: { _ in errSecParam },
            userInteractionAllowed: { true },
            setUserInteractionAllowed: { _ in }
        )
        KeychainStore.useOperationsForTesting(operations)
        defer { KeychainStore.resetForTesting() }

        XCTAssertNil(defaults.string(forKey: StorageMode.defaultsKey))
        let unset = OpenRecOnboarding.storageConfiguration(defaults: defaults)
        XCTAssertEqual(unset.mode, StorageMode.resolved(from: nil))
        XCTAssertEqual(unset.mode, .local)
        XCTAssertTrue(unset.isReady)
        XCTAssertTrue(unset.canContinue)
        XCTAssertNil(defaults.string(forKey: StorageMode.defaultsKey))

        var ready = readyAssemblyAndOpenAI(storage: unset)
        ready.persistedStep = .permissions
        ready.pendingScreenPermissionRelaunch = false
        ready.markedComplete = false
        XCTAssertEqual(OnboardingLaunch.decide(ready), .skip)

        defaults.set(StorageMode.managed.rawValue, forKey: StorageMode.defaultsKey)
        let managed = OpenRecOnboarding.storageConfiguration(defaults: defaults)
        XCTAssertEqual(managed.mode, .managed)
        XCTAssertFalse(managed.canContinue)
        XCTAssertEqual(defaults.string(forKey: StorageMode.defaultsKey), StorageMode.managed.rawValue)
        XCTAssertEqual(
            OnboardingLaunch.decide(readyAssemblyAndOpenAI(storage: managed)),
            .wizard(.storage)
        )

        defaults.set(StorageMode.ownR2.rawValue, forKey: StorageMode.defaultsKey)
        let ownR2 = OpenRecOnboarding.storageConfiguration(defaults: defaults)
        XCTAssertEqual(ownR2.mode, .ownR2)
        XCTAssertFalse(ownR2.canContinue)
        XCTAssertEqual(defaults.string(forKey: StorageMode.defaultsKey), StorageMode.ownR2.rawValue)

        defaults.set("account", forKey: "R2AccountID")
        defaults.set("bucket", forKey: "R2Bucket")
        defaults.set(true, forKey: "R2ConnectionVerified")
        let ownR2WithoutSecrets = OpenRecOnboarding.storageConfiguration(defaults: defaults)
        XCTAssertEqual(ownR2WithoutSecrets.mode, .ownR2)
        XCTAssertFalse(ownR2WithoutSecrets.isReady)
        XCTAssertFalse(ownR2WithoutSecrets.canContinue)

        defaults.set(StorageMode.local.rawValue, forKey: StorageMode.defaultsKey)
        let explicitLocal = OpenRecOnboarding.storageConfiguration(defaults: defaults)
        XCTAssertEqual(explicitLocal.mode, .local)
        XCTAssertTrue(explicitLocal.canContinue)
        XCTAssertEqual(defaults.string(forKey: StorageMode.defaultsKey), StorageMode.local.rawValue)
    }

    func testScreenPermissionRelaunchContinuesToTheFinalStepOnceReady() {
        var waiting = readyAssemblyAndOpenAI(storage: .localReady)
        waiting.persistedStep = .permissions
        waiting.pendingScreenPermissionRelaunch = true
        waiting.markedComplete = false
        waiting.microphone = .allowed
        waiting.screen = .denied

        XCTAssertEqual(OnboardingLaunch.decide(waiting), .wizard(.permissions))

        waiting.screen = .notDetermined
        XCTAssertEqual(OnboardingLaunch.decide(waiting), .wizard(.permissions))

        waiting.screen = .allowed
        waiting.microphone = .denied
        XCTAssertEqual(OnboardingLaunch.decide(waiting), .wizard(.permissions))

        waiting.microphone = .allowed
        XCTAssertEqual(OnboardingLaunch.decide(waiting), .wizard(.ready))

        var staleStep = waiting
        staleStep.pendingScreenPermissionRelaunch = false
        XCTAssertEqual(staleStep.persistedStep, .permissions)
        XCTAssertEqual(OnboardingLaunch.decide(staleStep), .skip)

        var missingStorage = waiting
        missingStorage.storage = .managedSignedOut
        XCTAssertEqual(OnboardingLaunch.decide(missingStorage), .wizard(.storage))
    }

    func testReadyPageKeepsTheScreenPermissionRelaunchPendingUntilFinish() {
        OpenRecOnboarding.persistWizardStep(.permissions, defaults: defaults)
        OpenRecOnboarding.persistWizardStep(.ready, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: OpenRecOnboarding.screenPermissionRelaunchKey))
        XCTAssertEqual(OpenRecOnboarding.persistedWizardStep(defaults: defaults), .ready)

        var showingReady = readyAssemblyAndOpenAI(storage: .localReady)
        showingReady.pendingScreenPermissionRelaunch = true
        showingReady.persistedStep = .ready
        XCTAssertEqual(OnboardingLaunch.decide(showingReady), .wizard(.ready))

        OpenRecOnboarding.persistWizardStep(.calendar, defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: OpenRecOnboarding.screenPermissionRelaunchKey))
        XCTAssertFalse(GoogleCalendarConnectPrompt.isDeclined(in: defaults))
    }

    func testReadyConfigurationSkipsEvenWithoutTheCompletionFlag() {
        var input = readyAssemblyAndOpenAI(storage: .localReady)
        input.markedComplete = false
        input.persistedStep = nil
        input.pendingScreenPermissionRelaunch = false

        XCTAssertEqual(OnboardingLaunch.decide(input), .skip)

        input.persistedStep = .permissions
        XCTAssertEqual(OnboardingLaunch.decide(input), .skip)

        input.persistedStep = .ready
        input.pendingScreenPermissionRelaunch = true
        input.markedComplete = true
        XCTAssertEqual(OnboardingLaunch.decide(input), .skip)
    }

    func testDeniedOrMissingPermissionDoesNotSkip() {
        var deniedScreen = readyAssemblyAndOpenAI(storage: .localReady)
        deniedScreen.markedComplete = true
        deniedScreen.persistedStep = .ready
        deniedScreen.screen = .denied
        XCTAssertEqual(OnboardingLaunch.decide(deniedScreen), .wizard(.permissions))

        var missingMicrophone = readyAssemblyAndOpenAI(storage: .localReady)
        missingMicrophone.markedComplete = true
        missingMicrophone.microphone = .notDetermined
        XCTAssertEqual(OnboardingLaunch.decide(missingMicrophone), .wizard(.permissions))

        var revokedAfterFinish = readyAssemblyAndOpenAI(storage: .localReady)
        revokedAfterFinish.markedComplete = true
        revokedAfterFinish.persistedStep = nil
        revokedAfterFinish.microphone = .denied
        revokedAfterFinish.screen = .allowed
        XCTAssertEqual(OnboardingLaunch.decide(revokedAfterFinish), .wizard(.permissions))
    }

    func testInaccessibleOrMissingSelectedCredentialsDoNotSkip() {
        var inaccessibleAssembly = readyAssemblyAndOpenAI(storage: .localReady)
        inaccessibleAssembly.markedComplete = true
        inaccessibleAssembly.persistedStep = .permissions
        inaccessibleAssembly.transcription.assemblyKey = ""
        inaccessibleAssembly.transcription.assemblyVerified = true
        XCTAssertFalse(inaccessibleAssembly.transcription.isSelectedKeyVerified)
        XCTAssertEqual(OnboardingLaunch.decide(inaccessibleAssembly), .wizard(.assemblyAI))

        var missingOpenAI = readyAssemblyAndOpenAI(storage: .localReady)
        missingOpenAI.meetingMemory.openAIKey = "   "
        missingOpenAI.meetingMemory.openAIVerified = true
        missingOpenAI.persistedStep = .ready
        XCTAssertEqual(OnboardingLaunch.decide(missingOpenAI), .wizard(.meetingMemory))

        var unverifiedGrok = readyGrokOnly(storage: .localReady)
        unverifiedGrok.transcription.grokVerified = false
        unverifiedGrok.meetingMemory.grokVerified = false
        unverifiedGrok.markedComplete = true
        XCTAssertEqual(unverifiedGrok.transcription.provider, .grok)
        XCTAssertEqual(unverifiedGrok.meetingMemory.provider, .grok)
        // The transcription page is the `.assemblyAI` step for either provider.
        XCTAssertEqual(OnboardingLaunch.decide(unverifiedGrok), .wizard(.assemblyAI))
    }

    func testSelectedProviderDecidesReadiness() {
        XCTAssertEqual(
            OnboardingLaunch.decide(readyAssemblyAndOpenAI(storage: .localReady)),
            .skip
        )
        XCTAssertEqual(
            OnboardingLaunch.decide(readyGrokOnly(storage: .localReady)),
            .skip
        )

        var grokTranscriptionOpenAIMemory = readyGrokOnly(storage: .localReady)
        grokTranscriptionOpenAIMemory.meetingMemory = memory(
            provider: .openai,
            openAIKey: "openai-present",
            openAIVerified: true,
            grokKey: "grok-present",
            grokVerified: true
        )
        XCTAssertEqual(OnboardingLaunch.decide(grokTranscriptionOpenAIMemory), .skip)

        var assemblyTranscriptionGrokMemory = readyAssemblyAndOpenAI(storage: .localReady)
        assemblyTranscriptionGrokMemory.meetingMemory = memory(
            provider: .grok,
            openAIKey: "",
            openAIVerified: false,
            grokKey: "grok-present",
            grokVerified: true
        )
        XCTAssertEqual(OnboardingLaunch.decide(assemblyTranscriptionGrokMemory), .skip)

        var assemblyStillSelected = readyGrokOnly(storage: .localReady)
        assemblyStillSelected.transcription.provider = .assemblyAI
        assemblyStillSelected.transcription.assemblyKey = ""
        XCTAssertEqual(assemblyStillSelected.transcription.provider, .assemblyAI)
        XCTAssertEqual(OnboardingLaunch.decide(assemblyStillSelected), .wizard(.assemblyAI))

        var openAIStillSelected = readyGrokOnly(storage: .localReady)
        openAIStillSelected.meetingMemory.provider = .openai
        openAIStillSelected.meetingMemory.openAIKey = ""
        XCTAssertEqual(OnboardingLaunch.decide(openAIStillSelected), .wizard(.meetingMemory))

        let unselectedGrok = OnboardingLaunchInput(
            markedComplete: false,
            persistedStep: nil,
            pendingScreenPermissionRelaunch: false,
            microphone: .allowed,
            screen: .allowed,
            transcription: credentials(
                provider: .assemblyAI,
                assemblyKey: "",
                assemblyVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            ),
            meetingMemory: memory(
                provider: .openai,
                openAIKey: "",
                openAIVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            ),
            storage: .localReady
        )
        XCTAssertEqual(unselectedGrok.transcription.provider, .assemblyAI)
        XCTAssertEqual(unselectedGrok.meetingMemory.provider, .openai)
        XCTAssertEqual(OnboardingLaunch.decide(unselectedGrok), .wizard(.welcome))
    }

    func testSelectedStorageDecidesReadiness() {
        XCTAssertEqual(StorageMode.resolved(from: nil), .local)
        XCTAssertEqual(StorageMode.resolved(from: ""), .local)
        XCTAssertEqual(StorageMode.resolved(from: "not-a-mode"), .local)
        XCTAssertEqual(StorageMode.resolved(from: "local"), .local)
        XCTAssertEqual(StorageMode.resolved(from: "ownR2"), .ownR2)
        XCTAssertEqual(StorageMode.resolved(from: "managed"), .managed)

        XCTAssertTrue(StorageMode.local.isReadyForRecording(
            managedSignedIn: false,
            r2AccountID: "",
            r2Bucket: "",
            r2AccessKeyID: "",
            r2SecretAccessKey: ""
        ))
        XCTAssertFalse(StorageMode.managed.isReadyForRecording(
            managedSignedIn: false,
            r2AccountID: "account",
            r2Bucket: "bucket",
            r2AccessKeyID: "access",
            r2SecretAccessKey: "secret-present"
        ))
        XCTAssertTrue(StorageMode.managed.isReadyForRecording(
            managedSignedIn: true,
            r2AccountID: "",
            r2Bucket: "",
            r2AccessKeyID: "",
            r2SecretAccessKey: ""
        ))
        XCTAssertFalse(StorageMode.ownR2.isReadyForRecording(
            managedSignedIn: true,
            r2AccountID: "account",
            r2Bucket: "bucket",
            r2AccessKeyID: "access",
            r2SecretAccessKey: ""
        ))
        XCTAssertTrue(StorageMode.ownR2.isReadyForRecording(
            managedSignedIn: false,
            r2AccountID: "account",
            r2Bucket: "bucket",
            r2AccessKeyID: "access",
            r2SecretAccessKey: "secret-present"
        ))

        XCTAssertEqual(
            OnboardingLaunch.decide(readyAssemblyAndOpenAI(storage: .localReady)),
            .skip
        )
        XCTAssertEqual(
            OnboardingLaunch.decide(readyAssemblyAndOpenAI(storage: .managedSignedIn)),
            .skip
        )
        XCTAssertEqual(
            OnboardingLaunch.decide(readyAssemblyAndOpenAI(storage: .managedSignedOut)),
            .wizard(.storage)
        )
        XCTAssertEqual(
            OnboardingLaunch.decide(readyAssemblyAndOpenAI(storage: .ownR2Verified)),
            .skip
        )

        var unverifiedBucket = readyAssemblyAndOpenAI(storage: .ownR2Verified)
        unverifiedBucket.storage.r2ConnectionVerified = false
        unverifiedBucket.persistedStep = .permissions
        XCTAssertEqual(OnboardingLaunch.decide(unverifiedBucket), .wizard(.storage))

        var inaccessibleSecret = readyAssemblyAndOpenAI(storage: .ownR2Verified)
        inaccessibleSecret.storage.isReady = false
        inaccessibleSecret.markedComplete = true
        XCTAssertEqual(OnboardingLaunch.decide(inaccessibleSecret), .wizard(.storage))
    }

    func testOptionalCalendarDoesNotBlockLocalUseAndChoicesSurviveResume() {
        defaults.set(TranscriptionProvider.assemblyAI.rawValue, forKey: TranscriptionProvider.defaultsKey)
        defaults.set(MeetingMemoryProvider.openai.rawValue, forKey: MeetingMemoryProvider.defaultsKey)
        defaults.set(StorageMode.local.rawValue, forKey: "StorageMode")
        defaults.set(false, forKey: OpenRecOnboarding.completionKey)
        GoogleCalendarConnectPrompt.decline(in: defaults)
        OpenRecOnboarding.persistWizardStep(.calendar, defaults: defaults)

        var onCalendar = readyAssemblyAndOpenAI(storage: .localReady)
        onCalendar.persistedStep = .calendar
        onCalendar.markedComplete = false
        onCalendar.screen = .denied
        XCTAssertEqual(OnboardingLaunch.decide(onCalendar), .wizard(.calendar))

        onCalendar.screen = .allowed
        XCTAssertEqual(OnboardingLaunch.decide(onCalendar), .skip)

        XCTAssertEqual(
            defaults.string(forKey: TranscriptionProvider.defaultsKey),
            TranscriptionProvider.assemblyAI.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: MeetingMemoryProvider.defaultsKey),
            MeetingMemoryProvider.openai.rawValue
        )
        XCTAssertEqual(defaults.string(forKey: "StorageMode"), StorageMode.local.rawValue)
        XCTAssertTrue(GoogleCalendarConnectPrompt.isDeclined(in: defaults))
        XCTAssertFalse(defaults.bool(forKey: OpenRecOnboarding.completionKey))
        XCTAssertEqual(OpenRecOnboarding.persistedWizardStep(defaults: defaults), .calendar)
    }

    func testFinishingClearsTheResumeStepWithoutRewritingSavedChoices() {
        defaults.set(TranscriptionProvider.grok.rawValue, forKey: TranscriptionProvider.defaultsKey)
        defaults.set(MeetingMemoryProvider.grok.rawValue, forKey: MeetingMemoryProvider.defaultsKey)
        defaults.set(StorageMode.local.rawValue, forKey: "StorageMode")
        GoogleCalendarConnectPrompt.decline(in: defaults)
        OpenRecOnboarding.persistWizardStep(.permissions, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: OpenRecOnboarding.screenPermissionRelaunchKey))

        OpenRecOnboarding.markComplete(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: OpenRecOnboarding.completionKey))
        XCTAssertNil(defaults.string(forKey: OpenRecOnboarding.stepKey))
        XCTAssertFalse(defaults.bool(forKey: OpenRecOnboarding.screenPermissionRelaunchKey))
        XCTAssertNil(OpenRecOnboarding.persistedWizardStep(defaults: defaults))
        XCTAssertEqual(
            defaults.string(forKey: TranscriptionProvider.defaultsKey),
            TranscriptionProvider.grok.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: MeetingMemoryProvider.defaultsKey),
            MeetingMemoryProvider.grok.rawValue
        )
        XCTAssertEqual(defaults.string(forKey: "StorageMode"), StorageMode.local.rawValue)
        XCTAssertTrue(GoogleCalendarConnectPrompt.isDeclined(in: defaults))
    }

    func testUnknownSavedStepIsIgnored() {
        defaults.set("not-a-step", forKey: OpenRecOnboarding.stepKey)
        XCTAssertNil(OnboardingStep.matchingPersistenceID("not-a-step"))
        XCTAssertNil(OpenRecOnboarding.persistedWizardStep(defaults: defaults))

        let input = OnboardingLaunchInput(
            markedComplete: false,
            persistedStep: OpenRecOnboarding.persistedWizardStep(defaults: defaults),
            pendingScreenPermissionRelaunch: false,
            microphone: .notDetermined,
            screen: .denied,
            transcription: credentials(provider: .assemblyAI, assemblyKey: "", assemblyVerified: false),
            meetingMemory: memory(provider: .openai, openAIKey: "", openAIVerified: false),
            storage: .managedSignedOut
        )
        XCTAssertEqual(OnboardingLaunch.decide(input), .wizard(.welcome))
    }

    func testWizardOrderKeepsResumeFromSkippingAhead() {
        XCTAssertLessThan(OnboardingStep.welcome.rawValue, OnboardingStep.assemblyAI.rawValue)
        XCTAssertLessThan(OnboardingStep.assemblyAI.rawValue, OnboardingStep.meetingMemory.rawValue)
        XCTAssertLessThan(OnboardingStep.meetingMemory.rawValue, OnboardingStep.storage.rawValue)
        XCTAssertLessThan(OnboardingStep.storage.rawValue, OnboardingStep.calendar.rawValue)
        XCTAssertLessThan(OnboardingStep.calendar.rawValue, OnboardingStep.defaults.rawValue)
        XCTAssertLessThan(OnboardingStep.defaults.rawValue, OnboardingStep.webhook.rawValue)
        XCTAssertLessThan(OnboardingStep.webhook.rawValue, OnboardingStep.permissions.rawValue)
        XCTAssertLessThan(OnboardingStep.permissions.rawValue, OnboardingStep.ready.rawValue)
    }

    private func readyAssemblyAndOpenAI(
        storage: OnboardingStorageConfiguration
    ) -> OnboardingLaunchInput {
        OnboardingLaunchInput(
            markedComplete: false,
            persistedStep: nil,
            pendingScreenPermissionRelaunch: false,
            microphone: .allowed,
            screen: .allowed,
            transcription: credentials(
                provider: .assemblyAI,
                assemblyKey: "assembly-present",
                assemblyVerified: true
            ),
            meetingMemory: memory(
                provider: .openai,
                openAIKey: "openai-present",
                openAIVerified: true
            ),
            storage: storage
        )
    }

    private func readyGrokOnly(
        storage: OnboardingStorageConfiguration
    ) -> OnboardingLaunchInput {
        OnboardingLaunchInput(
            markedComplete: false,
            persistedStep: nil,
            pendingScreenPermissionRelaunch: false,
            microphone: .allowed,
            screen: .allowed,
            transcription: credentials(
                provider: .grok,
                assemblyKey: "",
                assemblyVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            ),
            meetingMemory: memory(
                provider: .grok,
                openAIKey: "",
                openAIVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            ),
            storage: storage
        )
    }

    private func credentials(
        provider: TranscriptionProvider,
        assemblyKey: String,
        assemblyVerified: Bool,
        grokKey: String = "",
        grokVerified: Bool = false
    ) -> TranscriptionCredentials {
        TranscriptionCredentials(
            provider: provider,
            assemblyKey: assemblyKey,
            assemblyVerified: assemblyVerified,
            grokKey: grokKey,
            grokVerified: grokVerified
        )
    }

    private func memory(
        provider: MeetingMemoryProvider,
        openAIKey: String,
        openAIVerified: Bool,
        grokKey: String = "",
        grokVerified: Bool = false
    ) -> MeetingMemoryCredentials {
        MeetingMemoryCredentials(
            provider: provider,
            openAIKey: openAIKey,
            openAIVerified: openAIVerified,
            grokKey: grokKey,
            grokVerified: grokVerified
        )
    }
}

private extension OnboardingStorageConfiguration {
    static let localReady = OnboardingStorageConfiguration(
        mode: .local,
        isReady: true,
        r2ConnectionVerified: false
    )
    static let managedSignedIn = OnboardingStorageConfiguration(
        mode: .managed,
        isReady: true,
        r2ConnectionVerified: false
    )
    static let managedSignedOut = OnboardingStorageConfiguration(
        mode: .managed,
        isReady: false,
        r2ConnectionVerified: true
    )
    static let ownR2Verified = OnboardingStorageConfiguration(
        mode: .ownR2,
        isReady: true,
        r2ConnectionVerified: true
    )
}
