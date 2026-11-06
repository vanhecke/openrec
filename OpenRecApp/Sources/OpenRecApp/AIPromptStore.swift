import Foundation

/// Chat prompts for meeting memory and speaker names.
///
/// OpenAI and Grok share one set. Custom text is stored in UserDefaults on
/// this Mac. Empty text uses the built-in default. Transcription requests do
/// not read this store, and the JSON schemas stay outside it.
enum AIPromptStore {
    enum Prompt: String, CaseIterable {
        case meetingMemorySystem
        case meetingMemoryUser
        case speakerIdentificationSystem
        case speakerIdentificationUser

        var defaultsKey: String {
            switch self {
            case .meetingMemorySystem:
                return "OpenRecPrompt.meetingMemory.system"
            case .meetingMemoryUser:
                return "OpenRecPrompt.meetingMemory.user"
            case .speakerIdentificationSystem:
                return "OpenRecPrompt.speakerIdentification.system"
            case .speakerIdentificationUser:
                return "OpenRecPrompt.speakerIdentification.user"
            }
        }

        /// Placeholders that the built-in template sends today. A custom
        /// template that drops one still gets that live value appended.
        var requiredPlaceholders: [Placeholder] {
            switch self {
            case .meetingMemorySystem, .speakerIdentificationSystem:
                return []
            case .meetingMemoryUser:
                return [.callTitle, .transcript]
            case .speakerIdentificationUser:
                return [.speakerLabels, .callTitle, .transcript]
            }
        }

        var defaultText: String {
            switch self {
            case .meetingMemorySystem:
                return Self.meetingMemorySystemDefault
            case .meetingMemoryUser:
                return Self.meetingMemoryUserDefault
            case .speakerIdentificationSystem:
                return Self.speakerIdentificationSystemDefault
            case .speakerIdentificationUser:
                return Self.speakerIdentificationUserDefault
            }
        }

        private static let meetingMemorySystemDefault = "You take meeting notes like an excellent human note-taker, and extract participants, decisions, and concrete next steps."

        private static let meetingMemoryUserDefault = """
        Turn this meeting transcript into concise, factual meeting memory. Infer participant names only when the transcript explicitly supports them. Never invent names, owners, dates, or decisions. Return JSON matching the provided schema. Suggested title from the call window: {{callTitle}}.

        Lines begin with a bracketed speaker label. When that label is a person's name, use it for participants, decisions, and next-step owners.

        For "aiNotes", write markdown notes the way a sharp human note-taker would capture the call as it happened: short "## " section headers that follow the conversation's actual topics, tight "- " bullet fragments underneath (not full prose sentences), with concrete specifics preserved — names, numbers, prices, tools, dates, and memorable quotes worth keeping. Bold the load-bearing terms. Keep it scannable; no filler, no meta commentary about the transcript.

        For "summary", write 2-3 plain sentences of what the call was about and where it landed.

        Transcript:
        {{transcript}}
        """

        private static let speakerIdentificationSystemDefault = "You attach real names to diarized speaker labels. You never guess."

        private static let speakerIdentificationUserDefault = """
        Identify the real name of each diarized speaker. The transcript labels speakers as {{speakerLabels}}. Use a name only when the transcript explicitly supports it: someone introduces themselves, another speaker addresses them by name, or the meeting title names them. Never invent a name. If a speaker's name is not supported, return null. Return one entry for every label, using the label text exactly.

        Meeting title: {{callTitle}}

        Transcript:
        {{transcript}}
        """
    }

    enum Placeholder: String, CaseIterable {
        case transcript
        case callTitle
        case speakerLabels

        var token: String { "{{\(rawValue)}}" }
    }

