import XCTest
@testable import YouTubePod

final class DomainModelTests: XCTestCase {
    func testDownloadPhaseReportsOnlyInFlightStatesAsActive() {
        XCTAssertTrue(DownloadPhase.queued.isActive)
        XCTAssertTrue(DownloadPhase.downloading(0).isActive)
        XCTAssertTrue(DownloadPhase.downloading(0.5).isActive)
        XCTAssertTrue(DownloadPhase.validating.isActive)
        XCTAssertFalse(DownloadPhase.completed.isActive)
        XCTAssertFalse(DownloadPhase.failed("network").isActive)
    }

    func testDownloadProgressAndFailuresCarryTheirValues() {
        XCTAssertEqual(DownloadPhase.downloading(0.25), .downloading(0.25))
        XCTAssertNotEqual(DownloadPhase.downloading(0.25), .downloading(0.5))
        XCTAssertEqual(DownloadPhase.failed("quota"), .failed("quota"))
        XCTAssertNotEqual(DownloadPhase.failed("quota"), .failed("offline"))
    }

    func testVideoSummaryBuildsCanonicalWatchURL() {
        let video = makeVideoSummary(id: "dQw4w9WgXcQ")

        XCTAssertEqual(
            video.watchURL.absoluteString,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
    }

    func testLiveUpcomingAndZeroDurationVideosCannotBeExtracted() {
        let normal = makeVideoSummary(id: "normalvideo1")
        let live = makeVideoSummary(id: "livevideo001", broadcastStatus: .live)
        let upcoming = makeVideoSummary(id: "upcoming001", broadcastStatus: .upcoming)
        let processing = makeVideoSummary(id: "processing1", duration: 0)

        XCTAssertTrue(normal.supportsAudioExtraction)
        XCTAssertFalse(live.supportsAudioExtraction)
        XCTAssertFalse(upcoming.supportsAudioExtraction)
        XCTAssertFalse(processing.supportsAudioExtraction)
        XCTAssertEqual(live.audioExtractionUnavailableMessage, "ライブ配信は音声保存の対象外です")
        XCTAssertEqual(upcoming.audioExtractionUnavailableMessage, "公開前の動画は音声保存の対象外です")
        XCTAssertEqual(processing.audioExtractionUnavailableMessage, "音声の準備が完了していません")
    }

    func testExtractorMapsRawYTDLPFailuresToJapaneseGuidance() {
        XCTAssertEqual(
            ExtractionError.userFacingMessage(for: "ERROR: Requested format is not available"),
            "この動画では保存できるM4A音声が提供されていません。通常の公開済み動画を選んでください。"
        )
        XCTAssertEqual(
            ExtractionError.userFacingMessage(for: "ERROR: This video is unavailable"),
            "この動画は現在利用できません。公開状態を確認して、別の動画を選んでください。"
        )
        XCTAssertEqual(
            ExtractionError.userFacingMessage(for: "unexpected internal detail"),
            "音声を保存できませんでした。通信状態を確認して、もう一度お試しください。"
        )
    }

    func testSavedAudioInitializerPreservesOfflineMetadata() {
        let publishedAt = Date(timeIntervalSince1970: 1_000)
        let downloadedAt = Date(timeIntervalSince1970: 2_000)
        let audio = SavedAudio(
            youtubeID: "dQw4w9WgXcQ",
            title: "Test title",
            channelTitle: "Test channel",
            publishedAt: publishedAt,
            savedViewCount: 42,
            duration: 90,
            downloadedAt: downloadedAt,
            fileSize: 1_024,
            audioRelativePath: "Audio/dQw4w9WgXcQ.m4a",
            thumbnailRelativePath: "Thumbnails/dQw4w9WgXcQ.jpg",
            lastPlaybackPosition: 15
        )

        XCTAssertEqual(audio.youtubeID, "dQw4w9WgXcQ")
        XCTAssertEqual(audio.title, "Test title")
        XCTAssertEqual(audio.channelTitle, "Test channel")
        XCTAssertEqual(audio.publishedAt, publishedAt)
        XCTAssertEqual(audio.savedViewCount, 42)
        XCTAssertEqual(audio.duration, 90)
        XCTAssertEqual(audio.downloadedAt, downloadedAt)
        XCTAssertEqual(audio.fileSize, 1_024)
        XCTAssertEqual(audio.audioRelativePath, "Audio/dQw4w9WgXcQ.m4a")
        XCTAssertEqual(audio.thumbnailRelativePath, "Thumbnails/dQw4w9WgXcQ.jpg")
        XCTAssertEqual(audio.lastPlaybackPosition, 15)
        XCTAssertEqual(audio.playbackProgress, 1.0 / 6.0, accuracy: 0.000_001)
    }

    func testSavedAudioPlaybackProgressClampsInvalidAndOutOfRangePositions() {
        let audio = SavedAudio(
            youtubeID: "progress001",
            title: "Progress",
            channelTitle: "Channel",
            publishedAt: .now,
            savedViewCount: 1,
            duration: 100,
            fileSize: 1,
            audioRelativePath: "Audio/progress001.m4a",
            lastPlaybackPosition: 150,
            hasBeenPlayed: true
        )

        XCTAssertEqual(audio.playbackProgress, 1)
        audio.lastPlaybackPosition = -10
        XCTAssertEqual(audio.playbackProgress, 0)
        audio.lastPlaybackPosition = .nan
        XCTAssertEqual(audio.playbackProgress, 0)
        audio.lastPlaybackPosition = 50
        audio.duration = 0
        XCTAssertEqual(audio.playbackProgress, 0)
    }

    func testChunkingPreservesOrderAndRemainder() {
        XCTAssertEqual(Array(1...5).chunks(ofCount: 2), [[1, 2], [3, 4], [5]])
        XCTAssertEqual([Int]().chunks(ofCount: 3), [])
        XCTAssertEqual([1, 2].chunks(ofCount: 0), [])
    }

    func testFeedMergeSortsAndRemovesDuplicateVideos() {
        let older = makeVideoSummary(id: "aaaaaaaaaaa", publishedAt: Date(timeIntervalSince1970: 10))
        let newer = makeVideoSummary(id: "bbbbbbbbbbb", publishedAt: Date(timeIntervalSince1970: 20))
        let duplicate = makeVideoSummary(id: "aaaaaaaaaaa", publishedAt: Date(timeIntervalSince1970: 10))

        let result = YouTubeDataClient.mergeUnique([[older, newer], [duplicate]])

        XCTAssertEqual(result.map(\.id), ["bbbbbbbbbbb", "aaaaaaaaaaa"])
    }

    private func makeVideoSummary(
        id: String,
        publishedAt: Date = Date(timeIntervalSince1970: 0),
        duration: TimeInterval = 60,
        broadcastStatus: YouTubeBroadcastStatus = .none
    ) -> VideoSummary {
        VideoSummary(
            id: id,
            title: "Title",
            channelTitle: "Channel",
            thumbnailURL: URL(string: "https://example.com/image.jpg"),
            publishedAt: publishedAt,
            viewCount: 100,
            duration: duration,
            broadcastStatus: broadcastStatus
        )
    }
}
