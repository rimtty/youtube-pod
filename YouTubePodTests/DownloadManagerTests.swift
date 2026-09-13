import XCTest
@testable import YouTubePod

@MainActor
final class DownloadManagerTests: XCTestCase {
    func testDefaultQueueRunsOneImportAtATimeAndCompletes() async throws {
        let extractor = ImmediateExtractor()
        let library = LibraryStub()
        let manager = DownloadManager(extractor: extractor, library: library)
        let first = video(id: "aaaaaaaaaaa")
        let second = video(id: "bbbbbbbbbbb")
        let third = video(id: "cccccccccc1")
        let fourth = video(id: "dddddddddd1")

        manager.enqueue(first)
        manager.enqueue(second)
        manager.enqueue(third)
        manager.enqueue(fourth)
        try await waitUntil {
            [first, second, third, fourth].allSatisfy { manager.phases[$0.id] == .completed }
        }

        XCTAssertEqual(Set(library.importedVideoIDs), Set([first.id, second.id, third.id, fourth.id]))
        let maximumConcurrentExtractions = await extractor.maximumConcurrentExtractions
        XCTAssertEqual(maximumConcurrentExtractions, 1)
    }

    func testDownloadOptimizesSavedAudioBeforeCompletingAndIgnoresCancellation() async throws {
        let extractor = ImmediateExtractor()
        let library = LibraryStub()
        let optimizer = BlockingOptimizerStub()
        let manager = DownloadManager(extractor: extractor, library: library, optimizer: optimizer)
        let first = video(id: "optimize001")
        let second = video(id: "optimize002")

        manager.enqueue(first)
        manager.enqueue(second)
        try await waitUntil { optimizer.activeVideoID == first.id }
        XCTAssertEqual(manager.phases[first.id], .optimizing(0))
        // The serial slot is held while optimizing so the next yt-dlp run
        // does not compete with the remux for disk bandwidth.
        XCTAssertEqual(manager.phases[second.id], .queued)
        XCTAssertTrue(manager.isExtracting, "a queued download still counts as pending extraction")

        optimizer.report(videoID: first.id, progress: .remuxing(0.5))
        try await waitUntil { manager.phases[first.id] == .optimizing(0.45) }

        // The audio is already saved; neither a per-item cancel nor the
        // background-transition cancelAll may discard it.
        await manager.cancel(videoID: first.id)
        await manager.cancelAll()
        XCTAssertEqual(manager.phases[first.id], .optimizing(0.45))
        XCTAssertTrue(library.deletedVideoIDs.isEmpty)
        XCTAssertFalse(manager.isExtracting, "optimizing an already saved item is not an extraction")

        optimizer.complete(videoID: first.id)
        try await waitUntil { manager.phases[first.id] == .completed }
        XCTAssertEqual(manager.phases[second.id], .failed("バックグラウンド移行のためキャンセルしました"))
        XCTAssertEqual(optimizer.optimizedVideoIDs, [first.id])
    }

    func testOptimizerFailureStillCompletesTheDownload() async throws {
        let extractor = ImmediateExtractor()
        let library = LibraryStub()
        let optimizer = FailingOptimizerStub()
        let manager = DownloadManager(extractor: extractor, library: library, optimizer: optimizer)
        let item = video(id: "optimize003")

        manager.enqueue(item)
        try await waitUntil { manager.phases[item.id] == .completed }

        XCTAssertEqual(library.importedVideoIDs, [item.id])
        XCTAssertTrue(library.deletedVideoIDs.isEmpty)
        XCTAssertEqual(optimizer.attempts, 1)
    }

    func testCancellingQueuedItemLeavesActiveItemIndependent() async throws {
        let extractor = BlockingExtractor()
        let library = LibraryStub()
        let manager = DownloadManager(
            extractor: extractor,
            library: library,
            maximumConcurrentDownloads: 1
        )
        let active = video(id: "ccccccccccc")
        let queued = video(id: "ddddddddddd")

        manager.enqueue(active)
        manager.enqueue(queued)
        try await waitUntil { manager.phases[active.id] == .downloading(0) }

        await manager.cancel(videoID: queued.id)
        XCTAssertEqual(manager.phases[queued.id], .failed("キャンセルしました"))
        let cancelCountAfterQueuedItem = await extractor.cancelCount
        XCTAssertEqual(cancelCountAfterQueuedItem, 0)

        await manager.cancel(videoID: active.id)
        try await waitUntil {
            if case .failed = manager.phases[active.id] { return true }
            return false
        }
        let finalCancelCount = await extractor.cancelCount
        XCTAssertEqual(finalCancelCount, 1)
        XCTAssertTrue(library.importedVideoIDs.isEmpty)
    }

