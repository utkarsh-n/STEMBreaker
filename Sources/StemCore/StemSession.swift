import Foundation

public enum StemChannel: Int, CaseIterable, Codable, Sendable {
    case vocals, drums, bass, other

    public var title: String {
        switch self {
        case .vocals: "Vocals"
        case .drums: "Drums"
        case .bass: "Bass"
        case .other: "Other"
        }
    }
}

public struct StereoSamples: Sendable {
    public var left: [Float]
    public var right: [Float]

    public init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }

    public var count: Int { min(left.count, right.count) }
}

public struct StemSession: Sendable {
    public var title: String
    public var sampleRate: Double
    /// Always ordered vocals, drums, bass, other.
    public var channels: [StereoSamples]
    public var provenance: String

    public init(title: String, sampleRate: Double, channels: [StereoSamples], provenance: String) {
        self.title = title
        self.sampleRate = sampleRate
        self.channels = channels
        self.provenance = provenance
    }

    public var duration: Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return Double(channels.map(\.count).min() ?? 0) / sampleRate
    }

    public func validated() throws -> Self {
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 192_000,
              channels.count == 4, let count = channels.first?.count, count > 0,
              channels.allSatisfy({ $0.left.count == count && $0.right.count == count }) else {
            throw StemError.invalidSession
        }
        guard channels.allSatisfy({ $0.left.allSatisfy(\.isFinite) && $0.right.allSatisfy(\.isFinite) }) else {
            throw StemError.nonFiniteAudio
        }
        return self
    }
}

public enum StemError: Error, LocalizedError, Sendable {
    case invalidSession, nonFiniteAudio

    public var errorDescription: String? {
        switch self {
        case .invalidSession: "The four tracks must contain aligned stereo audio at a valid sample rate."
        case .nonFiniteAudio: "This audio contains invalid samples. Try exporting the source again."
        }
    }
}

public enum StemMixer {
    /// Solo wins over regular gains, while a muted solo track remains silent.
    public static func effectiveGains(gains: [Float], muted: [Bool], solo: [Bool]) -> [Float] {
        let hasSolo = solo.prefix(4).contains(true)
        return (0..<4).map { index in
            let gain = index < gains.count && gains[index].isFinite ? max(0, min(1, gains[index])) : 1
            let isMuted = index < muted.count && muted[index]
            let isSolo = index < solo.count && solo[index]
            return isMuted || (hasSolo && !isSolo) ? 0 : gain
        }
    }

    /// No per-track normalization: summing the original gains preserves separation reconstruction.
    public static func mix(_ session: StemSession, gains: [Float] = [1, 1, 1, 1]) -> StereoSamples {
        let count = session.channels.map(\.count).min() ?? 0
        var left = [Float](repeating: 0, count: count)
        var right = left
        for (index, track) in session.channels.enumerated() {
            let gain = index < gains.count && gains[index].isFinite ? gains[index] : 0
            for frame in 0..<count {
                left[frame] += track.left[frame] * gain
                right[frame] += track.right[frame] * gain
            }
        }
        return StereoSamples(left: left, right: right)
    }
}
