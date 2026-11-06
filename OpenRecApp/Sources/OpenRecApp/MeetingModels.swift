import Foundation

enum StorageMode: String, CaseIterable, Identifiable, Codable {
    case managed
    case ownR2
    case local

    var id: String { rawValue }
    var label: String {
        switch self {
        case .managed: return "OpenRec Cloud"
        case .ownR2: return "My R2"
        case .local: return "This Mac"
        }
    }

    /// Onboarding Continue on the storage step. OpenRec Cloud continues once
    /// Google sign-in makes storage ready. My R2 also needs a verified bucket.
    /// This Mac is ready with no Google session and no R2 credentials.
    func onboardingCanContinue(isReady: Bool, r2ConnectionVerified: Bool) -> Bool {
        guard isReady else { return false }
        switch self {
        case .managed, .local:
            return true
        case .ownR2:
            return r2ConnectionVerified
        }
    }
}

struct CallPreferences: Codable, Equatable {
    var keepScreenRecording = true
    var keepAudioRecording = true
    var storeTranscriptInCloud = true
    var sendToWebhook = false
}

enum SavePhase: Equatable {
    case idle
    case finalizing
    case transcribing
    case analyzing
    case uploading
    case deliveringWebhook
    case cleaningUp
    case complete
    case completeWithWarning(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .finalizing: return "Finalizing recording"
        case .transcribing: return "Transcribing"
        case .analyzing: return "Finding next steps"
        case .uploading: return "Uploading securely"
        case .deliveringWebhook: return "Sending webhook"
        case .cleaningUp: return "Applying retention"
        case .complete: return "Saved"
        case .completeWithWarning: return "Saved with a warning"
        case .failed: return "Couldn’t finish saving"
        }
    }

    var detail: String? {
        switch self {
        case .failed(let message), .completeWithWarning(let message): return message
        default: return nil
        }
    }

    var isSaved: Bool {
        switch self {
        case .complete, .completeWithWarning: return true
        default: return false
        }
    }
}

struct MeetingActionItem: Codable, Identifiable, Equatable {
    var id = UUID()
    let owner: String
    let task: String
    let dueDate: String?

    private enum CodingKeys: String, CodingKey {
        case owner, task, dueDate
    }
}

struct MeetingInsights: Codable, Equatable {
    var title = "Untitled call"
    var summary = ""
    /// Granola-style markdown meeting notes. Optional in stored records so
    /// meetings saved before this field existed keep decoding.
    var aiNotes = ""
    var participants: [String] = []
    var actionItems: [MeetingActionItem] = []
    var decisions: [String] = []

    init(
        title: String = "Untitled call",
        summary: String = "",
        aiNotes: String = "",
        participants: [String] = [],
        actionItems: [MeetingActionItem] = [],
        decisions: [String] = []
    ) {
        self.title = title
        self.summary = summary
        self.aiNotes = aiNotes
        self.participants = participants
        self.actionItems = actionItems
        self.decisions = decisions
    }

    private enum CodingKeys: String, CodingKey {
        case title, summary, aiNotes, participants, actionItems, decisions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Untitled call"
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        aiNotes = try values.decodeIfPresent(String.self, forKey: .aiNotes) ?? ""
        participants = try values.decodeIfPresent([String].self, forKey: .participants) ?? []
        actionItems = try values.decodeIfPresent([MeetingActionItem].self, forKey: .actionItems) ?? []
        decisions = try values.decodeIfPresent([String].self, forKey: .decisions) ?? []
    }
}

struct MeetingPayload: Codable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let callApp: String?
    let callTitle: String?
    let transcript: String
    let insights: MeetingInsights
    let durationSeconds: Int
}

enum MeetingSaveStatus: String, Codable, Equatable {
    case processing
    case saved
    case failed
}

enum WebhookDeliveryStatus: String, Codable, Equatable {
    case pending
    case delivered
    case failed
}

enum MeetingSaveStage: String, Codable, Equatable {
    case finalizing
    case transcribing
    case analyzing
    case storingMetadata
    case uploadingMedia
    case deliveringWebhook
    case cleaningUp
    case complete

    var label: String {
        switch self {
        case .finalizing: return "Finalizing recording"
        case .transcribing: return "Transcribing conversation"
        case .analyzing: return "Finding next steps"
        case .storingMetadata: return "Saving meeting memory"
        case .uploadingMedia: return "Uploading recordings"
        case .deliveringWebhook: return "Sending webhook"
        case .cleaningUp: return "Applying retention choices"
        case .complete: return "Saved"
        }
    }
}

