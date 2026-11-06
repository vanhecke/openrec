import AVFoundation
import CoreMedia
import XCTest
@testable import OpenRecApp

@available(macOS 13.0, *)
final class ScreenRecorderWriterTests: XCTestCase {
    func testMuxedScreenWriterUsesAppleHLSAndCreatesAdaptorBeforeWriting() throws {
        let delegate = SegmentCollector()
        let audioFormat = try ScreenRecorder.makeMixedPCMFormatDescription()
        let screen = try ScreenRecorder.startSegmentedWriter(
            kind: .muxedScreen(width: 640, height: 360),
            segmentDuration: CMTime(seconds: 2, preferredTimescale: 600),
            mixedPCMFormatDescription: audioFormat,
            delegate: delegate
        )
        defer { screen.writer.cancelWriting() }

        XCTAssertEqual(screen.writer.outputFileTypeProfile, .mpeg4AppleHLS)
        XCTAssertEqual(screen.writer.status, .writing)
        XCTAssertNotNil(screen.videoInput)
        XCTAssertEqual(screen.audioInput.mediaType, .audio)
        XCTAssertNotNil(screen.pixelBufferAdaptor)
        XCTAssertEqual(screen.pixelBufferAdaptorCreationStatus, .unknown)
    }

    func testAudioOnlyWriterRemainsStrictCMAF() throws {
        let delegate = SegmentCollector()
        let audioFormat = try ScreenRecorder.makeMixedPCMFormatDescription()
        let audio = try ScreenRecorder.startSegmentedWriter(
            kind: .audioOnly,
            segmentDuration: CMTime(seconds: 2, preferredTimescale: 600),
            mixedPCMFormatDescription: audioFormat,
            delegate: delegate
        )
        defer { audio.writer.cancelWriting() }

        XCTAssertEqual(audio.writer.outputFileTypeProfile, .mpeg4CMAFCompliant)
        XCTAssertEqual(audio.writer.status, .writing)
        XCTAssertNil(audio.videoInput)
        XCTAssertNil(audio.pixelBufferAdaptor)
        XCTAssertNil(audio.pixelBufferAdaptorCreationStatus)
        XCTAssertEqual(audio.audioInput.mediaType, .audio)
    }

