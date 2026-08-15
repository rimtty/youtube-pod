import XCTest
@testable import YouTubePod

@MainActor
final class DownloadManagerTests: XCTestCase {
    func testQueueImportsItemsSeriallyAndCompletes() async throws {
        let extractor = ImmediateExtractor()
        let library = LibraryStub()
        let manager = DownloadManager(extractor: extractor, library: library)
        let first = video(id: "aaaaaaaaaaa")
        let second = video(id: "bbbbbbbbbbb")

        manager.enqueue(first)
        manager.enqueue(second)
        try await waitUntil {
            manager.phases[first.id] == .completed && manager.phases[second.id] == .completed
        }

        XCTAssertEqual(library.importedVideoIDs, [first.id, second.id])
        let maximumConcurrentExtractions = await extractor.maximumConcurrentExtractions
        XCTAssertEqual(maximumConcurrentExtractions, 1)
    }

    func testCancellingQueuedItemLeavesActiveItemIndependent() async throws {
        let extractor = BlockingExtractor()
        let library = LibraryStub()
        let manager = DownloadManager(extractor: extractor, library: library)
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

    func testFailedDownloadCanBeManuallyRetriedAndCompleted() async throws {
        let extractor = FailOnceExtractor()
        let library = LibraryStub()
        let manager = DownloadManager(extractor: extractor, library: library)
        let item = video(id: "eeeeeeeeeee")

        manager.enqueue(item)
        try await waitUntil {
            if case .failed = manager.phases[item.id] { return true }
            return false
        }

        manager.enqueue(item)
        try await waitUntil { manager.phases[item.id] == .completed }

        let attempts = await extractor.attempts
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(library.importedVideoIDs, [item.id])
    }

    func testCancellingDuringValidationDeletesImportedResult() async throws {
        let extractor = ImmediateExtractor()
        let library = BlockingLibraryStub()
        let manager = DownloadManager(extractor: extractor, library: library)
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

@MainActor
private final class LibraryStub: AudioLibraryManaging {
    private(set) var importedVideoIDs: [String] = []

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

    func delete(_ audio: SavedAudio) throws {}
    func updateStatistics(_ counts: [String: Int64]) throws {}
    func updatePlaybackPosition(videoID: String, position: TimeInterval) {}
    func markPlayed(videoID: String) {}
    func audioURL(for audio: SavedAudio) -> URL { URL(fileURLWithPath: "/tmp/\(audio.youtubeID).m4a") }
    func thumbnailURL(for audio: SavedAudio) -> URL? { nil }
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
}
