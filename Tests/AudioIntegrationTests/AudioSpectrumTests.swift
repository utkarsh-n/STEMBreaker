import Foundation
import XCTest
@testable import STEMBreaker

/// Known physical signals exercise the FFT, its units, and stereo energy handling.
/// These tests do not require a microphone, a music account, or system capture consent.
final class AudioSpectrumTests: XCTestCase {
    @MainActor
    func testActual55And440HzTonesHaveCorrectFrequencyAndBandLocation() throws {
        for sampleRate in [44_100.0, 48_000.0] {
            for frequency in [55.0, 440.0] {
                let analyzer = AudioSpectrumAnalyzer()
                let result = analyzer.analyze(tone(frequency: frequency, amplitude: 0.4, sampleRate: sampleRate), sampleRate: sampleRate)
                let measured = try XCTUnwrap(result.peakFrequency)
                let binWidth = sampleRate / Double(AudioSpectrumAnalyzer.sampleCount)
                XCTAssertEqual(measured, frequency, accuracy: binWidth,
                               "The displayed strongest frequency must follow the real source, including a 55 Hz bass tone")
                let strongestBand = try XCTUnwrap(result.bandDecibels.indices.max { result.bandDecibels[$0] < result.bandDecibels[$1] })
                let center = AudioSpectrumAnalyzer.bandCenters(sampleRate: sampleRate)[strongestBand]
                XCTAssertLessThan(abs(log2(center / frequency)), 0.25,
                                  "The visible frequency-band location must agree with its labeled center")
                XCTAssertGreaterThan(result.spectrum.max() ?? 0, 0)
                XCTAssertEqual(result.spectrum.count, AudioSpectrumAnalyzer.bandCount)
            }
        }
    }

    @MainActor
    func testSinusoidRMSAndPeakDBFSHavePhysicalUnits() throws {
        let sampleRate = 48_000.0
        // An integer FFT bin removes spectral scalloping from the peak-level assertion.
        let frequency = sampleRate * 75 / Double(AudioSpectrumAnalyzer.sampleCount)
        var measuredRMSDecibels = [Double]()
        var measuredPeakDecibels = [Float]()
        for amplitude in [0.5, 0.25] {
            let analyzer = AudioSpectrumAnalyzer()
            let samples = tone(frequency: frequency, amplitude: amplitude, sampleRate: sampleRate)
            let result = analyzer.analyze(samples, sampleRate: sampleRate)
            let rmsDBFS = try XCTUnwrap(result.rmsDecibels)
            let expectedRMS = amplitude / sqrt(2)
            XCTAssertEqual(rmsDBFS, 20 * log10(expectedRMS), accuracy: 0.02,
                           "A sinusoid's RMS is amplitude / sqrt(2), independent of the Hann FFT window")
            let peakDBFS = try XCTUnwrap(result.bandDecibels.max())
            XCTAssertEqual(Double(peakDBFS), 20 * log10(amplitude), accuracy: 0.05,
                           "A full-scale sinusoid is 0 dBFS at its FFT peak; window/real-FFT scaling must be calibrated")
            measuredRMSDecibels.append(rmsDBFS)
            measuredPeakDecibels.append(peakDBFS)
        }
        XCTAssertEqual(measuredRMSDecibels[0] - measuredRMSDecibels[1], 20 * log10(2.0), accuracy: 0.02)
        XCTAssertEqual(Double(measuredPeakDecibels[0] - measuredPeakDecibels[1]), 20 * log10(2.0), accuracy: 0.02)
    }

    @MainActor
    func testLowMidAndHighTonesOccupyTheirMeasuredEnergyRegions() {
        let cases: [(Double, Int)] = [(55, 0), (440, 1), (8_000, 2)]
        for (frequency, expectedRegion) in cases {
            let analyzer = AudioSpectrumAnalyzer()
            let result = analyzer.analyze(tone(frequency: frequency, amplitude: 0.4), sampleRate: 48_000)
            XCTAssertEqual(result.energyDistribution.count, 3)
            XCTAssertGreaterThan(result.energyDistribution[expectedRegion], 0.995,
                                 "A pure tone must concentrate power in its bass, mid, or treble range")
            XCTAssertEqual(result.energyDistribution.reduce(0, +), 1, accuracy: 0.0001)
            XCTAssertTrue(result.energyDistribution.allSatisfy { $0.isFinite && (0...1).contains($0) })
        }
    }

    @MainActor
    func testMixedToneDistributionTracksSquaredAmplitudes() {
        let sampleRate = 48_000.0
        let binWidth = sampleRate / Double(AudioSpectrumAnalyzer.sampleCount)
        let bass = tone(frequency: binWidth * 10, amplitude: 0.2)
        let mid = tone(frequency: binWidth * 170, amplitude: 0.4)
        let treble = tone(frequency: binWidth * 1_024, amplitude: 0.1)
        let samples = bass.indices.map { bass[$0] + mid[$0] + treble[$0] }
        let result = AudioSpectrumAnalyzer().analyze(samples, sampleRate: sampleRate)
        // Independent sinusoidal powers are proportional to A², not A or peak bar height.
        let expected: [Float] = [0.04 / 0.21, 0.16 / 0.21, 0.01 / 0.21]
        for index in expected.indices {
            XCTAssertEqual(result.energyDistribution[index], expected[index], accuracy: 0.005)
        }
    }

