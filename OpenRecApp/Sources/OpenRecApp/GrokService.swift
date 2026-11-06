import Foundation

/// Meeting-memory client for the xAI API (`https://api.x.ai/v1`).
/// grok-4.7 writes structured meeting memory. Insights requests set
/// reasoning_effort to high. Key checks call xAI only.
struct GrokService {
    static let speechToTextModelID = TranscriptionProvider.grok.modelLabel

    let apiKey: String
    let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// xAI reports an incorrect API key as 400, and a missing or rejected
    /// credential as 401 or 403. 404 means the configured model is unavailable.
    /// Rate limits and transport failures are excluded so a verified key is
    /// kept when the service is only unreachable.
    static func isCredentialOrModelAccessFailure(_ error: Error) -> Bool {
        guard case .requestFailed(let status, _) = error as? OpenRecError else {
            return false
        }
        return status == 400 || status == 401 || status == 403 || status == 404
    }

    func validateAccess() async throws {
        let request = try makeValidationRequest()
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func generateInsights(transcript: String, callTitle: String?) async throws -> MeetingInsights {
        let request = try makeInsightsRequest(transcript: transcript, callTitle: callTitle)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decodeInsights(from: data)
    }

    func makeValidationRequest() throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OpenRecError.invalidConfiguration("Enter a Grok API key first.")
        }
        guard let url = URL(string: "https://api.x.ai/v1/models/\(MeetingMemoryProvider.grok.modelID)") else {
            throw OpenRecError.invalidConfiguration("Invalid Grok endpoint.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }

    func makeInsightsRequest(transcript: String, callTitle: String?) throws -> URLRequest {
        // grok-4.7 can reason before the structured notes, and long calls
        // produce a large response. Match the OpenAI insights timeout.
        var request = try chatRequest()

        let prompt = """
        Turn this meeting transcript into concise, factual meeting memory. Infer participant names only when the transcript explicitly supports them. Never invent names, owners, dates, or decisions. Return JSON matching the provided schema. Suggested title from the call window: \(callTitle ?? "none").

        Lines begin with a bracketed speaker label. When that label is a person's name, use it for participants, decisions, and next-step owners.

        For "aiNotes", write markdown notes the way a sharp human note-taker would capture the call as it happened: short "## " section headers that follow the conversation's actual topics, tight "- " bullet fragments underneath (not full prose sentences), with concrete specifics preserved — names, numbers, prices, tools, dates, and memorable quotes worth keeping. Bold the load-bearing terms. Keep it scannable; no filler, no meta commentary about the transcript.

        For "summary", write 2-3 plain sentences of what the call was about and where it landed.

        Transcript:
        \(transcript)
        """
        let system: [String: Any] = [
            "role": "system",
            "content": "You take meeting notes like an excellent human note-taker, and extract participants, decisions, and concrete next steps.",
        ]
        let user: [String: Any] = [
            "role": "user",
            "content": prompt,
        ]
        let jsonSchema: [String: Any] = [
            "name": "meeting_insights",
            "strict": true,
            "schema": Self.meetingInsightsSchema,
        ]
        let responseFormat: [String: Any] = [
            "type": "json_schema",
            "json_schema": jsonSchema,
        ]
        let body: [String: Any] = [
            "model": MeetingMemoryProvider.grok.modelID,
            // grok-4.7 defaults to high. Send it explicitly so the default
            // never decides the insights result.
            "reasoning_effort": "high",
            "messages": [system, user],
            "response_format": responseFormat,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func makeSpeakerNamesRequest(transcript: String, callTitle: String?) throws -> URLRequest {
        let request = try chatRequest()
        let body = SpeakerNames.requestBody(
            model: MeetingMemoryProvider.grok.modelID,
            reasoningEffort: "high",
            transcript: transcript,
            callTitle: callTitle
        )
        var named = request
        named.httpBody = try JSONSerialization.data(withJSONObject: body)
        return named
    }

    func identifySpeakerNames(transcript: String, callTitle: String?) async throws -> [String: String] {
        let labels = SpeakerNames.speakerLabels(in: transcript)
        guard !labels.isEmpty else { return [:] }
        let request = try makeSpeakerNamesRequest(transcript: transcript, callTitle: callTitle)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try SpeakerNames.mapping(
            fromCompletion: data,
            labels: labels,
            transcript: transcript,
            callTitle: callTitle
        )
    }

    /// Authorized chat-completions request with no body yet. Insights and
    /// speaker names share the host, model timeout, and credential check.
    private func chatRequest() throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OpenRecError.invalidConfiguration("Enter a Grok API key first.")
        }
        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
            throw OpenRecError.invalidConfiguration("Invalid Grok endpoint.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static let meetingInsightsSchema: [String: Any] = {
        let stringSchema: [String: Any] = ["type": "string"]
        let stringArray: [String: Any] = ["type": "array", "items": stringSchema]
        let dueDate: [String: Any] = ["type": ["string", "null"]]
        let actionItemProperties: [String: Any] = [
            "owner": stringSchema,
            "task": stringSchema,
            "dueDate": dueDate,
        ]
        let actionItem: [String: Any] = [
            "type": "object",
            "properties": actionItemProperties,
            "required": ["owner", "task", "dueDate"],
            "additionalProperties": false,
        ]
        let actionItems: [String: Any] = [
            "type": "array",
            "items": actionItem,
        ]
        let properties: [String: Any] = [
            "title": stringSchema,
            "summary": stringSchema,
            "aiNotes": stringSchema,
            "participants": stringArray,
            "actionItems": actionItems,
            "decisions": stringArray,
        ]
        return [
            "type": "object",
            "properties": properties,
            "required": ["title", "summary", "aiNotes", "participants", "actionItems", "decisions"],
            "additionalProperties": false,
        ]
    }()

    private func decodeInsights(from data: Data) throws -> MeetingInsights {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw OpenRecError.invalidResponse("Grok returned an unreadable insights response.")
        }
        if let refusal = message["refusal"] as? String,
           !refusal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           message["content"] as? String == nil {
            throw OpenRecError.invalidResponse(refusal)
        }
        guard let content = message["content"] as? String else {
            throw OpenRecError.invalidResponse("Grok returned an unreadable insights response.")
        }
        let payload = Self.jsonPayload(from: content)
        guard let contentData = payload.data(using: .utf8) else {
            throw OpenRecError.invalidResponse("Grok returned an unreadable insights response.")
        }
        do {
            return try JSONDecoder().decode(MeetingInsights.self, from: contentData)
        } catch {
            throw OpenRecError.invalidResponse("Grok returned an unreadable insights response.")
        }
    }

    /// Strict json_schema returns raw JSON. If a response is fenced anyway,
    /// peel one markdown fence so it still decodes into MeetingInsights.
    private static func jsonPayload(from content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRecError.invalidResponse("The server returned no HTTP status.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRecError.requestFailed(
                status: http.statusCode,
                message: Self.failureMessage(from: data)
            )
        }
    }

    private static func failureMessage(from data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message: String
        if let error = json?["error"] as? [String: Any], let text = error["message"] as? String {
            message = text
        } else if let text = json?["error"] as? String {
            message = text
        } else if let text = json?["message"] as? String {
            message = text
        } else {
            message = String(data: data, encoding: .utf8) ?? "Unknown error"
        }
        let flattened = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flattened.isEmpty { return "Unknown error" }
        if flattened.count > 280 { return String(flattened.prefix(280)) }
        return flattened
    }

    func transcribe(
        fileURL: URL,
        language: GrokTranscriptionLanguage = .autoDetect,
        keyTerms: [String] = []
    ) async throws -> [DisplaySegment] {
        let request = try makeTranscriptionRequest(
            fileURL: fileURL,
            language: language,
            keyTerms: keyTerms
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decodeTranscript(data)
    }

    /// Transcribe media that is already in private cloud storage through a
    /// short-lived HTTPS URL. xAI downloads it server-side.
    func transcribe(
        audioURL: URL,
        language: GrokTranscriptionLanguage = .autoDetect,
        keyTerms: [String] = []
    ) async throws -> [DisplaySegment] {
        let request = try makeTranscriptionRequest(
            audioURL: audioURL,
            language: language,
            keyTerms: keyTerms
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decodeTranscript(data)
    }

    func makeTranscriptionRequest(
        fileURL: URL,
        language: GrokTranscriptionLanguage = .autoDetect,
        keyTerms: [String] = []
    ) throws -> URLRequest {
        let key = try trimmedKey()
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            throw OpenRecError.invalidConfiguration("The recording for transcription is missing.")
        }
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw OpenRecError.recordingFailed("The recording for transcription is empty.")
        }
        guard fileSize <= 500 * 1024 * 1024 else {
            throw OpenRecError.invalidConfiguration("Grok transcription accepts audio up to 500 MB.")
        }
        let fileData = try Data(contentsOf: fileURL)
        let fileName = Self.safeFileName(fileURL.lastPathComponent)
        let boundary = "OpenRecGrok\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let body = Self.multipartBody(
            fields: Self.transcriptionFields(language: language, keyTerms: keyTerms),
            fileField: "file",
            fileName: fileName,
            mimeType: Self.mimeType(for: fileURL),
            fileData: fileData,
            boundary: boundary
        )
        return try Self.sttRequest(apiKey: key, body: body, boundary: boundary)
    }

