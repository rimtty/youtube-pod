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
    /// SHA-256 of `Audio/<id>.m4a` once it has been normalized into a flat
    /// M4A container. `nil` means the file is still the raw yt-dlp download.
    /// Every path that rewrites the audio file must reset this together with
    /// `audioNormalizationVersion`, otherwise Apple Watch rejects the digest.
    var audioContentSHA256: String? = nil
    var audioNormalizationVersion: Int = 0

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
        hasBeenPlayed: Bool = false,
        audioContentSHA256: String? = nil,
        audioNormalizationVersion: Int = 0
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
        self.audioContentSHA256 = audioContentSHA256
        self.audioNormalizationVersion = audioNormalizationVersion
    }

    var playbackProgress: Double {
        guard duration.isFinite, duration > 0, lastPlaybackPosition.isFinite else { return 0 }
        return min(max(lastPlaybackPosition / duration, 0), 1)
    }

    func isNormalized(currentVersion: Int) -> Bool {
        audioContentSHA256 != nil && audioNormalizationVersion >= currentVersion
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
    /// The audio is already saved and playable; the library file is being
    /// rewritten into a flat M4A so Apple Watch transfers can start at once.
    case optimizing(Double)
    case completed
    case failed(String)

    var isActive: Bool {
        switch self {
        case .queued, .downloading, .retrying, .validating, .optimizing: true
        case .completed, .failed: false
        }
    }

    /// True while the yt-dlp extraction or import still owns the file, i.e.
    /// before the audio exists in the library.
    var isExtracting: Bool {
        switch self {
        case .queued, .downloading, .retrying, .validating: true
        case .optimizing, .completed, .failed: false
        }
    }
}

/// Result of normalizing one library audio file into a flat M4A container.
struct OptimizedLibraryAudio: Equatable, Sendable {
    let audioURL: URL
    let contentSHA256: String
    let fileSize: Int64
}

enum LibraryAudioOptimizationProgress: Equatable, Sendable {
    /// AVFoundation is parsing the fragmented source; no sample has been
    /// copied yet, so there is no meaningful fraction.
    case inspecting
    case remuxing(Double)
    case verifying
    case hashing(Double)

    /// Combined 0...1 estimate for a single progress bar. The remux dominates
    /// wall-clock time, hashing is one sequential read of the output.
    var overallFraction: Double {
        switch self {
        case .inspecting:
            0
        case .remuxing(let fraction):
            min(max(fraction, 0), 1) * 0.9
        case .verifying:
            0.9
        case .hashing(let fraction):
            0.9 + min(max(fraction, 0), 1) * 0.1
        }
    }

    var isIndeterminate: Bool {
        switch self {
        case .inspecting, .verifying: true
        case .remuxing, .hashing: false
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