    @MainActor
    func testStereoPhaseDoesNotCancelPowerAndSingleChannelUsesStereoRMS() throws {
        let sampleRate = 48_000.0
        let frequency = sampleRate * 75 / Double(AudioSpectrumAnalyzer.sampleCount)
        let left = tone(frequency: frequency, amplitude: 0.4)
        let antiPhaseRight = left.map { -$0 }
        let zeros = [Float](repeating: 0, count: left.count)
        let inPhase = AudioSpectrumAnalyzer().analyzeStereo(left, left, sampleRate: sampleRate)
        let antiPhase = AudioSpectrumAnalyzer().analyzeStereo(left, antiPhaseRight, sampleRate: sampleRate)
        let leftOnly = AudioSpectrumAnalyzer().analyzeStereo(left, zeros, sampleRate: sampleRate)

        XCTAssertEqual(try XCTUnwrap(antiPhase.rmsDecibels), try XCTUnwrap(inPhase.rmsDecibels), accuracy: 0.001,
                       "Opposite-phase stereo is audible and cannot be reduced to a silent mono average")
        XCTAssertEqual(try XCTUnwrap(antiPhase.peakFrequency), frequency, accuracy: sampleRate / Double(left.count))
        XCTAssertGreaterThan(antiPhase.spectrum.max() ?? 0, 0)
        for band in inPhase.bandDecibels.indices {
            XCTAssertEqual(antiPhase.bandDecibels[band], inPhase.bandDecibels[band], accuracy: 0.001)
        }
        XCTAssertEqual(try XCTUnwrap(leftOnly.rmsDecibels), 20 * log10(0.4 / 2), accuracy: 0.02,
                       "With one silent channel, stereo mean-square power is half the single-channel power")
        XCTAssertEqual(try XCTUnwrap(inPhase.rmsDecibels) - XCTUnwrap(leftOnly.rmsDecibels), 10 * log10(2.0), accuracy: 0.02)
    }

    @MainActor
    func testSilenceAndNonFiniteInputDoNotInventSignal() throws {
        let count = AudioSpectrumAnalyzer.sampleCount
        let analyzer = AudioSpectrumAnalyzer()
        let signal = tone(frequency: 440, amplitude: 0.3)
        _ = analyzer.analyze(signal, sampleRate: 48_000)
        analyzer.reset()
        assertSilent(analyzer.analyze([Float](repeating: 0, count: count), sampleRate: 48_000))

        let invalid = (0..<count).map { index -> Float in
            switch index % 3 {
            case 0: .nan
            case 1: .infinity
            default: -.infinity
            }
        }
        assertSilent(AudioSpectrumAnalyzer().analyze(invalid, sampleRate: 48_000))

        // A few invalid PCM values are sanitized without poisoning otherwise valid audio.
        var sparseInvalid = signal
        sparseInvalid[0] = .nan
        sparseInvalid[1] = .infinity
        sparseInvalid[2] = -.infinity
        let recovered = AudioSpectrumAnalyzer().analyze(sparseInvalid, sampleRate: 48_000)
        XCTAssertEqual(try XCTUnwrap(recovered.peakFrequency), 440, accuracy: 48_000 / Double(count))
        XCTAssertTrue(try XCTUnwrap(recovered.rmsDecibels).isFinite)
        XCTAssertTrue(recovered.spectrum.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertTrue(recovered.bandDecibels.allSatisfy(\.isFinite))
    }

    @MainActor
    func testInvalidLengthsAndSampleRatesReturnSilentFiniteDiagnostics() {
        for count in [0, AudioSpectrumAnalyzer.sampleCount - 1, AudioSpectrumAnalyzer.sampleCount + 1] {
            let result = AudioSpectrumAnalyzer().analyze([Float](repeating: 0.4, count: count), sampleRate: 48_000)
            assertSilent(result)
        }
        let signal = tone(frequency: 440, amplitude: 0.3)
        for rate in [0.0, -48_000, Double.nan, Double.infinity] {
            assertSilent(AudioSpectrumAnalyzer().analyze(signal, sampleRate: rate))
        }
        assertSilent(AudioSpectrumAnalyzer().analyzeStereo(signal, [], sampleRate: 48_000))
    }

    @MainActor
    func testFrequencyBandMetadataStaysWithinTheSourceNyquistLimit() {
        for rate in [8_000.0, 44_100, 48_000] {
            let centers = AudioSpectrumAnalyzer.bandCenters(sampleRate: rate)
            XCTAssertEqual(centers.count, AudioSpectrumAnalyzer.bandCount)
            XCTAssertTrue(centers.allSatisfy { $0.isFinite && $0 >= 20 && $0 <= min(20_000, rate / 2) })
            XCTAssertEqual(centers, centers.sorted(), "Frequency-axis metadata must follow the rendered left-to-right band order")
        }
    }

    private func tone(frequency: Double, amplitude: Double, sampleRate: Double = 48_000) -> [Float] {
        (0..<AudioSpectrumAnalyzer.sampleCount).map { index in
            Float(amplitude * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    @MainActor
    private func assertSilent(_ result: AudioSpectrumAnalyzer.Result, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.spectrum.count, AudioSpectrumAnalyzer.bandCount, file: file, line: line)
        XCTAssertTrue(result.spectrum.allSatisfy { $0.isFinite && $0 == 0 }, file: file, line: line)
        XCTAssertEqual(result.level, 0, file: file, line: line)
        XCTAssertNil(result.peakFrequency, file: file, line: line)
        XCTAssertNil(result.rmsDecibels, file: file, line: line)
        XCTAssertEqual(result.bandDecibels.count, AudioSpectrumAnalyzer.bandCount, file: file, line: line)
        XCTAssertTrue(result.bandDecibels.allSatisfy { $0.isFinite && $0 == -120 }, file: file, line: line)
        XCTAssertEqual(result.energyDistribution, [0, 0, 0], file: file, line: line)
    }
}
