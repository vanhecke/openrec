import Foundation
import XCTest
@testable import OpenRecApp

final class AIPromptStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suite = "OpenRecAIPromptStore-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        try super.tearDownWithError()
    }

    func testUnsetStoreYieldsTodaysDefaultStrings() {
        let transcript = "[Ada] Ship it Friday."
        XCTAssertNil(defaults.string(forKey: AIPromptStore.Prompt.meetingMemorySystem.defaultsKey))
        XCTAssertEqual(
            AIPromptStore.effective(.meetingMemorySystem, defaults: defaults),
            "You take meeting notes like an excellent human note-taker, and extract participants, decisions, and concrete next steps."
        )
        XCTAssertEqual(
            AIPromptStore.effective(.speakerIdentificationSystem, defaults: defaults),
            "You attach real names to diarized speaker labels. You never guess."
        )
        XCTAssertEqual(
            AIPromptStore.meetingMemoryUser(transcript: transcript, callTitle: "Launch", defaults: defaults),
            historicalMeetingMemoryUser(transcript: transcript, callTitle: "Launch")
        )
        XCTAssertEqual(
            AIPromptStore.meetingMemoryUser(transcript: transcript, callTitle: nil, defaults: defaults),
            historicalMeetingMemoryUser(transcript: transcript, callTitle: nil)
        )
        XCTAssertEqual(
            AIPromptStore.meetingMemoryUser(transcript: transcript, callTitle: "", defaults: defaults),
            historicalMeetingMemoryUser(transcript: transcript, callTitle: "")
        )

        let labels = ["Speaker A", "Speaker 0"]
        XCTAssertEqual(
            AIPromptStore.speakerIdentificationUser(
                transcript: transcript,
                callTitle: "  Maya sync  ",
                labels: labels,
                defaults: defaults
            ),
            historicalSpeakerUser(transcript: transcript, callTitle: "  Maya sync  ", labels: labels)
        )
        XCTAssertEqual(
            AIPromptStore.speakerIdentificationUser(
                transcript: transcript,
                callTitle: nil,
                labels: labels,
                defaults: defaults
            ),
            historicalSpeakerUser(transcript: transcript, callTitle: nil, labels: labels)
        )
        XCTAssertEqual(
            AIPromptStore.speakerIdentificationUser(
                transcript: transcript,
                callTitle: "   ",
                labels: labels,
                defaults: defaults
            ),
            historicalSpeakerUser(transcript: transcript, callTitle: "   ", labels: labels)
        )

        let memoryTemplate = AIPromptStore.effective(.meetingMemoryUser, defaults: defaults)
        XCTAssertTrue(memoryTemplate.contains("{{transcript}}"))
        XCTAssertTrue(memoryTemplate.contains("{{callTitle}}"))
        XCTAssertFalse(memoryTemplate.contains(transcript))
        let speakerTemplate = AIPromptStore.effective(.speakerIdentificationUser, defaults: defaults)
        XCTAssertTrue(speakerTemplate.contains("{{speakerLabels}}"))
        XCTAssertTrue(speakerTemplate.contains("{{callTitle}}"))
        XCTAssertTrue(speakerTemplate.contains("{{transcript}}"))
        XCTAssertFalse(speakerTemplate.contains(transcript))
    }

    func testCustomSystemPromptIsSentForOpenAIAndGrokInsights() throws {
        let custom = "Take notes in the style of a terse chief of staff."
        AIPromptStore.set(.meetingMemorySystem, text: custom, defaults: defaults)
        let transcript = "[Ada] Ship it Friday."

        let openAI = try OpenAIService(apiKey: "test-openai-key").makeInsightsRequest(
            transcript: transcript,
            callTitle: "Launch",
            defaults: defaults
        )
        let grok = try GrokService(apiKey: "test-xai-token").makeInsightsRequest(
            transcript: transcript,
            callTitle: "Launch",
            defaults: defaults
        )

        let openAIBody = try jsonBody(openAI)
        let grokBody = try jsonBody(grok)
        for body in [openAIBody, grokBody] {
            let messages = try messages(in: body)
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages.first?["role"] as? String, "system")
            XCTAssertEqual(messages.first?["content"] as? String, custom)
            XCTAssertTrue((messages.last?["content"] as? String)?.contains(transcript) == true)
            XCTAssertNil(body["search_parameters"])
            let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
            let schema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
            XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
            XCTAssertEqual(schema["name"] as? String, "meeting_insights")
            XCTAssertEqual(schema["strict"] as? Bool, true)
        }
        XCTAssertEqual(openAI.url?.host, "api.openai.com")
        XCTAssertEqual(openAIBody["model"] as? String, "gpt-5-mini")
        XCTAssertNil(openAIBody["reasoning_effort"])
        XCTAssertEqual(grok.url?.host, "api.x.ai")
        XCTAssertEqual(grokBody["model"] as? String, "grok-4.7")
        XCTAssertEqual(grokBody["reasoning_effort"] as? String, "high")
        let openAISerialized = String(data: try XCTUnwrap(openAI.httpBody), encoding: .utf8) ?? ""
        let grokSerialized = String(data: try XCTUnwrap(grok.httpBody), encoding: .utf8) ?? ""
        XCTAssertFalse(openAISerialized.contains("test-openai-key"))
        XCTAssertFalse(grokSerialized.contains("test-xai-token"))
    }

    func testCustomSpeakerSystemPromptIsSentInTheSharedRequestBody() throws {
        let custom = "Name speakers only from explicit introductions."
        AIPromptStore.set(.speakerIdentificationSystem, text: custom, defaults: defaults)
        let transcript = "[Speaker A] Hi, I'm Maya.\n[Speaker 0] Thanks Maya."

        let body = SpeakerNames.requestBody(
            model: "gpt-5-mini",
            reasoningEffort: nil,
            transcript: transcript,
            callTitle: "Maya sync",
            defaults: defaults
        )
        let speakerMessages = try messages(in: body)
        XCTAssertEqual(speakerMessages.first?["content"] as? String, custom)
        XCTAssertTrue((speakerMessages.last?["content"] as? String)?.contains("Speaker A, Speaker 0") == true)
        XCTAssertTrue((speakerMessages.last?["content"] as? String)?.contains(transcript) == true)
        XCTAssertNil(body["search_parameters"])
        XCTAssertNil(body["reasoning_effort"])
        let schema = ((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
        XCTAssertEqual(schema?["name"] as? String, "speaker_names")
        XCTAssertEqual(schema?["strict"] as? Bool, true)

        let openAI = try OpenAIService(apiKey: "test-openai-key").makeSpeakerNamesRequest(
            transcript: transcript,
            callTitle: "Maya sync",
            defaults: defaults
        )
        let grok = try GrokService(apiKey: "test-xai-token").makeSpeakerNamesRequest(
            transcript: transcript,
            callTitle: "Maya sync",
            defaults: defaults
        )
        let openAIBody = try jsonBody(openAI)
        let grokBody = try jsonBody(grok)
        let openAIMessages = try messages(in: openAIBody)
        let grokMessages = try messages(in: grokBody)
        XCTAssertEqual(openAIMessages.first?["content"] as? String, custom)
        XCTAssertEqual(grokMessages.first?["content"] as? String, custom)
        XCTAssertEqual(openAIBody["model"] as? String, "gpt-5-mini")
        XCTAssertNil(openAIBody["reasoning_effort"])
        XCTAssertNil(openAIBody["search_parameters"])
        XCTAssertEqual(grokBody["model"] as? String, "grok-4.7")
        XCTAssertEqual(grokBody["reasoning_effort"] as? String, "high")
        XCTAssertNil(grokBody["search_parameters"])
    }

    func testRestoreAndEmptyReturnToDefaults() {
        AIPromptStore.set(.meetingMemorySystem, text: "Custom notes.", defaults: defaults)
        AIPromptStore.set(.speakerIdentificationSystem, text: "Custom names.", defaults: defaults)
        XCTAssertEqual(AIPromptStore.effective(.meetingMemorySystem, defaults: defaults), "Custom notes.")

        AIPromptStore.restore(.meetingMemorySystem, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: AIPromptStore.Prompt.meetingMemorySystem.defaultsKey))
        XCTAssertEqual(
            AIPromptStore.effective(.meetingMemorySystem, defaults: defaults),
            AIPromptStore.Prompt.meetingMemorySystem.defaultText
        )
        XCTAssertEqual(AIPromptStore.effective(.speakerIdentificationSystem, defaults: defaults), "Custom names.")

        AIPromptStore.set(.speakerIdentificationSystem, text: "   \n", defaults: defaults)
        XCTAssertNil(defaults.string(forKey: AIPromptStore.Prompt.speakerIdentificationSystem.defaultsKey))
        XCTAssertEqual(
            AIPromptStore.effective(.speakerIdentificationSystem, defaults: defaults),
            "You attach real names to diarized speaker labels. You never guess."
        )

        AIPromptStore.set(.meetingMemoryUser, text: "Only this. {{transcript}}", defaults: defaults)
        AIPromptStore.set(.speakerIdentificationUser, text: "Name them. {{transcript}}", defaults: defaults)
        AIPromptStore.restoreAll(defaults: defaults)
        XCTAssertEqual(
            AIPromptStore.effective(.meetingMemoryUser, defaults: defaults),
            AIPromptStore.Prompt.meetingMemoryUser.defaultText
        )
        XCTAssertEqual(
            AIPromptStore.effective(.speakerIdentificationUser, defaults: defaults),
            AIPromptStore.Prompt.speakerIdentificationUser.defaultText
        )
        XCTAssertEqual(
            AIPromptStore.meetingMemoryUser(transcript: "[Ada] Hello.", callTitle: "Launch", defaults: defaults),
            historicalMeetingMemoryUser(transcript: "[Ada] Hello.", callTitle: "Launch")
        )
    }

    func testSavingTheBuiltInDefaultLeavesTheStoreUnset() {
        for prompt in AIPromptStore.Prompt.allCases {
            AIPromptStore.set(prompt, text: prompt.defaultText, defaults: defaults)
            XCTAssertNil(defaults.string(forKey: prompt.defaultsKey))
            XCTAssertEqual(AIPromptStore.effective(prompt, defaults: defaults), prompt.defaultText)
        }
    }

    func testPlaceholderSubstitutionInsertsTranscriptTitleAndLabels() {
        let transcript = "[Speaker A] I'm Maya.\n[Speaker 0] Thanks Maya."
        AIPromptStore.set(
            .speakerIdentificationUser,
            text: "Labels {{speakerLabels}}. Title {{callTitle}}. Body {{transcript}}.",
            defaults: defaults
        )
        XCTAssertEqual(
            AIPromptStore.speakerIdentificationUser(
                transcript: transcript,
                callTitle: "  Maya sync  ",
                labels: ["Speaker A", "Speaker 0"],
                defaults: defaults
            ),
            "Labels Speaker A, Speaker 0. Title Maya sync. Body \(transcript)."
        )

        AIPromptStore.set(
            .meetingMemoryUser,
            text: "Title {{callTitle}}\n{{transcript}}",
            defaults: defaults
        )
        XCTAssertEqual(
            AIPromptStore.meetingMemoryUser(transcript: transcript, callTitle: "Launch", defaults: defaults),
            "Title Launch\n\(transcript)"
        )
        XCTAssertEqual(
            AIPromptStore.meetingMemoryUser(transcript: transcript, callTitle: nil, defaults: defaults),
            "Title none\n\(transcript)"
        )
    }

    func testInsertedTranscriptIsNotScannedForPlaceholders() {
        let transcript = "Keep {{callTitle}} and {{transcript}} literal."
        AIPromptStore.set(
            .meetingMemoryUser,
            text: "Title {{callTitle}}\n{{transcript}}",
            defaults: defaults
        )
        XCTAssertEqual(
            AIPromptStore.meetingMemoryUser(transcript: transcript, callTitle: "Launch", defaults: defaults),
            "Title Launch\n\(transcript)"
        )
    }

    func testMissingTranscriptPlaceholderStillSendsTheTranscript() throws {
        let transcript = "[Ada] The distinguishing line is blue heron."
        AIPromptStore.set(
            .meetingMemoryUser,
            text: "Write notes. Suggested title from the call window: {{callTitle}}.",
            defaults: defaults
        )
        let openAI = try OpenAIService(apiKey: "test-openai-key").makeInsightsRequest(
            transcript: transcript,
            callTitle: "Launch",
            defaults: defaults
        )
        let grok = try GrokService(apiKey: "test-xai-token").makeInsightsRequest(
            transcript: transcript,
            callTitle: "Launch",
            defaults: defaults
        )
        for request in [openAI, grok] {
            let user = try userContent(in: try jsonBody(request))
            XCTAssertFalse(user.contains("{{transcript}}"))
            XCTAssertTrue(user.contains(transcript))
            XCTAssertTrue(user.contains("Launch"))
            XCTAssertTrue(user.contains("Transcript:\n\(transcript)"))
        }

        AIPromptStore.set(.speakerIdentificationUser, text: "Name them carefully.", defaults: defaults)
        let body = SpeakerNames.requestBody(
            model: "grok-4.7",
            reasoningEffort: "high",
            transcript: transcript,
            callTitle: "Launch",
            defaults: defaults
        )
        let user = try userContent(in: body)
        XCTAssertTrue(user.contains(transcript))
        XCTAssertTrue(user.contains("Speaker labels: Ada"))
        XCTAssertTrue(user.contains("Meeting title: Launch"))
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        XCTAssertNil(body["search_parameters"])
        let schema = ((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
        XCTAssertEqual(schema?["name"] as? String, "speaker_names")
    }

    func testCustomInstructionTemplateIsWhatBothProvidersSend() throws {
        let template = "Custom notes for {{callTitle}}.\n{{transcript}}"
        AIPromptStore.set(.meetingMemoryUser, text: template, defaults: defaults)
        let transcript = "[Ada] Ship the notes."
        let openAI = try OpenAIService(apiKey: "test-openai-key").makeInsightsRequest(
            transcript: transcript,
            callTitle: "Launch",
            defaults: defaults
        )
        let grok = try GrokService(apiKey: "test-xai-token").makeInsightsRequest(
            transcript: transcript,
            callTitle: "Launch",
            defaults: defaults
        )
        for request in [openAI, grok] {
            XCTAssertEqual(
                try userContent(in: try jsonBody(request)),
                "Custom notes for Launch.\n\(transcript)"
            )
        }
    }

    func testMissingCallTitlePlaceholderStillSendsTheTitle() {
        AIPromptStore.set(.meetingMemoryUser, text: "Notes:\n{{transcript}}", defaults: defaults)
        let rendered = AIPromptStore.meetingMemoryUser(
            transcript: "[Ada] Hello.",
            callTitle: "Launch",
            defaults: defaults
        )
        XCTAssertTrue(rendered.contains("[Ada] Hello."))
        XCTAssertTrue(rendered.contains("Meeting title: Launch"))
        XCTAssertFalse(rendered.contains("{{callTitle}}"))
        XCTAssertFalse(rendered.contains("{{transcript}}"))
    }

    private func historicalMeetingMemoryUser(transcript: String, callTitle: String?) -> String {
        let title = callTitle ?? "none"
        return """
        Turn this meeting transcript into concise, factual meeting memory. Infer participant names only when the transcript explicitly supports them. Never invent names, owners, dates, or decisions. Return JSON matching the provided schema. Suggested title from the call window: \(title).

        Lines begin with a bracketed speaker label. When that label is a person's name, use it for participants, decisions, and next-step owners.

        For "aiNotes", write markdown notes the way a sharp human note-taker would capture the call as it happened: short "## " section headers that follow the conversation's actual topics, tight "- " bullet fragments underneath (not full prose sentences), with concrete specifics preserved — names, numbers, prices, tools, dates, and memorable quotes worth keeping. Bold the load-bearing terms. Keep it scannable; no filler, no meta commentary about the transcript.

        For "summary", write 2-3 plain sentences of what the call was about and where it landed.

        Transcript:
        \(transcript)
        """
    }

    private func historicalSpeakerUser(transcript: String, callTitle: String?, labels: [String]) -> String {
        let trimmed = callTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let titleLine = trimmed.isEmpty ? "none" : trimmed
        return """
        Identify the real name of each diarized speaker. The transcript labels speakers as \(labels.joined(separator: ", ")). Use a name only when the transcript explicitly supports it: someone introduces themselves, another speaker addresses them by name, or the meeting title names them. Never invent a name. If a speaker's name is not supported, return null. Return one entry for every label, using the label text exactly.

        Meeting title: \(titleLine)

        Transcript:
        \(transcript)
        """
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func messages(in body: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(body["messages"] as? [[String: Any]])
    }

    private func userContent(in body: [String: Any]) throws -> String {
        try XCTUnwrap(try messages(in: body).last?["content"] as? String)
    }
}
