import Foundation
import SwiftData

struct VideoSummary: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let channelTitle: String
    let thumbnailURL: URL?
    let publishedAt: Date
    let viewCount: Int64
    let duration: TimeInterval
    var channelID: String = ""
    var broadcastStatus: YouTubeBroadcastStatus = .none

    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }

    var supportsAudioExtraction: Bool {
        broadcastStatus == .none && duration > 0
    }

    var audioExtractionUnavailableMessage: String {
        switch broadcastStatus {
        case .live:
            "ライブ配信は音声保存の対象外です"
        case .upcoming:
            "公開前の動画は音声保存の対象外です"
        case .none:
            "音声の準備が完了していません"
        }
    }
}

enum YouTubeBroadcastStatus: String, Codable, Hashable, Sendable {
    case none, live, upcoming
}

struct SubscriptionFeedPage: Codable, Sendable {
    let videos: [VideoSummary]
    let nextPageToken: String?
}

struct ChannelVideoPage: Codable, Sendable {
    let videos: [VideoSummary]
    let nextPageToken: String?
}

struct YouTubeCredential: Sendable {
    let accessToken: String
    let accountID: String
    let sessionID: UUID
}

@Model
final class SavedAudio {
    @Attribute(.unique) var youtubeID: String
    var title: String
    var channelTitle: String
    var publishedAt: Date
    var savedViewCount: Int64
    var duration: TimeInterval
    var downloadedAt: Date
    var fileSize: Int64
    var audioRelativePath: String
    var thumbnailRelativePath: String?
    var lastPlaybackPosition: TimeInterval
    var hasBeenPlayed: Bool = false

    init(
        youtubeID: String,
        title: String,
        channelTitle: String,
        publishedAt: Date,
        savedViewCount: Int64,
        duration: TimeInterval,
        downloadedAt: Date = .now,
        fileSize: Int64,
        audioRelativePath: String,
        thumbnailRelativePath: String? = nil,
        lastPlaybackPosition: TimeInterval = 0,
        hasBeenPlayed: Bool = false
    ) {
        self.youtubeID = youtubeID
        self.title = title
        self.channelTitle = channelTitle
        self.publishedAt = publishedAt
        self.savedViewCount = savedViewCount
        self.duration = duration
        self.downloadedAt = downloadedAt
        self.fileSize = fileSize
        self.audioRelativePath = audioRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.lastPlaybackPosition = lastPlaybackPosition
        self.hasBeenPlayed = hasBeenPlayed
    }

    var playbackProgress: Double {
        guard duration.isFinite, duration > 0, lastPlaybackPosition.isFinite else { return 0 }
        return min(max(lastPlaybackPosition / duration, 0), 1)
    }
}

struct ExtractedAudio: Sendable {
    let fileURL: URL
    let videoID: String
    let title: String
    let channel: String
    let duration: TimeInterval
    let thumbnailURL: URL?
}

enum DownloadPhase: Equatable, Sendable {
    case queued
    case downloading(Double)
    case retrying(attempt: Int, maximumRetries: Int)
    case validating
    case completed
    case failed(String)

    var isActive: Bool {
        switch self {
        case .queued, .downloading, .retrying, .validating: true
        case .completed, .failed: false
        }
    }
}

struct PlaybackItem: Identifiable, Sendable {
    let id: String
    let title: String
    let channelTitle: String
    let duration: TimeInterval
    let fileURL: URL
    let artworkURL: URL?
    let resumePosition: TimeInterval
}
