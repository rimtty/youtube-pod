import AVFAudio
import SwiftData
import XCTest
@testable import YouTubePod

@MainActor
final class LibraryAudioOptimizerTests: XCTestCase {
    func testOptimizeReplacesFragmentedLibraryFileAndRecordsDigest() async throws {
        let fixture = try makeFixture()
        let saved = try await fixture.importFragmentedFixture(id: "optimize0001")
        let audioURL = fixture.library.audioURL(for: saved)
        XCTAssertFalse(AVFoundationLibraryAudioNormalizer.isFlatContainer(at: audioURL))
        XCTAssertFalse(saved.isNormalized(currentVersion: LibraryAudioOptimizer.currentNormalizationVersion))

        let optimized = try await fixture.optimizer.optimize(videoID: saved.youtubeID)

        XCTAssertEqual(optimized.audioURL, audioURL)
        XCTAssertTrue(AVFoundationLibraryAudioNormalizer.isFlatContainer(at: audioURL))
        XCTAssertEqual(optimized.contentSHA256, try WatchFileDigest.sha256(at: audioURL))
        XCTAssertEqual(saved.audioContentSHA256, optimized.contentSHA256)
        XCTAssertEqual(saved.audioNormalizationVersion, LibraryAudioOptimizer.currentNormalizationVersion)
        XCTAssertEqual(saved.fileSize, optimized.fileSize)
        XCTAssertEqual(saved.fileSize, try fileSize(at: audioURL))
        XCTAssertTrue(try fixture.hiddenFilesInAudioDirectory().isEmpty)
        XCTAssertNil(fixture.optimizer.progress[saved.youtubeID])
        XCTAssertNil(fixture.optimizer.activeVideoID)
        XCTAssertEqual(fixture.normalizer.invocations, 1)
        XCTAssertEqual(fixture.backgroundGrants.count, 1)
        XCTAssertTrue(fixture.backgroundGrants[0].ended)
    }

    func testAlreadyNormalizedItemReturnsWithoutTouchingTheFile() async throws {
        let fixture = try makeFixture()
        let saved = try await fixture.importFragmentedFixture(id: "optimize0002")
        let first = try await fixture.optimizer.optimize(videoID: saved.youtubeID)
        let modification = try modificationDate(at: first.audioURL)

        let second = try await fixture.optimizer.optimize(videoID: saved.youtubeID)

        XCTAssertEqual(second, first)
        XCTAssertEqual(fixture.normalizer.invocations, 1)
        XCTAssertEqual(try modificationDate(at: first.audioURL), modification)
        XCTAssertTrue(fixture.backgroundGrants.count == 1)
    }

    func testFlatSourceSkipsRemuxAndOnlyRecordsDigest() async throws {
        let fixture = try makeFixture()
        let saved = try await fixture.importFlatAudio(id: "optimize0003")
        let audioURL = fixture.library.audioURL(for: saved)
        let originalBytes = try Data(contentsOf: audioURL)

        let optimized = try await fixture.optimizer.optimize(videoID: saved.youtubeID)

        XCTAssertEqual(fixture.normalizer.invocations, 0)
        XCTAssertEqual(try Data(contentsOf: audioURL), originalBytes)
        XCTAssertEqual(optimized.contentSHA256, try WatchFileDigest.sha256(at: audioURL))
        XCTAssertTrue(saved.isNormalized(currentVersion: LibraryAudioOptimizer.currentNormalizationVersion))
    }

    func testConcurrentRequestsForTheSameItemShareOneJob() async throws {
        let fixture = try makeFixture(blockNormalizer: true)
        let saved = try await fixture.importFragmentedFixture(id: "optimize0004")
        let videoID = saved.youtubeID

        async let first = fixture.optimizer.optimize(videoID: videoID)
        async let second = fixture.optimizer.optimize(videoID: videoID)
        try await waitUntil { fixture.normalizer.invocations == 1 }
        XCTAssertEqual(fixture.optimizer.activeVideoID, videoID)
        fixture.normalizer.release()

        let results = try await [first, second]
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(fixture.normalizer.invocations, 1)
    }

