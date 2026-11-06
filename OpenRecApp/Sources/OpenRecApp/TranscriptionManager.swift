import Foundation
import CoreMedia
import Combine

protocol RealtimeTranscriptionDelegate: AnyObject {
    func realtimeTranscriptionDidUpdate(_ text: String)
    func realtimeTranscriptionDidCommit(_ text: String, speakerLabel: String?)
    func realtimeTranscriptionDidFail(_ error: Error)
}

enum TranscriptionMode: String, CaseIterable {
    case live = "Live"
    case postRecording = "After"
}

// Transcription always runs post-recording; the live mode code paths are kept but unreachable.

struct DisplaySegment: Identifiable {
    let id = UUID()
    let speakerLabel: String
    let text: String
    let timestamp: Double?
}

@MainActor
final class TranscriptionManager: ObservableObject {
    let mode: TranscriptionMode = .postRecording
    @Published var isTranscribing = false
    @Published var isAnalyzing = false
    @Published var showPanel = false
    @Published var partialText = ""
    @Published var committedSegments: [DisplaySegment] = []
    @Published var insights = MeetingInsights()
    @Published var error: String?

    private var realtimeSTT: AssemblyAIRealtimeTranscriber?
    private(set) var audioMixer: AudioMixer?
    private var delegateBridge: RealtimeBridge?
    private var savedEnergyTimeline: [AudioEnergySnapshot] = []

