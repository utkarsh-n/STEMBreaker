import Foundation

/// Median-filter harmonic/percussive estimation, then a soft harmonic bass crossover.
/// These are overlapping instrument estimates, not trained drum/bass/other source models.
public enum InstrumentEstimator {
    public static func split(_ accompaniment: StereoSamples, sampleRate: Double) throws -> [StereoSamples] {
        guard sampleRate.isFinite, sampleRate > 0, accompaniment.count > 0,
              accompaniment.left.count == accompaniment.right.count else { throw StemError.invalidSession }
        let transform = try ShortTimeFourier(size: 2048, hop: 512)
        let left = try splitChannel(accompaniment.left, sampleRate: sampleRate, transform: transform)
        let right = try splitChannel(accompaniment.right, sampleRate: sampleRate, transform: transform)
        return (0..<3).map { StereoSamples(left: left[$0], right: right[$0]) }
    }

    private static func splitChannel(_ samples: [Float], sampleRate: Double, transform: ShortTimeFourier) throws -> [[Float]] {
        let input = try transform.forward(samples)
        let magnitude = input.magnitudes
        let frames = magnitude.count
        let bins = magnitude[0].count
        var drums = input
        var bass = input
        var other = input
        for frame in 0..<frames {
            if frame.isMultiple(of: 32) { try Task.checkCancellation() }
            for bin in 0..<bins {
                // A stable sinusoid is horizontal in a spectrogram; a transient is vertical.
                let harmonic = median9(
                    magnitude[max(0, frame - 4)][bin], magnitude[max(0, frame - 3)][bin],
                    magnitude[max(0, frame - 2)][bin], magnitude[max(0, frame - 1)][bin], magnitude[frame][bin],
                    magnitude[min(frames - 1, frame + 1)][bin], magnitude[min(frames - 1, frame + 2)][bin],
                    magnitude[min(frames - 1, frame + 3)][bin], magnitude[min(frames - 1, frame + 4)][bin])
                let row = magnitude[frame]
                let percussive = median9(
                    row[max(0, bin - 4)], row[max(0, bin - 3)], row[max(0, bin - 2)], row[max(0, bin - 1)], row[bin],
                    row[min(bins - 1, bin + 1)], row[min(bins - 1, bin + 2)],
                    row[min(bins - 1, bin + 3)], row[min(bins - 1, bin + 4)])
                let h2 = harmonic * harmonic
                let p2 = percussive * percussive
                let percussionMask: Float = h2 + p2 > 1e-16 ? p2 / (h2 + p2) : 0
                let frequency = Double(bin) * sampleRate / Double(transform.size)
                // Butterworth-like smooth crossover avoids ringing at a hard frequency cutoff.
                let bassMask = Float(1 / (1 + pow(frequency / 220, 8))) * (1 - percussionMask)
                let otherMask = 1 - percussionMask - bassMask
                drums.real[frame][bin] *= percussionMask
                drums.imaginary[frame][bin] *= percussionMask
                bass.real[frame][bin] *= bassMask
                bass.imaginary[frame][bin] *= bassMask
                other.real[frame][bin] *= otherMask
                other.imaginary[frame][bin] *= otherMask
            }
        }
        return try [transform.inverse(drums), transform.inverse(bass), transform.inverse(other)]
    }

    @inline(__always)
    private static func median9(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ e: Float,
                                _ f: Float, _ g: Float, _ h: Float, _ i: Float) -> Float {
        // Stack storage avoids two heap arrays per time-frequency bin.
        var values = SIMD16<Float>(a, b, c, d, e, f, g, h, i, 0, 0, 0, 0, 0, 0, 0)
        for index in 1..<9 {
            let value = values[index]
            var position = index
            while position > 0 && values[position - 1] > value {
                values[position] = values[position - 1]
                position -= 1
            }
            values[position] = value
        }
        return values[4]
    }
}
