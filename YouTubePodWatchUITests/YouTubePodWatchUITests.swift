import XCTest

@MainActor
final class YouTubePodWatchUITests: XCTestCase {
    private enum AccessibilityID {
        static let compactReceiverError = "watch.receiver.error.compact"
        static let detailedReceiverError = "watch.receiver.error.detailed"
        static let playableRow = "watch.library.row.uitest00001"
        static let missingFileRow = "watch.library.row.uitest00002"
        static let simulatorSyncRow = "watch.library.row.simulator01"
        static let openPlayer = "watch.player.open"
        static let seekBackward = "watch.now-playing.seek-backward"
        static let seekForward = "watch.now-playing.seek-forward"
        static let scrubber = "watch.now-playing.scrubber"
        static let playPauseOverlay = "watch.now-playing.play-pause-overlay"
        static let systemVolumeControl = "watch.now-playing.system-volume-control"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAccessibilitySizeUsesCompactErrorAndKeepsPlayableRowReachable() {
        let app = launchFixture(
            additionalArguments: ["--watch-ui-test-accessibility-size"]
        )

        let compactError = element(AccessibilityID.compactReceiverError, in: app)
        XCTAssertTrue(compactError.waitForExistence(timeout: 8))
        XCTAssertTrue(
            makeHittable(compactError, in: app),
            "The compact retry control must remain reachable at an accessibility text size."
        )
        XCTAssertFalse(
            element(AccessibilityID.detailedReceiverError, in: app).exists,
            "The detailed error layout must not compete for space at an accessibility text size."
        )

        let playableRow = app.buttons[AccessibilityID.playableRow]
        XCTAssertTrue(
            makeHittable(playableRow, in: app),
            "A playable row must remain scroll-reachable and tappable on the compact Watch display."
        )
    }

    func testMissingFileRowIsPresentedAsNonButton() {
        let app = launchFixture()
        let missingFileRow = element(AccessibilityID.missingFileRow, in: app)

        XCTAssertTrue(
            makeExist(missingFileRow, in: app),
            "The missing-file row must remain reachable below the first row on 41 mm displays."
        )
        XCTAssertEqual(
            app.buttons.matching(identifier: AccessibilityID.missingFileRow).count,
            0,
            "A row whose local audio file is missing must not expose a playback action."
        )
    }

    func testCurrentRowAccessibilityValueReportsLiveProgress() {
        let app = launchFixture()
        let currentRow = element(AccessibilityID.playableRow, in: app)

        XCTAssertTrue(currentRow.waitForExistence(timeout: 8))
        XCTAssertTrue(
            waitForValue("25%", on: currentRow, timeout: 8),
            "The fixture must expose its initial live playback position."
        )
        XCTAssertTrue(
            waitForValue("30%", on: currentRow, timeout: 8),
            "The row accessibility value must follow the player's live progress."
        )
    }

    func testReduceMotionFixtureReportsStaticPlaybackPresentation() {
        let app = launchFixture(
            additionalArguments: ["--watch-ui-test-reduce-motion"]
        )
        let currentRow = element(AccessibilityID.playableRow, in: app)

        XCTAssertTrue(currentRow.waitForExistence(timeout: 8))
        XCTAssertTrue(
            waitForValueContaining("static", on: currentRow, timeout: 8),
            "Playback decoration must stay static when Reduce Motion is enabled."
        )
    }

    func testNowPlayingSeekButtonsUseFifteenSecondActionsAndUpdatePosition() {
        let app = launchFixture()
        openNowPlaying(in: app)

        let scrubber = element(AccessibilityID.scrubber, in: app)
        let forward = app.buttons[AccessibilityID.seekForward].firstMatch
        let backward = app.buttons[AccessibilityID.seekBackward].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        XCTAssertTrue(backward.waitForExistence(timeout: 5))

        guard let initialTime = playbackSeconds(on: scrubber) else {
            return XCTFail("The scrubber must expose a readable playback position.")
        }
        forward.tap()
        guard let forwardedTime = waitForPlaybackSeconds(
            on: scrubber,
            timeout: 3,
            satisfying: { $0 >= initialTime + 13 }
        ) else {
            return XCTFail("The forward action must advance playback by about 15 seconds.")
        }
        backward.tap()
        XCTAssertNotNil(
            waitForPlaybackSeconds(
                on: scrubber,
                timeout: 3,
                satisfying: { $0 <= forwardedTime - 13 }
            ),
            "The backward action must move playback back by about 15 seconds."
        )
    }

