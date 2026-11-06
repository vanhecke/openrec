import Foundation
import XCTest
@testable import OpenRecApp

final class LocalStorageModeTests: XCTestCase {
    @MainActor
    func testLocalModeIsReadyWithoutCredentialsAndExistingModesAreUnchanged() {
        XCTAssertTrue(CloudStorageManager.storageIsReady(
            mode: .local,
            managedSignedIn: false,
            r2AccountID: "",
            r2Bucket: "",
            r2AccessKeyID: "",
            r2SecretAccessKey: ""
        ))
        XCTAssertFalse(CloudStorageManager.storageIsReady(
            mode: .managed,
            managedSignedIn: false,
            r2AccountID: "account",
            r2Bucket: "bucket",
            r2AccessKeyID: "access",
            r2SecretAccessKey: "secret"
        ))
        XCTAssertTrue(CloudStorageManager.storageIsReady(
            mode: .managed,
            managedSignedIn: true,
            r2AccountID: "",
            r2Bucket: "",
            r2AccessKeyID: "",
            r2SecretAccessKey: ""
        ))
        XCTAssertFalse(CloudStorageManager.storageIsReady(
            mode: .ownR2,
            managedSignedIn: true,
            r2AccountID: "account",
            r2Bucket: "",
            r2AccessKeyID: "access",
            r2SecretAccessKey: "secret"
        ))
        XCTAssertTrue(CloudStorageManager.storageIsReady(
            mode: .ownR2,
            managedSignedIn: false,
            r2AccountID: "account",
            r2Bucket: "bucket",
            r2AccessKeyID: "access",
            r2SecretAccessKey: "secret"
        ))
    }

    func testUnsetStorageModeDefaultsToManagedAndKnownRawValuesStayStable() {
        XCTAssertNil(StorageMode(rawValue: ""))
        XCTAssertEqual(StorageMode(rawValue: "") ?? .managed, .managed)
        XCTAssertEqual(StorageMode(rawValue: "managed"), .managed)
        XCTAssertEqual(StorageMode(rawValue: "ownR2"), .ownR2)
        XCTAssertEqual(StorageMode(rawValue: "local"), .local)
        XCTAssertEqual(StorageMode.managed.label, "OpenRec Cloud")
        XCTAssertEqual(StorageMode.ownR2.label, "My R2")
        XCTAssertEqual(StorageMode.local.label, "This Mac")
    }

