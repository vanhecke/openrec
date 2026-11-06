import XCTest
@testable import OpenRecApp

final class GoogleCalendarConnectPromptTests: XCTestCase {
    func testDeclineHidesThePromptAndSettingsConnectClearsIt() throws {
        let suite = "openrec.google-calendar-prompt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(GoogleCalendarConnectPrompt.isDeclined(in: defaults))
        XCTAssertTrue(GoogleCalendarConnectPrompt.shouldShowAutomaticPrompt(
            declined: false,
            googleCalendarConnected: false
        ))

        GoogleCalendarConnectPrompt.decline(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: GoogleCalendarConnectPrompt.declinedDefaultsKey))
        XCTAssertTrue(GoogleCalendarConnectPrompt.isDeclined(in: defaults))
        XCTAssertFalse(GoogleCalendarConnectPrompt.shouldShowAutomaticPrompt(
            declined: GoogleCalendarConnectPrompt.isDeclined(in: defaults),
            googleCalendarConnected: false
        ))

        // Settings connects through the same success path, which clears this flag.
        GoogleCalendarConnectPrompt.clearDeclined(in: defaults)
        XCTAssertFalse(GoogleCalendarConnectPrompt.isDeclined(in: defaults))
        XCTAssertTrue(GoogleCalendarConnectPrompt.shouldShowAutomaticPrompt(
            declined: GoogleCalendarConnectPrompt.isDeclined(in: defaults),
            googleCalendarConnected: false
        ))
        XCTAssertFalse(GoogleCalendarConnectPrompt.shouldShowAutomaticPrompt(
            declined: false,
            googleCalendarConnected: true
        ))
    }

    func testSkippingTheCalendarStepDeclinesOnlyWhenGoogleConnectWasOffered() {
        XCTAssertTrue(GoogleCalendarConnectPrompt.shouldDeclineWhenSkippingCalendarStep(
            offersGoogleCalendarConnect: true,
            googleCalendarConnected: false
        ))
        XCTAssertFalse(GoogleCalendarConnectPrompt.shouldDeclineWhenSkippingCalendarStep(
            offersGoogleCalendarConnect: true,
            googleCalendarConnected: true
        ))
        XCTAssertFalse(GoogleCalendarConnectPrompt.shouldDeclineWhenSkippingCalendarStep(
            offersGoogleCalendarConnect: false,
            googleCalendarConnected: false
        ))
    }

    func testDecliningGoogleCalendarDoesNotBlockOnboarding() throws {
        let suite = "openrec.google-calendar-prompt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        GoogleCalendarConnectPrompt.decline(in: defaults)
        let readiness = OnboardingReadiness(
            markedComplete: true,
            transcription: TranscriptionCredentials(
                provider: .assemblyAI,
                assemblyKey: "assembly-present",
                assemblyVerified: true,
                grokKey: "",
                grokVerified: false
            ),
            meetingMemory: MeetingMemoryCredentials(
                provider: .openai,
                openAIKey: "openai-present",
                openAIVerified: true,
                grokKey: "",
                grokVerified: false
            )
        )

        XCTAssertTrue(readiness.isComplete)
        XCTAssertFalse(GoogleCalendarConnectPrompt.shouldShowAutomaticPrompt(
            declined: GoogleCalendarConnectPrompt.isDeclined(in: defaults),
            googleCalendarConnected: false
        ))
    }
}
