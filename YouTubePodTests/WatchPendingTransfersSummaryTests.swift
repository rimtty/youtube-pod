import XCTest
@testable import YouTubePod

@MainActor
final class WatchPendingTransfersSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testBuilderCountsUndeliveredAudioAndPicksOldestTransferringAsActive() {
        let later = record("active00002", state: .transferring, queuedAt: 20, bytes: 200)
        let active = record("active00001", state: .transferring, queuedAt: 10, bytes: 100, title: "  Active title ")
        let delivered = record("active00003", state: .transferring, queuedAt: 5, bytes: 999, audioDelivered: true)
        let queued = record("queued00001", state: .queued, queuedAt: 30, bytes: 50)
        let preparing = record("prep0000001", state: .preparing, queuedAt: 1, bytes: 5_000)
        let done = record("done0000001", state: .availableOnWatch, queuedAt: 1, bytes: 5_000)

        let summary = WatchPendingTransfersSummary.make(
            records: [later, active, delivered, queued, preparing, done],
            at: now
        )

        XCTAssertEqual(summary.queuedCount, 1)
        XCTAssertEqual(summary.transferringCount, 2)
        XCTAssertEqual(summary.pendingCount, 3)
        XCTAssertEqual(summary.totalBytes, 350)
        XCTAssertEqual(summary.activeYouTubeID, active.youtubeID)
        XCTAssertEqual(summary.activeTitle, "Active title")
        XCTAssertEqual(summary.publishedAt, now)
        XCTAssertNoThrow(try summary.validated())
    }

    func testEmptyLibraryProducesNoneAndContentComparisonIgnoresPublishedAt() {
        let first = WatchPendingTransfersSummary.make(records: [], at: now)
        let second = WatchPendingTransfersSummary.make(records: [], at: now.addingTimeInterval(60))

        XCTAssertEqual(first.pendingCount, 0)
        XCTAssertNil(first.activeYouTubeID)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasSameContent(as: second))

        let changed = WatchPendingTransfersSummary.make(
            records: [record("queued00002", state: .queued, queuedAt: 1, bytes: 1)],
            at: now
        )
        XCTAssertFalse(first.hasSameContent(as: changed))
    }

    func testPhoneApplicationContextComparesBothParts() {
        let request = WatchInventoryRequest(requestID: UUID(), requestedAt: now)
        let summary = WatchPendingTransfersSummary.none(at: now)
        let base = WatchPhoneApplicationContext(inventoryRequest: request, pendingTransfers: summary)

        XCTAssertTrue(base.hasSameContent(as: WatchPhoneApplicationContext(
            inventoryRequest: request,
            pendingTransfers: .none(at: now.addingTimeInterval(5))
        )))
        XCTAssertFalse(base.hasSameContent(as: WatchPhoneApplicationContext(
            inventoryRequest: nil,
            pendingTransfers: summary
        )))
        XCTAssertFalse(base.hasSameContent(as: WatchPhoneApplicationContext(
            inventoryRequest: request,
            pendingTransfers: WatchPendingTransfersSummary(queuedCount: 1, transferringCount: 0, totalBytes: 1, publishedAt: now)
        )))
    }

    private func record(
        _ id: String,
        state: WatchTransferState,
        queuedAt: TimeInterval,
        bytes: Int64,
        title: String = "Title",
        audioDelivered: Bool = false
    ) -> WatchTransferRecord {
        WatchTransferRecord(
            youtubeID: id,
            title: title,
            channelTitle: "Channel",
            publishedAt: now,
            duration: 60,
            savedViewCount: 1,
            sourceFileSize: bytes,
            transferID: UUID(),
            revision: 1,
            state: state,
            audioDeliveryFinished: audioDelivered,
            queuedAt: Date(timeIntervalSince1970: queuedAt)
        )
    }
}
