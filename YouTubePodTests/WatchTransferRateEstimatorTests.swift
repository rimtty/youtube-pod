import XCTest
@testable import YouTubePod

final class WatchTransferRateEstimatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let fileSize: Int64 = 100_000_000

    func testEstimateNeedsTwoSamplesSpanningTheMinimumInterval() {
        var estimator = WatchTransferRateEstimator()
        XCTAssertNil(estimator.estimate(fileSize: fileSize, at: start))

        estimator.record(fraction: 0.1, at: start)
        XCTAssertNil(estimator.estimate(fileSize: fileSize, at: start.addingTimeInterval(5)))

        estimator.record(fraction: 0.12, at: start.addingTimeInterval(5))
        XCTAssertNil(estimator.estimate(fileSize: fileSize, at: start.addingTimeInterval(5)))

        estimator.record(fraction: 0.2, at: start.addingTimeInterval(20))
        let estimate = try? XCTUnwrap(estimator.estimate(fileSize: fileSize, at: start.addingTimeInterval(20)))
        // 10% of 100 MB in 20 s = 500 KB/s; 80 MB remain = 160 s.
        XCTAssertEqual(estimate?.bytesPerSecond ?? 0, 500_000, accuracy: 1)
        XCTAssertEqual(estimate?.remainingSeconds ?? 0, 160, accuracy: 0.01)
    }

    func testCountdownAdvancesBetweenCallbacksAndClampsAtZero() {
        var estimator = WatchTransferRateEstimator()
        estimator.record(fraction: 0.5, at: start)
        estimator.record(fraction: 0.9, at: start.addingTimeInterval(40))

        let later = estimator.estimate(fileSize: fileSize, at: start.addingTimeInterval(45))
        // 10 MB remain at 1 MB/s = 10 s, minus the 5 s already elapsed.
        XCTAssertEqual(later?.remainingSeconds ?? -1, 5, accuracy: 0.01)

        let overdue = estimator.estimate(fileSize: fileSize, at: start.addingTimeInterval(60))
        XCTAssertEqual(overdue?.remainingSeconds, 0)
    }

    func testStallIsReportedAfterThirtySecondsWithoutProgress() {
        var estimator = WatchTransferRateEstimator()
        estimator.record(fraction: 0.2, at: start)
        estimator.record(fraction: 0.4, at: start.addingTimeInterval(20))

        let active = estimator.estimate(fileSize: fileSize, at: start.addingTimeInterval(49))
        XCTAssertFalse(active?.isStalled ?? true)

        let stalled = try? XCTUnwrap(estimator.estimate(fileSize: fileSize, at: start.addingTimeInterval(51)))
        XCTAssertTrue(stalled?.isStalled ?? false)
        XCTAssertNil(stalled?.remainingSeconds)
    }

    func testNonIncreasingSamplesAreIgnoredAndOldSamplesTrimmed() {
        var estimator = WatchTransferRateEstimator()
        estimator.record(fraction: 0.3, at: start)
        estimator.record(fraction: 0.3, at: start.addingTimeInterval(1))
        estimator.record(fraction: 0.25, at: start.addingTimeInterval(2))
        XCTAssertEqual(estimator.samples.count, 1)

        for second in stride(from: 10, through: 120, by: 10) {
            estimator.record(fraction: 0.3 + Double(second) / 1_000, at: start.addingTimeInterval(TimeInterval(second)))
        }
        let span = estimator.samples.last!.time.timeIntervalSince(estimator.samples.first!.time)
        XCTAssertLessThanOrEqual(span, WatchTransferRateEstimator.windowDuration + 10)
        XCTAssertGreaterThanOrEqual(span, WatchTransferRateEstimator.windowDuration)
    }

    func testPresentationRoundsUpToWholeMinutes() {
        let now = Date()
        func estimate(_ seconds: TimeInterval?) -> WatchTransferEstimate {
            WatchTransferEstimate(remainingSeconds: seconds, bytesPerSecond: 1, computedAt: now)
        }
        XCTAssertNil(WatchTransferEstimatePresentation.text(for: nil))
        XCTAssertEqual(WatchTransferEstimatePresentation.text(for: estimate(nil)), "一時停止中")
        XCTAssertEqual(WatchTransferEstimatePresentation.text(for: estimate(30)), "残り1分未満")
        XCTAssertEqual(WatchTransferEstimatePresentation.text(for: estimate(61)), "残り約2分")
        XCTAssertEqual(WatchTransferEstimatePresentation.text(for: estimate(59 * 60)), "残り約59分")
        XCTAssertEqual(WatchTransferEstimatePresentation.text(for: estimate(3_600)), "残り約1時間")
        XCTAssertEqual(WatchTransferEstimatePresentation.text(for: estimate(90 * 60)), "残り約1時間30分")
    }
}
