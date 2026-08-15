import AVFoundation
import MediaPlayer
import XCTest
@testable import YouTubePodWatch

@MainActor
final class WatchAudioPlayerServiceTests: XCTestCase {
    func testPlayActivatesSessionAndMarksItemPlayed() {
        let session = TestWatchAudioSession()
        var persisted: [(String, TimeInterval, Bool)] = []
        let player = makePlayer(
            session: session,
            persist: { persisted.append(($0, $1, $2)) }
        )
        let item = playbackItem(id: "watchplay01", duration: 100, resume: 12)

        player.play(item, queue: [item])

        XCTAssertEqual(session.activationCount, 1)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentItem, item)
        XCTAssertEqual(player.currentTime, 12)
        XCTAssertEqual(player.duration, 100)
        XCTAssertEqual(persisted.last?.0, item.id)
        XCTAssertEqual(persisted.last?.1, 12)
        XCTAssertEqual(persisted.last?.2, true)
    }

    func testRouteActivationFailureIsVisibleAndDoesNotPlay() {
        let session = TestWatchAudioSession(result: .audioRouteUnavailable)
        let player = makePlayer(session: session)
        let item = playbackItem(id: "watchplay02", duration: 50)

        player.play(item, queue: [item])

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playbackError, .audioRouteUnavailable)
        XCTAssertEqual(player.currentItem, item)
    }

    func testTogglePauseAndResumeForcePersistence() {
        let session = TestWatchAudioSession()
        var persisted: [(String, TimeInterval, Bool)] = []
        let player = makePlayer(
            session: session,
            persist: { persisted.append(($0, $1, $2)) }
        )
        let item = playbackItem(id: "watchplay03", duration: 80, resume: 20)
        player.play(item, queue: [item])
        persisted.removeAll()

        player.togglePlayback()

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(persisted.map(\.1), [20])

        player.togglePlayback()

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(session.activationCount, 2)
        XCTAssertEqual(persisted.last?.2, true)
    }

    func testSeekClampsAndRapidSkipsAccumulateFromVisiblePosition() {
        let player = makePlayer()
        let item = playbackItem(id: "watchplay04", duration: 120, resume: 45)
        player.play(item, queue: [item])

        player.seek(to: -10)
        XCTAssertEqual(player.currentTime, 0)
        player.seek(to: 500)
        XCTAssertEqual(player.currentTime, 120)
        player.seek(to: 45)

        player.skip(by: 15)
        player.skip(by: 15)
        player.skip(by: -15)
        player.skip(by: 15)

        XCTAssertEqual(player.currentTime, 75)
    }

    func testPreviousRestartsCurrentBeforeMovingBackAndNextNavigatesQueue() {
        let player = makePlayer()
        let first = playbackItem(id: "watchplay05", duration: 100)
        let second = playbackItem(id: "watchplay06", duration: 100)
        let third = playbackItem(id: "watchplay07", duration: 100)
        player.play(second, queue: [first, second, third])

        player.seek(to: 20)
        player.previous()
        XCTAssertEqual(player.currentItem?.id, second.id)
        XCTAssertEqual(player.currentTime, 0)

        player.previous()
        XCTAssertEqual(player.currentItem?.id, first.id)

        player.next()
        XCTAssertEqual(player.currentItem?.id, second.id)
        player.next()
        XCTAssertEqual(player.currentItem?.id, third.id)
    }

    func testCompletionPersistsEndAndAdvancesThenStopsAtQueueEnd() {
        var persisted: [(String, TimeInterval, Bool)] = []
        let player = makePlayer(persist: { persisted.append(($0, $1, $2)) })
        let first = playbackItem(id: "watchplay08", duration: 60)
        let second = playbackItem(id: "watchplay09", duration: 90, resume: 7)
        player.play(first, queue: [first, second])
        persisted.removeAll()

        player.handlePlaybackCompletion()

        XCTAssertTrue(persisted.contains { $0.0 == first.id && $0.1 == 60 && $0.2 })
        XCTAssertEqual(player.currentItem?.id, second.id)
        XCTAssertEqual(player.currentTime, 7)
        XCTAssertTrue(player.isPlaying)

        player.handlePlaybackCompletion()

        XCTAssertEqual(player.currentItem?.id, second.id)
        XCTAssertEqual(player.currentTime, 90)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(persisted.last?.0, second.id)
        XCTAssertEqual(persisted.last?.1, 90)
    }

    func testPeriodicObserverPersistsOnlyAtFiveSecondThreshold() {
        var persisted: [(String, TimeInterval, Bool)] = []
        let player = makePlayer(persist: { persisted.append(($0, $1, $2)) })
        let item = playbackItem(id: "watchplay10", duration: 100)
        player.play(item, queue: [item])
        player.receivePeriodicTime(0)
        persisted.removeAll()

        player.receivePeriodicTime(4.9)
        XCTAssertTrue(persisted.isEmpty)

        player.receivePeriodicTime(5)
        XCTAssertEqual(persisted.map(\.1), [5])

        player.receivePeriodicTime(9.9)
        XCTAssertEqual(persisted.map(\.1), [5])

        player.receivePeriodicTime(10)
        XCTAssertEqual(persisted.map(\.1), [5, 10])
    }

    func testStalePeriodicSamplesCannotOverrideLatestSeekUntilDeadline() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let player = makePlayer(now: { clock })
        let item = playbackItem(id: "watchplay11", duration: 100, resume: 20)
        player.play(item, queue: [item])

        player.seek(to: 70)
        player.receivePeriodicTime(21)
        XCTAssertEqual(player.currentTime, 70)

        player.receivePeriodicTime(69.5)
        XCTAssertEqual(player.currentTime, 69.5)

        player.seek(to: 40)
        clock = clock.addingTimeInterval(3)
        player.receivePeriodicTime(25)
        XCTAssertEqual(player.currentTime, 25)
    }

    func testRemovingCurrentItemStopsAndClearsPlayerBeforeDeletion() {
        var persisted: [(String, TimeInterval, Bool)] = []
        let player = makePlayer(persist: { persisted.append(($0, $1, $2)) })
        let item = playbackItem(id: "watchplay12", duration: 100, resume: 30)
        player.play(item, queue: [item])
        persisted.removeAll()

        player.removeFromQueue(youtubeID: item.id)

        XCTAssertNil(player.currentItem)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(persisted.last?.0, item.id)
        XCTAssertEqual(persisted.last?.1, 30)
    }

    func testRemovingQueuedItemPreventsItFromPlayingNext() {
        let player = makePlayer()
        let first = playbackItem(id: "watchplay13", duration: 100)
        let removed = playbackItem(id: "watchplay14", duration: 100)
        let last = playbackItem(id: "watchplay15", duration: 100)
        player.play(first, queue: [first, removed, last])

        player.removeFromQueue(youtubeID: removed.id)
        player.next()

        XCTAssertEqual(player.currentItem?.id, last.id)
    }

    func testLateActivationCannotRestartClearedOrReplacedItem() {
        let session = TestWatchAudioSession(automaticallyCompletes: false)
        let player = makePlayer(session: session)
        let first = playbackItem(id: "watchplay16", duration: 100)
        let second = playbackItem(id: "watchplay17", duration: 100)
        player.play(first, queue: [first, second])
        player.next()

        session.completeActivation(at: 0, error: nil)
        XCTAssertEqual(player.currentItem?.id, second.id)
        XCTAssertFalse(player.isPlaying)

        session.completeActivation(at: 1, error: nil)
        XCTAssertTrue(player.isPlaying)

        player.stopAndClearCurrentItem()
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(player.isPlaying)
    }

    func testInterruptionPausesPersistsAndResumesOnlyWhenSystemAllows() {
        let session = TestWatchAudioSession()
        var persisted: [(String, TimeInterval, Bool)] = []
        let player = makePlayer(
            session: session,
            persist: { persisted.append(($0, $1, $2)) }
        )
        let item = playbackItem(id: "watchplay18", duration: 100, resume: 22)
        player.play(item, queue: [item])
        persisted.removeAll()

        player.handleAudioSessionInterruptionBegan()

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(persisted.last?.1, 22)

        player.handleAudioSessionInterruptionEnded(shouldResume: false)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(session.activationCount, 1)

        player.togglePlayback()
        player.handleAudioSessionInterruptionBegan()
        player.handleAudioSessionInterruptionEnded(shouldResume: true)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(session.activationCount, 3)
    }

    func testLostRouteAndPlaybackFailurePauseAndExposeErrors() {
        let player = makePlayer()
        let item = playbackItem(id: "watchplay19", duration: 100)
        player.play(item, queue: [item])

        player.handleAudioRouteLost()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playbackError, .audioRouteUnavailable)

        player.togglePlayback()
        XCTAssertTrue(player.isPlaying)
        player.handlePlaybackFailure()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playbackError, .playbackFailed)
    }

    func testMissingFileIsRejectedWithoutKeepingDeletedCurrentItem() {
        let player = makePlayer()
        let valid = playbackItem(id: "watchplay20", duration: 100)
        player.play(valid, queue: [valid])
        let missing = WatchPlaybackItem(
            id: "watchplay21",
            title: "Missing",
            channelTitle: "Test channel",
            duration: 50,
            fileURL: URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString).m4a")
        )

        player.play(missing, queue: [missing])

        XCTAssertNil(player.currentItem)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playbackError, .fileUnavailable)
    }

    func testPersistenceFailureKeepsThresholdPendingAndRetriesNextTick() {
        var attempts = 0
        let player = makePlayer(persist: { _, _, _ in
            attempts += 1
            if attempts == 1 { throw TestPersistenceError.failed }
        })
        let item = playbackItem(id: "watchplay22", duration: 100)

        player.play(item, queue: [item])
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(player.playbackError, .persistenceFailed)

        player.receivePeriodicTime(0)
        player.receivePeriodicTime(5)
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(player.playbackError)
    }

    func testQueueSwitchDoesNotLoseCurrentItemWhenForcedPersistenceFails() {
        let persistence = TestPersistenceController()
        let player = makePlayer(persist: persistence.persist)
        let first = playbackItem(id: "watchplay24", duration: 100, resume: 25)
        let second = playbackItem(id: "watchplay25", duration: 100)
        player.play(first, queue: [first, second])

        persistence.shouldFail = true
        player.next()
        XCTAssertEqual(player.currentItem?.id, first.id)
        XCTAssertEqual(player.playbackError, .persistenceFailed)

        persistence.shouldFail = false
        player.next()
        XCTAssertEqual(player.currentItem?.id, second.id)
        XCTAssertNil(player.playbackError)
    }

    func testNowPlayingMetadataTracksItemPauseAndSeek() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let player = makePlayer()
        let item = playbackItem(id: "watchplay23", duration: 100, resume: 10)

        player.play(item, queue: [item])
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String,
            item.title
        )
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double,
            1
        )

        player.seek(to: 30)
        player.togglePlayback()
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double,
            30
        )
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double,
            0
        )
        player.stopAndClearCurrentItem()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    private func makePlayer(
        session: TestWatchAudioSession = TestWatchAudioSession(),
        now: @escaping @MainActor () -> Date = Date.init,
        persist: @escaping @MainActor (String, TimeInterval, Bool) throws -> Void = { _, _, _ in }
    ) -> WatchAudioPlayerService {
        WatchAudioPlayerService(
            player: AVPlayer(),
            audioSession: session,
            now: now,
            persistPlaybackPosition: persist
        )
    }

    private func makePlayer(
        now: @escaping @MainActor () -> Date = Date.init,
        persist: @escaping @MainActor (String, TimeInterval, Bool) throws -> Void
    ) -> WatchAudioPlayerService {
        makePlayer(session: TestWatchAudioSession(), now: now, persist: persist)
    }

    private func playbackItem(
        id: String,
        duration: TimeInterval,
        resume: TimeInterval = 0
    ) -> WatchPlaybackItem {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id).caf")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
            let file = try! AVAudioFile(forWriting: fileURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(800)
            )!
            buffer.frameLength = AVAudioFrameCount(800)
            try! file.write(from: buffer)
        }
        return WatchPlaybackItem(
            id: id,
            title: id,
            channelTitle: "Test channel",
            duration: duration,
            fileURL: fileURL,
            resumePosition: resume
        )
    }
}

private enum TestPersistenceError: Error {
    case failed
}

@MainActor
private final class TestPersistenceController {
    var shouldFail = false

    func persist(_: String, _: TimeInterval, _: Bool) throws {
        if shouldFail { throw TestPersistenceError.failed }
    }
}

@MainActor
private final class TestWatchAudioSession: WatchAudioSessionActivating {
    private(set) var activationCount = 0
    private var completions: [@MainActor @Sendable (WatchAudioPlayerError?) -> Void] = []
    private let result: WatchAudioPlayerError?
    private let automaticallyCompletes: Bool

    init(
        result: WatchAudioPlayerError? = nil,
        automaticallyCompletes: Bool = true
    ) {
        self.result = result
        self.automaticallyCompletes = automaticallyCompletes
    }

    func activate(
        completion: @escaping @MainActor @Sendable (WatchAudioPlayerError?) -> Void
    ) {
        activationCount += 1
        completions.append(completion)
        if automaticallyCompletes {
            completion(result)
        }
    }

    func completeActivation(at index: Int, error: WatchAudioPlayerError?) {
        completions[index](error)
    }
}
