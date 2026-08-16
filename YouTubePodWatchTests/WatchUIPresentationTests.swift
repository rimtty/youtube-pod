import XCTest
@testable import YouTubePodWatch

final class WatchUIPresentationTests: XCTestCase {
    func testCurrentItemUsesLiveProgressInsteadOfPersistedProgress() {
        let progress = WatchUIPresentation.playbackProgress(
            duration: 200,
            persistedProgress: 0.1,
            isCurrent: true,
            currentTime: 75
        )

        XCTAssertEqual(progress, 0.375, accuracy: 0.000_001)
    }

    func testNoncurrentItemUsesPersistedProgress() {
        let progress = WatchUIPresentation.playbackProgress(
            duration: 200,
            persistedProgress: 0.42,
            isCurrent: false,
            currentTime: 150
        )

        XCTAssertEqual(progress, 0.42, accuracy: 0.000_001)
    }

    func testProgressClampsCurrentAndPersistedValues() {
        XCTAssertEqual(
            WatchUIPresentation.playbackProgress(
                duration: 100,
                persistedProgress: 0.5,
                isCurrent: true,
                currentTime: -25
            ),
            0
        )
        XCTAssertEqual(
            WatchUIPresentation.playbackProgress(
                duration: 100,
                persistedProgress: 0.5,
                isCurrent: true,
                currentTime: 125
            ),
            1
        )
        XCTAssertEqual(
            WatchUIPresentation.playbackProgress(
                duration: 100,
                persistedProgress: -0.2,
                isCurrent: false,
                currentTime: 0
            ),
            0
        )
        XCTAssertEqual(
            WatchUIPresentation.playbackProgress(
                duration: 100,
                persistedProgress: 1.2,
                isCurrent: false,
                currentTime: 0
            ),
            1
        )
    }

    func testInvalidLiveProgressFallsBackToSanitizedPersistedProgress() {
        XCTAssertEqual(
            WatchUIPresentation.playbackProgress(
                duration: 100,
                persistedProgress: 0.35,
                isCurrent: true,
                currentTime: .nan
            ),
            0.35,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            WatchUIPresentation.playbackProgress(
                duration: .nan,
                persistedProgress: 0.35,
                isCurrent: true,
                currentTime: 20
            ),
            0.35,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            WatchUIPresentation.playbackProgress(
                duration: 100,
                persistedProgress: .nan,
                isCurrent: false,
                currentTime: 0
            ),
            0
        )
    }

    func testFreshCurrentItemShowsZeroPercentInsteadOfNewBadge() {
        XCTAssertTrue(
            WatchUIPresentation.showsPlaybackProgress(hasBeenPlayed: false, isCurrent: true)
        )
        XCTAssertFalse(
            WatchUIPresentation.showsPlaybackProgress(hasBeenPlayed: false, isCurrent: false)
        )
        XCTAssertTrue(
            WatchUIPresentation.showsPlaybackProgress(hasBeenPlayed: true, isCurrent: false)
        )
        XCTAssertEqual(WatchUIPresentation.playbackPercentage(progress: 0), 0)
    }

    func testPlaybackPercentageUsesTheSameClampedRoundedProgress() {
        XCTAssertEqual(WatchUIPresentation.playbackPercentage(progress: 0.424), 42)
        XCTAssertEqual(WatchUIPresentation.playbackPercentage(progress: 0.425), 43)
        XCTAssertEqual(WatchUIPresentation.playbackPercentage(progress: -1), 0)
        XCTAssertEqual(WatchUIPresentation.playbackPercentage(progress: 2), 100)
        XCTAssertEqual(WatchUIPresentation.playbackPercentage(progress: .nan), 0)
    }

    func testPlaybackSymbolAnimationRespectsReduceMotion() {
        XCTAssertTrue(
            WatchUIPresentation.shouldAnimatePlaybackSymbol(
                isPlaying: true,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            WatchUIPresentation.shouldAnimatePlaybackSymbol(
                isPlaying: true,
                reduceMotion: true
            )
        )
        XCTAssertFalse(
            WatchUIPresentation.shouldAnimatePlaybackSymbol(
                isPlaying: false,
                reduceMotion: false
            )
        )
    }

    func testReceiverErrorUsesCompactLayoutOnlyForAccessibilitySizes() {
        XCTAssertEqual(
            WatchUIPresentation.receiverErrorLayout(isAccessibilitySize: false),
            .detailed
        )
        XCTAssertEqual(
            WatchUIPresentation.receiverErrorLayout(isAccessibilitySize: true),
            .compact
        )
    }

    func testPlaybackErrorsHaveSpecificMessagesAndSymbols() {
        XCTAssertEqual(
            WatchUIPresentation.playbackError(.audioSessionConfigurationFailed),
            WatchPlaybackErrorPresentation(
                message: "オーディオを設定できませんでした",
                symbolName: "exclamationmark.triangle.fill"
            )
        )
        XCTAssertEqual(
            WatchUIPresentation.playbackError(.audioRouteUnavailable),
            WatchPlaybackErrorPresentation(
                message: "イヤホンの接続を確認してください",
                symbolName: "airpodspro"
            )
        )
        XCTAssertEqual(
            WatchUIPresentation.playbackError(.fileUnavailable),
            WatchPlaybackErrorPresentation(
                message: "音声ファイルが見つかりません",
                symbolName: "doc.badge.xmark"
            )
        )
        XCTAssertEqual(
            WatchUIPresentation.playbackError(.playbackFailed),
            WatchPlaybackErrorPresentation(
                message: "音声を再生できませんでした",
                symbolName: "speaker.slash.fill"
            )
        )
        XCTAssertEqual(
            WatchUIPresentation.playbackError(.persistenceFailed),
            WatchPlaybackErrorPresentation(
                message: "再生位置を保存できませんでした",
                symbolName: "externaldrive.badge.exclamationmark"
            )
        )
    }
}
