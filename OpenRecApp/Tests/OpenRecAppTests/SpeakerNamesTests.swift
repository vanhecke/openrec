import Foundation
import XCTest
@testable import OpenRecApp

final class SpeakerNamesTests: XCTestCase {
    private let diarized = """
    [Speaker A] Hi, I'm Maya.
    [Speaker B] Thanks Maya. I'm Jordan.
    [Speaker 0] Maya, we should ship on Friday.
    [Speaker 1] I agree with Jordan.
    [Speaker] Someone joined late.
    Speaker A already agreed.
    """

    func testApplyReplacesAssemblyAIAndGrokLabelsWithoutTouchingTheSentence() {
        let named = SpeakerNames.apply(
            [
                "Speaker A": "Maya",
                "Speaker B": "Jordan",
                "Speaker 0": "Maya",
                "Speaker 1": "  ",
                "Speaker": "Speaker",
            ],
            to: diarized
        )

        XCTAssertEqual(
            named,
            """
            [Maya] Hi, I'm Maya.
            [Jordan] Thanks Maya. I'm Jordan.
            [Maya] Maya, we should ship on Friday.
            [Speaker 1] I agree with Jordan.
            [Speaker] Someone joined late.
            Speaker A already agreed.
            """
        )
        XCTAssertEqual(SpeakerNames.apply([:], to: diarized), diarized)
        XCTAssertEqual(
            SpeakerNames.speakerLabels(in: diarized),
            ["Speaker A", "Speaker B", "Speaker 0", "Speaker 1", "Speaker"]
        )
    }

    func testAcceptedMappingKeepsSupportedNamesAndDropsInventions() throws {
        let content = """
        {"speakers":[
          {"label":"Speaker A","name":"Maya"},
          {"label":"speaker b","name":"Jordan."},
          {"label":"Speaker 0","name":"Alexandra"},
          {"label":"Speaker 1","name":null},
          {"label":"Speaker","name":"Speaker"},
          {"label":"Nobody","name":"Maya"},
          {"label":"Speaker A","name":"Ann"}
        ]}
        """

        let mapping = SpeakerNames.acceptedMapping(
            from: content,
            labels: SpeakerNames.speakerLabels(in: diarized),
            transcript: diarized,
            callTitle: "Launch"
        )

        XCTAssertEqual(mapping, ["Speaker A": "Maya", "Speaker B": "Jordan"])
        XCTAssertNil(mapping["Speaker 0"])
        XCTAssertFalse(mapping.values.contains("Ann"))
        XCTAssertFalse(mapping.values.contains("Alexandra"))

        let anniversary = "[Speaker A] The anniversary is Friday."
        XCTAssertEqual(
            SpeakerNames.acceptedMapping(
                from: #"{"speakers":[{"label":"Speaker A","name":"Ann"}]}"#,
                labels: ["Speaker A"],
                transcript: anniversary,
                callTitle: nil
            ),
            [:]
        )
    }

    func testMeetingTitleCanSupplyANameTheTranscriptNeverSays() {
        let transcript = "[Speaker A] Let's start."
        let mapping = SpeakerNames.acceptedMapping(
            from: #"{"speakers":[{"label":"Speaker A","name":"Priya"}]}"#,
            labels: ["Speaker A"],
            transcript: transcript,
            callTitle: "Weekly with Priya"
        )

        XCTAssertEqual(mapping, ["Speaker A": "Priya"])
        XCTAssertEqual(
            SpeakerNames.acceptedMapping(
                from: #"{"speakers":[{"label":"Speaker A","name":"Priya"}]}"#,
                labels: ["Speaker A"],
                transcript: transcript,
                callTitle: "Weekly sync"
            ),
            [:]
        )
    }

    func testFencedCompletionStillDecodesSpeakerNames() throws {
        let fenced = """
        ```json
        {"speakers":[{"label":"Speaker 0","name":"Maya"},{"label":"Speaker 1","name":"Jordan"}]}
        ```
        """
        let transcript = """
        [Speaker 0] I'm Maya.
        [Speaker 1] Thanks, Jordan.
        """
        let completion = #"{"choices":[{"message":{"content":\#(jsonString(fenced))}}]}"#
        let mapping = try SpeakerNames.mapping(
            fromCompletion: Data(completion.utf8),
            labels: ["Speaker 0", "Speaker 1"],
            transcript: transcript,
            callTitle: nil
        )

        XCTAssertEqual(mapping, ["Speaker 0": "Maya", "Speaker 1": "Jordan"])
    }

    func testNamedTranscriptIsWhatBothMeetingMemoryProvidersSend() throws {
        let named = SpeakerNames.apply(
            ["Speaker A": "Maya", "Speaker 0": "Jordan"],
            to: """
            [Speaker A] We should ship on Friday.
            [Speaker 0] I will send the notes.
            [Speaker B] Speaker A already agreed.
            """
        )
        let openAI = try OpenAIService(apiKey: "test-openai-key").makeInsightsRequest(
            transcript: named,
            callTitle: "Launch"
        )
        let grok = try GrokService(apiKey: "test-xai-token").makeInsightsRequest(
            transcript: named,
            callTitle: "Launch"
        )

        let openAIBody = try jsonBody(openAI)
        let grokBody = try jsonBody(grok)
        for body in [openAIBody, grokBody] {
            let serialized = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
            XCTAssertTrue(serialized.contains("[Maya]"))
            XCTAssertTrue(serialized.contains("[Jordan]"))
            XCTAssertTrue(serialized.contains("Speaker A already agreed."))
            XCTAssertFalse(serialized.contains("[Speaker A]"))
            XCTAssertFalse(serialized.contains("[Speaker 0]"))
            XCTAssertTrue(serialized.contains("When that label is a person's name"))
            XCTAssertNil(body["search_parameters"])
        }

        XCTAssertEqual(openAI.url?.host, "api.openai.com")
        XCTAssertEqual(openAIBody["model"] as? String, "gpt-5-mini")
        XCTAssertNil(openAIBody["reasoning_effort"])
        XCTAssertEqual(grok.url?.host, "api.x.ai")
        XCTAssertEqual(grokBody["model"] as? String, "grok-4.7")
        XCTAssertEqual(grokBody["reasoning_effort"] as? String, "high")
    }

