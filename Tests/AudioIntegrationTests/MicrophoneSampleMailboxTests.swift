import AVFoundation
import XCTest
@testable import STEMBreaker

final class MicrophoneSampleMailboxTests: XCTestCase {
    func testCallbackRingRetainsTheNewestWindowAcrossMultipleWraps() throws {
        let capacity = MicrophoneSampleMailbox.sampleCount
        XCTAssertEqual(capacity, AudioSpectrumAnalyzer.sampleCount,
                       "The microphone callback must fill the FFT's complete analysis window")
        let count = capacity * 2 + 17
        let incoming = (0..<count).map { Float($0) / Float(count) }
        let mailbox = MicrophoneSampleMailbox()
        mailbox.push(try pcm(left: incoming))
        var copied = [Float](repeating: -1, count: AudioSpectrumAnalyzer.sampleCount)
        XCTAssertTrue(mailbox.copyLatest(into: &copied))
        XCTAssertEqual(copied, Array(incoming.suffix(capacity)),
                       "A callback larger than two windows must return the newest samples in chronological order")
    }

    func testShortCallbacksZeroPadThePrefixAndAppendInTimeOrder() throws {
        let mailbox = MicrophoneSampleMailbox()
        let first: [Float] = [0.01, 0.02, 0.03, 0.04, 0.05]
        let second: [Float] = [0.11, 0.12, 0.13]
        mailbox.push(try pcm(left: first))
        mailbox.push(try pcm(left: second))
        var copied = [Float](repeating: -1, count: AudioSpectrumAnalyzer.sampleCount)
        XCTAssertTrue(mailbox.copyLatest(into: &copied))
        XCTAssertEqual(Array(copied.suffix(first.count + second.count)), first + second)
        XCTAssertTrue(copied.dropLast(first.count + second.count).allSatisfy { $0 == 0 },
                      "Before a full FFT window arrives, padding must be silence rather than uninitialized or previous data")
    }

    func testOppositePhaseStereoPreservesAudibleSamplesAndTheLouderInput() throws {
        let count = AudioSpectrumAnalyzer.sampleCount
        let left = (0..<count).map { index in Float(0.2 * sin(2 * .pi * 440 * Double(index) / 48_000)) }
        let antiPhase = left.map { -$0 }
        let louderRight = left.map { -2 * $0 }
        for interleaved in [false, true] {
            let mailbox = MicrophoneSampleMailbox()
            mailbox.push(try pcm(left: left, right: antiPhase, interleaved: interleaved))
            var copied = [Float](repeating: 0, count: count)
            XCTAssertTrue(mailbox.copyLatest(into: &copied))
            XCTAssertEqual(copied.map { abs($0) }, left.map { abs($0) },
                           "A stereo input with opposite phase must not become silent through averaging")

            mailbox.reset()
            mailbox.push(try pcm(left: left, right: louderRight, interleaved: interleaved))
            XCTAssertTrue(mailbox.copyLatest(into: &copied))
            XCTAssertEqual(copied, louderRight, "When input channels differ in energy, analysis should retain the audible stronger channel")
        }
    }

    func testResetDiscardsOldSamplesAndRefillsWithoutOldTailData() throws {
        let capacity = AudioSpectrumAnalyzer.sampleCount
        let mailbox = MicrophoneSampleMailbox()
        mailbox.push(try pcm(left: [Float](repeating: 0.4, count: capacity)))
        var copied = [Float](repeating: 0, count: capacity)
        XCTAssertTrue(mailbox.copyLatest(into: &copied))
        mailbox.reset()
        XCTAssertFalse(mailbox.copyLatest(into: &copied), "A reset cannot expose the previous input session as fresh audio")
        let fresh: [Float] = [0.1, 0.2, 0.3]
        mailbox.push(try pcm(left: fresh))
        XCTAssertTrue(mailbox.copyLatest(into: &copied))
        XCTAssertEqual(Array(copied.suffix(fresh.count)), fresh)
        XCTAssertTrue(copied.dropLast(fresh.count).allSatisfy { $0 == 0 })
    }

    func testStoppedCallbacksExpireInsteadOfProvidingFrozenAudio() async throws {
        let mailbox = MicrophoneSampleMailbox()
        let samples = [Float](repeating: 0.2, count: AudioSpectrumAnalyzer.sampleCount)
        mailbox.push(try pcm(left: samples))
        var copied = [Float](repeating: 0, count: samples.count)
        XCTAssertTrue(mailbox.copyLatest(into: &copied))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(mailbox.copyLatest(into: &copied), "When callbacks stop, old microphone audio must not be reported as a new measurement")
        mailbox.push(try pcm(left: samples))
        XCTAssertTrue(mailbox.copyLatest(into: &copied), "A fresh callback should make analysis available again")
    }

    private func pcm(left: [Float], right: [Float]? = nil, interleaved: Bool = false) throws -> AVAudioPCMBuffer {
        if let right { XCTAssertEqual(left.count, right.count) }
        let channelCount: AVAudioChannelCount = right == nil ? 1 : 2
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                               channels: channelCount, interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)))
        buffer.frameLength = AVAudioFrameCount(left.count)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in left.indices {
            if interleaved {
                channels[0][frame * Int(channelCount)] = left[frame]
                if let right { channels[0][frame * Int(channelCount) + 1] = right[frame] }
            } else {
                channels[0][frame] = left[frame]
                if let right { channels[1][frame] = right[frame] }
            }
        }
        return buffer
    }
}