    func testNowPlayingScrubberSupportsPressAndDragSeeking() {
        let app = launchFixture()
        openNowPlaying(in: app)

        let scrubber = element(AccessibilityID.scrubber, in: app)
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))

        let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: end)

        XCTAssertNotNil(
            waitForPlaybackSeconds(
                on: scrubber,
                timeout: 3,
                satisfying: { $0 >= 80 }
            ),
            "Dragging to three quarters of the timeline must seek near that position."
        )
    }

    func testNowPlayingFitsPrimaryControlsAndUsesArtworkPlaybackOverlay() {
        let app = launchFixture()
        openNowPlaying(in: app)

        let playPause = app.buttons[AccessibilityID.playPauseOverlay].firstMatch
        let scrubber = element(AccessibilityID.scrubber, in: app)
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertTrue(playPause.isHittable)
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Watch Now Playing compact layout"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertLessThanOrEqual(
            scrubber.frame.maxY,
            app.frame.maxY,
            "The artwork playback control and timeline must fit without scrolling."
        )
        XCTAssertFalse(app.buttons["前の項目"].exists)
        XCTAssertFalse(app.buttons["次の項目"].exists)

        playPause.tap()
        let pausedOverlay = app.buttons[AccessibilityID.playPauseOverlay].firstMatch
        XCTAssertTrue(pausedOverlay.waitForExistence(timeout: 2))
        XCTAssertEqual(pausedOverlay.label, "再生")
    }

    func testDigitalCrownUsesSystemVolumeControlWithoutMovingTimeline() {
        let app = launchFixture()
        openNowPlaying(in: app)

        let volumeControl = element(AccessibilityID.systemVolumeControl, in: app)
        let scrubber = element(AccessibilityID.scrubber, in: app)
        XCTAssertTrue(volumeControl.waitForExistence(timeout: 5))
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        let initialVolumeFrame = volumeControl.frame
        let initialScrubberFrame = scrubber.frame

        XCUIDevice.shared.rotateDigitalCrown(delta: -0.5)

        XCTAssertEqual(volumeControl.frame.minY, initialVolumeFrame.minY, accuracy: 1)
        XCTAssertEqual(scrubber.frame.minY, initialScrubberFrame.minY, accuracy: 1)
    }

    func testSimulatorSyncFixtureImportsAudioThroughProductionReceivePipeline() {
        let app = XCUIApplication()
        app.launchArguments = ["--watch-sync-simulator-fixture"]
        app.launch()

        let row = app.buttons[AccessibilityID.simulatorSyncRow]
        XCTAssertTrue(
            row.waitForExistence(timeout: 12),
            "The Simulator delivery boundary must feed the production staging, validation, persistence, and library UI pipeline."
        )
        XCTAssertEqual(row.value as? String, "新着")
    }

    private func launchFixture(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--watch-ui-test-fixture"] + additionalArguments
        app.launch()
        return app
    }

    private func openNowPlaying(in app: XCUIApplication) {
        let openPlayer = app.buttons[AccessibilityID.openPlayer].firstMatch
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 8))
        openPlayer.tap()
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func makeHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard makeExist(element, in: app) else { return false }
        if element.isHittable { return true }

        for _ in 0..<6 {
            app.swipeUp()
            if waitForHittable(element, timeout: 0.75) {
                return true
            }
        }
        return false
    }

    private func makeExist(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 2) { return true }

        // SwiftUI List lazily omits off-screen rows from the accessibility
        // hierarchy on the 41 mm Watch. Scroll while resolving the query,
        // rather than requiring the element to exist before scrolling.
        for _ in 0..<6 {
            app.swipeUp()
            if element.waitForExistence(timeout: 0.75) {
                return true
            }
        }
        return false
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForValue(
        _ expectedValue: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForValueContaining(
        _ expectedFragment: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", expectedFragment),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForPlaybackSeconds(
        on element: XCUIElement,
        timeout: TimeInterval,
        satisfying condition: (Int) -> Bool
    ) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let seconds = playbackSeconds(on: element), condition(seconds) {
                return seconds
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    private func playbackSeconds(on element: XCUIElement) -> Int? {
        guard let value = element.value as? String else { return nil }
        let numbers = value
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        return numbers[0] * 60 + numbers[1]
    }
}
