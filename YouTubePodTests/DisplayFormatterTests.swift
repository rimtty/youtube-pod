import XCTest
@testable import YouTubePod

final class DisplayFormatterTests: XCTestCase {
    func testFormatsDurationsAcrossMinuteAndHourBoundaries() {
        XCTAssertEqual(DisplayFormatter.duration(0), "0:00")
        XCTAssertEqual(DisplayFormatter.duration(65), "1:05")
        XCTAssertEqual(DisplayFormatter.duration(3_661), "1:01:01")
    }

    func testInvalidDurationsFallBackToZero() {
        XCTAssertEqual(DisplayFormatter.duration(-1), "0:00")
        XCTAssertEqual(DisplayFormatter.duration(.infinity), "0:00")
        XCTAssertEqual(DisplayFormatter.duration(.nan), "0:00")
    }

    func testDurationDropsSubsecondPrecision() {
        XCTAssertEqual(DisplayFormatter.duration(59.999), "0:59")
    }

    func testFormatsViewsUsingJapaneseGrouping() {
        XCTAssertEqual(DisplayFormatter.views(1_234_567), "1,234,567 回視聴")
    }

    func testRelativeDateProducesLocalizedText() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let oneHourAgo = now.addingTimeInterval(-3_600)

        let result = DisplayFormatter.relativeDate(oneHourAgo, relativeTo: now)

        XCTAssertFalse(result.isEmpty)
        XCTAssertNotEqual(result, oneHourAgo.description)
    }
}
