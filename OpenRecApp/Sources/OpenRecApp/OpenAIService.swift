import Foundation

struct OpenAIService {
    let apiKey: String
    let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    static func isCredentialOrModelAccessFailure(_ error: Error) -> Bool {
        guard case .requestFailed(let status, _) = error as? OpenRecError else {
            return false
        }
        return status == 401 || status == 403 || status == 404
    }

    func validateAccess() async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRecError.invalidConfiguration("Enter an OpenAI API key first.")
        }
        guard let url = URL(string: "https://api.openai.com/v1/models/gpt-5-mini") else {
            throw OpenRecError.invalidConfiguration("Invalid OpenAI endpoint.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func generateInsights(transcript: String, callTitle: String?) async throws -> MeetingInsights {
        let request = try makeInsightsRequest(transcript: transcript, callTitle: callTitle)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8) else {
            throw OpenRecError.invalidResponse("OpenAI returned an unreadable insights response.")
        }
        return try JSONDecoder().decode(MeetingInsights.self, from: contentData)
    }

    func makeInsightsRequest(
        transcript: String,
        callTitle: String?,
        defaults: UserDefaults = .standard
    ) throws -> URLRequest {
        let prompt = AIPromptStore.meetingMemoryUser(
            transcript: transcript,
            callTitle: callTitle,
            defaults: defaults
        )
        let body: [String: Any] = [
            "model": MeetingMemoryProvider.openai.modelID,
            "messages": [
                ["role": "system", "content": AIPromptStore.meetingMemorySystem(defaults: defaults)],
                ["role": "user", "content": prompt],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "meeting_insights",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "summary": ["type": "string"],
                            "aiNotes": ["type": "string"],
                            "participants": ["type": "array", "items": ["type": "string"]],
                            "actionItems": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "owner": ["type": "string"],
                                        "task": ["type": "string"],
                                        "dueDate": ["type": ["string", "null"]],
                                    ],
                                    "required": ["owner", "task", "dueDate"],
                                    "additionalProperties": false,
                                ],
                            ],
                            "decisions": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": ["title", "summary", "aiNotes", "participants", "actionItems", "decisions"],
                        "additionalProperties": false,
                    ],
                ],
            ],
        ]
        return try chatRequest(body: body)
    }

    func makeSpeakerNamesRequest(
        transcript: String,
        callTitle: String?,
        defaults: UserDefaults = .standard
    ) throws -> URLRequest {
        let body = SpeakerNames.requestBody(
            model: MeetingMemoryProvider.openai.modelID,
            reasoningEffort: nil,
            transcript: transcript,
            callTitle: callTitle,
            defaults: defaults
        )
        return try chatRequest(body: body)
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

    private func chatRequest(body: [String: Any]) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OpenRecError.invalidConfiguration("Enter an OpenAI API key first.")
        }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw OpenRecError.invalidConfiguration("Invalid OpenAI endpoint.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // gpt-5-mini reasons before answering and long calls produce large
        // structured notes; a full response can take several minutes.
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRecError.invalidResponse("The server returned no HTTP status.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenRecError.requestFailed(status: http.statusCode, message: message)
        }
    }

}
