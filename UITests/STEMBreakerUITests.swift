import XCTest

final class STEMBreakerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let title = app.staticTexts["track-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 45), "The instrument did not open")
        waitUntil("The generated demo did not finish loading", timeout: 45) {
            title.exists && !title.label.isEmpty && title.label != "Loading session"
                && !self.control("processing").exists
        }
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testDemoTransportPlaysPausesAndSeeks() {
        XCTAssertFalse(app.staticTexts["track-title"].label.isEmpty)
        let position = app.sliders["playback-position"]
        XCTAssertTrue(position.exists)
        assertValue("00:00", on: position)

        tap("play-toggle")
        waitUntil("Play did not change to Pause") { self.app.buttons["play-toggle"].label == "Pause" }
        waitUntil("The audio playhead did not advance", timeout: 8) {
            self.seconds(position.value as? String) >= 1
        }

        tap("play-toggle")
        waitUntil("Pause did not return the transport to Play") { self.app.buttons["play-toggle"].label == "Play" }
        let pausedPosition = seconds(position.value as? String)
        let forward = app.buttons["Forward 15 seconds"]
        reveal(forward)
        forward.tap()
        waitUntil("Forward 15 seconds did not seek the audio playhead") {
            self.seconds(position.value as? String) >= pausedPosition + 13
        }
    }

    func testScopeShowsMeasuredFrequencyAndSupportsProbeAndHistory() {
        XCTAssertTrue(control("visualizer-spectrum").isSelected)
        XCTAssertTrue(control("frequency-readout").label.contains("Hz"))
        XCTAssertTrue(control("rms-readout").label.contains("dBFS"))
        for index in 0..<3 { XCTAssertTrue(control("band-energy-\(index)").exists) }
        let scope = control("audio-visualization")
        scope.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        waitUntil("Frequency probe did not report its measured band") {
            self.control("frequency-readout").label.contains("dBFS")
        }
        tap("visualizer-history")
        XCTAssertTrue(control("visualizer-history").isSelected)
        XCTAssertEqual(control("audio-visualization").label, "History visualization")
        tap("play-toggle")
        waitUntil("History did not leave the paused transport") { self.control("play-toggle").label == "Pause" }
        waitUntil("Playing mix did not publish measured digital level") {
            !self.control("rms-readout").label.contains("—")
        }
        tap("play-toggle")
        scrollToTop()
        tap("source-apple")
        XCTAssertEqual(control("frequency-readout").label, "— Hz")
        XCTAssertEqual(control("rms-readout").label, "— dBFS")
        for index in 0..<3 { assertValue("0 percent", on: control("band-energy-\(index)")) }
    }

    func testIndependentMuteSoloAndGainReset() {
        let initialGain = control("gain-0").value as? String
        XCTAssertNotNil(initialGain)
        for index in 0..<4 {
            assertValue("Off", on: control("mute-\(index)"))
            assertValue("Off", on: control("solo-\(index)"))
        }

        tap("mute-0")
        assertValue("On", on: control("mute-0"))
        assertValue("Off", on: control("mute-1"))
        tap("solo-2")
        assertValue("On", on: control("solo-2"))
        assertValue("Off", on: control("solo-1"))

        let fader = control("gain-0")
        reveal(fader)
        let start = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.1, thenDragTo: end)
        waitUntil("Dragging the vocal fader did not change its level") { (fader.value as? String) != initialGain }

        tap("reset-mix")
        for index in 0..<4 {
            assertValue("Off", on: control("mute-\(index)"))
            assertValue("Off", on: control("solo-\(index)"))
        }
        assertValue(initialGain ?? "", on: fader)
    }

    func testLoopAndAppleMusicSourceOfferAppropriateControls() {
        let loop = control("loop-toggle")
        let initialLoop = loop.value as? String ?? ""
        XCTAssertTrue(initialLoop == "On" || initialLoop == "Off")
        tap("loop-toggle")
        assertValue(initialLoop == "On" ? "Off" : "On", on: loop)
        tap("loop-toggle")
        assertValue(initialLoop, on: loop)

        scrollToTop()
        tap("source-apple")
        XCTAssertTrue(app.buttons["source-apple"].isSelected)
        XCTAssertTrue(control("mic-toggle").exists)
        if #available(iOS 27, *) {
            XCTAssertTrue(control("output-toggle").exists)
            XCTAssertEqual(control("output-toggle").label, "Listen to output")
            XCTAssertTrue(control("output-explanation").label.contains("Bluetooth"))
        }
        XCTAssertFalse(control("loop-toggle").exists)
        for index in 0..<4 {
            XCTAssertFalse(control("gain-\(index)").exists, "Apple Music must not expose unimplemented stem gain controls")
            XCTAssertFalse(control("mute-\(index)").exists)
            XCTAssertFalse(control("solo-\(index)").exists)
        }

        tap("source-deck")
        XCTAssertTrue(app.buttons["source-deck"].isSelected)
        XCTAssertTrue(control("gain-0").exists)
        XCTAssertTrue(control("loop-toggle").exists)
    }

    func testLibraryConnectExplainsSimulatorAvailability() {
        tap("open-library")
        let connect = control("connect-music")
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        reveal(connect)
        connect.tap()
        #if targetEnvironment(simulator)
        let error = control("library-error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        waitUntil("The library should explain that Apple Music requires an iPhone") {
            error.label.localizedCaseInsensitiveContains("iPhone")
                && error.label.localizedCaseInsensitiveContains("simulator")
        }
        XCTAssertTrue(connect.isEnabled, "The simulator error must leave the connection action available")
        #endif
        app.buttons["Done"].tap()
        XCTAssertTrue(control("open-library").waitForExistence(timeout: 3))
    }

    func testOutputListeningHasAnHonestSimulatorFallback() {
        #if targetEnvironment(simulator)
        if #available(iOS 27, *) {
            tap("source-apple")
            tap("output-toggle")
            let status = control("output-status")
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            XCTAssertTrue(status.label.localizedCaseInsensitiveContains("unavailable"))
            XCTAssertEqual(control("output-toggle").label, "Listen to output")
            scrollToTop()
            XCTAssertEqual(control("audio-visualization").value as? String, "Playback position only. Audio listening off.")
            tap("source-deck")
            XCTAssertTrue(control("gain-0").exists)
        }
        #endif
    }

    func testImportAndGuideExplainSourceCapabilities() {
        tap("open-import")
        XCTAssertTrue(app.navigationBars["Bring your sound"].waitForExistence(timeout: 5))
        XCTAssertTrue(control("import-mix").exists)
        XCTAssertTrue(control("import-stems").exists)
        XCTAssertTrue(control("load-demo").exists)
        XCTAssertTrue(app.staticTexts["Protected Apple Music downloads cannot be imported or separated."].exists)
        app.buttons["Done"].tap()

        tap("open-guide")
        let guide = app.navigationBars["Inside STEM breaker"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Apple Music")).firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(control("play-toggle").waitForExistence(timeout: 3))
    }

    func testExportCreatesShareableWAV() {
        tap("open-import")
        let export = control("export-mix")
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertTrue(export.isEnabled)
        reveal(export)
        export.tap()
        let share = control("share-mix")
        XCTAssertTrue(share.waitForExistence(timeout: 30), "Export did not produce a WAV ShareLink")
        reveal(share)
        XCTAssertTrue(share.isHittable)
        XCTAssertTrue(share.label.localizedCaseInsensitiveContains("WAV"))
        XCTAssertTrue(export.isEnabled, "Export should become available again after writing the mix")
    }

    private func control(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ identifier: String) {
        let element = control(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing control: \(identifier)")
        reveal(element)
        element.tap()
    }

    private func reveal(_ element: XCUIElement) {
        guard !element.isHittable else { return }
        for _ in 0..<4 {
            app.swipeUp()
            if element.isHittable { return }
        }
        for _ in 0..<4 {
            app.swipeDown()
            if element.isHittable { return }
        }
        XCTAssertTrue(element.isHittable, "The control is not reachable: \(element.identifier)")
    }

    private func scrollToTop() {
        for _ in 0..<4 {
            if control("source-apple").isHittable { return }
            app.swipeDown()
        }
    }

    private func assertValue(_ expected: String, on element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("Expected \(expected) on \(element.identifier)", file: file, line: line) {
            (element.value as? String) == expected
        }
    }

    private func waitUntil(_ failure: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, failure, file: file, line: line)
    }

    private func seconds(_ value: String?) -> Int {
        let parts = (value ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return -1 }
        return parts[0] * 60 + parts[1]
    }
}
