import Foundation
import AVFoundation
import CoreMedia

/// Frame rate and bitrate applied the next time a screen recording starts.
///
/// The segmented screen file stays H.264. The Apple HLS mux profile is what
/// lets that file include mixed call audio; the strict CMAF profile allows
/// only one track, so HEVC is not a choice.
struct ScreenEncodeSettings: Codable, Equatable, Sendable {
    struct Choice: Equatable, Identifiable, Sendable {
        let value: Int
        let title: String
        let detail: String
        var id: Int { value }
    }

    static let defaultFrameRate = 15
    static let defaultAverageBitRate = 3_000_000
    static let frameRateRange = 10...60
    static let averageBitRateRange = 1_500_000...6_000_000
    static let defaultsKey = "ScreenEncodeSettings"
    static let videoCodec = AVVideoCodecType.h264

    static let frameRateChoices: [Choice] = [
        Choice(value: 10, title: "10 fps", detail: "Lower motion"),
        Choice(value: 15, title: "15 fps", detail: "Recommended"),
        Choice(value: 24, title: "24 fps", detail: "Smoother motion"),
        Choice(value: 30, title: "30 fps", detail: "Smoother motion"),
        Choice(value: 60, title: "60 fps", detail: "Smoothest motion")
    ]

    static let qualityChoices: [Choice] = [
        Choice(value: 1_500_000, title: "Smaller files", detail: "1.5 Mb/s"),
        Choice(value: 3_000_000, title: "Balanced", detail: "3 Mb/s"),
        Choice(value: 6_000_000, title: "Sharper", detail: "6 Mb/s")
    ]

    var frameRate: Int {
        didSet { frameRate = Self.clampedFrameRate(frameRate) }
    }

    var averageBitRate: Int {
        didSet { averageBitRate = Self.clampedAverageBitRate(averageBitRate) }
    }

    init(frameRate: Int = defaultFrameRate, averageBitRate: Int = defaultAverageBitRate) {
        self.frameRate = Self.clampedFrameRate(frameRate)
        self.averageBitRate = Self.clampedAverageBitRate(averageBitRate)
    }

    var minimumFrameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(frameRate))
    }

    func frameRatePresentation() -> Choice {
        Self.frameRateChoices.first { $0.value == frameRate }
            ?? Choice(value: frameRate, title: "\(frameRate) fps", detail: "Custom")
    }

    func qualityPresentation() -> Choice {
        Self.qualityChoices.first { $0.value == averageBitRate }
            ?? Choice(value: averageBitRate, title: Self.bitRateLabel(averageBitRate), detail: "Custom")
    }

    static func clampedFrameRate(_ value: Int) -> Int {
        min(frameRateRange.upperBound, max(frameRateRange.lowerBound, value))
    }

    static func clampedAverageBitRate(_ value: Int) -> Int {
        min(averageBitRateRange.upperBound, max(averageBitRateRange.lowerBound, value))
    }

    static func accepts(videoCodec: AVVideoCodecType) -> Bool {
        videoCodec == Self.videoCodec
    }

    static func bitRateLabel(_ averageBitRate: Int) -> String {
        if averageBitRate % 1_000_000 == 0 {
            return "\(averageBitRate / 1_000_000) Mb/s"
        }
        let mbps = Double(averageBitRate) / 1_000_000
        return String(format: "%.1f Mb/s", locale: Locale(identifier: "en_US_POSIX"), mbps)
    }

    func videoOutputSettings(width: Int, height: Int, segmentDuration: CMTime) -> [String: Any] {
        [
            AVVideoCodecKey: Self.videoCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: CMTimeGetSeconds(segmentDuration)
            ]
        ]
    }

    func store(in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func stored(in defaults: UserDefaults) -> ScreenEncodeSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(ScreenEncodeSettings.self, from: data) else {
            return ScreenEncodeSettings()
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case frameRate
        case averageBitRate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let frameRate = try values.decodeIfPresent(Int.self, forKey: .frameRate) ?? Self.defaultFrameRate
        let averageBitRate = try values.decodeIfPresent(Int.self, forKey: .averageBitRate) ?? Self.defaultAverageBitRate
        self.init(frameRate: frameRate, averageBitRate: averageBitRate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(averageBitRate, forKey: .averageBitRate)
    }
}