    @MainActor
    func testSelectingThisMacDoesNotRequireR2OrGoogle() async throws {
        XCTAssertTrue(StorageMode.local.onboardingCanContinue(isReady: true, r2ConnectionVerified: false))
        XCTAssertTrue(StorageMode.managed.onboardingCanContinue(isReady: true, r2ConnectionVerified: false))
        XCTAssertFalse(StorageMode.managed.onboardingCanContinue(isReady: false, r2ConnectionVerified: true))
        XCTAssertFalse(StorageMode.ownR2.onboardingCanContinue(isReady: true, r2ConnectionVerified: false))
        XCTAssertTrue(StorageMode.ownR2.onboardingCanContinue(isReady: true, r2ConnectionVerified: true))
        XCTAssertFalse(StorageMode.ownR2.onboardingCanContinue(isReady: false, r2ConnectionVerified: true))

        let previous = UserDefaults.standard.string(forKey: "StorageMode")
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "StorageMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "StorageMode")
            }
        }

        let manager = CloudStorageManager()
        manager.mode = .local
        XCTAssertTrue(manager.isReady)
        let mode = try manager.captureStorageContext(for: .local).mode
        XCTAssertEqual(mode, .local)
    }

    @MainActor
    func testRecordingsDirectoryHonorsTheExistingUserDefaultsKey() {
        let suiteName = "openrec.local-storage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fallback = CloudStorageManager.recordingsDirectory(defaults: defaults)
        XCTAssertEqual(fallback.lastPathComponent, "OpenRec")

        defaults.set("   ", forKey: CloudStorageManager.recordingsDirectoryDefaultsKey)
        XCTAssertEqual(CloudStorageManager.recordingsDirectory(defaults: defaults).lastPathComponent, "OpenRec")

        defaults.set("/tmp/openrec-recordings", forKey: CloudStorageManager.recordingsDirectoryDefaultsKey)
        XCTAssertEqual(
            CloudStorageManager.recordingsDirectory(defaults: defaults).standardizedFileURL.path,
            URL(fileURLWithPath: "/tmp/openrec-recordings", isDirectory: true).standardizedFileURL.path
        )
    }

    func testSequentialPartsProduceFinishedFileOnCompleteUpload() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocalMediaStreamingTransport(directory: root)
        let meetingID = UUID()
        let upload = try await transport.beginUpload(
            meetingID: meetingID,
            kind: .screen,
            contentType: "video/mp4"
        )
        let first = try await transport.uploadPart(Data("abcd".utf8), partNumber: 1, upload: upload)
        let second = try await transport.uploadPart(Data("efgh".utf8), partNumber: 2, upload: upload)
        let third = try await transport.uploadPart(Data("ij".utf8), partNumber: 3, upload: upload)
        let completed = try await transport.completeUpload(upload, parts: [first, second, third])

        let finished = URL(fileURLWithPath: completed.objectKey)
        XCTAssertEqual(try Data(contentsOf: finished), Data("abcdefghij".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: upload.objectKey))
        XCTAssertEqual(
            finished.standardizedFileURL.path,
            LocalMediaStreamingTransport.finalURL(directory: root, meetingID: meetingID, kind: .screen).standardizedFileURL.path
        )

        try await transport.abortUpload(upload)
        XCTAssertEqual(try Data(contentsOf: finished), Data("abcdefghij".utf8))

        let access = try await transport.accessURL(meetingID: meetingID, kind: .screen, ttl: 60)
        XCTAssertTrue(access.url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: access.url), Data("abcdefghij".utf8))

        try await transport.deleteMedia(meetingID: meetingID, kind: .screen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finished.path))
    }

    func testSessionWritesReorderedChunksIntoFinishedLocalFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID()
        let transport = LocalMediaStreamingTransport(directory: root)
        let journal = MediaStreamingUploadJournal(
            fileURL: root.appendingPathComponent("journal.json"),
            launchID: UUID()
        )
        let session = try await MediaStreamingSession.begin(
            descriptor: MediaStreamingMeetingDescriptor(
                meetingID: meetingID,
                startedAt: Date(timeIntervalSince1970: 10),
                callApp: "Tests",
                callTitle: "Local"
            ),
            kinds: [.screen, .audio],
            transport: transport,
            maximumPendingBytes: 64,
            reorderWindow: 4,
            partSize: 4,
            journal: journal
        )

        try await session.append(Data("efgh".utf8), kind: .screen, sequence: 1)
        try await session.append(Data("abcd".utf8), kind: .screen, sequence: 0)
        try await session.append(Data("ij".utf8), kind: .screen, sequence: 2)
        try await session.append(Data("xyz".utf8), kind: .audio, sequence: 0)
        let result = try await session.finish()

        let screenURL = LocalMediaStreamingTransport.finalURL(directory: root, meetingID: meetingID, kind: .screen)
        let audioURL = LocalMediaStreamingTransport.finalURL(directory: root, meetingID: meetingID, kind: .audio)
        XCTAssertEqual(try Data(contentsOf: screenURL), Data("abcdefghij".utf8))
        XCTAssertEqual(try Data(contentsOf: audioURL), Data("xyz".utf8))
        XCTAssertEqual(result.media.first(where: { $0.kind == .screen })?.objectKey, screenURL.path)
        XCTAssertEqual(result.media.first(where: { $0.kind == .audio })?.objectKey, audioURL.path)
        let remaining = try await journal.allEntries()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMeetingRecordRoundTripsLocalStorageModeAndOldModesStillDecode() throws {
        let record = makeRecord(
            storageMode: .local,
            localScreenPath: "/tmp/openrec/screen.mp4",
            localAudioPath: "/tmp/openrec/audio.m4a",
            transcript: "Kept on this Mac"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingRecord.self, from: encoder.encode(record))

        XCTAssertEqual(decoded.storageMode, .local)
        XCTAssertEqual(decoded.localScreenPath, record.localScreenPath)
        XCTAssertEqual(decoded.localAudioPath, record.localAudioPath)
        XCTAssertEqual(decoded.transcript, "Kept on this Mac")
        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.preferences, record.preferences)

        let managed = try decoder.decode(MeetingRecord.self, from: Data(legacyMeetingJSON(storageMode: "managed").utf8))
        XCTAssertEqual(managed.storageMode, .managed)
        XCTAssertEqual(managed.localScreenPath, "/tmp/openrec/legacy-screen.mp4")
        XCTAssertEqual(managed.transcript, "hello")
        XCTAssertNil(managed.webhookDeliveryStatus)

        let ownR2 = try decoder.decode(MeetingRecord.self, from: Data(legacyMeetingJSON(storageMode: "ownR2").utf8))
        XCTAssertEqual(ownR2.storageMode, .ownR2)
        XCTAssertEqual(ownR2.callTitle, "Weekly product review")
    }

    @MainActor
    func testDeleteRemovesLocalMediaFilesAndTheJSONRecord() async throws {
        let root = try makeRoot()
        let meetingID = UUID()
        let folder = root.appendingPathComponent(meetingID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let screen = folder.appendingPathComponent("screen.mp4")
        let audio = folder.appendingPathComponent("audio.m4a")
        try Data("screen-bytes".utf8).write(to: screen)
        try Data("audio-bytes".utf8).write(to: audio)
        let record = makeRecord(
            id: meetingID,
            storageMode: .local,
            localScreenPath: screen.path,
            localAudioPath: audio.path
        )

        let manager = CloudStorageManager()
        try manager.upsertLocalMeeting(record)
        try await manager.deleteMeeting(record)
        XCTAssertNil(manager.localMeeting(id: meetingID))

        XCTAssertFalse(FileManager.default.fileExists(atPath: screen.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrec-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRecord(
        id: UUID = UUID(uuidString: "B8E17C31-12A5-4C0A-9BC7-573E180DB52E")!,
        storageMode: StorageMode,
        localScreenPath: String?,
        localAudioPath: String?,
        transcript: String? = "Transcript"
    ) -> MeetingRecord {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return MeetingRecord(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            durationSeconds: 90,
            callApp: "FaceTime",
            callTitle: "Local call",
            transcript: transcript,
            insights: MeetingInsights(title: "Local call", summary: "Notes stay here"),
            hasScreenRecording: localScreenPath != nil,
            hasAudioRecording: localAudioPath != nil,
            screenFileExtension: "mp4",
            audioFileExtension: "m4a",
            localScreenPath: localScreenPath,
            localAudioPath: localAudioPath,
            storageMode: storageMode,
            preferences: CallPreferences(
                keepScreenRecording: true,
                keepAudioRecording: true,
                storeTranscriptInCloud: true,
                sendToWebhook: false
            ),
            saveStatus: .saved,
            saveStage: .complete,
            errorMessage: nil,
            createdAt: startedAt,
            updatedAt: startedAt
        )
    }

    private func legacyMeetingJSON(storageMode: String) -> String {
        """
        {
          "id": "B8E17C31-12A5-4C0A-9BC7-573E180DB52E",
          "startedAt": "2023-11-14T22:13:20Z",
          "endedAt": "2023-11-14T22:44:05Z",
          "durationSeconds": 1845,
          "callApp": "Google Chrome",
          "callTitle": "Weekly product review",
          "transcript": "hello",
          "insights": {
            "title": "Product review",
            "summary": "",
            "participants": [],
            "actionItems": [],
            "decisions": []
          },
          "hasScreenRecording": true,
          "hasAudioRecording": false,
          "screenFileExtension": "mp4",
          "localScreenPath": "/tmp/openrec/legacy-screen.mp4",
          "storageMode": "\(storageMode)",
          "preferences": {
            "keepScreenRecording": true,
            "keepAudioRecording": true,
            "storeTranscriptInCloud": true,
            "sendToWebhook": false
          },
          "saveStatus": "saved",
          "saveStage": "complete",
          "createdAt": "2023-11-14T22:13:20Z",
          "updatedAt": "2023-11-14T22:44:05Z"
        }
        """
    }
}
