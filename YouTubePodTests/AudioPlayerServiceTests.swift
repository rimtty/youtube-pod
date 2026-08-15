import MediaPlayer
import UIKit
import XCTest
@testable import YouTubePod

@MainActor
final class AudioPlayerServiceTests: XCTestCase {
    func testQueueSeekNavigationAndExplicitPersistence() {
        var persisted: [(String, TimeInterval)] = []
        let player = AudioPlayerService(persistPlaybackPosition: { videoID, position in
            persisted.append((videoID, position))
        })
        let first = item(id: "player00001", duration: 100, resumePosition: 12)
        let second = item(id: "player00002", duration: 50, resumePosition: 3)

        player.play(first, queue: [first, second])
        XCTAssertEqual(player.currentItem?.id, first.id)
        XCTAssertEqual(player.currentTime, 12)

        player.seek(to: 40)
        player.persistPosition()
        XCTAssertEqual(player.currentTime, 40)
        XCTAssertEqual(persisted.last?.0, first.id)
        XCTAssertEqual(persisted.last?.1, 40)

        player.previous()
        XCTAssertEqual(player.currentTime, 0)

        player.next()
        XCTAssertEqual(player.currentItem?.id, second.id)
        XCTAssertEqual(player.currentTime, 3)
    }

    func testSeekClampsToPlaybackBounds() {
        let player = AudioPlayerService()
        let item = item(id: "player00003", duration: 30, resumePosition: 0)
        player.play(item, queue: [item])

        player.seek(to: -5)
        XCTAssertEqual(player.currentTime, 0)
        player.seek(to: 90)
        XCTAssertEqual(player.currentTime, 30)
    }

    func testRapidAlternatingSkipsAccumulateFromLatestVisiblePosition() {
        let player = AudioPlayerService()
        let item = item(id: "player00004", duration: 120, resumePosition: 45)
        player.play(item, queue: [item])

        player.skip(by: 15)
        player.skip(by: 15)
        player.skip(by: -15)
        player.skip(by: 15)

        XCTAssertEqual(player.currentTime, 75)
    }

    func testCompletionPersistsOneHundredPercentAndReplayStartsAtBeginning() {
        var persisted: [(String, TimeInterval)] = []
        let player = AudioPlayerService(persistPlaybackPosition: { videoID, position in
            persisted.append((videoID, position))
        })
        let playbackItem = item(id: "playerdone1", duration: 120, resumePosition: 30)
        player.play(playbackItem, queue: [playbackItem])

        player.handlePlaybackCompletion()

        XCTAssertEqual(player.currentTime, 120)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(persisted.last?.0, playbackItem.id)
        XCTAssertEqual(persisted.last?.1, 120)

        player.togglePlayback()
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(persisted.last?.1, 0)
    }

    func testCompletionAdvancesToNextQueuedItem() {
        let player = AudioPlayerService()
        let first = item(id: "playerdone2", duration: 60, resumePosition: 0)
        let second = item(id: "playerdone3", duration: 90, resumePosition: 12)
        player.play(first, queue: [first, second])

        player.handlePlaybackCompletion()

        XCTAssertEqual(player.currentItem?.id, second.id)
        XCTAssertEqual(player.currentTime, 12)
    }

    func testStartingItemsMarksEachQueueEntryAsPlayed() {
        var playedIDs: [String] = []
        let player = AudioPlayerService(markPlaybackStarted: { playedIDs.append($0) })
        let first = item(id: "player00005", duration: 120, resumePosition: 0)
        let second = item(id: "player00006", duration: 120, resumePosition: 0)

        player.play(first, queue: [first, second])
        player.next()

        XCTAssertEqual(playedIDs, [first.id, second.id])
    }