enum MeetingMediaKind: String, CaseIterable, Identifiable {
    case screen
    case audio

    var id: String { rawValue }
    var label: String { self == .screen ? "Screen recording" : "Voice recording" }
}

/// The durable local index behind the recordings library. Managed-cloud records
/// are merged into this model so the UI behaves the same online and offline.
struct MeetingRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date
    var durationSeconds: Int
    var callApp: String?
    var callTitle: String?
    var transcript: String?
    var insights: MeetingInsights
    var hasScreenRecording: Bool
    var hasAudioRecording: Bool
    var screenFileExtension: String?
    var audioFileExtension: String?
    var localScreenPath: String?
    var localAudioPath: String?
    var storageMode: StorageMode
    var preferences: CallPreferences
    var saveStatus: MeetingSaveStatus
    var saveStage: MeetingSaveStage
    var errorMessage: String?
    var webhookDeliveryStatus: WebhookDeliveryStatus? = nil
    var webhookErrorMessage: String? = nil
    /// URL-based webhook receivers may fetch media after acknowledging the
    /// event. Unretained objects remain private until these local cleanup times.
    var screenDeletionScheduledAt: Date? = nil
    var audioDeletionScheduledAt: Date? = nil
    var createdAt: Date
    var updatedAt: Date

    var title: String {
        let generated = insights.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !generated.isEmpty && generated != "Untitled call" { return generated }
        let detected = callTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detected.isEmpty ? "Untitled call" : detected
    }

    var localScreenURL: URL? {
        guard let localScreenPath, FileManager.default.fileExists(atPath: localScreenPath) else { return nil }
        return URL(fileURLWithPath: localScreenPath)
    }

    var localAudioURL: URL? {
        guard let localAudioPath, FileManager.default.fileExists(atPath: localAudioPath) else { return nil }
        return URL(fileURLWithPath: localAudioPath)
    }

    var hasPlayableScreen: Bool {
        hasScreenRecording || (localScreenURL != nil && (preferences.keepScreenRecording || saveStatus != .saved))
    }
    var hasPlayableAudio: Bool {
        hasAudioRecording || (localAudioURL != nil && (preferences.keepAudioRecording || saveStatus != .saved))
    }

    var payload: MeetingPayload {
        MeetingPayload(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            callApp: callApp,
            callTitle: callTitle,
            transcript: transcript ?? "",
            insights: insights,
            durationSeconds: durationSeconds
        )
    }
}

/// Which provider transcribes and diarizes the recording.
/// An absent or unknown stored value stays on AssemblyAI so existing installs
/// keep their current transcription key and path.
enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case assemblyAI
    case grok

    static let defaultsKey = "TranscriptionProvider"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .assemblyAI: return "AssemblyAI"
        case .grok: return "Grok"
        }
    }

    var modelLabel: String {
        switch self {
        case .assemblyAI: return "Universal-3.5 Pro"
        case .grok: return "grok-voice-transcribe-2.0"
        }
    }

    var missingKeySettingsMessage: String {
        switch self {
        case .assemblyAI:
            return "Open Settings and add your AssemblyAI API key before recording."
        case .grok:
            return "Open Settings and add your Grok API key before recording."
        }
    }

    var unverifiedKeySettingsMessage: String {
        switch self {
        case .assemblyAI:
            return "Open Settings and test your AssemblyAI API key before recording."
        case .grok:
            return "Open Settings and test your Grok API key before recording."
        }
    }

    var missingKeyConfigurationMessage: String {
        switch self {
        case .assemblyAI:
            return "Add your AssemblyAI API key before recording."
        case .grok:
            return "Add your Grok API key before recording."
        }
    }

    static func resolved(from stored: String?) -> TranscriptionProvider {
        guard let stored, let provider = TranscriptionProvider(rawValue: stored) else {
            return .assemblyAI
        }
        return provider
    }
}

