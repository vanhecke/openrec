import Foundation

struct SpeakerNameRow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let name: String
}

/// Maps diarized speaker labels onto real names.
///
/// AssemblyAI stores labels as `Speaker A`. Grok stores them as `Speaker 0`.
/// The transcript line stays `[Label] text`. Names are substituted only at the
/// bracket, so a later mention of the raw label inside the sentence is kept.
enum SpeakerNames {
    static func speakerLabels(in transcript: String) -> [String] {
        var labels: [String] = []
        var seen = Set<String>()
        for line in lines(in: transcript) {
            guard let label = label(atStartOf: line), seen.insert(label).inserted else { continue }
            labels.append(label)
        }
        return labels
    }

    static func rows(transcript: String, mapping: [String: String]) -> [SpeakerNameRow] {
        var labels = speakerLabels(in: transcript)
        let extras = mapping.keys.filter { !labels.contains($0) }.sorted()
        labels.append(contentsOf: extras)
        return labels.map { label in
            SpeakerNameRow(label: label, name: mapping[label].flatMap(normalizedUserName) ?? "")
        }
    }

    static func displayName(for label: String, mapping: [String: String]) -> String {
        guard let name = mapping[label].flatMap(normalizedUserName),
              name.caseInsensitiveCompare(label) != .orderedSame else { return label }
        return name
    }

