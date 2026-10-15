import AVFoundation
import XCTest
import StemCore
@testable import STEMBreaker

final class AudioIntegrationTests: XCTestCase {
    @MainActor
    func testLoadSeekAndMixControlsPreserveSessionWithoutPlayback() throws {
        let session = makeSession()
        let engine = RemixEngine()
        defer { engine.pause() }
        try engine.load(session)

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.duration, Double(session.channels[0].count) / session.sampleRate, accuracy: 1e-9)
        XCTAssertEqual(engine.gains, [1, 1, 1, 1])
        engine.seek(to: 0.03)
        XCTAssertEqual(engine.position, 0.03, accuracy: 1e-9)
        XCTAssertFalse(engine.isPlaying, "Seeking a paused deck must not start hardware playback")

        engine.setGain(0.25, channel: 2)
        engine.toggleMute(0)
        engine.toggleSolo(2)
        XCTAssertEqual(engine.gains, [1, 1, 0.25, 1])
        XCTAssertEqual(engine.muted, [0])
        XCTAssertEqual(engine.soloed, [2])
        XCTAssertEqual(engine.levels[0], 0)
        XCTAssertEqual(engine.levels[1], 0)
        XCTAssertGreaterThan(engine.levels[2], 0)
        XCTAssertEqual(engine.levels[3], 0)
        engine.toggleMute(2)
        XCTAssertTrue(engine.levels.allSatisfy { $0 == 0 }, "A muted solo track must leave the entire mix silent")