/// Language sent to grok-voice-transcribe-2.0.
/// A missing or unknown stored value is Auto-Detect: the request omits both
/// `language` and `format`, so the model follows mid-call language switches.
/// A chosen language sends `language` and `format=true` together.
enum GrokTranscriptionLanguage: String, CaseIterable, Identifiable {
    case autoDetect = "auto"
    case arabic = "ar"
    case bosnian = "bs"
    case bulgarian = "bg"
    case cantonese = "yue"
    case catalan = "ca"
    case chineseMandarin = "zh"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case english = "en"
    case filipino = "fil"
    case finnish = "fi"
    case french = "fr"
    case german = "de"
    case greek = "el"
    case hindi = "hi"
    case hungarian = "hu"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case macedonian = "mk"
    case malay = "ms"
    case norwegianBokmal = "nb"
    case persian = "fa"
    case polish = "pl"
    case portuguese = "pt"
    case romanian = "ro"
    case russian = "ru"
    case slovak = "sk"
    case spanish = "es"
    case swedish = "sv"
    case thai = "th"
    case turkish = "tr"
    case ukrainian = "uk"
    case urdu = "ur"
    case vietnamese = "vi"

    static let defaultsKey = "GrokTranscriptionLanguage"

    var id: String { rawValue }

    /// Code for the `language` field. Nil means Auto-Detect: omit `language`
    /// and `format`. `format=true` without `language` is rejected.
    var languageCode: String? {
        self == .autoDetect ? nil : rawValue
    }

    var displayName: String {
        switch self {
        case .autoDetect: return "Auto-Detect"
        case .arabic: return "Arabic"
        case .bosnian: return "Bosnian"
        case .bulgarian: return "Bulgarian"
        case .cantonese: return "Cantonese"
        case .catalan: return "Catalan"
        case .chineseMandarin: return "Chinese (Mandarin)"
        case .croatian: return "Croatian"
        case .czech: return "Czech"
        case .danish: return "Danish"
        case .dutch: return "Dutch"
        case .english: return "English"
        case .filipino: return "Filipino"
        case .finnish: return "Finnish"
        case .french: return "French"
        case .german: return "German"
        case .greek: return "Greek"
        case .hindi: return "Hindi"
        case .hungarian: return "Hungarian"
        case .indonesian: return "Indonesian"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .macedonian: return "Macedonian"
        case .malay: return "Malay"
        case .norwegianBokmal: return "Norwegian (Bokmål)"
        case .persian: return "Persian"
        case .polish: return "Polish"
        case .portuguese: return "Portuguese"
        case .romanian: return "Romanian"
        case .russian: return "Russian"
        case .slovak: return "Slovak"
        case .spanish: return "Spanish"
        case .swedish: return "Swedish"
        case .thai: return "Thai"
        case .turkish: return "Turkish"
        case .ukrainian: return "Ukrainian"
        case .urdu: return "Urdu"
        case .vietnamese: return "Vietnamese"
        }
    }

    var pickerDetail: String {
        if languageCode == nil {
            return "Follows mid-call language switches"
        }
        return "Prefers this language"
    }

    static func resolved(from stored: String?) -> GrokTranscriptionLanguage {
        guard let stored, let language = GrokTranscriptionLanguage(rawValue: stored) else {
            return .autoDetect
        }
        return language
    }

    static func stored(in defaults: UserDefaults = .standard) -> GrokTranscriptionLanguage {
        resolved(from: defaults.string(forKey: defaultsKey))
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Product names and proper nouns repeated as `keyterm` for grok-voice-transcribe-2.0.
/// A missing, empty, or unreadable stored value is an empty list, and an empty
/// list omits `keyterm` from the transcription request.
/// Stored as a JSON string array so spaces survive. On store and on send,
/// terms are trimmed, empties dropped, each capped at 50 characters, and
/// limited to the first 100. Wording and order are preserved.
enum GrokTranscriptionKeyTerms {
    static let defaultsKey = "GrokTranscriptionKeyTerms"
    static let maxCount = 100
    static let maxCharacters = 50

    static func normalized(_ terms: [String]) -> [String] {
        var kept: [String] = []
        kept.reserveCapacity(min(terms.count, maxCount))
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            kept.append(String(trimmed.prefix(maxCharacters)))
            if kept.count == maxCount { break }
        }
        return kept
    }

    static func resolved(from stored: String?) -> [String] {
        guard let stored, let data = stored.data(using: .utf8),
              let terms = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return normalized(terms)
    }

    static func stored(in defaults: UserDefaults = .standard) -> [String] {
        resolved(from: defaults.string(forKey: defaultsKey))
    }

    static func store(_ terms: [String], in defaults: UserDefaults = .standard) {
        let normalized = normalized(terms)
        guard let data = try? JSONEncoder().encode(normalized),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(json, forKey: defaultsKey)
    }
}

struct TranscriptionCredentials: Equatable {
    var provider: TranscriptionProvider
    var assemblyKey: String
    var assemblyVerified: Bool
    var grokKey: String
    var grokVerified: Bool

