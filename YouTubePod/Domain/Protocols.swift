import Foundation

protocol YouTubeCatalogServing: Sendable {
    func popularVideos(regionCode: String, forceRefresh: Bool) async throws -> [VideoSummary]
    func searchVideos(query: String) async throws -> [VideoSummary]
    func subscriptionUploadsPage(pageToken: String?, forceRefresh: Bool) async throws -> SubscriptionFeedPage
    func channelVideosPage(channelID: String, pageToken: String?, forceRefresh: Bool) async throws -> ChannelVideoPage
    func refreshStatistics(videoIDs: [String]) async throws -> [String: Int64]
}

protocol AudioExtracting: Sendable {
    func extract(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExtractedAudio
    func cancel() async

    func extract(
        requestID: String,
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExtractedAudio
    func cancel(requestID: String) async
}

extension AudioExtracting {
    func extract(
        requestID _: String,
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExtractedAudio {
        try await extract(from: url, progress: progress)
    }

    func cancel(requestID _: String) async {
        await cancel()
    }
}

@MainActor
protocol AudioLibraryManaging: AnyObject {
    func importAudio(_ extracted: ExtractedAudio, metadata: VideoSummary) async throws -> SavedAudio
    func delete(_ audio: SavedAudio) throws
    func updateStatistics(_ counts: [String: Int64]) throws
    func updatePlaybackPosition(videoID: String, position: TimeInterval)
    func markPlayed(videoID: String)
    func audioURL(for audio: SavedAudio) -> URL
    func thumbnailURL(for audio: SavedAudio) -> URL?
    func savedAudio(videoID: String) -> SavedAudio?
    /// Library items whose audio file has not been normalized to
    /// `currentVersion`, most recently downloaded first.
    func audiosRequiringNormalization(currentVersion: Int) -> [SavedAudio]
    func recordNormalizedAudio(
        videoID: String,
        contentSHA256: String,
        fileSize: Int64,
        normalizationVersion: Int
    ) throws
}

/// Rewrites library audio into a flat, digest-bound M4A so Apple Watch
/// transfers can start immediately. Jobs are serialized per process.
@MainActor
protocol LibraryAudioOptimizing: AnyObject {
    var progress: [String: LibraryAudioOptimizationProgress] { get }
    var activeVideoID: String? { get }

    /// Returns immediately when the item is already normalized. Concurrent
    /// calls for the same video join the in-flight job.
    func optimize(videoID: String) async throws -> OptimizedLibraryAudio
    func resumeBackfill()
    func pauseBackfill()
}

@MainActor
protocol AudioPlaying: AnyObject {
    func play(_ item: PlaybackItem, queue: [PlaybackItem])
    func togglePlayback()
    func seek(to seconds: TimeInterval)
    func skip(by seconds: TimeInterval)
    func persistPosition()
    func removeFromQueue(videoID: String)
    func next()
    func previous()
}

@MainActor
protocol WatchTransferManaging: AnyObject {
    var connectionStatus: WatchConnectionStatus { get }
    var liveProgress: [String: Double] { get }
    var liveEstimates: [String: WatchTransferEstimate] { get }
    var latestInventory: WatchInventorySnapshot? { get }

    func start()
    func refreshState()
    func resumeFromForeground()
    func enqueue(_ source: WatchTransferSource) async throws
    func cancel(videoID: String)
    func retry(videoID: String) async throws
    func discardRetry(videoID: String) throws
    func requestDeletion(videoID: String) throws
}