    func testBackgroundExpirationCancelsJobAndLeavesRawFileIntact() async throws {
        let fixture = try makeFixture(blockNormalizer: true)
        let saved = try await fixture.importFragmentedFixture(id: "optimize0005")
        let audioURL = fixture.library.audioURL(for: saved)
        let originalBytes = try Data(contentsOf: audioURL)

        let videoID = saved.youtubeID
        let job = Task { try await fixture.optimizer.optimize(videoID: videoID) }
        try await waitUntil { fixture.normalizer.invocations == 1 }
        let grant = try XCTUnwrap(fixture.backgroundGrants.first)
        grant.expire()

        do {
            _ = try await job.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: audioURL), originalBytes)
        XCTAssertNil(saved.audioContentSHA256)
        XCTAssertEqual(saved.audioNormalizationVersion, 0)
        XCTAssertTrue(try fixture.hiddenFilesInAudioDirectory().isEmpty)
        XCTAssertNil(fixture.optimizer.progress[saved.youtubeID])
        XCTAssertTrue(grant.ended)
    }

    func testInvalidAudioFailsWithoutStagedFileAndIsSkippedByBackfill() async throws {
        let fixture = try makeFixture(useProductionNormalizer: true)
        let saved = try await fixture.importFlatAudio(id: "optimize0006")
        let audioURL = fixture.library.audioURL(for: saved)
        try Data("corrupt".utf8).write(to: audioURL)
        let backfillCandidate = try await fixture.importFragmentedFixture(id: "optimize0007")

        do {
            _ = try await fixture.optimizer.optimize(videoID: saved.youtubeID)
            XCTFail("Expected failure")
        } catch is LibraryAudioNormalizationError {
            // Expected.
        }
        XCTAssertTrue(try fixture.hiddenFilesInAudioDirectory().isEmpty)
        XCTAssertNil(saved.audioContentSHA256)

        fixture.optimizer.resumeBackfill()
        try await waitUntil(timeout: .seconds(10)) {
            backfillCandidate.isNormalized(currentVersion: LibraryAudioOptimizer.currentNormalizationVersion)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(saved.audioContentSHA256)
    }

    func testBackfillProcessesNewestFirstAndSkipsThePlayingItem() async throws {
        let fixture = try makeFixture()
        let oldest = try await fixture.importFragmentedFixture(id: "backfill001")
        oldest.downloadedAt = Date(timeIntervalSince1970: 1_000)
        let playing = try await fixture.importFragmentedFixture(id: "backfill002")
        playing.downloadedAt = Date(timeIntervalSince1970: 2_000)
        let newest = try await fixture.importFragmentedFixture(id: "backfill003")
        newest.downloadedAt = Date(timeIntervalSince1970: 3_000)
        try fixture.container.mainContext.save()
        fixture.playingVideoID = playing.youtubeID

        fixture.optimizer.resumeBackfill()
        try await waitUntil(timeout: .seconds(10)) {
            oldest.isNormalized(currentVersion: LibraryAudioOptimizer.currentNormalizationVersion)
        }

        XCTAssertEqual(fixture.normalizer.order, [newest.youtubeID, oldest.youtubeID])
        XCTAssertFalse(playing.isNormalized(currentVersion: LibraryAudioOptimizer.currentNormalizationVersion))

        fixture.playingVideoID = nil
        fixture.optimizer.resumeBackfill()
        try await waitUntil(timeout: .seconds(10)) {
            playing.isNormalized(currentVersion: LibraryAudioOptimizer.currentNormalizationVersion)
        }
        XCTAssertEqual(fixture.normalizer.order.last, playing.youtubeID)
    }

    func testBackfillWaitsWhileADownloadIsExtracting() async throws {
        let fixture = try makeFixture()
        let saved = try await fixture.importFragmentedFixture(id: "backfill004")
        fixture.isExtracting = true

        fixture.optimizer.resumeBackfill()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fixture.normalizer.invocations, 0)

        fixture.isExtracting = false
        fixture.optimizer.resumeBackfill()
        try await waitUntil(timeout: .seconds(10)) {
            saved.isNormalized(currentVersion: LibraryAudioOptimizer.currentNormalizationVersion)
        }
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let container: ModelContainer
        let library: AudioLibraryService
        let normalizer: RecordingNormalizer
        private(set) var optimizer: LibraryAudioOptimizer!
        var backgroundGrants: [BackgroundGrant] = []
        var playingVideoID: String?
        var isExtracting = false

        init(
            container: ModelContainer,
            library: AudioLibraryService,
            normalizer: RecordingNormalizer,
            makeOptimizer: (Fixture) -> LibraryAudioOptimizer
        ) {
            self.container = container
            self.library = library
            self.normalizer = normalizer
            self.optimizer = makeOptimizer(self)
        }

        func importFragmentedFixture(id: String) async throws -> SavedAudio {
            let fixtureURL = try XCTUnwrap(
                Bundle(for: LibraryAudioOptimizerTests.self).url(forResource: "fragmented-aac", withExtension: "m4a")
            )
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("YouTubePod-OptimizerImport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sourceURL = directory.appendingPathComponent("source.m4a")
            try FileManager.default.copyItem(at: fixtureURL, to: sourceURL)
            return try await importSource(sourceURL, id: id)
        }

        func importFlatAudio(id: String) async throws -> SavedAudio {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("YouTubePod-OptimizerImport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("source.m4a")
            // Scope the writer so the container is finalized before import.
            do {
                let file = try AVAudioFile(
                    forWriting: url,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 44_100,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 64_000,
                    ]
                )
                let buffer = try XCTUnwrap(
                    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_410)
                )
                buffer.frameLength = 4_410
                try file.write(from: buffer)
            }
            return try await importSource(url, id: id)
        }

        private func importSource(_ sourceURL: URL, id: String) async throws -> SavedAudio {
            let metadata = VideoSummary(
                id: id,
                title: "Audio \(id)",
                channelTitle: "Channel",
                thumbnailURL: nil,
                publishedAt: Date(timeIntervalSince1970: 1_000),
                viewCount: 1,
                duration: 1.5
            )
            let extracted = ExtractedAudio(
                fileURL: sourceURL,
                videoID: id,
                title: metadata.title,
                channel: metadata.channelTitle,
                duration: metadata.duration,
                thumbnailURL: nil
            )
            return try await library.importAudio(extracted, metadata: metadata)
        }

        func hiddenFilesInAudioDirectory() throws -> [URL] {
            guard let saved = try container.mainContext.fetch(FetchDescriptor<SavedAudio>()).first else {
                return []
            }
            let directory = library.audioURL(for: saved).deletingLastPathComponent()
            return try FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".") }
        }
    }

    @MainActor
    final class BackgroundGrant {
        let name: String
        private(set) var ended = false
        private let expiration: @MainActor () -> Void

        init(name: String, expiration: @escaping @MainActor () -> Void) {
            self.name = name
            self.expiration = expiration
        }

        func expire() { expiration() }
        func end() { ended = true }
    }

    /// Wraps the production normalizer to count and optionally block calls.
    final class RecordingNormalizer: LibraryAudioNormalizing, @unchecked Sendable {
        private let lock = NSLock()
        private let wrapped = AVFoundationLibraryAudioNormalizer()
        private let blocks: Bool
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var _order: [String] = []

        init(blocks: Bool) {
            self.blocks = blocks
        }

        var invocations: Int { order.count }
        var order: [String] {
            lock.withLock { _order }
        }

        func normalize(
            sourceURL: URL,
            destinationURL: URL,
            progress: @escaping @Sendable (LibraryAudioOptimizationProgress) -> Void
        ) async throws {
            recordInvocation(sourceURL.deletingPathExtension().lastPathComponent)
            if blocks {
                // Resume on cancellation so an expired background grant can
                // unwind the job instead of hanging the test.
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        store(continuation)
                    }
                } onCancel: {
                    release()
                }
                try Task.checkCancellation()
            }
            try await wrapped.normalize(sourceURL: sourceURL, destinationURL: destinationURL, progress: progress)
        }

        func release() {
            let pending = lock.withLock {
                let value = continuations
                continuations = []
                return value
            }
            for continuation in pending {
                continuation.resume()
            }
        }

        private func recordInvocation(_ id: String) {
            lock.withLock { _order.append(id) }
        }

        private func store(_ continuation: CheckedContinuation<Void, Never>) {
            let resumeNow = lock.withLock {
                if Task.isCancelled { return true }
                continuations.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    private func makeFixture(
        blockNormalizer: Bool = false,
        useProductionNormalizer: Bool = false
    ) throws -> Fixture {
        let container = try ModelContainer(
            for: SavedAudio.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let library = AudioLibraryService(modelContext: container.mainContext)
        let normalizer = RecordingNormalizer(blocks: blockNormalizer)
        return Fixture(container: container, library: library, normalizer: normalizer) { fixture in
            LibraryAudioOptimizer(
                library: library,
                normalizer: useProductionNormalizer ? AVFoundationLibraryAudioNormalizer() : normalizer,
                // Weak: a backfill loop can outlive the test's fixture.
                shouldDeferBackfill: { [weak fixture] in fixture?.isExtracting ?? true },
                isCurrentlyPlaying: { [weak fixture] videoID in fixture?.playingVideoID == videoID },
                beginBackgroundExecution: { [weak fixture] name, expiration in
                    let grant = BackgroundGrant(name: name, expiration: expiration)
                    fixture?.backgroundGrants.append(grant)
                    return { grant.end() }
                },
                backfillItemInterval: .milliseconds(10)
            )
        }
    }

    private func fileSize(at url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private func modificationDate(at url: URL) throws -> Date {
        try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for optimizer state")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
