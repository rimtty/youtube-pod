import XCTest

@MainActor
final class YouTubePodWatchUITests: XCTestCase {
    private enum AccessibilityID {
        static let compactReceiverError = "watch.receiver.error.compact"
        static let detailedReceiverError = "watch.receiver.error.detailed"
        static let playableRow = "watch.library.row.uitest00001"
        static let missingFileRow = "watch.library.row.uitest00002"
        static let simulatorSyncRow = "watch.library.row.simulator01"
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
}
