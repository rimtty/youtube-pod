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