    func testSpeakerNameRequestsUseTheMeetingMemoryModels() throws {
        let transcript = "[Speaker A] Hi, I'm Maya.\n[Speaker 0] Thanks Maya."
        let openAI = try OpenAIService(apiKey: "test-openai-key").makeSpeakerNamesRequest(
            transcript: transcript,
            callTitle: "Maya sync"
        )
        let grok = try GrokService(apiKey: "test-xai-token").makeSpeakerNamesRequest(
            transcript: transcript,
            callTitle: "Maya sync"
        )
        let openAIBody = try jsonBody(openAI)
        let grokBody = try jsonBody(grok)

        XCTAssertEqual(openAI.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(openAIBody["model"] as? String, "gpt-5-mini")
        XCTAssertNil(openAIBody["reasoning_effort"])
        XCTAssertNil(openAIBody["search_parameters"])
        XCTAssertEqual(grok.url?.absoluteString, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(grokBody["model"] as? String, "grok-4.7")
        XCTAssertEqual(grokBody["reasoning_effort"] as? String, "high")
        XCTAssertNil(grokBody["search_parameters"])

        let schema = (openAIBody["response_format"] as? [String: Any])?["json_schema"] as? [String: Any]
        let schemaName = schema?["name"] as? String
        let schemaIsStrict = schema?["strict"] as? Bool
        XCTAssertEqual(schemaName, "speaker_names")
        XCTAssertEqual(schemaIsStrict, true)
        let prompt = ((openAIBody["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
        XCTAssertTrue(prompt.contains("Speaker A"))
        XCTAssertTrue(prompt.contains("Speaker 0"))
        XCTAssertTrue(prompt.contains("Maya sync"))
        XCTAssertFalse(prompt.contains("test-openai-key"))
        let grokSerialized = String(data: try bodyData(grok), encoding: .utf8) ?? ""
        XCTAssertFalse(grokSerialized.contains("test-xai-token"))
    }

    func testMeetingRecordKeepsSpeakerNamesAndStillDecodesOlderRecords() throws {
        var record = makeRecord(transcript: "[Speaker A] Hi, I'm Maya.")
        record.speakerNames = ["Speaker A": "Maya"]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(MeetingRecord.self, from: encoder.encode(record))
        XCTAssertEqual(decoded.speakerNames, ["Speaker A": "Maya"])

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        object.removeValue(forKey: "speakerNames")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let older = try decoder.decode(MeetingRecord.self, from: legacy)
        XCTAssertNil(older.speakerNames)

        var remote = older
        remote.speakerNames = nil
        var local = older
        local.speakerNames = ["Speaker 0": "Jordan"]
        XCTAssertEqual(remote.withSpeakerNamesPreserved(from: local).speakerNames, ["Speaker 0": "Jordan"])
        local.speakerNames = nil
        remote.speakerNames = ["Speaker A": "Maya"]
        XCTAssertEqual(remote.withSpeakerNamesPreserved(from: local).speakerNames, ["Speaker A": "Maya"])

        XCTAssertEqual(
            MeetingClipboardText.transcript(for: decoded),
            "[Maya] Hi, I'm Maya."
        )
    }

    func testUserNamesRejectBracketsAndBlankValues() {
        XCTAssertEqual(SpeakerNames.normalizedUserName("  Maya   Chen "), "Maya Chen")
        XCTAssertNil(SpeakerNames.normalizedUserName("   "))
        XCTAssertNil(SpeakerNames.normalizedUserName("Maya [guest]"))
        XCTAssertNil(SpeakerNames.normalizedUserName(String(repeating: "a", count: 81)))
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let body = try bodyData(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            XCTFail("Expected an HTTP body")
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1024)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let encoded = String(data: data, encoding: .utf8)!
        return String(encoded.dropFirst().dropLast())
    }

    private func makeRecord(transcript: String) -> MeetingRecord {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return MeetingRecord(
            id: UUID(uuidString: "B8E17C31-12A5-4C0A-9BC7-573E180DB52E")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            durationSeconds: 60,
            callApp: "Google Chrome",
            callTitle: "Weekly with Maya",
            transcript: transcript,
            insights: MeetingInsights(title: "Weekly"),
            hasScreenRecording: false,
            hasAudioRecording: true,
            screenFileExtension: nil,
            audioFileExtension: "m4a",
            localScreenPath: nil,
            localAudioPath: nil,
            storageMode: .local,
            preferences: CallPreferences(),
            saveStatus: .saved,
            saveStage: .complete,
            errorMessage: nil,
            createdAt: startedAt,
            updatedAt: startedAt
        )
    }
}