    func makeTranscriptionRequest(
        audioURL: URL,
        language: GrokTranscriptionLanguage = .autoDetect,
        keyTerms: [String] = []
    ) throws -> URLRequest {
        let key = try trimmedKey()
        guard audioURL.scheme == "https", audioURL.host != nil else {
            throw OpenRecError.invalidConfiguration("Grok needs a valid HTTPS recording URL.")
        }
        let boundary = "OpenRecGrok\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let body = Self.multipartBody(
            fields: Self.transcriptionFields(
                language: language,
                keyTerms: keyTerms,
                url: audioURL.absoluteString
            ),
            fileField: nil,
            fileName: nil,
            mimeType: nil,
            fileData: nil,
            boundary: boundary
        )
        return try Self.sttRequest(apiKey: key, body: body, boundary: boundary)
    }

    /// Auto-Detect omits `language` and `format`. A chosen language sends both.
    /// `format=true` without `language` is HTTP 400. Formatting is a no-op in
    /// languages without coverage, including Thai, and is still sent.
    /// Each normalized key term is one repeated `keyterm` field. An empty list
    /// omits `keyterm`. `file` is appended after these fields so it stays last.
    private static func transcriptionFields(
        language: GrokTranscriptionLanguage,
        keyTerms: [String] = [],
        url: String? = nil
    ) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model", speechToTextModelID),
            ("diarize", "true"),
        ]
        if let languageCode = language.languageCode {
            fields.append(("language", languageCode))
            fields.append(("format", "true"))
        }
        if let url {
            fields.append(("url", url))
        }
        for term in GrokTranscriptionKeyTerms.normalized(keyTerms) {
            fields.append(("keyterm", term))
        }
        return fields
    }

    private func trimmedKey() throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OpenRecError.invalidConfiguration("Enter a Grok API key first.")
        }
        return key
    }

    private func decodeTranscript(_ data: Data) throws -> [DisplaySegment] {
        let response: GrokSTTResponse
        do {
            response = try JSONDecoder().decode(GrokSTTResponse.self, from: data)
        } catch {
            throw OpenRecError.invalidResponse("Grok returned an unreadable transcript.")
        }
        return try GrokTranscriptMapper.displaySegments(from: response)
    }

    private static func sttRequest(apiKey: String, body: Data, boundary: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.x.ai/v1/stt") else {
            throw OpenRecError.invalidConfiguration("Invalid Grok endpoint.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func multipartBody(
        fields: [(String, String)],
        fileField: String?,
        fileName: String?,
        mimeType: String?,
        fileData: Data?,
        boundary: String
    ) -> Data {
        var body = Data()
        let crlf = Data("\r\n".utf8)
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(crlf)
        }
        if let fileField, let fileName, let mimeType, let fileData {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data(
                "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n".utf8
            ))
            body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
            body.append(fileData)
            body.append(crlf)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private static func safeFileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return cleaned.isEmpty ? "audio.m4a" : cleaned
    }

    private static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }
}

