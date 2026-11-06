import Foundation
import XCTest
@testable import OpenRecApp

final class GrokServiceTests: XCTestCase {
    private let apiKey = "test-xai-token"
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokMockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        GrokMockURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        try super.tearDownWithError()
    }

    func testValidationRequestChecksTheGrokModelOnXAI() throws {
        let request = try GrokService(apiKey: "  \(apiKey)\n").makeValidationRequest()

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "api.x.ai")
        XCTAssertEqual(request.url?.path, "/v1/models/grok-4.3")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        XCTAssertFalse(request.url?.absoluteString.contains(apiKey) == true)
        XCTAssertFalse(request.url?.host == "api.openai.com")
    }

    func testInsightsRequestUsesStructuredMeetingInsightsSchema() throws {
        let request = try GrokService(apiKey: apiKey).makeInsightsRequest(
            transcript: "[Ada] Ship it Friday.",
            callTitle: "Launch"
        )
        let body = try JSONSerialization.jsonObject(with: try bodyData(from: request)) as? [String: Any]
        let responseFormat = body?["response_format"] as? [String: Any]
        let schema = responseFormat?["json_schema"] as? [String: Any]
        let inner = schema?["schema"] as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]]

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(body?["model"] as? String, "grok-4.3")
        XCTAssertEqual(body?["reasoning_effort"] as? String, "low")
        XCTAssertNil(body?["search_parameters"])
        XCTAssertEqual(responseFormat?["type"] as? String, "json_schema")
        XCTAssertEqual(schema?["name"] as? String, "meeting_insights")
        XCTAssertEqual(schema?["strict"] as? Bool, true)
        XCTAssertEqual(
            inner?["required"] as? [String],
            ["title", "summary", "aiNotes", "participants", "actionItems", "decisions"]
        )
        XCTAssertEqual(messages?.count, 2)
        XCTAssertTrue((messages?.last?["content"] as? String)?.contains("Launch") == true)
        XCTAssertFalse(request.url?.absoluteString.contains(apiKey) == true)
        let serialized = String(data: try bodyData(from: request), encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains(apiKey))
    }

    func testEmptyKeyDoesNotReachTheNetwork() async {
        GrokMockURLProtocol.handler = { _ in
            XCTFail("An empty Grok key must not make a request")
            throw URLError(.badServerResponse)
        }
        let service = GrokService(apiKey: "   ", session: session)

        do {
            try await service.validateAccess()
            XCTFail("Expected an empty key to fail before the network")
        } catch let error as OpenRecError {
            guard case .invalidConfiguration = error else {
                return XCTFail("Expected invalidConfiguration, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testValidateAccessAcceptsAModelResponseAndRejectsAnIncorrectKey() async throws {
        let service = GrokService(apiKey: apiKey, session: session)
        GrokMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.x.ai")
            return (
                Self.response(url: try XCTUnwrap(request.url)),
                Data(#"{"id":"grok-4.3","object":"model"}"#.utf8)
            )
        }
        try await service.validateAccess()

        GrokMockURLProtocol.handler = { request in
            (
                Self.response(url: try XCTUnwrap(request.url), statusCode: 400),
                Data(#"{"code":"invalid-argument","error":"Incorrect API key provided."}"#.utf8)
            )
        }
        do {
            try await service.validateAccess()
            XCTFail("Expected a rejected key")
        } catch let error as OpenRecError {
            guard case .requestFailed(let status, let message) = error else {
                return XCTFail("Expected requestFailed, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(message.contains("Incorrect API key"))
            XCTAssertFalse(message.contains(apiKey))
            XCTAssertTrue(GrokService.isCredentialOrModelAccessFailure(error))
        }
    }

    func testRateLimitDoesNotCountAsACredentialFailure() async {
        GrokMockURLProtocol.handler = { request in
            (
                Self.response(url: try XCTUnwrap(request.url), statusCode: 429),
                Data(#"{"error":"Rate limited"}"#.utf8)
            )
        }
        let service = GrokService(apiKey: apiKey, session: session)

        do {
            try await service.validateAccess()
            XCTFail("Expected a rate limit")
        } catch {
            XCTAssertFalse(GrokService.isCredentialOrModelAccessFailure(error))
        }
    }

    func testGenerateInsightsDecodesTheMeetingInsightsShape() async throws {
        GrokMockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: try Self.bodyData(from: request)) as? [String: Any]
            XCTAssertEqual(request.url?.host, "api.x.ai")
            XCTAssertNotEqual(request.url?.host, "api.openai.com")
            XCTAssertEqual(body?["model"] as? String, "grok-4.3")
            return (
                Self.response(url: try XCTUnwrap(request.url)),
                Self.completion(Self.insightsJSON)
            )
        }
        let insights = try await GrokService(apiKey: apiKey, session: session).generateInsights(
            transcript: "[Ada] Ship the notes Friday.",
            callTitle: "Launch"
        )

        XCTAssertEqual(insights.title, "Ship the notes")
        XCTAssertEqual(insights.summary, "The team agreed to ship.")
        XCTAssertEqual(insights.aiNotes, "## Ship\n- **Friday**")
        XCTAssertEqual(insights.participants, ["Ada"])
        XCTAssertEqual(insights.decisions, ["Ship Friday"])
        XCTAssertEqual(insights.actionItems.count, 1)
        XCTAssertEqual(insights.actionItems[0].owner, "Ada")
        XCTAssertEqual(insights.actionItems[0].task, "Write the notes")
        XCTAssertNil(insights.actionItems[0].dueDate)
    }

    func testFencedJSONStillDecodesIntoMeetingInsights() async throws {
        let fenced = "```json\n\(Self.insightsJSON)\n```"
        GrokMockURLProtocol.handler = { request in
            (
                Self.response(url: try XCTUnwrap(request.url)),
                Self.completion(fenced)
            )
        }

        let insights = try await GrokService(apiKey: apiKey, session: session).generateInsights(
            transcript: "notes",
            callTitle: nil
        )

        XCTAssertEqual(insights.title, "Ship the notes")
        XCTAssertEqual(insights.participants, ["Ada"])
    }

    func testDiarizedWordsGroupIntoConsecutiveSpeakerTurns() throws {
        let response = GrokSTTResponse(
            text: "Morning. Let's ship it. Agreed.",
            duration: 2.8,
            words: [
                GrokSTTWord(text: "Morning.", start: 0.25, end: 0.6, speaker: 0),
                GrokSTTWord(text: "Let's", start: 1.25, end: 1.45, speaker: 1),
                GrokSTTWord(text: "ship", start: 1.45, end: 1.7, speaker: 1),
                GrokSTTWord(text: "it.", start: 1.7, end: 2.0, speaker: 1),
                GrokSTTWord(text: "Agreed.", start: 2.4, end: 2.8, speaker: 0),
            ]
        )

        let segments = try GrokTranscriptMapper.displaySegments(from: response)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].speakerLabel, "Speaker 0")
        XCTAssertEqual(segments[0].text, "Morning.")
        XCTAssertEqual(try XCTUnwrap(segments[0].timestamp), 0.25, accuracy: 0.000_001)
        XCTAssertEqual(segments[1].speakerLabel, "Speaker 1")
        XCTAssertEqual(segments[1].text, "Let's ship it.")
        XCTAssertEqual(try XCTUnwrap(segments[1].timestamp), 1.25, accuracy: 0.000_001)
        XCTAssertEqual(segments[2].speakerLabel, "Speaker 0")
        XCTAssertEqual(segments[2].text, "Agreed.")
        XCTAssertEqual(try XCTUnwrap(segments[2].timestamp), 2.4, accuracy: 0.000_001)
    }

    func testMissingSpeakerAndEmptyTranscriptFollowTheDisplayShape() throws {
        let unlabeled = GrokSTTResponse(
            text: "Hello there.",
            duration: 1,
            words: [
                GrokSTTWord(text: "Hello", start: 0.1, end: 0.3, speaker: nil),
                GrokSTTWord(text: " ", start: 0.3, end: 0.31, speaker: nil),
                GrokSTTWord(text: "there.", start: 0.31, end: 0.6, speaker: nil),
            ]
        )
        let textOnly = GrokSTTResponse(text: "A transcript without words.", duration: 1, words: nil)
        let silent = GrokSTTResponse(text: "  ", duration: 0, words: [])

        let unlabeledSegments = try GrokTranscriptMapper.displaySegments(from: unlabeled)
        XCTAssertEqual(unlabeledSegments.count, 1)
        XCTAssertEqual(unlabeledSegments[0].speakerLabel, "Speaker")
        XCTAssertEqual(unlabeledSegments[0].text, "Hello there.")

        let fallback = try GrokTranscriptMapper.displaySegments(from: textOnly)
        XCTAssertEqual(fallback.count, 1)
        XCTAssertEqual(fallback[0].speakerLabel, "Conversation")
        XCTAssertEqual(fallback[0].text, "A transcript without words.")

        XCTAssertThrowsError(try GrokTranscriptMapper.displaySegments(from: silent)) { error in
            guard case OpenRecError.noSpeechDetected = error else {
                return XCTFail("Expected noSpeechDetected, got \(error)")
            }
        }
    }

    func testFileTranscriptionRequestIsMultipartDiarizedSTT() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokSTT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("call.m4a")
        let audio = Data("not-a-real-recording".utf8)
        try audio.write(to: audioURL)

        let request = try GrokService(apiKey: "  \(apiKey)\n").makeTranscriptionRequest(fileURL: audioURL)
        let body = try bodyData(from: request)
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.x.ai/v1/stt")
        XCTAssertNotEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        XCTAssertTrue(body.range(of: Data("name=\"model\"".utf8)) != nil)
        XCTAssertTrue(body.range(of: Data("grok-voice-transcribe-2.0".utf8)) != nil)
        XCTAssertTrue(body.range(of: Data("name=\"diarize\"".utf8)) != nil)
        XCTAssertTrue(body.range(of: Data("true".utf8)) != nil)
        XCTAssertTrue(body.range(of: Data("name=\"file\"; filename=\"call.m4a\"".utf8)) != nil)
        XCTAssertTrue(body.range(of: Data("Content-Type: audio/mp4".utf8)) != nil)
        XCTAssertTrue(body.range(of: audio) != nil)
        let model = try XCTUnwrap(body.range(of: Data("name=\"model\"".utf8)))
        let file = try XCTUnwrap(body.range(of: Data("name=\"file\"".utf8)))
        XCTAssertLessThan(model.lowerBound, file.lowerBound)
        XCTAssertFalse(body.range(of: Data(apiKey.utf8)) != nil)
        XCTAssertFalse(request.url?.absoluteString.contains("api.openai.com") == true)
        XCTAssertFalse(request.url?.absoluteString.contains("assemblyai.com") == true)
    }

    func testURLTranscriptionRequestSendsTheRemoteURLWithoutAFilePart() throws {
        let audioURL = try XCTUnwrap(URL(string: "https://example.com/calls/audio.m4a?sig=1"))
        let request = try GrokService(apiKey: apiKey).makeTranscriptionRequest(audioURL: audioURL)
        let body = try bodyData(from: request)

        XCTAssertEqual(request.url?.absoluteString, "https://api.x.ai/v1/stt")
        XCTAssertTrue(body.range(of: Data("name=\"url\"".utf8)) != nil)
        XCTAssertTrue(body.range(of: Data(audioURL.absoluteString.utf8)) != nil)
        XCTAssertTrue(body.range(of: Data("name=\"diarize\"".utf8)) != nil)
        XCTAssertNil(body.range(of: Data("name=\"file\"".utf8)))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
    }

    func testFileAutoDetectOmitsLanguageAndFormat() throws {
        let audioURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }

        let request = try GrokService(apiKey: apiKey).makeTranscriptionRequest(fileURL: audioURL)
        let body = try bodyData(from: request)

        XCTAssertEqual(request.url?.absoluteString, "https://api.x.ai/v1/stt")
        assertField("model", equals: "grok-voice-transcribe-2.0", in: body)
        assertField("diarize", equals: "true", in: body)
        assertAbsent("language", in: body)
        assertAbsent("format", in: body)
        assertFieldOrder(["model", "diarize", "file"], in: body)
        assertLastMultipartField(named: "file", in: body)
    }

    func testFileEnglishSendsLanguageAndFormatWithFileLast() throws {
        let audioURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }

        let request = try GrokService(apiKey: apiKey).makeTranscriptionRequest(
            fileURL: audioURL,
            language: .english
        )
        let body = try bodyData(from: request)

        assertField("model", equals: "grok-voice-transcribe-2.0", in: body)
        assertField("diarize", equals: "true", in: body)
        assertField("language", equals: "en", in: body)
        assertField("format", equals: "true", in: body)
        assertFieldOrder(["model", "diarize", "language", "format", "file"], in: body)
        assertLastMultipartField(named: "file", in: body)
    }

    func testFileThaiSendsLanguageAndFormatEvenThoughFormattingIsANoOp() throws {
        let audioURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }

        let body = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                fileURL: audioURL,
                language: .thai
            )
        )

        assertField("language", equals: "th", in: body)
        assertField("format", equals: "true", in: body)
        assertField("model", equals: "grok-voice-transcribe-2.0", in: body)
        assertField("diarize", equals: "true", in: body)
        assertLastMultipartField(named: "file", in: body)
    }

    func testEmptyFileIsStillRejectedWhenALanguageIsChosen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokSTT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("empty.m4a")
        try Data().write(to: audioURL)

        XCTAssertThrowsError(
            try GrokService(apiKey: apiKey).makeTranscriptionRequest(fileURL: audioURL, language: .english)
        ) { error in
            guard case OpenRecError.recordingFailed = error else {
                return XCTFail("Expected recordingFailed, got \(error)")
            }
        }
    }

    func testURLAutoDetectOmitsLanguageAndFormat() throws {
        let audioURL = try XCTUnwrap(URL(string: "https://example.com/calls/audio.m4a?sig=1"))
        let body = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(audioURL: audioURL)
        )

        assertField("model", equals: "grok-voice-transcribe-2.0", in: body)
        assertField("diarize", equals: "true", in: body)
        assertField("url", equals: audioURL.absoluteString, in: body)
        assertAbsent("language", in: body)
        assertAbsent("format", in: body)
        assertAbsent("file", in: body)
        assertFieldOrder(["model", "diarize", "url"], in: body)
        assertLastMultipartField(named: "url", in: body)
    }

    func testURLEnglishSendsLanguageAndFormat() throws {
        let audioURL = try XCTUnwrap(URL(string: "https://example.com/calls/audio.m4a?sig=1"))
        let body = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                audioURL: audioURL,
                language: .english
            )
        )

        assertField("language", equals: "en", in: body)
        assertField("format", equals: "true", in: body)
        assertField("url", equals: audioURL.absoluteString, in: body)
        assertField("model", equals: "grok-voice-transcribe-2.0", in: body)
        assertField("diarize", equals: "true", in: body)
        assertAbsent("file", in: body)
        assertFieldOrder(["model", "diarize", "language", "format", "url"], in: body)
        assertLastMultipartField(named: "url", in: body)
    }

    func testURLThaiSendsLanguageAndFormatEvenThoughFormattingIsANoOp() throws {
        let audioURL = try XCTUnwrap(URL(string: "https://example.com/calls/audio.m4a"))
        let body = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                audioURL: audioURL,
                language: .thai
            )
        )

        assertField("language", equals: "th", in: body)
        assertField("format", equals: "true", in: body)
        assertField("url", equals: audioURL.absoluteString, in: body)
        assertLastMultipartField(named: "url", in: body)
        assertAbsent("file", in: body)
    }

    func testMissingLanguagePreferenceIsAutoDetectAndRoundTrips() throws {
        let suite = "OpenRecGrokLanguage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(defaults.string(forKey: GrokTranscriptionLanguage.defaultsKey))
        XCTAssertEqual(GrokTranscriptionLanguage.resolved(from: nil), .autoDetect)
        XCTAssertEqual(GrokTranscriptionLanguage.resolved(from: ""), .autoDetect)
        XCTAssertEqual(GrokTranscriptionLanguage.resolved(from: "es-MX"), .autoDetect)
        XCTAssertEqual(GrokTranscriptionLanguage.stored(in: defaults), .autoDetect)
        XCTAssertNil(GrokTranscriptionLanguage.autoDetect.languageCode)

        GrokTranscriptionLanguage.english.store(in: defaults)
        XCTAssertEqual(defaults.string(forKey: GrokTranscriptionLanguage.defaultsKey), "en")
        XCTAssertEqual(GrokTranscriptionLanguage.stored(in: defaults), .english)
        XCTAssertEqual(GrokTranscriptionLanguage.stored(in: defaults).languageCode, "en")

        let audioURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }
        let chosen = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                fileURL: audioURL,
                language: GrokTranscriptionLanguage.stored(in: defaults)
            )
        )
        assertField("language", equals: "en", in: chosen)
        assertField("format", equals: "true", in: chosen)
        assertLastMultipartField(named: "file", in: chosen)

        GrokTranscriptionLanguage.autoDetect.store(in: defaults)
        XCTAssertEqual(defaults.string(forKey: GrokTranscriptionLanguage.defaultsKey), "auto")
        XCTAssertEqual(GrokTranscriptionLanguage.stored(in: defaults), .autoDetect)
        let restoredURL = try XCTUnwrap(URL(string: "https://example.com/audio.m4a"))
        let restored = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                audioURL: restoredURL,
                language: GrokTranscriptionLanguage.stored(in: defaults)
            )
        )
        assertAbsent("language", in: restored)
        assertAbsent("format", in: restored)
        assertField("model", equals: "grok-voice-transcribe-2.0", in: restored)
        assertField("diarize", equals: "true", in: restored)
        assertField("url", equals: restoredURL.absoluteString, in: restored)
    }

    func testEmptyKeyTermsOmitTheField() throws {
        let audioURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }

        let explicit = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                fileURL: audioURL,
                keyTerms: []
            )
        )
        assertField("model", equals: "grok-voice-transcribe-2.0", in: explicit)
        assertField("diarize", equals: "true", in: explicit)
        assertAbsent("keyterm", in: explicit)
        assertAbsent("language", in: explicit)
        assertAbsent("format", in: explicit)
        assertAbsent("filler_words", in: explicit)
        assertAbsent("vad_threshold", in: explicit)
        assertFieldOrder(["model", "diarize", "file"], in: explicit)
        assertLastMultipartField(named: "file", in: explicit)

        let defaulted = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(fileURL: audioURL)
        )
        assertAbsent("keyterm", in: defaulted)
        assertLastMultipartField(named: "file", in: defaulted)
    }

    func testSingleKeyTermIsSentAndFileStaysLast() throws {
        let audioURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }

        let body = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                fileURL: audioURL,
                keyTerms: ["Understand The Universe"]
            )
        )

        XCTAssertEqual(multipartFieldValues(named: "keyterm", in: body), ["Understand The Universe"])
        assertField("keyterm", equals: "Understand The Universe", in: body)
        assertField("model", equals: "grok-voice-transcribe-2.0", in: body)
        assertField("diarize", equals: "true", in: body)
        assertAbsent("language", in: body)
        assertAbsent("format", in: body)
        assertFieldOrder(["model", "diarize", "keyterm", "file"], in: body)
        assertLastMultipartField(named: "file", in: body)
    }

    func testRepeatedKeyTermsPreserveSpaces() throws {
        let audioURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }
        let terms = ["Understand The Universe", "OpenRec", "Q&A Bot"]

        let body = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                fileURL: audioURL,
                keyTerms: terms
            )
        )

        XCTAssertEqual(multipartFieldValues(named: "keyterm", in: body), terms)
        assertField("diarize", equals: "true", in: body)
        assertAbsent("filler_words", in: body)
        assertAbsent("vad_threshold", in: body)
        assertFieldOrder(["model", "diarize", "keyterm", "file"], in: body)
        assertLastMultipartField(named: "file", in: body)
    }

    func testURLTranscriptionSendsKeyTerms() throws {
        let audioURL = try XCTUnwrap(URL(string: "https://example.com/calls/audio.m4a?sig=1"))
        let terms = ["Understand The Universe", "OpenRec"]
        let body = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                audioURL: audioURL,
                keyTerms: terms
            )
        )

        XCTAssertEqual(multipartFieldValues(named: "keyterm", in: body), terms)
        assertField("url", equals: audioURL.absoluteString, in: body)
        assertField("model", equals: "grok-voice-transcribe-2.0", in: body)
        assertField("diarize", equals: "true", in: body)
        assertAbsent("language", in: body)
        assertAbsent("format", in: body)
        assertAbsent("file", in: body)
        assertFieldOrder(["model", "diarize", "url", "keyterm"], in: body)
        assertLastMultipartField(named: "keyterm", in: body)
    }

    func testAutoDetectWithKeyTermsOmitsLanguageAndFormat() throws {
        let audioURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }

        let body = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                fileURL: audioURL,
                language: .autoDetect,
                keyTerms: ["Understand The Universe"]
            )
        )

        XCTAssertEqual(multipartFieldValues(named: "keyterm", in: body), ["Understand The Universe"])
        assertAbsent("language", in: body)
        assertAbsent("format", in: body)
        assertField("diarize", equals: "true", in: body)
        assertFieldOrder(["model", "diarize", "keyterm", "file"], in: body)
        assertLastMultipartField(named: "file", in: body)
    }

    func testEnglishWithKeyTermsSendsLanguageAndFormat() throws {
        let audioURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }
        let terms = ["Understand The Universe", "OpenRec"]

        let body = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                fileURL: audioURL,
                language: .english,
                keyTerms: terms
            )
        )

        XCTAssertEqual(multipartFieldValues(named: "keyterm", in: body), terms)
        assertField("language", equals: "en", in: body)
        assertField("format", equals: "true", in: body)
        assertField("model", equals: "grok-voice-transcribe-2.0", in: body)
        assertField("diarize", equals: "true", in: body)
        assertFieldOrder(["model", "diarize", "language", "format", "keyterm", "file"], in: body)
        assertLastMultipartField(named: "file", in: body)

        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/calls/audio.m4a"))
        let remote = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                audioURL: remoteURL,
                language: .english,
                keyTerms: terms
            )
        )
        XCTAssertEqual(multipartFieldValues(named: "keyterm", in: remote), terms)
        assertField("language", equals: "en", in: remote)
        assertField("format", equals: "true", in: remote)
        assertField("url", equals: remoteURL.absoluteString, in: remote)
        assertAbsent("file", in: remote)
        assertFieldOrder(["model", "diarize", "language", "format", "url", "keyterm"], in: remote)
        assertLastMultipartField(named: "keyterm", in: remote)
    }

    func testOverlongKeyTermsAreCappedWhenSent() throws {
        let audioURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }

        let long = String(repeating: "é", count: 51)
        var terms = ["  Understand The Universe  ", "", "   ", long, "Open  Rec"]
        terms.append(contentsOf: (1...100).map { "Extra \($0)" })

        let body = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                fileURL: audioURL,
                language: .autoDetect,
                keyTerms: terms
            )
        )

        let values = multipartFieldValues(named: "keyterm", in: body)
        XCTAssertEqual(values.count, 100)
        XCTAssertEqual(values[0], "Understand The Universe")
        XCTAssertEqual(values[1], String(repeating: "é", count: 50))
        XCTAssertEqual(values[2], "Open  Rec")
        XCTAssertEqual(values[3], "Extra 1")
        XCTAssertEqual(values.last, "Extra 97")
        XCTAssertFalse(values.contains("Extra 98"))
        XCTAssertFalse(values.contains("Extra 100"))
        XCTAssertFalse(values.contains(long))
        assertAbsent("language", in: body)
        assertAbsent("format", in: body)
        assertField("diarize", equals: "true", in: body)
        assertLastMultipartField(named: "file", in: body)
    }

    func testKeyTermsRoundTripThroughUserDefaults() throws {
        let suite = "OpenRecGrokKeyTerms-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(defaults.string(forKey: GrokTranscriptionKeyTerms.defaultsKey))
        XCTAssertEqual(GrokTranscriptionKeyTerms.resolved(from: nil), [])
        XCTAssertEqual(GrokTranscriptionKeyTerms.resolved(from: ""), [])
        XCTAssertEqual(GrokTranscriptionKeyTerms.resolved(from: "not-json"), [])
        XCTAssertEqual(
            GrokTranscriptionKeyTerms.resolved(from: "Understand The Universe, OpenRec"),
            []
        )
        XCTAssertEqual(GrokTranscriptionKeyTerms.stored(in: defaults), [])

        GrokTranscriptionKeyTerms.store([], in: defaults)
        let emptyJSON = try XCTUnwrap(defaults.string(forKey: GrokTranscriptionKeyTerms.defaultsKey))
        XCTAssertEqual(emptyJSON.trimmingCharacters(in: .whitespacesAndNewlines), "[]")
        XCTAssertNil(defaults.array(forKey: GrokTranscriptionKeyTerms.defaultsKey))
        XCTAssertEqual(GrokTranscriptionKeyTerms.stored(in: defaults), [])

        let long = String(repeating: "B", count: 60)
        var input = [
            "  Understand The Universe  ",
            "",
            "   ",
            long,
            "Open  Rec",
            "zeta term",
            "Alpha",
        ]
        input.append(contentsOf: (1...100).map { "Extra \($0)" })
        GrokTranscriptionKeyTerms.store(input, in: defaults)

        let storedJSON = try XCTUnwrap(defaults.string(forKey: GrokTranscriptionKeyTerms.defaultsKey))
        XCTAssertTrue(storedJSON.hasPrefix("["))
        XCTAssertTrue(storedJSON.contains("\"Understand The Universe\""))
        XCTAssertNil(defaults.array(forKey: GrokTranscriptionKeyTerms.defaultsKey))

        let loaded = GrokTranscriptionKeyTerms.stored(in: defaults)
        XCTAssertEqual(loaded.count, 100)
        XCTAssertEqual(loaded[0], "Understand The Universe")
        XCTAssertEqual(loaded[1], String(repeating: "B", count: 50))
        XCTAssertEqual(loaded[2], "Open  Rec")
        XCTAssertEqual(loaded[3], "zeta term")
        XCTAssertEqual(loaded[4], "Alpha")
        XCTAssertEqual(loaded[5], "Extra 1")
        XCTAssertEqual(loaded.last, "Extra 95")
        XCTAssertFalse(loaded.contains("Extra 96"))
        XCTAssertEqual(loaded, GrokTranscriptionKeyTerms.normalized(input))

        let exactlyFifty = String(repeating: "é", count: 50)
        GrokTranscriptionKeyTerms.store(["  \(exactlyFifty)  ", "  "], in: defaults)
        XCTAssertEqual(GrokTranscriptionKeyTerms.stored(in: defaults), [exactlyFifty])

        let unnormalized = "[\"  Understand The Universe  \",\"\",\"\(long)\"]"
        defaults.set(unnormalized, forKey: GrokTranscriptionKeyTerms.defaultsKey)
        XCTAssertEqual(
            GrokTranscriptionKeyTerms.stored(in: defaults),
            ["Understand The Universe", String(repeating: "B", count: 50)]
        )

        GrokTranscriptionKeyTerms.store(["Understand The Universe", "OpenRec"], in: defaults)
        let audioURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }
        let body = try bodyData(
            from: try GrokService(apiKey: apiKey).makeTranscriptionRequest(
                fileURL: audioURL,
                language: GrokTranscriptionLanguage.stored(in: defaults),
                keyTerms: GrokTranscriptionKeyTerms.stored(in: defaults)
            )
        )
        XCTAssertEqual(
            multipartFieldValues(named: "keyterm", in: body),
            ["Understand The Universe", "OpenRec"]
        )
        assertAbsent("language", in: body)
        assertAbsent("format", in: body)
        assertLastMultipartField(named: "file", in: body)
    }

    func testPickerUsesOfficialBaseLanguageCodes() {
        XCTAssertEqual(GrokTranscriptionLanguage.allCases.first, .autoDetect)
        XCTAssertEqual(GrokTranscriptionLanguage.autoDetect.displayName, "Auto-Detect")
        XCTAssertEqual(
            GrokTranscriptionLanguage.allCases.compactMap(\.languageCode),
            [
                "ar", "bs", "bg", "yue", "ca", "zh", "hr", "cs", "da", "nl",
                "en", "fil", "fi", "fr", "de", "el", "hi", "hu", "id", "it",
                "ja", "ko", "mk", "ms", "nb", "fa", "pl", "pt", "ro", "ru",
                "sk", "es", "sv", "th", "tr", "uk", "ur", "vi",
            ]
        )
        XCTAssertEqual(GrokTranscriptionLanguage.chineseMandarin.displayName, "Chinese (Mandarin)")
        XCTAssertEqual(GrokTranscriptionLanguage.norwegianBokmal.displayName, "Norwegian (Bokmål)")
        XCTAssertEqual(GrokTranscriptionLanguage.spanish.languageCode, "es")
        XCTAssertEqual(GrokTranscriptionLanguage.portuguese.languageCode, "pt")
        XCTAssertEqual(GrokTranscriptionLanguage.arabic.languageCode, "ar")
    }

    func testTranscribeMapsADiarizedFixtureFromTheSTTEndpoint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokSTTLive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("call.m4a")
        try Data("audio-bytes".utf8).write(to: audioURL)
        GrokMockURLProtocol.handler = { request in
            let body = try Self.bodyData(from: request)
            XCTAssertEqual(request.url?.absoluteString, "https://api.x.ai/v1/stt")
            XCTAssertNotEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertTrue(body.range(of: Data("name=\"diarize\"".utf8)) != nil)
            XCTAssertTrue(body.range(of: Data("grok-voice-transcribe-2.0".utf8)) != nil)
            let payload = """
            {"text":"Morning. Let's ship it.","duration":2.0,"words":[{"text":"Morning.","start":0.25,"end":0.6,"speaker":0},{"text":"Let's","start":1.25,"end":1.5,"speaker":1},{"text":"ship","start":1.5,"end":1.8,"speaker":1},{"text":"it.","start":1.8,"end":2.0,"speaker":1}]}
            """
            return (Self.response(url: try XCTUnwrap(request.url)), Data(payload.utf8))
        }

        let segments = try await GrokService(apiKey: apiKey, session: session).transcribe(fileURL: audioURL)

        XCTAssertEqual(segments.map(\.speakerLabel), ["Speaker 0", "Speaker 1"])
        XCTAssertEqual(segments.map(\.text), ["Morning.", "Let's ship it."])
        XCTAssertEqual(try XCTUnwrap(segments[0].timestamp), 0.25, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(segments[1].timestamp), 1.25, accuracy: 0.000_001)
    }

    func testSelectedProviderRoutesInsightsToThatAPI() async throws {
        GrokMockURLProtocol.handler = { request in
            let host = try XCTUnwrap(request.url?.host)
            let body = try JSONSerialization.jsonObject(with: try Self.bodyData(from: request)) as? [String: Any]
            switch host {
            case "api.x.ai":
                XCTAssertEqual(body?["model"] as? String, "grok-4.3")
            case "api.openai.com":
                XCTAssertEqual(body?["model"] as? String, "gpt-5-mini")
                XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            default:
                XCTFail("Unexpected host \(host)")
            }
            return (
                Self.response(url: try XCTUnwrap(request.url)),
                Self.completion(Self.insightsJSON)
            )
        }

        let grok = try await MeetingMemoryClient.generateInsights(
            provider: .grok,
            apiKey: apiKey,
            transcript: "Grok transcript",
            callTitle: "Grok call",
            session: session
        )
        let openai = try await MeetingMemoryClient.generateInsights(
            provider: .openai,
            apiKey: "test-openai-token",
            transcript: "OpenAI transcript",
            callTitle: "OpenAI call",
            session: session
        )

        XCTAssertEqual(grok.title, "Ship the notes")
        XCTAssertEqual(openai.title, "Ship the notes")
        XCTAssertEqual(openai.actionItems[0].task, "Write the notes")
    }

    private func temporaryAudioFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokSTT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("call.m4a")
        try Data("not-a-real-recording".utf8).write(to: audioURL)
        return audioURL
    }

    /// Reads repeated form-data values by matching `; name="` and then the
    /// quoted field name. A search for `name="` also matches `filename="`.
    private func multipartFieldValues(named name: String, in body: Data) -> [String] {
        let marker = Data("; name=\"\(name)\"".utf8)
        let separator = Data("\r\n\r\n".utf8)
        let lineEnd = Data("\r\n".utf8)
        var values: [String] = []
        var search = body.startIndex
        while let range = body.range(of: marker, in: search..<body.endIndex) {
            let afterName = range.upperBound
            guard let separatorRange = body.range(of: separator, in: afterName..<body.endIndex),
                  separatorRange.lowerBound == afterName else {
                search = afterName
                continue
            }
            let contentStart = separatorRange.upperBound
            guard let end = body.range(of: lineEnd, in: contentStart..<body.endIndex) else { break }
            values.append(String(data: body[contentStart..<end.lowerBound], encoding: .utf8) ?? "")
            search = end.upperBound
        }
        return values
    }

    private func assertField(
        _ name: String,
        equals value: String,
        in body: Data,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let needle = Data("name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        XCTAssertNotNil(body.range(of: needle), "Missing \(name)=\(value)", file: file, line: line)
    }

    private func assertAbsent(
        _ name: String,
        in body: Data,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertNil(
            body.range(of: Data("name=\"\(name)\"".utf8)),
            "Unexpected field \(name)",
            file: file,
            line: line
        )
    }

    private func assertFieldOrder(
        _ names: [String],
        in body: Data,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        var previous: Data.Index?
        for name in names {
            guard let index = body.range(of: Data("name=\"\(name)\"".utf8))?.lowerBound else {
                XCTFail("Missing field \(name)", file: file, line: line)
                return
            }
            if let previous {
                XCTAssertLessThan(previous, index, "\(name) is out of order", file: file, line: line)
            }
            previous = index
        }
    }

    /// The file part is `name="file"; filename="..."`. A search for `name="`
    /// also matches the `name="` inside `filename=`, so match the form-data
    /// parameter `; name="` and read the quoted field name that follows it.
    private func assertLastMultipartField(
        named name: String,
        in body: Data,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let needle = Data("; name=\"".utf8)
        var lastValue: Data.Index?
        var search = body.startIndex
        while let range = body.range(of: needle, in: search..<body.endIndex) {
            lastValue = range.upperBound
            search = range.upperBound
        }
        guard let lastValue else {
            XCTFail("Expected multipart fields", file: file, line: line)
            return
        }
        let expected = Data("\(name)\"".utf8)
        let observed = String(data: body[lastValue...].prefix(32), encoding: .utf8) ?? "<binary>"
        XCTAssertTrue(
            body[lastValue...].starts(with: expected),
            "Last field was not \(name); found \(observed)",
            file: file,
            line: line
        )
    }

    private func bodyData(from request: URLRequest) throws -> Data {
        try Self.bodyData(from: request)
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            XCTFail("Expected an HTTP body")
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func response(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static let insightsJSON = """
    {"title":"Ship the notes","summary":"The team agreed to ship.","aiNotes":"## Ship\\n- **Friday**","participants":["Ada"],"actionItems":[{"owner":"Ada","task":"Write the notes","dueDate":null}],"decisions":["Ship Friday"]}
    """

    private static func completion(_ content: String) -> Data {
        let message: [String: Any] = [
            "role": "assistant",
            "content": content,
        ]
        let choice: [String: Any] = [
            "index": 0,
            "message": message,
            "finish_reason": "stop",
        ]
        let payload: [String: Any] = [
            "id": "completion-test",
            "object": "chat.completion",
            "choices": [choice],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}

private final class GrokMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var storedHandler: Handler?

    static var handler: Handler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
