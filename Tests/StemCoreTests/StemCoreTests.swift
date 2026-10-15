import Foundation
import Testing
@testable import StemCore

@Test func fourierReconstructsDCNyquistAndArbitraryLength() throws {
    let n = 7_037
    let samples = (0..<n).map { i in Float(0.1 + 0.2 * sin(Double(i) * 0.13) + (i.isMultiple(of: 2) ? 0.03 : -0.03)) }
    let transform = try ShortTimeFourier(size: 1024, hop: 256)
    let restored = try transform.inverse(transform.forward(samples))
    #expect(restored.count == n)
    #expect(zip(samples, restored).map { abs($0 - $1) }.max()! < 0.00001)
}

@Test func estimatesReconstructInputAndKeepBassLow() throws {
    let rate = 8_000.0
    let samples = (0..<16_000).map { i in Float(0.3 * sin(2 * .pi * 70 * Double(i) / rate) + 0.2 * sin(2 * .pi * 1_200 * Double(i) / rate)) }
    let input = StereoSamples(left: samples, right: samples)
    let layers = try InstrumentEstimator.split(input, sampleRate: rate)
    #expect(layers.count == 3)
    let reconstructed = StemMixer.mix(StemSession(title: "Test", sampleRate: rate, channels: layers, provenance: "Test"))
    #expect(zip(samples, reconstructed.left).map { abs($0 - $1) }.max()! < 0.00001)
    let bass = layers[1].left
    let low = sinusoidAmplitude(bass, frequency: 70, sampleRate: rate)
    let high = sinusoidAmplitude(bass, frequency: 1_200, sampleRate: rate)
    #expect(low > 0.2)
    #expect(high < 0.01)
}

@Test func demoIsDeterministicDistinctAndBounded() throws {
    let first = DemoFactory.makeDemo()
    let second = DemoFactory.makeDemo()
    #expect(first.channels.count == 4)
    #expect(first.duration == 24)
    _ = try first.validated()
    for i in 0..<4 {
        #expect(first.channels[i].left == second.channels[i].left)
        #expect(first.channels[i].left.contains { abs($0) > 0.01 })
        if i > 0 { #expect(first.channels[i].left != first.channels[i - 1].left) }
    }
    let mix = StemMixer.mix(first)
    #expect(mix.left.allSatisfy { $0.isFinite && abs($0) <= 0.851 })
    #expect(mix.right.allSatisfy { $0.isFinite && abs($0) <= 0.851 })
}

@Test func muteAndSoloProduceExactExportGains() {
    #expect(StemMixer.effectiveGains(gains: [1, 0.5, 0.8, 0.2], muted: [false, false, false, false], solo: [false, true, false, false]) == [0, 0.5, 0, 0])
    #expect(StemMixer.effectiveGains(gains: [1, 1, 1, 1], muted: [false, true, false, false], solo: [false, true, false, false]) == [0, 0, 0, 0])
    #expect(StemMixer.effectiveGains(gains: [Float.nan, -1, 2, 0.5], muted: [], solo: []) == [1, 0, 1, 0.5])
}

@Test func invalidSessionRejectsNonFiniteAndMismatchedTracks() {
    let valid = StereoSamples(left: [0, 0.2], right: [0, 0.2])
    let invalid = StereoSamples(left: [.nan, 0], right: [0, 0])
    #expect(throws: StemError.self) { try StemSession(title: "Invalid", sampleRate: 44_100, channels: [valid, valid, valid, invalid], provenance: "Test").validated() }
    #expect(throws: StemError.self) { try StemSession(title: "Invalid", sampleRate: 0, channels: [valid, valid, valid, valid], provenance: "Test").validated() }
}

private func sinusoidAmplitude(_ samples: [Float], frequency: Double, sampleRate: Double) -> Double {
    let range = 2_000..<(samples.count - 2_000)
    let correlation = range.reduce(0.0) { $0 + Double(samples[$1]) * sin(2 * .pi * frequency * Double($1) / sampleRate) }
    return abs(correlation * 2 / Double(range.count))
}