    var assemblyAIAPIKey: String {
        get { KeychainStore.string(for: "assemblyai-api-key") }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let changed = normalized
                != assemblyAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainStore.set(normalized, for: "assemblyai-api-key")
            if changed { UserDefaults.standard.set(false, forKey: "AssemblyAIKeyVerified") }
            objectWillChange.send()
        }
    }

    var openAIAPIKey: String {
        get { KeychainStore.string(for: MeetingMemoryProvider.openAIKeychainAccount) }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let changed = normalized
                != openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainStore.set(normalized, for: MeetingMemoryProvider.openAIKeychainAccount)
            if changed { UserDefaults.standard.set(false, forKey: MeetingMemoryProvider.openAIVerifiedDefaultsKey) }
            objectWillChange.send()
        }
    }

    var xaiAPIKey: String {
        get { KeychainStore.string(for: MeetingMemoryProvider.grokKeychainAccount) }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let changed = normalized
                != xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainStore.set(normalized, for: MeetingMemoryProvider.grokKeychainAccount)
            if changed { UserDefaults.standard.set(false, forKey: MeetingMemoryProvider.grokVerifiedDefaultsKey) }
            objectWillChange.send()
        }
    }

    var meetingMemoryProvider: MeetingMemoryProvider {
        get {
            MeetingMemoryProvider.resolved(
                from: UserDefaults.standard.string(forKey: MeetingMemoryProvider.defaultsKey)
            )
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: MeetingMemoryProvider.defaultsKey)
            objectWillChange.send()
        }
    }

    var hasAssemblyAIAPIKey: Bool {
        !assemblyAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isAssemblyAIAPIKeyVerified: Bool {
        hasAssemblyAIAPIKey && UserDefaults.standard.bool(forKey: "AssemblyAIKeyVerified")
    }

    var transcriptionProvider: TranscriptionProvider {
        get {
            TranscriptionProvider.resolved(
                from: UserDefaults.standard.string(forKey: TranscriptionProvider.defaultsKey)
            )
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: TranscriptionProvider.defaultsKey)
            objectWillChange.send()
        }
    }

    var transcriptionCredentials: TranscriptionCredentials {
        TranscriptionCredentials(
            provider: transcriptionProvider,
            assemblyKey: assemblyAIAPIKey,
            assemblyVerified: UserDefaults.standard.bool(forKey: "AssemblyAIKeyVerified"),
            grokKey: xaiAPIKey,
            grokVerified: UserDefaults.standard.bool(forKey: MeetingMemoryProvider.grokVerifiedDefaultsKey)
        )
    }

    var isSelectedTranscriptionKeyVerified: Bool {
        transcriptionCredentials.isSelectedKeyVerified
    }

    var hasOpenAIAPIKey: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isOpenAIAPIKeyVerified: Bool {
        hasOpenAIAPIKey && UserDefaults.standard.bool(forKey: MeetingMemoryProvider.openAIVerifiedDefaultsKey)
    }

    var hasXAIAPIKey: Bool {
        !xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isXAIAPIKeyVerified: Bool {
        hasXAIAPIKey && UserDefaults.standard.bool(forKey: MeetingMemoryProvider.grokVerifiedDefaultsKey)
    }

    var meetingMemoryCredentials: MeetingMemoryCredentials {
        MeetingMemoryCredentials(
            provider: meetingMemoryProvider,
            openAIKey: openAIAPIKey,
            openAIVerified: UserDefaults.standard.bool(forKey: MeetingMemoryProvider.openAIVerifiedDefaultsKey),
            grokKey: xaiAPIKey,
            grokVerified: UserDefaults.standard.bool(forKey: MeetingMemoryProvider.grokVerifiedDefaultsKey)
        )
    }

    var isSelectedMeetingMemoryKeyVerified: Bool {
        meetingMemoryCredentials.isSelectedKeyVerified
    }

    func startLiveTranscription() {
        guard hasAssemblyAIAPIKey, mode == .live else { return }
        resetTranscript()
        isTranscribing = true

        let mixer = AudioMixer()
        audioMixer = mixer
        let bridge = RealtimeBridge(manager: self)
        delegateBridge = bridge
        let transcriber = AssemblyAIRealtimeTranscriber(apiKey: assemblyAIAPIKey)
        realtimeSTT = transcriber
        transcriber.delegate = bridge
        mixer.onChunkReady = { [weak transcriber] data in transcriber?.sendAudioChunk(data) }
        transcriber.connect()
        mixer.start()
    }

    func startEnergyTracking() {
        let mixer = AudioMixer()
        audioMixer = mixer
        mixer.onChunkReady = { _ in }
        mixer.start()
    }

    func stopEnergyTracking() {
        if let mixer = audioMixer { savedEnergyTimeline = mixer.energyTimeline }
        audioMixer?.stop()
        audioMixer = nil
    }

    func stopLiveTranscription() {
        if let mixer = audioMixer { savedEnergyTimeline = mixer.energyTimeline }
        audioMixer?.stop()
        audioMixer = nil
        realtimeSTT?.disconnect()
        realtimeSTT = nil
        delegateBridge = nil
        isTranscribing = false
        partialText = ""
    }

    func getAudioMixer() -> AudioMixer? { audioMixer }

    func transcribeRecording(audioURL: URL) async throws {
        try await transcribe(localFile: audioURL)
    }

    func transcribeCloudRecording(audioURL: URL) async throws {
        try await transcribe(remoteAudioURL: audioURL)
    }

    private func transcribe(localFile audioURL: URL) async throws {
        let credentials = transcriptionCredentials
        guard credentials.hasSelectedKey else {
            throw OpenRecError.invalidConfiguration(credentials.provider.missingKeyConfigurationMessage)
        }
        isTranscribing = true
        error = nil
        defer { isTranscribing = false }
        do {
            let segments: [DisplaySegment]
            switch credentials.provider {
            case .assemblyAI:
                segments = try await AssemblyAIService(apiKey: assemblyAIAPIKey).transcribe(fileURL: audioURL)
            case .grok:
                segments = try await GrokService(apiKey: xaiAPIKey).transcribe(fileURL: audioURL)
            }
            committedSegments = segments
            partialText = ""
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    private func transcribe(remoteAudioURL audioURL: URL) async throws {
        let credentials = transcriptionCredentials
        guard credentials.hasSelectedKey else {
            throw OpenRecError.invalidConfiguration(credentials.provider.missingKeyConfigurationMessage)
        }
        isTranscribing = true
        error = nil
        defer { isTranscribing = false }
        do {
            let segments: [DisplaySegment]
            switch credentials.provider {
            case .assemblyAI:
                segments = try await AssemblyAIService(apiKey: assemblyAIAPIKey).transcribe(audioURL: audioURL)
            case .grok:
                segments = try await GrokService(apiKey: xaiAPIKey).transcribe(audioURL: audioURL)
            }
            committedSegments = segments
            partialText = ""
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    func analyze(callTitle: String?) async throws -> MeetingInsights {
        let transcript = fullTranscriptText()
        guard !transcript.isEmpty else { return MeetingInsights() }
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let value = try await generateInsights(transcript: transcript, callTitle: callTitle)
            insights = value
            return value
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    func generateInsights(transcript: String, callTitle: String?) async throws -> MeetingInsights {
        let credentials = meetingMemoryCredentials
        guard credentials.hasSelectedKey else {
            throw OpenRecError.invalidConfiguration(credentials.provider.missingKeyConfigurationMessage)
        }
        return try await MeetingMemoryClient.generateInsights(
            provider: credentials.provider,
            apiKey: credentials.selectedKey,
            transcript: transcript,
            callTitle: callTitle
        )
    }

    func saveTranscript(to directory: URL, baseName: String) throws {
        guard !committedSegments.isEmpty else { return }
        let fileURL = directory.appendingPathComponent("\(baseName)_transcript.txt")
        try fullTranscriptText().write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func fullTranscriptText() -> String {
        committedSegments.map { "[\($0.speakerLabel)] \($0.text)" }.joined(separator: "\n")
    }

    func resetTranscript() {
        partialText = ""
        committedSegments = []
        error = nil
        insights = MeetingInsights()
        savedEnergyTimeline = []
    }

    fileprivate func handlePartial(_ text: String) { partialText = text }

    fileprivate func handleCommitted(_ text: String, speakerLabel: String?) {
        partialText = ""
        let timestamp = savedEnergyTimeline.last?.timestamp ?? audioMixer?.energyTimeline.last?.timestamp
        committedSegments.append(DisplaySegment(
            speakerLabel: normalizedSpeakerLabel(speakerLabel) ?? speakerLabelFromEnergy(at: timestamp),
            text: text,
            timestamp: timestamp
        ))
    }

    fileprivate func handleFailure(_ failure: Error) {
        error = failure.localizedDescription
        isTranscribing = false
    }

    private func speakerLabelFromEnergy(at timestamp: Double?) -> String {
        guard let timestamp else { return "Conversation" }
        let timeline = audioMixer?.energyTimeline ?? savedEnergyTimeline
        guard var closest = timeline.first else { return "Conversation" }
        var difference = abs(closest.timestamp - timestamp)
        for snapshot in timeline {
            let candidate = abs(snapshot.timestamp - timestamp)
            if candidate < difference { closest = snapshot; difference = candidate }
            if snapshot.timestamp > timestamp + 1 { break }
        }
        return closest.dominantSource == .mic ? "Me" : "Others"
    }

    private func normalizedSpeakerLabel(_ label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return nil
        }
        return label.localizedCaseInsensitiveCompare("unknown") == .orderedSame
            ? "Speaker"
            : "Speaker \(label)"
    }
}

private final class RealtimeBridge: RealtimeTranscriptionDelegate {
    private weak var manager: TranscriptionManager?
    init(manager: TranscriptionManager) { self.manager = manager }

    func realtimeTranscriptionDidUpdate(_ text: String) {
        Task { @MainActor [weak self] in self?.manager?.handlePartial(text) }
    }

    func realtimeTranscriptionDidCommit(_ text: String, speakerLabel: String?) {
        Task { @MainActor [weak self] in
            self?.manager?.handleCommitted(text, speakerLabel: speakerLabel)
        }
    }

    func realtimeTranscriptionDidFail(_ error: Error) {
        Task { @MainActor [weak self] in self?.manager?.handleFailure(error) }
    }
}
