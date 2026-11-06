import XCTest
@testable import OpenRecApp

final class MeetingMemoryProviderTests: XCTestCase {
    func testMissingStoredProviderStaysOnOpenAI() {
        XCTAssertEqual(MeetingMemoryProvider.resolved(from: nil), .openai)
        XCTAssertEqual(MeetingMemoryProvider.resolved(from: ""), .openai)
        XCTAssertEqual(MeetingMemoryProvider.resolved(from: "claude"), .openai)
        XCTAssertEqual(MeetingMemoryProvider.resolved(from: "openai"), .openai)
        XCTAssertEqual(MeetingMemoryProvider.resolved(from: "grok"), .grok)
    }

    func testOpenAIOnlyUserCompletesWhenOpenAIIsSelected() {
        let readiness = OnboardingReadiness(
            markedComplete: true,
            assemblyKey: "assembly-present",
            assemblyVerified: true,
            meetingMemory: MeetingMemoryCredentials(
                provider: .openai,
                openAIKey: "openai-present",
                openAIVerified: true,
                grokKey: "",
                grokVerified: false
            )
        )

        XCTAssertTrue(readiness.meetingMemory.hasSelectedKey)
        XCTAssertTrue(readiness.meetingMemory.isSelectedKeyVerified)
        XCTAssertTrue(readiness.isComplete)
    }

    func testGrokOnlyUserCompletesWhenGrokIsSelectedAndVerified() {
        let credentials = MeetingMemoryCredentials(
            provider: .grok,
            openAIKey: "",
            openAIVerified: false,
            grokKey: "grok-present",
            grokVerified: true
        )
        let readiness = OnboardingReadiness(
            markedComplete: true,
            assemblyKey: "assembly-present",
            assemblyVerified: true,
            meetingMemory: credentials
        )

        XCTAssertTrue(credentials.hasSelectedKey)
        XCTAssertTrue(credentials.isSelectedKeyVerified)
        XCTAssertTrue(readiness.isComplete)
        XCTAssertFalse(credentials.openAIVerified)
    }

    func testGrokOnlyUserDoesNotCompleteWhileOpenAIRemainsSelected() {
        let readiness = OnboardingReadiness(
            markedComplete: true,
            assemblyKey: "assembly-present",
            assemblyVerified: true,
            meetingMemory: MeetingMemoryCredentials(
                provider: MeetingMemoryProvider.resolved(from: nil),
                openAIKey: "",
                openAIVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            )
        )

        XCTAssertEqual(readiness.meetingMemory.provider, .openai)
        XCTAssertFalse(readiness.meetingMemory.hasSelectedKey)
        XCTAssertFalse(readiness.meetingMemory.isSelectedKeyVerified)
        XCTAssertFalse(readiness.isComplete)
    }

    func testSelectedProviderMustBeVerifiedAndAssemblyAIStaysRequired() {
        let unverifiedGrok = OnboardingReadiness(
            markedComplete: true,
            assemblyKey: "assembly-present",
            assemblyVerified: true,
            meetingMemory: MeetingMemoryCredentials(
                provider: .grok,
                openAIKey: "openai-present",
                openAIVerified: true,
                grokKey: "grok-present",
                grokVerified: false
            )
        )
        let missingAssembly = OnboardingReadiness(
            markedComplete: true,
            assemblyKey: "  ",
            assemblyVerified: true,
            meetingMemory: MeetingMemoryCredentials(
                provider: .grok,
                openAIKey: "",
                openAIVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            )
        )
        let notMarked = OnboardingReadiness(
            markedComplete: false,
            assemblyKey: "assembly-present",
            assemblyVerified: true,
            meetingMemory: MeetingMemoryCredentials(
                provider: .openai,
                openAIKey: "openai-present",
                openAIVerified: true,
                grokKey: "",
                grokVerified: false
            )
        )

        XCTAssertFalse(unverifiedGrok.isComplete)
        XCTAssertFalse(missingAssembly.isComplete)
        XCTAssertFalse(notMarked.isComplete)
    }

    func testRecordingGateMessagesFollowTheSelectedProvider() {
        XCTAssertTrue(MeetingMemoryProvider.openai.missingKeySettingsMessage.contains("OpenAI"))
        XCTAssertTrue(MeetingMemoryProvider.grok.missingKeySettingsMessage.contains("Grok"))
        XCTAssertFalse(MeetingMemoryProvider.grok.missingKeyConfigurationMessage.contains("OpenAI"))
        XCTAssertEqual(MeetingMemoryProvider.grok.keychainAccount, "xai-api-key")
        XCTAssertEqual(MeetingMemoryProvider.grok.verifiedDefaultsKey, "XAIKeyVerified")
        XCTAssertEqual(MeetingMemoryProvider.openai.keychainAccount, "openai-api-key")
    }
}