    func testTransientFailureIsAutomaticallyRetriedAndCompleted() async throws {
        let extractor = FailOnceExtractor()
        let library = LibraryStub()
        let manager = DownloadManager(
            extractor: extractor,
            library: library,
            extractionRetryDelays: [.zero, .zero, .zero]
        )
        let item = video(id: "eeeeeeeeeee")

        manager.enqueue(item)
        try await waitUntil { manager.phases[item.id] == .completed }

        let attempts = await extractor.attempts
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(library.importedVideoIDs, [item.id])
    }

    func testTransientFailureStopsAfterThreeAdditionalRetries() async throws {
        let extractor = AlwaysFailingExtractor(message: "HTTP Error 403: Forbidden")
        let manager = DownloadManager(
            extractor: extractor,
            library: LibraryStub(),
            extractionRetryDelays: [.zero, .zero, .zero]
        )
        let item = video(id: "eeeeeeeeee1")

        manager.enqueue(item)
        try await waitUntil {
            if case .failed = manager.phases[item.id] { return true }
            return false
        }

        let attempts = await extractor.attempts
        XCTAssertEqual(attempts, 4)
    }

    func testPermanentExtractionFailureIsNotAutomaticallyRetried() async throws {
        let extractor = AlwaysFailingExtractor(message: "Requested format is not available")
        let manager = DownloadManager(
            extractor: extractor,
            library: LibraryStub(),
            extractionRetryDelays: [.zero, .zero, .zero]
        )
        let item = video(id: "eeeeeeeeee2")

        manager.enqueue(item)
        try await waitUntil {
            if case .failed = manager.phases[item.id] { return true }
            return false
        }

        let attempts = await extractor.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testCancellationDuringRetryDelayPreventsAnotherAttempt() async throws {
        let extractor = AlwaysFailingExtractor(message: "一時的な通信エラー")
        let manager = DownloadManager(
            extractor: extractor,
            library: LibraryStub(),
            extractionRetryDelays: [.seconds(5)]
        )
        let item = video(id: "eeeeeeeeee3")

        manager.enqueue(item)
        try await waitUntil {
            if case .retrying = manager.phases[item.id] { return true }
            return false
        }
        await manager.cancel(videoID: item.id)
        try await waitUntil { manager.phases[item.id] == .failed("キャンセルしました") }

        let attempts = await extractor.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testCancellingDuringValidationDeletesImportedResult() async throws {
        let extractor = ImmediateExtractor()
        let library = BlockingLibraryStub()
        let manager = DownloadManager(
            extractor: extractor,
            library: library,
            maximumConcurrentDownloads: 1
        )
        let item = video(id: "ffffffffff1")

        manager.enqueue(item)
        try await waitUntil { manager.phases[item.id] == .validating }

        await manager.cancel(videoID: item.id)
        library.completeImport()

        try await waitUntil {
            if case .failed("キャンセルしました") = manager.phases[item.id] { return true }
            return false
        }
        XCTAssertEqual(library.deletedVideoIDs, [item.id])
    }

    func testCancellingCompletedItemDoesNotRegressItsPhase() async throws {
        let extractor = ImmediateExtractor()
        let library = LibraryStub()
        let manager = DownloadManager(extractor: extractor, library: library)
        let item = video(id: "ffffffffff2")

        manager.enqueue(item)
        try await waitUntil { manager.phases[item.id] == .completed }

        await manager.cancel(videoID: item.id)

        XCTAssertEqual(manager.phases[item.id], .completed)
    }

    func testDiscardingCompletedPhaseRemovesDownloadState() async throws {
        let manager = DownloadManager(extractor: ImmediateExtractor(), library: LibraryStub())
        let item = video(id: "discard0001")
        manager.enqueue(item)
        try await waitUntil { manager.phases[item.id] == .completed }

        manager.discardTerminalPhase(videoID: item.id)

        XCTAssertNil(manager.phases[item.id])
    }

    func testDiscardingTerminalPhaseDoesNotClearActiveDownload() async throws {
        let extractor = BlockingExtractor()
        let manager = DownloadManager(extractor: extractor, library: LibraryStub())
        let item = video(id: "discard0002")
        manager.enqueue(item)
        try await waitUntil { manager.phases[item.id] == .downloading(0) }

        manager.discardTerminalPhase(videoID: item.id)

        XCTAssertEqual(manager.phases[item.id], .downloading(0))
        await manager.cancel(videoID: item.id)
    }

    func testCancelAllCancelsActiveExtractionAndQueuedItems() async throws {
        let extractor = BlockingExtractor()
        let library = LibraryStub()
        let manager = DownloadManager(
            extractor: extractor,
            library: library,
            maximumConcurrentDownloads: 1
        )
        let active = video(id: "cancelall01")
        let queued = video(id: "cancelall02")
        manager.enqueue(active)
        manager.enqueue(queued)
        try await waitUntil { manager.phases[active.id] == .downloading(0) }

        await manager.cancelAll()
        try await waitUntil { manager.phases[active.id] == .failed("キャンセルしました") }

        XCTAssertEqual(
            manager.phases[queued.id],
            .failed("バックグラウンド移行のためキャンセルしました")
        )
        let cancelCount = await extractor.cancelCount
        XCTAssertEqual(cancelCount, 1)
        XCTAssertTrue(library.importedVideoIDs.isEmpty)
    }

    func testCancelAllDuringRetryDelayPreventsAnotherAttempt() async throws {
        let extractor = AlwaysFailingExtractor(message: "一時的な通信エラー")
        let manager = DownloadManager(
            extractor: extractor,
            library: LibraryStub(),
            extractionRetryDelays: [.seconds(5)]
        )
        let item = video(id: "cancelall03")
        manager.enqueue(item)
        try await waitUntil {
            if case .retrying = manager.phases[item.id] { return true }
            return false
        }

        await manager.cancelAll()
        try await waitUntil { manager.phases[item.id] == .failed("キャンセルしました") }

        let attempts = await extractor.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testCancelAllDuringValidationDeletesImportedResult() async throws {
        let library = BlockingLibraryStub()
        let manager = DownloadManager(
            extractor: ImmediateExtractor(),
            library: library,
            maximumConcurrentDownloads: 1
        )
        let item = video(id: "cancelall04")
        manager.enqueue(item)
        try await waitUntil { manager.phases[item.id] == .validating }

        await manager.cancelAll()
        library.completeImport()
        try await waitUntil { manager.phases[item.id] == .failed("キャンセルしました") }

        XCTAssertEqual(library.deletedVideoIDs, [item.id])
    }

    func testImportFailureDoesNotPreventNextQueuedItemFromCompleting() async throws {
        let library = FailFirstImportLibraryStub()
        let manager = DownloadManager(
            extractor: ImmediateExtractor(),
            library: library,
            maximumConcurrentDownloads: 1
        )
        let first = video(id: "importfail1")
        let second = video(id: "importnext1")
        manager.enqueue(first)
        manager.enqueue(second)

        try await waitUntil {
            if case .failed = manager.phases[first.id] {
                return manager.phases[second.id] == .completed
            }
            return false
        }

        XCTAssertEqual(library.importedVideoIDs, [first.id, second.id])
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for download state")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func video(id: String) -> VideoSummary {
        VideoSummary(
            id: id,
            title: id,
            channelTitle: "Test channel",
            thumbnailURL: nil,
            publishedAt: .now,
            viewCount: 1,
            duration: 10
        )
    }
}

private actor ImmediateExtractor: AudioExtracting {
    private var concurrentExtractions = 0
    private(set) var maximumConcurrentExtractions = 0

    func extract(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExtractedAudio {
        concurrentExtractions += 1
        maximumConcurrentExtractions = max(maximumConcurrentExtractions, concurrentExtractions)
        defer { concurrentExtractions -= 1 }
        let videoID = YouTubeURLParser.videoID(from: url.absoluteString) ?? ""
        progress(0.5)
        await Task.yield()
        return ExtractedAudio(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(videoID).m4a"),
            videoID: videoID,
            title: videoID,
            channel: "Test channel",
            duration: 10,
            thumbnailURL: nil
        )
    }

    func cancel() async {}
}

private actor BlockingExtractor: AudioExtracting {
    private var continuation: CheckedContinuation<ExtractedAudio, any Error>?
    private(set) var cancelCount = 0

    func extract(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExtractedAudio {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() async {
        cancelCount += 1
        continuation?.resume(throwing: ExtractionError.cancelled)
        continuation = nil
    }
}

private actor FailOnceExtractor: AudioExtracting {
    private(set) var attempts = 0

    func extract(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExtractedAudio {
        attempts += 1
        if attempts == 1 {
            throw ExtractionError.failed("一時的な通信エラー")
        }
        let videoID = YouTubeURLParser.videoID(from: url.absoluteString) ?? ""
        progress(1)
        return ExtractedAudio(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(videoID).m4a"),
            videoID: videoID,
            title: videoID,
            channel: "Test channel",
            duration: 10,
            thumbnailURL: nil
        )
    }

    func cancel() async {}
}

private actor AlwaysFailingExtractor: AudioExtracting {
    private let message: String
    private(set) var attempts = 0

    init(message: String) {
        self.message = message
    }

    func extract(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExtractedAudio {
        attempts += 1
        throw ExtractionError.failed(message)
    }

    func cancel() async {}
}

@MainActor
private final class LibraryStub: AudioLibraryManaging {
    private(set) var importedVideoIDs: [String] = []
    private(set) var deletedVideoIDs: [String] = []

    func importAudio(_ extracted: ExtractedAudio, metadata: VideoSummary) async throws -> SavedAudio {
        importedVideoIDs.append(metadata.id)
        return SavedAudio(
            youtubeID: metadata.id,
            title: metadata.title,
            channelTitle: metadata.channelTitle,
            publishedAt: metadata.publishedAt,
            savedViewCount: metadata.viewCount,
            duration: metadata.duration,
            fileSize: 1,
            audioRelativePath: "Audio/\(metadata.id).m4a"
        )
    }

    func delete(_ audio: SavedAudio) throws { deletedVideoIDs.append(audio.youtubeID) }
    func updateStatistics(_ counts: [String: Int64]) throws {}
    func updatePlaybackPosition(videoID: String, position: TimeInterval) {}
    func markPlayed(videoID: String) {}
    func audioURL(for audio: SavedAudio) -> URL { URL(fileURLWithPath: "/tmp/\(audio.youtubeID).m4a") }
    func thumbnailURL(for audio: SavedAudio) -> URL? { nil }
    func savedAudio(videoID: String) -> SavedAudio? { nil }
    func audiosRequiringNormalization(currentVersion: Int) -> [SavedAudio] { [] }
    func recordNormalizedAudio(
        videoID: String,
        contentSHA256: String,
        fileSize: Int64,
        normalizationVersion: Int
    ) throws {}
}

@MainActor
private final class BlockingLibraryStub: AudioLibraryManaging {
    private var continuation: CheckedContinuation<SavedAudio, Never>?
    private var pendingMetadata: VideoSummary?
    private(set) var deletedVideoIDs: [String] = []

    func importAudio(_ extracted: ExtractedAudio, metadata: VideoSummary) async throws -> SavedAudio {
        pendingMetadata = metadata
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func completeImport() {
        guard let metadata = pendingMetadata else { return }
        continuation?.resume(returning: SavedAudio(
            youtubeID: metadata.id,
            title: metadata.title,
            channelTitle: metadata.channelTitle,
            publishedAt: metadata.publishedAt,
            savedViewCount: metadata.viewCount,
            duration: metadata.duration,
            fileSize: 1,
            audioRelativePath: "Audio/\(metadata.id).m4a"
        ))
        continuation = nil
        pendingMetadata = nil
    }

    func delete(_ audio: SavedAudio) throws { deletedVideoIDs.append(audio.youtubeID) }
    func updateStatistics(_ counts: [String: Int64]) throws {}
    func updatePlaybackPosition(videoID: String, position: TimeInterval) {}
    func markPlayed(videoID: String) {}
    func audioURL(for audio: SavedAudio) -> URL { URL(fileURLWithPath: "/tmp/\(audio.youtubeID).m4a") }
    func thumbnailURL(for audio: SavedAudio) -> URL? { nil }
    func savedAudio(videoID: String) -> SavedAudio? { nil }
    func audiosRequiringNormalization(currentVersion: Int) -> [SavedAudio] { [] }
    func recordNormalizedAudio(
        videoID: String,
        contentSHA256: String,
        fileSize: Int64,
        normalizationVersion: Int
    ) throws {}
}

@MainActor
private final class FailFirstImportLibraryStub: AudioLibraryManaging {
    private(set) var importedVideoIDs: [String] = []

    func importAudio(_ extracted: ExtractedAudio, metadata: VideoSummary) async throws -> SavedAudio {
        importedVideoIDs.append(metadata.id)
        if importedVideoIDs.count == 1 {
            throw TestImportError.failed
        }
        return SavedAudio(
            youtubeID: metadata.id,
            title: metadata.title,
            channelTitle: metadata.channelTitle,
            publishedAt: metadata.publishedAt,
            savedViewCount: metadata.viewCount,
            duration: metadata.duration,
            fileSize: 1,
            audioRelativePath: "Audio/\(metadata.id).m4a"
        )
    }

    func delete(_ audio: SavedAudio) throws {}
    func updateStatistics(_ counts: [String: Int64]) throws {}
    func updatePlaybackPosition(videoID: String, position: TimeInterval) {}
    func markPlayed(videoID: String) {}
    func audioURL(for audio: SavedAudio) -> URL { URL(fileURLWithPath: "/tmp/\(audio.youtubeID).m4a") }
    func thumbnailURL(for audio: SavedAudio) -> URL? { nil }
    func savedAudio(videoID: String) -> SavedAudio? { nil }
    func audiosRequiringNormalization(currentVersion: Int) -> [SavedAudio] { [] }
    func recordNormalizedAudio(
        videoID: String,
        contentSHA256: String,
        fileSize: Int64,
        normalizationVersion: Int
    ) throws {}
}

private enum TestImportError: LocalizedError {
    case failed
    var errorDescription: String? { "Import failed" }
}

@MainActor
private final class BlockingOptimizerStub: LibraryAudioOptimizing {
    private(set) var progress: [String: LibraryAudioOptimizationProgress] = [:]
    private(set) var activeVideoID: String?
    private(set) var optimizedVideoIDs: [String] = []
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]

    func optimize(videoID: String) async throws -> OptimizedLibraryAudio {
        activeVideoID = videoID
        await withCheckedContinuation { continuation in
            continuations[videoID] = continuation
        }
        progress[videoID] = nil
        activeVideoID = nil
        optimizedVideoIDs.append(videoID)
        return OptimizedLibraryAudio(
            audioURL: URL(fileURLWithPath: "/tmp/\(videoID).m4a"),
            contentSHA256: String(repeating: "0", count: 64),
            fileSize: 1
        )
    }

    func report(videoID: String, progress value: LibraryAudioOptimizationProgress) {
        progress[videoID] = value
    }

    func complete(videoID: String) {
        continuations.removeValue(forKey: videoID)?.resume()
    }

    func resumeBackfill() {}
    func pauseBackfill() {}
}

@MainActor
private final class FailingOptimizerStub: LibraryAudioOptimizing {
    private(set) var progress: [String: LibraryAudioOptimizationProgress] = [:]
    private(set) var activeVideoID: String?
    private(set) var attempts = 0

    struct Failure: Error {}

    func optimize(videoID: String) async throws -> OptimizedLibraryAudio {
        attempts += 1
        throw Failure()
    }

    func resumeBackfill() {}
    func pauseBackfill() {}
}
