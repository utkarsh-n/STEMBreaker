import AVFoundation
import Accelerate
import Foundation

/// The audio callback only copies into this fixed-size window. It never waits for
/// the UI, allocates sample arrays, runs an FFT, or touches observable state.
final class MicrophoneSampleMailbox: @unchecked Sendable {
    static let sampleCount = AudioSpectrumAnalyzer.sampleCount

    private let lock = NSLock()
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
    private var writeIndex = 0
    private var filledCount = 0
    private var lastArrival: UInt64 = 0
    private var sampleRate = 44_100.0

    init() {
        storage.initialize(repeating: 0, count: Self.sampleCount)
    }

    deinit {
        storage.deinitialize(count: Self.sampleCount)
        storage.deallocate()
    }

    func reset() {
        lock.lock()
        writeIndex = 0
        filledCount = 0
        lastArrival = 0
        lock.unlock()
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, lock.try() else { return }
        defer { lock.unlock() }

        let channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0 else { return }
        if sampleRate != buffer.format.sampleRate {
            sampleRate = buffer.format.sampleRate
            writeIndex = 0
            filledCount = 0
        }

        // Use the louder input channel rather than averaging stereo: an
        // opposite-phase microphone pair must not cancel audible energy.
        var firstEnergy: Double = 0
        var secondEnergy: Double = 0
        if channelCount > 1 {
            for frame in 0..<frameCount {
                let first = channels[0][interleaved ? frame * channelCount : frame]
                let second = interleaved ? channels[0][frame * channelCount + 1] : channels[1][frame]
                if first.isFinite { firstEnergy += Double(first) * Double(first) }
                if second.isFinite { secondEnergy += Double(second) * Double(second) }
            }
        }
        let useSecond = secondEnergy > firstEnergy
        for frame in 0..<frameCount {
            let first = channels[0][interleaved ? frame * channelCount : frame]
            let value = useSecond
                ? (interleaved ? channels[0][frame * channelCount + 1] : channels[1][frame])
                : first
            storage[writeIndex] = value.isFinite ? value : 0
            writeIndex = (writeIndex + 1) % Self.sampleCount
            filledCount = min(Self.sampleCount, filledCount + 1)
        }
        if frameCount > 0 { lastArrival = mach_absolute_time() }
    }

    /// Called outside the render callback. The only shared data is protected by
    /// this lock; the callback skips a frame if this brief copy is in progress.
    func copyLatest(into samples: inout [Float]) -> Bool {
        var ignoredRate = 0.0
        return copyLatest(into: &samples, sampleRate: &ignoredRate)
    }

    func copyLatest(into samples: inout [Float], sampleRate copiedRate: inout Double) -> Bool {
        guard samples.count == Self.sampleCount else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard filledCount > 0, lastArrival > 0,
              AVAudioTime.seconds(forHostTime: mach_absolute_time() - lastArrival) < 0.35 else { return false }
        copiedRate = sampleRate

        let zeroCount = Self.sampleCount - filledCount
        samples.withUnsafeMutableBufferPointer { output in
            for index in 0..<zeroCount { output[index] = 0 }
            let start = (writeIndex - filledCount + Self.sampleCount) % Self.sampleCount
            for index in 0..<filledCount {
                output[zeroCount + index] = storage[(start + index) % Self.sampleCount]
            }
        }
        return true
    }
}

/// A reusable real FFT with logarithmic frequency bands. This runs at UI update
/// cadence on the main actor, never on an audio render callback.
@MainActor
final class AudioSpectrumAnalyzer {
    nonisolated static let sampleCount = 8_192
    nonisolated static let bandCount = 48
    nonisolated static let minimumFrequency = 20.0
    nonisolated static let maximumFrequency = 20_000.0
    nonisolated static let decibelFloor: Float = -120
    nonisolated static let displayDecibelFloor: Float = -66