    func testNextAtQueueEndPreservesLastPlaybackPosition() {
        var persisted: [(String, TimeInterval)] = []
        let player = AudioPlayerService(persistPlaybackPosition: { videoID, position in
            persisted.append((videoID, position))
        })
        let playbackItem = item(id: "playerend01", duration: 120, resumePosition: 12)
        player.play(playbackItem, queue: [playbackItem])
        player.seek(to: 42)
        persisted.removeAll()

        player.next()
        player.next()
        player.persistPosition()

        XCTAssertEqual(player.currentItem?.id, playbackItem.id)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(persisted.map(\.0), [playbackItem.id, playbackItem.id, playbackItem.id])
        XCTAssertEqual(persisted.map(\.1), [42, 42, 42])
        XCTAssertFalse(persisted.contains { $0.1 == 0 })

        player.seek(to: 10)
        player.persistPosition()
        XCTAssertEqual(persisted.suffix(2).map(\.1), [10, 10])
    }

    func testRemovingCurrentItemStopsPlaybackAndClearsNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let player = AudioPlayerService()
        let playbackItem = item(id: "player00007", duration: 120, resumePosition: 30)
        player.play(playbackItem, queue: [playbackItem])

        player.removeFromQueue(videoID: playbackItem.id)

        XCTAssertNil(player.currentItem)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    func testRemovingQueuedItemPreventsItFromPlayingNext() {
        let player = AudioPlayerService()
        let first = item(id: "player00008", duration: 120, resumePosition: 0)
        let removed = item(id: "player00009", duration: 120, resumePosition: 0)
        let third = item(id: "player00010", duration: 120, resumePosition: 0)
        player.play(first, queue: [first, removed, third])

        player.removeFromQueue(videoID: removed.id)
        player.next()

        XCTAssertEqual(player.currentItem?.id, third.id)
    }

    func testNowPlayingArtworkHandlerCanRunOnMediaPlayerBackgroundQueue() async throws {
        let artworkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-playing-\(UUID().uuidString).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 32, height: 32)))
        }
        try XCTUnwrap(image.pngData()).write(to: artworkURL)
        defer {
            try? FileManager.default.removeItem(at: artworkURL)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }

        let player = AudioPlayerService()
        let playbackItem = PlaybackItem(
            id: "artwork0001",
            title: "Artwork",
            channelTitle: "Test channel",
            duration: 30,
            fileURL: URL(fileURLWithPath: "/tmp/artwork0001.m4a"),
            artworkURL: artworkURL,
            resumePosition: 0
        )
        player.play(playbackItem, queue: [playbackItem])

        var artwork: MPMediaItemArtwork?
        for _ in 0..<50 where artwork == nil {
            try await Task.sleep(for: .milliseconds(20))
            artwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork]
                as? MPMediaItemArtwork
        }
        let box = ArtworkBox(try XCTUnwrap(artwork))

        let generatedOffMainActor = await Task.detached {
            box.artwork.image(at: CGSize(width: 24, height: 24)) != nil
        }.value

        XCTAssertTrue(generatedOffMainActor)
    }

    func testArtworkFromPreviousItemCannotAppearOnItemWithoutArtwork() async throws {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let artworkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-now-playing-\(UUID().uuidString).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1_024, height: 1_024)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 1_024, height: 1_024)))
        }
        try XCTUnwrap(image.pngData()).write(to: artworkURL)
        defer {
            try? FileManager.default.removeItem(at: artworkURL)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }

        let player = AudioPlayerService()
        let first = PlaybackItem(
            id: "staleart001",
            title: "First",
            channelTitle: "Test channel",
            duration: 30,
            fileURL: URL(fileURLWithPath: "/tmp/staleart001.m4a"),
            artworkURL: artworkURL,
            resumePosition: 0
        )
        let second = item(id: "staleart002", duration: 30, resumePosition: 0)

        player.play(first, queue: [first, second])
        player.next()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(player.currentItem?.id, second.id)
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String,
            second.title
        )
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
    }

    private func item(id: String, duration: TimeInterval, resumePosition: TimeInterval) -> PlaybackItem {
        PlaybackItem(
            id: id,
            title: id,
            channelTitle: "Test channel",
            duration: duration,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).m4a"),
            artworkURL: nil,
            resumePosition: resumePosition
        )
    }
}

private final class ArtworkBox: @unchecked Sendable {
    let artwork: MPMediaItemArtwork
    init(_ artwork: MPMediaItemArtwork) { self.artwork = artwork }
}
