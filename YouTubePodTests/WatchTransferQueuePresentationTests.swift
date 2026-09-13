import XCTest
@testable import YouTubePod

@MainActor
final class WatchTransferQueuePresentationTests: XCTestCase {
    func testPositionFollowsSubmissionOrderAmongUndeliveredAudioTransfers() {
        let first = record("queue000001", state: .transferring, queuedAt: 10)
        let second = record("queue000002", state: .transferring, queuedAt: 20)
        let third = record("queue000003", state: .transferring, queuedAt: 30)
        let delivered = record("queue000004", state: .transferring, queuedAt: 5, audioDelivered: true)
        let waiting = record("queue000005", state: .queued, queuedAt: 1)
        let records = [third, waiting, delivered, second, first]

        XCTAssertEqual(WatchTransferQueuePresentation.position(of: first, in: records), 0)
        XCTAssertEqual(WatchTransferQueuePresentation.position(of: second, in: records), 1)
        XCTAssertEqual(WatchTransferQueuePresentation.position(of: third, in: records), 2)
        XCTAssertNil(WatchTransferQueuePresentation.position(of: delivered, in: records))
        XCTAssertNil(WatchTransferQueuePresentation.position(of: waiting, in: records))
    }

    func testOnlyRecordsBehindTheActiveTransferWithoutProgressWaitForTheirTurn() {
        XCTAssertFalse(WatchTransferQueuePresentation.isWaitingForTurn(position: 0, rawProgress: 0))
        XCTAssertFalse(WatchTransferQueuePresentation.isWaitingForTurn(position: nil, rawProgress: nil))
        XCTAssertTrue(WatchTransferQueuePresentation.isWaitingForTurn(position: 1, rawProgress: nil))
        XCTAssertTrue(WatchTransferQueuePresentation.isWaitingForTurn(position: 2, rawProgress: 0))
        // WCSession started this one after all; show its real progress.
        XCTAssertFalse(WatchTransferQueuePresentation.isWaitingForTurn(position: 1, rawProgress: 0.05))
        XCTAssertEqual(WatchTransferQueuePresentation.waitingText(position: 1), "Watchへ転送待ち（2番目）")
    }

    func testKeepWatchOpenHintShowsOnlyWhilePendingAndConnected() {
        let connected = WatchConnectionStatus(activation: .activated, isPaired: true, isWatchAppInstalled: true)
        let disconnected = WatchConnectionStatus(activation: .activated, isPaired: false, isWatchAppInstalled: false)
        let transferring = [record("hint0000001", state: .transferring, queuedAt: 1)]
        let queued = [record("hint0000002", state: .queued, queuedAt: 1)]
        let idle = [record("hint0000003", state: .availableOnWatch, queuedAt: 1), record("hint0000004", state: .preparing, queuedAt: 2)]

        XCTAssertTrue(WatchTransferHintPresentation.showsKeepWatchOpenHint(records: transferring, status: connected))
        XCTAssertTrue(WatchTransferHintPresentation.showsKeepWatchOpenHint(records: queued, status: connected))
        XCTAssertFalse(WatchTransferHintPresentation.showsKeepWatchOpenHint(records: idle, status: connected))
        XCTAssertFalse(WatchTransferHintPresentation.showsKeepWatchOpenHint(records: transferring, status: disconnected))
        XCTAssertFalse(WatchTransferHintPresentation.showsKeepWatchOpenHint(records: [], status: connected))
    }

    private func record(
        _ id: String,
        state: WatchTransferState,
        queuedAt: TimeInterval,
        audioDelivered: Bool = false
    ) -> WatchTransferRecord {
        WatchTransferRecord(
            youtubeID: id,
            title: id,
            channelTitle: "Channel",
            publishedAt: .now,
            duration: 60,
            savedViewCount: 1,
            sourceFileSize: 1,
            transferID: UUID(),
            revision: 1,
            state: state,
            audioDeliveryFinished: audioDelivered,
            queuedAt: Date(timeIntervalSince1970: queuedAt)
        )
    }
}
