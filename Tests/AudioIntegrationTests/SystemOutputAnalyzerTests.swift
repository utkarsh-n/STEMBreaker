import AVFoundation
import CoreMedia
import XCTest
@testable import STEMBreaker

final class SystemOutputAnalyzerTests: XCTestCase {
    @MainActor
    func testCapturedStereoToneProducesActualSpectrumWithoutPhaseCancellation() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("ScreenCaptureKit audio buffers require iOS 27") }
        let count = AudioSpectrumAnalyzer.sampleCount
        let left = makeTone(frequency: 1_000, amplitude: 0.25, count: count)
        let right = left.map { -$0 }
        let buffer = try makeAudioSampleBuffer(left: left, right: right)
        let mailbox = SystemOutputSampleMailbox()
        mailbox.push(buffer, arrivalTime: 100)
        let analyzer = SystemOutputAnalyzer()
        analyzer.updateAnalysis(from: mailbox, at: 100)
        XCTAssertGreaterThan(analyzer.level, 0.3, "Opposite-phase stereo must remain audible to the meter")
        XCTAssertEqual(analyzer.spectrum.count, AudioSpectrumAnalyzer.bandCount)
        XCTAssertGreaterThan(analyzer.spectrum.max() ?? 0, 0.4)
        XCTAssertTrue(analyzer.status.contains("Live shared audio"))
        XCTAssertFalse(analyzer.isListening, "Analyzing a synthetic sample must not request system sharing or start a capture")
    }

    @MainActor
    func testZeroPCMImmediatelyClearsThePreviousToneAndExplainsSilence() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("ScreenCaptureKit audio buffers require iOS 27") }
        let tone = makeTone(frequency: 440)
        let zeros = [Float](repeating: 0, count: AudioSpectrumAnalyzer.sampleCount)
        let mailbox = SystemOutputSampleMailbox()
        let analyzer = SystemOutputAnalyzer()
        mailbox.push(try makeAudioSampleBuffer(left: tone, right: tone), arrivalTime: 100)
        analyzer.updateAnalysis(from: mailbox, at: 100)
        XCTAssertGreaterThan(analyzer.level, 0.3)
        mailbox.push(try makeAudioSampleBuffer(left: zeros, right: zeros), arrivalTime: 102)
        analyzer.updateAnalysis(from: mailbox, at: 102)
        XCTAssertEqual(analyzer.level, 0)
        XCTAssertTrue(analyzer.spectrum.allSatisfy { $0 == 0 })
        XCTAssertTrue(analyzer.status.contains("silent"))
        XCTAssertTrue(analyzer.status.contains("paused, quiet, or restricted"), "Silence must not be asserted to prove DRM")
    }

    @MainActor
    func testMissingNewSamplesClearsFrozenSpectrumAfterTimeout() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("ScreenCaptureKit audio buffers require iOS 27") }
        let tone = makeTone(frequency: 880)
        let mailbox = SystemOutputSampleMailbox()
        mailbox.push(try makeAudioSampleBuffer(left: tone, right: tone), arrivalTime: 100)
        let analyzer = SystemOutputAnalyzer()
        analyzer.updateAnalysis(from: mailbox, at: 100)
        XCTAssertGreaterThan(analyzer.spectrum.max() ?? 0, 0.4)
        analyzer.updateAnalysis(from: mailbox, at: 100.36)
        XCTAssertEqual(analyzer.level, 0)
        XCTAssertTrue(analyzer.spectrum.allSatisfy { $0 == 0 })
        XCTAssertTrue(analyzer.status.contains("No audio samples are arriving"))
        analyzer.stop()
        XCTAssertFalse(analyzer.isStarting)
        XCTAssertFalse(analyzer.isListening)
        XCTAssertEqual(analyzer.level, 0)
    }

    @MainActor
    func testMalformedPCMFormatProducesNoFabricatedSpectrum() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("ScreenCaptureKit audio buffers require iOS 27") }
        // The generic Core Media container is valid, but deliberately has no
        // audio format/data buffer. It cannot be treated as captured PCM.
        var sampleBuffer: CMSampleBuffer?
        let result = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: nil,
                                               sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                               sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        XCTAssertEqual(result, noErr)
        let mailbox = SystemOutputSampleMailbox()
        mailbox.push(try XCTUnwrap(sampleBuffer), arrivalTime: 100)
        let analyzer = SystemOutputAnalyzer()
        analyzer.updateAnalysis(from: mailbox, at: 100)
        XCTAssertEqual(analyzer.level, 0)
        XCTAssertTrue(analyzer.spectrum.allSatisfy { $0 == 0 })
        XCTAssertTrue(analyzer.status.contains("format could not be analyzed"))
    }

    @MainActor
    func testBuffersFromReplacedOrStoppedStreamsAreIgnored() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("ScreenCaptureKit audio buffers require iOS 27") }
        let oldStream = NSObject()
        let replacement = NSObject()
        let tone = makeTone(frequency: 660)
        let pcm = try makeAudioSampleBuffer(left: tone, right: tone)
        let mailbox = SystemOutputSampleMailbox()
        let analyzer = SystemOutputAnalyzer()
        mailbox.bind(to: ObjectIdentifier(oldStream))
        mailbox.push(pcm, arrivalTime: 100, sourceIdentifier: ObjectIdentifier(oldStream))
        analyzer.updateAnalysis(from: mailbox, at: 100)
        XCTAssertGreaterThan(analyzer.level, 0.3)
        mailbox.bind(to: ObjectIdentifier(replacement))
        mailbox.push(pcm, arrivalTime: 101, sourceIdentifier: ObjectIdentifier(oldStream))
        analyzer.updateAnalysis(from: mailbox, at: 101)
        XCTAssertEqual(analyzer.level, 0, "A late callback from a replaced stream cannot provide the new stream's audio")
        mailbox.push(pcm, arrivalTime: 102, sourceIdentifier: ObjectIdentifier(replacement))
        analyzer.updateAnalysis(from: mailbox, at: 102)
        XCTAssertGreaterThan(analyzer.level, 0.3)
        mailbox.disable()
        mailbox.push(pcm, arrivalTime: 103, sourceIdentifier: ObjectIdentifier(replacement))
        analyzer.updateAnalysis(from: mailbox, at: 103)
        XCTAssertEqual(analyzer.level, 0, "A stopped stream must ignore late samples")
        XCTAssertTrue(analyzer.spectrum.allSatisfy { $0 == 0 })
    }

    private func makeTone(frequency: Double, amplitude: Float = 0.3, count: Int = AudioSpectrumAnalyzer.sampleCount) -> [Float] {
        let phaseStep = 2.0 * Double.pi * frequency / 48_000.0
        return (0..<count).map { index -> Float in amplitude * Float(sin(Double(index) * phaseStep)) }
    }

    private func makeAudioSampleBuffer(left: [Float], right: [Float]) throws -> CMSampleBuffer {
        XCTAssertEqual(left.count, right.count)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)))
        pcm.frameLength = AVAudioFrameCount(left.count)
        let data = try XCTUnwrap(pcm.floatChannelData)
        for index in left.indices { data[0][index] = left[index]; data[1][index] = right[index] }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let result = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil,
                                               formatDescription: format.formatDescription, sampleCount: left.count,
                                               sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        XCTAssertEqual(result, noErr)
        let sample = try XCTUnwrap(sampleBuffer)
        let copyResult = CMSampleBufferSetDataBufferFromAudioBufferList(sample,
                                                                      blockBufferAllocator: kCFAllocatorDefault,
                                                                      blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                      flags: 0, bufferList: pcm.audioBufferList)
        XCTAssertEqual(copyResult, noErr)
        return sample
    }
}