    struct Result {
        let spectrum: [Float]
        let level: Float
        /// Peak sinusoid amplitude in each band, in dBFS. These measurements
        /// are not normalized to the loudest band or display-smoothed.
        let bandDecibels: [Float]
        /// Strongest FFT bin in the analysis range; this is not pitch tracking.
        let peakFrequency: Double?
        let rmsDecibels: Double?
        /// FFT power fractions: 20–250 Hz, 250–4000 Hz, 4000–20000 Hz.
        let energyDistribution: [Float]

        static var silent: Result {
            Result(spectrum: Array(repeating: 0, count: bandCount), level: 0,
                   bandDecibels: Array(repeating: decibelFloor, count: bandCount),
                   peakFrequency: nil, rmsDecibels: nil, energyDistribution: [0, 0, 0])
        }
    }

    private let log2Count = vDSP_Length(13)
    private let setup: FFTSetup?
    private var window = [Float](repeating: 0, count: sampleCount)
    private var windowed = [Float](repeating: 0, count: sampleCount)
    private var real = [Float](repeating: 0, count: sampleCount / 2)
    private var imaginary = [Float](repeating: 0, count: sampleCount / 2)
    private var powers = [Float](repeating: 0, count: sampleCount / 2)
    private var stereoPowers = [Float](repeating: 0, count: sampleCount / 2)
    private var smoothed = [Float](repeating: 0, count: bandCount)
    private var bandRanges: [Range<Int>] = []
    private var configuredSampleRate = 0.0
    private var windowSum: Float = 1

