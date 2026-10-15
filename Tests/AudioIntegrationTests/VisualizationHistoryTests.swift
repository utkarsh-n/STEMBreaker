import Foundation
import XCTest
@testable import STEMBreaker

final class VisualizationHistoryTests: XCTestCase {
    @MainActor
    func testRealDemoBuildsMeasuredHistoryAndPausingFreezesIt() async throws {
        let deck = try await preparedDemoDeck()
        defer { stop(deck) }
        XCTAssertTrue(deck.spectrumHistory.isEmpty)
        XCTAssertFalse(deck.engine.isPlaying)

        deck.togglePlayback()
        XCTAssertTrue(deck.engine.isPlaying, deck.message ?? "The demo should play through the native remix engine")
        try await waitUntil("Playing the demo should produce several measured history columns") {
            deck.spectrumHistory.count >= 3 && deck.spectrumHistory.contains { ($0.max() ?? -120) > -80 }
        }
        XCTAssertTrue(deck.spectrumHistory.allSatisfy {
            $0.count == AudioSpectrumAnalyzer.bandCount && $0.allSatisfy { $0.isFinite && $0 >= -120 }
        }, "History stores calibrated frequency measurements, rather than an unrelated animation")
        XCTAssertNotNil(deck.peakFrequency)
        XCTAssertNotNil(deck.rmsDecibels)

        deck.togglePlayback()
        XCTAssertFalse(deck.engine.isPlaying)
        let pausedHistory = deck.spectrumHistory
        let pausedPosition = deck.position
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(deck.spectrumHistory, pausedHistory, "A pause must preserve the existing history without adding silent or fabricated columns")
        XCTAssertEqual(deck.position, pausedPosition, accuracy: 0.0001)
    }

    @MainActor
    func testSeekAndSourceChangesClearHistoryAndUncapturedMusicHasNoAudio() async throws {
        let deck = try await preparedDemoDeck()
        defer { stop(deck) }
        deck.togglePlayback()
        try await waitUntil("The demo should create history before a seek") { deck.spectrumHistory.count >= 2 }
        deck.togglePlayback()

        deck.seek(5)
        XCTAssertEqual(deck.position, 5, accuracy: 0.001)
        XCTAssertTrue(deck.spectrumHistory.isEmpty, "Seeking starts a new time context instead of joining unrelated audio together")
        XCTAssertFalse(deck.engine.isPlaying, "Seeking a paused demo must not restart sound")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(deck.spectrumHistory.isEmpty)

        deck.togglePlayback()
        try await waitUntil("Playback after a seek should create fresh history") { deck.spectrumHistory.count >= 2 }
        deck.changeSource(.appleMusic)
        XCTAssertFalse(deck.engine.isPlaying)
        XCTAssertTrue(deck.spectrumHistory.isEmpty)
        XCTAssertFalse(deck.outputAudio.isListening)
        XCTAssertFalse(deck.microphone.isListening)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(deck.spectrumHistory.isEmpty, "Song metadata and playback position cannot manufacture an audio history")
        XCTAssertTrue(deck.spectrum.allSatisfy { $0 == 0 })
        XCTAssertTrue(deck.bandDecibels.allSatisfy { $0 == -120 })
        XCTAssertNil(deck.peakFrequency)
        XCTAssertNil(deck.rmsDecibels)
        XCTAssertEqual(deck.energyDistribution, [0, 0, 0])
    }

    @MainActor
    func testHiddenVisualizationStopsHistoryWorkAndReactivationDoesNotResumePausedAudio() async throws {
        let deck = try await preparedDemoDeck()
        defer { stop(deck) }
        deck.togglePlayback()
        try await waitUntil("The visible demo should create history") { deck.spectrumHistory.count >= 3 }

        deck.setVisualizationActive(false)
        let hiddenHistory = deck.spectrumHistory
        let playingPosition = deck.position
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(deck.spectrumHistory, hiddenHistory,
                       "Hiding the instrument must stop history accumulation even when background audio playback remains active")
        XCTAssertTrue(deck.engine.isPlaying)
        XCTAssertGreaterThan(deck.position, playingPosition, "Stopping the visualizer ticker must not accidentally stop permitted audio playback")

        deck.togglePlayback()
        XCTAssertFalse(deck.engine.isPlaying)
        let pausedPosition = deck.position
        deck.setVisualizationActive(true)
        XCTAssertTrue(deck.spectrumHistory.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(deck.engine.isPlaying, "Making the view visible again must not restart a paused deck")
        XCTAssertEqual(deck.position, pausedPosition, accuracy: 0.0001)
        XCTAssertTrue(deck.spectrumHistory.isEmpty)
    }

    @MainActor
    private func preparedDemoDeck() async throws -> DeckStore {
        let deck = DeckStore()
        await deck.prepare()
        let session = try XCTUnwrap(deck.engine.session, deck.message ?? "The original bundled demo must be present")
        XCTAssertEqual(session.title, "Neon Circuit")
        XCTAssertEqual(session.channels.count, 4)
        XCTAssertEqual(session.duration, 24, accuracy: 0.001)
        return deck
    }

    @MainActor
    private func stop(_ deck: DeckStore) {
        deck.setVisualizationActive(false)
        deck.engine.pause()
        deck.microphone.stop()
        deck.outputAudio.stop()
        deck.music.stopObserving()
    }

    @MainActor
    private func waitUntil(_ message: String, condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(1_500))
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }
}
