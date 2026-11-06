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
        let search = body?["search_parameters"] as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]]

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(body?["model"] as? String, "grok-4.3")
        XCTAssertEqual(body?["reasoning_effort"] as? String, "low")
        XCTAssertEqual(search?["mode"] as? String, "off")
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