struct GrokSTTWord: Decodable, Equatable {
    let text: String
    let start: Double
    let end: Double
    let speaker: Int?
}

struct GrokSTTResponse: Decodable, Equatable {
    let text: String?
    let duration: Double?
    let words: [GrokSTTWord]?
}

enum GrokTranscriptMapper {
    static func displaySegments(from response: GrokSTTResponse) throws -> [DisplaySegment] {
        var segments: [DisplaySegment] = []
        var currentSpeaker: Int?
        var currentTexts: [String] = []
        var currentStart = 0.0
        var hasTurn = false

        func flush() {
            let text = currentTexts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            segments.append(DisplaySegment(
                speakerLabel: speakerLabel(for: currentSpeaker),
                text: text,
                timestamp: max(0, currentStart)
            ))
        }

        for word in response.words ?? [] {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !hasTurn {
                hasTurn = true
                currentSpeaker = word.speaker
                currentStart = word.start
                currentTexts = [text]
                continue
            }
            if word.speaker == currentSpeaker {
                currentTexts.append(text)
            } else {
                flush()
                currentSpeaker = word.speaker
                currentStart = word.start
                currentTexts = [text]
            }
        }
        if hasTurn { flush() }
        if !segments.isEmpty { return segments }

        if let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return [DisplaySegment(speakerLabel: "Conversation", text: text, timestamp: 0)]
        }
        throw OpenRecError.noSpeechDetected("Grok processed the recording but did not detect any spoken words.")
    }

    static func speakerLabel(for speaker: Int?) -> String {
        guard let speaker else { return "Speaker" }
        return "Speaker \(speaker)"
    }
}

enum MeetingMemoryClient {
    static func generateInsights(
        provider: MeetingMemoryProvider,
        apiKey: String,
        transcript: String,
        callTitle: String?,
        session: URLSession = .shared
    ) async throws -> MeetingInsights {
        switch provider {
        case .openai:
            return try await OpenAIService(apiKey: apiKey, session: session).generateInsights(
                transcript: transcript,
                callTitle: callTitle
            )
        case .grok:
            return try await GrokService(apiKey: apiKey, session: session).generateInsights(
                transcript: transcript,
                callTitle: callTitle
            )
        }
    }

    static func identifySpeakerNames(
        provider: MeetingMemoryProvider,
        apiKey: String,
        transcript: String,
        callTitle: String?,
        session: URLSession = .shared
    ) async throws -> [String: String] {
        switch provider {
        case .openai:
            return try await OpenAIService(apiKey: apiKey, session: session).identifySpeakerNames(
                transcript: transcript,
                callTitle: callTitle
            )
        case .grok:
            return try await GrokService(apiKey: apiKey, session: session).identifySpeakerNames(
                transcript: transcript,
                callTitle: callTitle
            )
        }
    }
}