        engine.resetMix()
        XCTAssertEqual(engine.gains, [1, 1, 1, 1])
        XCTAssertTrue(engine.muted.isEmpty)
        XCTAssertTrue(engine.soloed.isEmpty)
        XCTAssertEqual(engine.position, 0.03, accuracy: 1e-9)
        XCTAssertEqual(engine.session?.title, session.title)
        engine.seek(to: -10)
        XCTAssertEqual(engine.position, 0)
        engine.seek(to: .infinity)
        XCTAssertEqual(engine.position, 0)
        engine.seek(to: 10)
        XCTAssertEqual(engine.position, engine.duration)
    }

    @MainActor
    func testInvalidControlsAndOverlongAudioAreRejectedWithoutChangingSession() throws {
        let engine = RemixEngine()
        defer { engine.pause() }
        try engine.load(makeSession())
        let title = engine.session?.title
        engine.setGain(-1, channel: 0)
        engine.setGain(4, channel: 1)
        engine.setGain(.nan, channel: 2)
        engine.setGain(0.1, channel: -1)
        engine.toggleMute(9)
        engine.toggleSolo(-1)
        XCTAssertEqual(engine.gains, [0, 1, 0, 1])
        XCTAssertTrue(engine.muted.isEmpty)
        XCTAssertTrue(engine.soloed.isEmpty)

        // All eight arrays share this immutable storage; this boundary check
        // does not allocate eight copies of a three-minute recording.
        let overlong = [Float](repeating: 0, count: 180 * 8_000 + 1)
        let track = StereoSamples(left: overlong, right: overlong)
        XCTAssertThrowsError(try engine.load(StemSession(title: "Too long", sampleRate: 8_000, channels: Array(repeating: track, count: 4), provenance: "Test")))
        XCTAssertEqual(engine.session?.title, title)
        XCTAssertThrowsError(try engine.load(StemSession(title: "Missing stem", sampleRate: 8_000, channels: [track], provenance: "Test")))
    }

    @MainActor
    func testExportedWAVHasStereoFramesAndMatchesGainMuteSoloMix() async throws {
        let session = makeSession()
        let engine = RemixEngine()
        defer { engine.pause() }
        try engine.load(session)
        engine.setGain(0.5, channel: 0)
        engine.setGain(0.25, channel: 2)
        engine.toggleSolo(0)
        engine.toggleSolo(2)
        engine.toggleMute(0)
        engine.seek(to: 0.03)
        engine.loopEnabled = false
        let url = try await engine.exportMix()
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(url.pathExtension, "wav")
        XCTAssertEqual(file.fileFormat.sampleRate, session.sampleRate)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.length, AVAudioFramePosition(session.channels[0].count), "Export is a complete session, independent of the playhead or loop toggle")
        let decoded = try readStereo(file)
        let expected = StemMixer.mix(session, gains: [0, 0, 0.25, 0])
        assertSamples(decoded.left, match: expected.left, tolerance: 2.0 / 32_768)
        assertSamples(decoded.right, match: expected.right, tolerance: 2.0 / 32_768)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.position, 0.03, accuracy: 1e-9)
    }

    @MainActor
    func testExportClampsFullScaleAndMutedSoloWritesSilence() async throws {
        let fullScale = StereoSamples(left: [Float](repeating: 0.8, count: 512), right: [Float](repeating: -0.8, count: 512))
        let session = StemSession(title: "Clipping", sampleRate: 8_000, channels: Array(repeating: fullScale, count: 4), provenance: "Test")
        let engine = RemixEngine()
        defer { engine.pause() }
        try engine.load(session)
        let clippingURL = try await engine.exportMix()
        defer { try? FileManager.default.removeItem(at: clippingURL) }
        let clipped = try readStereo(AVAudioFile(forReading: clippingURL))
        XCTAssertTrue(clipped.left.allSatisfy { abs($0 - 1) < 2.0 / 32_768 })
        XCTAssertTrue(clipped.right.allSatisfy { abs($0 + 1) < 2.0 / 32_768 })

        engine.toggleSolo(1)
        engine.toggleMute(1)
        let silenceURL = try await engine.exportMix()
        defer { try? FileManager.default.removeItem(at: silenceURL) }
        let silence = try readStereo(AVAudioFile(forReading: silenceURL))
        XCTAssertTrue(silence.left.allSatisfy { $0 == 0 })
        XCTAssertTrue(silence.right.allSatisfy { $0 == 0 })
    }

    @MainActor
    func testExportBeforeLoadingFails() async {
        let engine = RemixEngine()
        do {
            _ = try await engine.exportMix()
            XCTFail("An empty deck cannot export audio")
        } catch {
            XCTAssertTrue(error is StemAudioError)
        }
    }

    func testShortLocalWAVSeparatesOnDeviceAndReconstructsSource() async throws {
        let sampleRate = 44_100.0
        let count = Int(sampleRate * 0.15)
        let left = (0..<count).map { index in
            Float(0.12 * sin(2 * .pi * 220 * Double(index) / sampleRate)
                  + 0.08 * sin(2 * .pi * 2_300 * Double(index) / sampleRate))
        }
        let right = (0..<count).map { index in
            Float(0.1 * sin(2 * .pi * 80 * Double(index) / sampleRate)
                  + 0.06 * sin(2 * .pi * 12_000 * Double(index) / sampleRate))
        }
        let url = try writeSourceWAV(left: left, right: right, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try AudioImporter.decode(url)
        let separated = try await AudioImporter.separate(url: url) { _, _ in }
        XCTAssertEqual(separated.channels.count, 4)
        XCTAssertEqual(separated.sampleRate, sampleRate)
        XCTAssertEqual(separated.channels[0].count, source.count)
        _ = try separated.validated()
        XCTAssertTrue(separated.provenance.contains("On-device Spleeter AI"))
        let reconstruction = StemMixer.mix(separated)
        assertSamples(reconstruction.left, match: source.left, tolerance: 0.000_02)
        assertSamples(reconstruction.right, match: source.right, tolerance: 0.000_02)
        XCTAssertTrue(separated.channels.contains { $0.left.contains { abs($0) > 0.001 } }, "Separation must return audible finite audio")
    }

    private func makeSession() -> StemSession {
        let count = 2_049 // Crosses both the analysis window and an odd file-frame boundary.
        let tracks = (0..<4).map { channel in
            let left = (0..<count).map { index in Float(channel + 1) * 0.04 + Float(index % 7) * 0.001 }
            let right = (0..<count).map { index in -Float(channel + 1) * 0.03 + Float(index % 11) * 0.001 }
            return StereoSamples(left: left, right: right)
        }
        return StemSession(title: "Audio integration", sampleRate: 8_000, channels: tracks, provenance: "Generated test signal")
    }

    private func readStereo(_ file: AVAudioFile) throws -> StereoSamples {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        return StereoSamples(left: Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))),
                             right: Array(UnsafeBufferPointer(start: channels[1], count: Int(buffer.frameLength))))
    }

    private func assertSamples(_ actual: [Float], match expected: [Float], tolerance: Float, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        let maximumError = zip(actual, expected).map { abs($0.0 - $0.1) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximumError, tolerance, file: file, line: line)
    }

    private func writeSourceWAV(left: [Float], right: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("STEMBreaker-test-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)))
        let channels = try XCTUnwrap(buffer.floatChannelData)
        buffer.frameLength = AVAudioFrameCount(left.count)
        for index in left.indices { channels[0][index] = left[index]; channels[1][index] = right[index] }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