    /// Names in first-appearance order, skipping blank and duplicate entries.
    static func identifiedNames(transcript: String, mapping: [String: String]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for row in rows(transcript: transcript, mapping: mapping) {
            guard let name = normalizedUserName(row.name) else { continue }
            guard seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    static func apply(_ mapping: [String: String], to transcript: String) -> String {
        guard !mapping.isEmpty, transcript.contains("[") else { return transcript }
        return lines(in: transcript).map { line in
            guard let labelRange = labelRange(atStartOf: line) else { return line }
            let label = String(line[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = mapping[label].flatMap(normalizedUserName),
                  name.caseInsensitiveCompare(label) != .orderedSame else { return line }
            var replaced = line
            replaced.replaceSubrange(labelRange, with: name)
            return replaced
        }.joined(separator: "\n")
    }

    /// A name typed in the library. Empty means the speaker goes back to the diarized label.
    static func normalizedUserName(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= 80 else { return nil }
        guard !collapsed.contains("["), !collapsed.contains("]") else { return nil }
        return collapsed
    }

    /// Keeps model assignments whose label exists and whose name is actually
    /// written in the transcript or the meeting title.
    static func acceptedMapping(
        from content: String,
        labels: [String],
        transcript: String,
        callTitle: String?
    ) -> [String: String] {
        let payload = jsonPayload(from: content)
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SpeakerNameResponse.self, from: data) else {
            return [:]
        }
        let canonical = labels.reduce(into: [String: String]()) { result, label in
            result[label.lowercased()] = label
        }
        var mapping: [String: String] = [:]
        for speaker in decoded.speakers {
            let key = speaker.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let label = canonical[key] else { continue }
            guard let name = normalizedModelName(speaker.name) else { continue }
            guard name.caseInsensitiveCompare(label) != .orderedSame else { continue }
            guard !isGenericLabel(name) else { continue }
            guard isSupported(name, transcript: transcript, callTitle: callTitle) else { continue }
            mapping[label] = name
        }
        return mapping
    }

    static func mapping(
        fromCompletion data: Data,
        labels: [String],
        transcript: String,
        callTitle: String?
    ) throws -> [String: String] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw OpenRecError.invalidResponse("The model returned an unreadable speaker-name response.")
        }
        if let refusal = message["refusal"] as? String,
           !refusal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           message["content"] as? String == nil {
            throw OpenRecError.invalidResponse(refusal)
        }
        guard let content = message["content"] as? String else {
            throw OpenRecError.invalidResponse("The model returned an unreadable speaker-name response.")
        }
        return acceptedMapping(from: content, labels: labels, transcript: transcript, callTitle: callTitle)
    }

    static func identificationPrompt(transcript: String, callTitle: String?, labels: [String]) -> String {
        let title = callTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleLine = (title?.isEmpty == false) ? title! : "none"
        return """
        Identify the real name of each diarized speaker. The transcript labels speakers as \(labels.joined(separator: ", ")). Use a name only when the transcript explicitly supports it: someone introduces themselves, another speaker addresses them by name, or the meeting title names them. Never invent a name. If a speaker's name is not supported, return null. Return one entry for every label, using the label text exactly.

        Meeting title: \(titleLine)

        Transcript:
        \(transcript)
        """
    }

    static func requestBody(
        model: String,
        reasoningEffort: String?,
        transcript: String,
        callTitle: String?
    ) -> [String: Any] {
        let labels = speakerLabels(in: transcript)
        let system: [String: Any] = [
            "role": "system",
            "content": "You attach real names to diarized speaker labels. You never guess.",
        ]
        let user: [String: Any] = [
            "role": "user",
            "content": identificationPrompt(transcript: transcript, callTitle: callTitle, labels: labels),
        ]
        let responseFormat: [String: Any] = [
            "type": "json_schema",
            "json_schema": [
                "name": "speaker_names",
                "strict": true,
                "schema": responseSchema,
            ],
        ]
        var body: [String: Any] = [
            "model": model,
            "messages": [system, user],
            "response_format": responseFormat,
        ]
        if let reasoningEffort {
            body["reasoning_effort"] = reasoningEffort
        }
        return body
    }

    private static let responseSchema: [String: Any] = {
        let speaker: [String: Any] = [
            "type": "object",
            "properties": [
                "label": ["type": "string"],
                "name": ["type": ["string", "null"]],
            ],
            "required": ["label", "name"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "speakers": [
                    "type": "array",
                    "items": speaker,
                ],
            ],
            "required": ["speakers"],
            "additionalProperties": false,
        ]
    }()

    private struct SpeakerNameResponse: Decodable {
        let speakers: [SpeakerNameAssignment]
    }

    private struct SpeakerNameAssignment: Decodable {
        let label: String
        let name: String?
    }

    private static func lines(in transcript: String) -> [String] {
        transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func label(atStartOf line: String) -> String? {
        guard let range = labelRange(atStartOf: line) else { return nil }
        let label = line[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    /// The range of the text inside the leading `[label]`.
    private static func labelRange(atStartOf line: String) -> Range<String.Index>? {
        let start = line.firstIndex(where: { !$0.isWhitespace }) ?? line.endIndex
        guard start < line.endIndex, line[start] == "[" else { return nil }
        let labelStart = line.index(after: start)
        guard let close = line[labelStart...].firstIndex(of: "]"), labelStart < close else { return nil }
        return labelStart..<close
    }

    private static func normalizedModelName(_ raw: String?) -> String? {
        guard var name = raw.flatMap(normalizedUserName) else { return nil }
        if name.hasSuffix(".") {
            name = String(name.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalizedUserName(name)
    }

    private static func isGenericLabel(_ name: String) -> Bool {
        let folded = name.lowercased()
        if folded == "speaker" || folded == "unknown" || folded == "conversation" || folded == "participant" {
            return true
        }
        if folded.hasPrefix("speaker ") {
            let rest = folded.dropFirst("speaker ".count)
            return !rest.isEmpty && rest.allSatisfy { $0.isLetter || $0.isNumber }
        }
        return false
    }

    private static func isSupported(_ name: String, transcript: String, callTitle: String?) -> Bool {
        if let callTitle, containsName(name, in: callTitle) { return true }
        let speech = lines(in: transcript).map { line -> String in
            guard let range = labelRange(atStartOf: line) else { return line }
            let after = line.index(after: range.upperBound)
            guard after <= line.endIndex else { return "" }
            return String(line[after...])
        }.joined(separator: "\n")
        return containsName(name, in: speech)
    }

    private static func containsName(_ name: String, in text: String) -> Bool {
        let haystack = text.lowercased()
        let needle = name.lowercased()
        guard !needle.isEmpty else { return false }
        var search = haystack.startIndex
        while let range = haystack.range(of: needle, range: search..<haystack.endIndex) {
            let beforeOK = range.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == haystack.endIndex
                || !haystack[range.upperBound].isLetter
            if beforeOK && afterOK { return true }
            search = range.upperBound
        }
        return false
    }

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
}