    func testMuxedScreenWriterAppliesTheSelectedBitRateAndStaysH264() throws {
        let settings = ScreenEncodeSettings(frameRate: 15, averageBitRate: 1_500_000)
        let delegate = SegmentCollector()
        let audioFormat = try ScreenRecorder.makeMixedPCMFormatDescription()
        let screen = try ScreenRecorder.startSegmentedWriter(
            kind: .muxedScreen(width: 640, height: 360),
            segmentDuration: CMTime(seconds: 2, preferredTimescale: 600),
            mixedPCMFormatDescription: audioFormat,
            delegate: delegate,
            encodeSettings: settings
        )
        defer { screen.writer.cancelWriting() }

        let output = try XCTUnwrap(screen.videoInput?.outputSettings)
        XCTAssertEqual(stringValue(output[AVVideoCodecKey]), AVVideoCodecType.h264.rawValue)
        let compression = try XCTUnwrap(output[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual(intValue(compression[AVVideoAverageBitRateKey]), 1_500_000)
        XCTAssertEqual(stringValue(compression[AVVideoProfileLevelKey]), AVVideoProfileLevelH264HighAutoLevel)
    }
}

@available(macOS 13.0, *)
final class ScreenEncodeSettingsTests: XCTestCase {
    func testDefaultFrameRateIsFifteenAndBitRateStaysAtThreeMegabits() {
        let settings = ScreenEncodeSettings()

        XCTAssertEqual(settings.frameRate, 15)
        XCTAssertEqual(settings.averageBitRate, 3_000_000)
        XCTAssertEqual(settings.minimumFrameInterval, CMTime(value: 1, timescale: 15))
        XCTAssertEqual(ScreenEncodeSettings.videoCodec, .h264)
        XCTAssertTrue(ScreenEncodeSettings.accepts(videoCodec: .h264))
        XCTAssertFalse(ScreenEncodeSettings.accepts(videoCodec: .hevc))
        XCTAssertFalse(ScreenEncodeSettings.accepts(videoCodec: AVVideoCodecType(rawValue: "hev1")))
    }

    func testChoicesStayInsideTheRangeTheWriterAccepts() {
        for choice in ScreenEncodeSettings.frameRateChoices {
            let settings = ScreenEncodeSettings(frameRate: choice.value, averageBitRate: ScreenEncodeSettings.defaultAverageBitRate)
            XCTAssertEqual(settings.frameRate, choice.value)
            XCTAssertEqual(settings.minimumFrameInterval, CMTime(value: 1, timescale: CMTimeScale(choice.value)))
        }
        for choice in ScreenEncodeSettings.qualityChoices {
            let settings = ScreenEncodeSettings(frameRate: 15, averageBitRate: choice.value)
            XCTAssertEqual(settings.averageBitRate, choice.value)
            XCTAssertEqual(choice.detail, ScreenEncodeSettings.bitRateLabel(choice.value))
        }
        XCTAssertTrue(ScreenEncodeSettings.frameRateChoices.contains { $0.value == ScreenEncodeSettings.defaultFrameRate })
        XCTAssertTrue(ScreenEncodeSettings.qualityChoices.contains { $0.value == ScreenEncodeSettings.defaultAverageBitRate })
    }

    func testOutOfRangeValuesClampAndUnreadableValuesAreRejected() throws {
        let clamped = ScreenEncodeSettings(frameRate: 1, averageBitRate: 50_000_000)
        XCTAssertEqual(clamped.frameRate, 10)
        XCTAssertEqual(clamped.averageBitRate, 6_000_000)

        var mutated = ScreenEncodeSettings()
        mutated.frameRate = 1_000
        mutated.averageBitRate = 1
        XCTAssertEqual(mutated.frameRate, 60)
        XCTAssertEqual(mutated.averageBitRate, 1_500_000)

        let high = #"{"frameRate":1000,"averageBitRate":1}"#
        let decoded = try JSONDecoder().decode(ScreenEncodeSettings.self, from: Data(high.utf8))
        XCTAssertEqual(decoded.frameRate, 60)
        XCTAssertEqual(decoded.averageBitRate, 1_500_000)

        let partial = #"{"frameRate":24}"#
        let partialDecoded = try JSONDecoder().decode(ScreenEncodeSettings.self, from: Data(partial.utf8))
        XCTAssertEqual(partialDecoded.frameRate, 24)
        XCTAssertEqual(partialDecoded.averageBitRate, 3_000_000)

        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"frameRate":"fast","averageBitRate":3000000}"#.utf8), forKey: ScreenEncodeSettings.defaultsKey)
        XCTAssertEqual(ScreenEncodeSettings.stored(in: defaults), ScreenEncodeSettings())

        defaults.set(Data("[]".utf8), forKey: ScreenEncodeSettings.defaultsKey)
        XCTAssertEqual(ScreenEncodeSettings.stored(in: defaults), ScreenEncodeSettings())
    }

    func testSettingsRoundTripThroughUserDefaults() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ScreenEncodeSettings.stored(in: defaults), ScreenEncodeSettings())

        let custom = ScreenEncodeSettings(frameRate: 24, averageBitRate: 6_000_000)
        custom.store(in: defaults)
        XCTAssertEqual(ScreenEncodeSettings.stored(in: defaults), custom)

        let encoded = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(ScreenEncodeSettings.self, from: encoded)
        XCTAssertEqual(decoded, custom)
        let output = custom.videoOutputSettings(
            width: 1280,
            height: 720,
            segmentDuration: CMTime(seconds: 8, preferredTimescale: 600)
        )
        XCTAssertEqual(stringValue(output[AVVideoCodecKey]), AVVideoCodecType.h264.rawValue)
        let compression = try XCTUnwrap(output[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual(intValue(compression[AVVideoAverageBitRateKey]), 6_000_000)
        XCTAssertEqual(intValue(compression[AVVideoMaxKeyFrameIntervalDurationKey]), 8)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "ScreenEncodeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}

private func stringValue(_ value: Any?) -> String? {
    switch value {
    case let codec as AVVideoCodecType:
        return codec.rawValue
    case let text as String:
        return text
    default:
        return nil
    }
}

private func intValue(_ value: Any?) -> Int? {
    switch value {
    case let number as Int:
        return number
    case let number as Double:
        return Int(number.rounded())
    case let number as NSNumber:
        return number.intValue
    default:
        return nil
    }
}

@available(macOS 13.0, *)
private final class SegmentCollector: NSObject, AVAssetWriterDelegate {
    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType
    ) {}
}