    static func effective(_ prompt: Prompt, defaults: UserDefaults = .standard) -> String {
        guard let stored = defaults.string(forKey: prompt.defaultsKey) else {
            return prompt.defaultText
        }
        if stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return prompt.defaultText
        }
        return stored
    }

    /// Empty text and text that matches the built-in default both clear the
    /// customization, so a later default change still applies.
    static func set(_ prompt: Prompt, text: String, defaults: UserDefaults = .standard) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == prompt.defaultText.trimmingCharacters(in: .whitespacesAndNewlines) {
            defaults.removeObject(forKey: prompt.defaultsKey)
            return
        }
        defaults.set(text, forKey: prompt.defaultsKey)
    }

    static func restore(_ prompt: Prompt, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: prompt.defaultsKey)
    }

    static func restoreAll(defaults: UserDefaults = .standard) {
        for prompt in Prompt.allCases {
            restore(prompt, defaults: defaults)
        }
    }

    static func meetingMemorySystem(defaults: UserDefaults = .standard) -> String {
        effective(.meetingMemorySystem, defaults: defaults)
    }

    static func meetingMemoryUser(
        transcript: String,
        callTitle: String?,
        defaults: UserDefaults = .standard
    ) -> String {
        render(
            .meetingMemoryUser,
            values: [
                .callTitle: callTitle ?? "none",
                .transcript: transcript,
            ],
            defaults: defaults
        )
    }

    static func speakerIdentificationSystem(defaults: UserDefaults = .standard) -> String {
        effective(.speakerIdentificationSystem, defaults: defaults)
    }

    static func speakerIdentificationUser(
        transcript: String,
        callTitle: String?,
        labels: [String],
        defaults: UserDefaults = .standard
    ) -> String {
        let trimmedTitle = callTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedTitle.isEmpty ? "none" : trimmedTitle
        return render(
            .speakerIdentificationUser,
            values: [
                .speakerLabels: labels.joined(separator: ", "),
                .callTitle: title,
                .transcript: transcript,
            ],
            defaults: defaults
        )
    }

    private static func render(
        _ prompt: Prompt,
        values: [Placeholder: String],
        defaults: UserDefaults
    ) -> String {
        let template = effective(prompt, defaults: defaults)
        let filled = substitute(template, values: values)
        return appendMissing(prompt, to: filled, template: template, values: values)
    }

    /// Replaces tokens in the template only. Inserted values are not scanned,
    /// so a transcript that mentions a placeholder stays literal.
    private static func substitute(_ template: String, values: [Placeholder: String]) -> String {
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            guard let (placeholder, tokenRange) = firstPlaceholder(in: template, from: index) else {
                result.append(contentsOf: template[index...])
                break
            }
            result.append(contentsOf: template[index..<tokenRange.lowerBound])
            if let value = values[placeholder] {
                result.append(value)
            } else {
                result.append(contentsOf: template[tokenRange])
            }
            index = tokenRange.upperBound
        }
        return result
    }

    private static func firstPlaceholder(
        in template: String,
        from index: String.Index
    ) -> (Placeholder, Range<String.Index>)? {
        let remainder = index..<template.endIndex
        var found: (Placeholder, Range<String.Index>)?
        for placeholder in Placeholder.allCases {
            guard let range = template.range(of: placeholder.token, range: remainder) else { continue }
            if let current = found, range.lowerBound >= current.1.lowerBound { continue }
            found = (placeholder, range)
        }
        return found
    }

    private static func appendMissing(
        _ prompt: Prompt,
        to text: String,
        template: String,
        values: [Placeholder: String]
    ) -> String {
        var suffix: [String] = []
        for placeholder in prompt.requiredPlaceholders where !template.contains(placeholder.token) {
            guard let value = values[placeholder] else { continue }
            suffix.append(fallbackLine(placeholder, value: value))
        }
        guard !suffix.isEmpty else { return text }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return suffix.joined(separator: "\n\n")
        }
        return text + "\n\n" + suffix.joined(separator: "\n\n")
    }

    private static func fallbackLine(_ placeholder: Placeholder, value: String) -> String {
        switch placeholder {
        case .transcript:
            return "Transcript:\n\(value)"
        case .callTitle:
            return "Meeting title: \(value)"
        case .speakerLabels:
            return "Speaker labels: \(value)"
        }
    }
}