    var selectedKey: String {
        switch provider {
        case .assemblyAI: return assemblyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        case .grok: return grokKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var hasSelectedKey: Bool { !selectedKey.isEmpty }

    var isSelectedKeyVerified: Bool {
        guard hasSelectedKey else { return false }
        switch provider {
        case .assemblyAI: return assemblyVerified
        case .grok: return grokVerified
        }
    }
}

/// Which provider writes meeting memory after transcription.
/// An absent or unknown stored value stays on OpenAI so existing installs
/// keep their current key, onboarding, and analyze path.
enum MeetingMemoryProvider: String, CaseIterable, Identifiable {
    case openai
    case grok

    static let defaultsKey = "MeetingMemoryProvider"
    static let openAIKeychainAccount = "openai-api-key"
    static let grokKeychainAccount = "xai-api-key"
    static let openAIVerifiedDefaultsKey = "OpenAIKeyVerified"
    static let grokVerifiedDefaultsKey = "XAIKeyVerified"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .grok: return "Grok"
        }
    }

    /// Text model for summaries, decisions, next steps, participants, and notes.
    /// Grok uses grok-4.7. OpenAI stays on gpt-5-mini.
    var modelID: String {
        switch self {
        case .openai: return "gpt-5-mini"
        case .grok: return "grok-4.7"
        }
    }

    var keychainAccount: String {
        switch self {
        case .openai: return Self.openAIKeychainAccount
        case .grok: return Self.grokKeychainAccount
        }
    }

    var verifiedDefaultsKey: String {
        switch self {
        case .openai: return Self.openAIVerifiedDefaultsKey
        case .grok: return Self.grokVerifiedDefaultsKey
        }
    }

    var consoleURL: URL {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .grok: return URL(string: "https://console.x.ai/")!
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openai: return "sk-proj-…"
        case .grok: return "xai-…"
        }
    }

    var missingKeySettingsMessage: String {
        switch self {
        case .openai:
            return "Open Settings and add your OpenAI API key for meeting summaries and next steps."
        case .grok:
            return "Open Settings and add your Grok API key for meeting summaries and next steps."
        }
    }

    var unverifiedKeySettingsMessage: String {
        switch self {
        case .openai:
            return "Open Settings and test your OpenAI API key before recording."
        case .grok:
            return "Open Settings and test your Grok API key before recording."
        }
    }

    var missingKeyConfigurationMessage: String {
        switch self {
        case .openai:
            return "Add your OpenAI API key to generate meeting memory."
        case .grok:
            return "Add your Grok API key to generate meeting memory."
        }
    }

    static func resolved(from stored: String?) -> MeetingMemoryProvider {
        guard let stored, let provider = MeetingMemoryProvider(rawValue: stored) else {
            return .openai
        }
        return provider
    }
}

struct MeetingMemoryCredentials: Equatable {
    var provider: MeetingMemoryProvider
    var openAIKey: String
    var openAIVerified: Bool
    var grokKey: String
    var grokVerified: Bool

    var selectedKey: String {
        switch provider {
        case .openai: return openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        case .grok: return grokKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var hasSelectedKey: Bool { !selectedKey.isEmpty }

    var isSelectedKeyVerified: Bool {
        guard hasSelectedKey else { return false }
        switch provider {
        case .openai: return openAIVerified
        case .grok: return grokVerified
        }
    }
}

struct OnboardingReadiness: Equatable {
    var markedComplete: Bool
    var transcription: TranscriptionCredentials
    var meetingMemory: MeetingMemoryCredentials

    var isComplete: Bool {
        markedComplete
            && transcription.isSelectedKeyVerified
            && meetingMemory.isSelectedKeyVerified
    }
}

enum OpenRecError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case requestFailed(status: Int, message: String)
    case recordingFailed(String)
    case timedOut(String)
    /// The provider processed the audio successfully but found no spoken
    /// words. Distinct from request/auth failures so the UI can avoid
    /// blaming the API key or the network for a silent recording.
    case noSpeechDetected(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message),
             .invalidResponse(let message),
             .recordingFailed(let message),
             .timedOut(let message),
             .noSpeechDetected(let message):
            return message
        case .requestFailed(let status, let message):
            return "Request failed (\(status)): \(message)"
        }
    }
}
