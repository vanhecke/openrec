import XCTest
@testable import OpenRecApp

final class MeetingMemoryProviderTests: XCTestCase {
    func testMissingStoredProviderStaysOnOpenAIAndAssemblyAI() {
        XCTAssertEqual(MeetingMemoryProvider.resolved(from: nil), .openai)
        XCTAssertEqual(MeetingMemoryProvider.resolved(from: ""), .openai)
        XCTAssertEqual(MeetingMemoryProvider.resolved(from: "claude"), .openai)
        XCTAssertEqual(MeetingMemoryProvider.resolved(from: "openai"), .openai)
        XCTAssertEqual(MeetingMemoryProvider.resolved(from: "grok"), .grok)
        XCTAssertEqual(TranscriptionProvider.resolved(from: nil), .assemblyAI)
        XCTAssertEqual(TranscriptionProvider.resolved(from: ""), .assemblyAI)
        XCTAssertEqual(TranscriptionProvider.resolved(from: "whisper"), .assemblyAI)
        XCTAssertEqual(TranscriptionProvider.resolved(from: "assemblyAI"), .assemblyAI)
        XCTAssertEqual(TranscriptionProvider.resolved(from: "grok"), .grok)
    }

    func testOpenAIOnlyUserCompletesWhenAssemblyAIAndOpenAIAreSelected() {
        let readiness = OnboardingReadiness(
            markedComplete: true,
            transcription: assemblyTranscription(),
            meetingMemory: MeetingMemoryCredentials(
                provider: .openai,
                openAIKey: "openai-present",
                openAIVerified: true,
                grokKey: "",
                grokVerified: false
            )
        )

        XCTAssertEqual(readiness.transcription.provider, .assemblyAI)
        XCTAssertTrue(readiness.transcription.isSelectedKeyVerified)
        XCTAssertTrue(readiness.meetingMemory.isSelectedKeyVerified)
        XCTAssertTrue(readiness.isComplete)
    }

    func testGrokMemoryStillRequiresAssemblyAIWhenThatTranscriptionProviderIsSelected() {
        let readiness = OnboardingReadiness(
            markedComplete: true,
            transcription: assemblyTranscription(),
            meetingMemory: MeetingMemoryCredentials(
                provider: .grok,
                openAIKey: "",
                openAIVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            )
        )

        XCTAssertTrue(readiness.isComplete)
        XCTAssertFalse(readiness.meetingMemory.openAIVerified)
    }

    func testGrokOnlyUserCompletesWithoutAssemblyAIOrOpenAI() {
        let transcription = TranscriptionCredentials(
            provider: .grok,
            assemblyKey: "",
            assemblyVerified: false,
            grokKey: "grok-present",
            grokVerified: true
        )
        let memory = MeetingMemoryCredentials(
            provider: .grok,
            openAIKey: "",
            openAIVerified: false,
            grokKey: "grok-present",
            grokVerified: true
        )
        let readiness = OnboardingReadiness(
            markedComplete: true,
            transcription: transcription,
            meetingMemory: memory
        )

        XCTAssertTrue(transcription.isSelectedKeyVerified)
        XCTAssertTrue(memory.isSelectedKeyVerified)
        XCTAssertTrue(readiness.isComplete)
        XCTAssertTrue(transcription.assemblyKey.isEmpty)
        XCTAssertTrue(memory.openAIKey.isEmpty)
    }

    func testGrokTranscriptionAndOpenAIMemoryCompleteWithoutAnAssemblyAIKey() {
        let readiness = OnboardingReadiness(
            markedComplete: true,
            transcription: TranscriptionCredentials(
                provider: .grok,
                assemblyKey: "",
                assemblyVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            ),
            meetingMemory: MeetingMemoryCredentials(
                provider: .openai,
                openAIKey: "openai-present",
                openAIVerified: true,
                grokKey: "grok-present",
                grokVerified: true
            )
        )

        XCTAssertTrue(readiness.isComplete)
    }

    func testGrokTranscriptionDoesNotCompleteWhileAssemblyAIRemainsSelected() {
        let readiness = OnboardingReadiness(
            markedComplete: true,
            transcription: TranscriptionCredentials(
                provider: TranscriptionProvider.resolved(from: nil),
                assemblyKey: "",
                assemblyVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            ),
            meetingMemory: MeetingMemoryCredentials(
                provider: .grok,
                openAIKey: "",
                openAIVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            )
        )

        XCTAssertEqual(readiness.transcription.provider, .assemblyAI)
        XCTAssertFalse(readiness.transcription.hasSelectedKey)
        XCTAssertFalse(readiness.transcription.isSelectedKeyVerified)
        XCTAssertFalse(readiness.isComplete)
    }

    func testGrokOnlyUserDoesNotCompleteWhileOpenAIRemainsSelected() {
        let readiness = OnboardingReadiness(
            markedComplete: true,
            transcription: TranscriptionCredentials(
                provider: .grok,
                assemblyKey: "",
                assemblyVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            ),
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
        XCTAssertFalse(readiness.isComplete)
    }

    func testSelectedProvidersMustBeVerified() {
        let unverifiedGrokTranscription = OnboardingReadiness(
            markedComplete: true,
            transcription: TranscriptionCredentials(
                provider: .grok,
                assemblyKey: "",
                assemblyVerified: false,
                grokKey: "grok-present",
                grokVerified: false
            ),
            meetingMemory: MeetingMemoryCredentials(
                provider: .grok,
                openAIKey: "",
                openAIVerified: false,
                grokKey: "grok-present",
                grokVerified: true
            )
        )
        let missingAssembly = OnboardingReadiness(
            markedComplete: true,
            transcription: TranscriptionCredentials(
                provider: .assemblyAI,
                assemblyKey: "  ",
                assemblyVerified: true,
                grokKey: "grok-present",
                grokVerified: true
            ),
            meetingMemory: MeetingMemoryCredentials(
                provider: .openai,
                openAIKey: "openai-present",
                openAIVerified: true,
                grokKey: "",
                grokVerified: false
            )
        )
        let notMarked = OnboardingReadiness(
            markedComplete: false,
            transcription: assemblyTranscription(),
            meetingMemory: MeetingMemoryCredentials(
                provider: .openai,
                openAIKey: "openai-present",
                openAIVerified: true,
                grokKey: "",
                grokVerified: false
            )
        )

        XCTAssertFalse(unverifiedGrokTranscription.isComplete)
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
        XCTAssertTrue(TranscriptionProvider.assemblyAI.missingKeySettingsMessage.contains("AssemblyAI"))
        XCTAssertTrue(TranscriptionProvider.grok.missingKeySettingsMessage.contains("Grok"))
        XCTAssertFalse(TranscriptionProvider.grok.missingKeyConfigurationMessage.contains("AssemblyAI"))
        XCTAssertEqual(TranscriptionProvider.grok.modelLabel, "grok-voice-transcribe-2.0")
    }

    private func assemblyTranscription() -> TranscriptionCredentials {
        TranscriptionCredentials(
            provider: .assemblyAI,
            assemblyKey: "assembly-present",
            assemblyVerified: true,
            grokKey: "",
            grokVerified: false
        )
    }
}