    init() {
        setup = vDSP_create_fftsetup(log2Count, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(Self.sampleCount), Int32(vDSP_HANN_NORM))
        windowSum = window.reduce(0, +)
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func reset() {
        for index in smoothed.indices { smoothed[index] = 0 }
    }

    /// The 8192-sample window overlaps successive 40 ms publications. At 48 kHz
    /// it resolves 5.86 Hz bins; its center trails the newest sample by 85 ms.
    func analyze(_ samples: [Float], sampleRate: Double) -> Result {
        guard isValid(samples, sampleRate: sampleRate) else {
            reset()
            return .silent
        }
        if sampleRate != configuredSampleRate { configureBands(sampleRate: sampleRate) }
        let squareMean = transform(samples)
        return result(squareMean: squareMean, sampleRate: sampleRate)
    }

    /// Averaging channel powers preserves wide/opposite-phase stereo without
    /// reporting the artificial cancellations of a mono sample average.
    func analyzeStereo(_ left: [Float], _ right: [Float], sampleRate: Double) -> Result {
        guard isValid(left, sampleRate: sampleRate), isValid(right, sampleRate: sampleRate) else {
            reset()
            return .silent
        }
        if sampleRate != configuredSampleRate { configureBands(sampleRate: sampleRate) }
        let leftMean = transform(left)
        for index in powers.indices { stereoPowers[index] = powers[index] }
        let rightMean = transform(right)
        for index in powers.indices { powers[index] = (powers[index] + stereoPowers[index]) * 0.5 }
        return result(squareMean: (leftMean + rightMean) * 0.5, sampleRate: sampleRate)
    }

    nonisolated static func bandCenters(sampleRate: Double = 48_000) -> [Double] {
        guard sampleRate.isFinite, sampleRate > 0 else { return [] }
        let maximum = min(maximumFrequency, sampleRate * 0.5)
        let minimum = min(minimumFrequency, maximum / 20)
        let ratio = maximum / minimum
        return (0..<bandCount).map { minimum * pow(ratio, (Double($0) + 0.5) / Double(bandCount)) }
    }

    private func isValid(_ samples: [Float], sampleRate: Double) -> Bool {
        samples.count == Self.sampleCount && sampleRate.isFinite && sampleRate > 0 && setup != nil
    }

    private func transform(_ samples: [Float]) -> Double {
        var squareSum: Double = 0
        for index in samples.indices {
            // Audio may exceed unity before clipping, but corrupted extreme
            // floats must not overflow the FFT into nonfinite UI values.
            let sample = samples[index].isFinite ? min(32, max(-32, samples[index])) : 0
            squareSum += Double(sample) * Double(sample)
            windowed[index] = sample * window[index]
        }

        windowed.withUnsafeBufferPointer { input in
            input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.sampleCount / 2) { packed in
                real.withUnsafeMutableBufferPointer { realBuffer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                        var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                        vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(Self.sampleCount / 2))
                        vDSP_fft_zrip(setup!, &split, 1, log2Count, FFTDirection(FFT_FORWARD))
                        powers.withUnsafeMutableBufferPointer { powerBuffer in
                            vDSP_zvmags(&split, 1, powerBuffer.baseAddress!, 1, vDSP_Length(Self.sampleCount / 2))
                        }
                    }
                }
            }
        }
        return squareSum / Double(Self.sampleCount)
    }

    private func result(squareMean: Double, sampleRate: Double) -> Result {
        let rms = sqrt(squareMean)
        guard rms > 0.000_001 else {
            reset()
            return .silent
        }

        var bandDecibels = [Float](repeating: Self.decibelFloor, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            var peakPower: Float = 0
            for bin in bandRanges[band] { peakPower = max(peakPower, powers[bin]) }
            // vDSP's real transform is scaled by two; dividing by the Hann sum
            // puts a full-scale sinusoid close to 0 dBFS.
            let amplitude = sqrt(peakPower) / max(windowSum, 1)
            let decibels = max(Self.decibelFloor, 20 * log10(max(amplitude, 0.000_001)))
            bandDecibels[band] = decibels
            // Compatibility output has an explicit fixed dB axis. Raw dBFS
            // above remains available for a labeled, calibrated visualization.
            let value = min(1, max(0, (decibels - Self.displayDecibelFloor) / -Self.displayDecibelFloor))
            let response: Float = value > smoothed[band] ? 0.65 : 0.24
            smoothed[band] += (value - smoothed[band]) * response
        }
        let binWidth = sampleRate / Double(Self.sampleCount)
        let maximum = min(Self.maximumFrequency, sampleRate * 0.5)
        var energy = [Double](repeating: 0, count: 3)
        var strongestPower: Float = 0
        var strongestBin: Int?
        // Bin zero contains packed DC and Nyquist components in a real FFT.
        // Exclude it from audible band energies and frequency detection.
        for bin in 1..<powers.count {
            let frequency = Double(bin) * binWidth
            guard frequency >= Self.minimumFrequency, frequency <= maximum else { continue }
            let power = powers[bin]
            energy[frequency < 250 ? 0 : frequency < 4_000 ? 1 : 2] += Double(power)
            if power > strongestPower { strongestPower = power; strongestBin = bin }
        }
        let totalEnergy = energy.reduce(0, +)
        let distribution = totalEnergy > 0 ? energy.map { Float($0 / totalEnergy) } : [0, 0, 0]
        let hasSpectralPeak = sqrt(strongestPower) / max(windowSum, 1) > 0.000_001
        return Result(spectrum: smoothed, level: min(1, Float(rms * 2)), bandDecibels: bandDecibels,
                      peakFrequency: hasSpectralPeak ? strongestBin.map { Double($0) * binWidth } : nil,
                      rmsDecibels: 20 * log10(rms), energyDistribution: distribution)
    }

    private func configureBands(sampleRate: Double) {
        configuredSampleRate = sampleRate
        let maximumFrequency = min(Self.maximumFrequency, sampleRate * 0.5)
        let minimumFrequency = min(Self.minimumFrequency, maximumFrequency / 20)
        let ratio = maximumFrequency / minimumFrequency
        let binWidth = sampleRate / Double(Self.sampleCount)
        bandRanges = (0..<Self.bandCount).map { band in
            let lowerFrequency = minimumFrequency * pow(ratio, Double(band) / Double(Self.bandCount))
            let upperFrequency = minimumFrequency * pow(ratio, Double(band + 1) / Double(Self.bandCount))
            let lower = max(1, min(Self.sampleCount / 2 - 1, Int(floor(lowerFrequency / binWidth))))
            let upper = max(lower + 1, min(Self.sampleCount / 2, Int(ceil(upperFrequency / binWidth))))
            return lower..<upper
        }
    }
}
