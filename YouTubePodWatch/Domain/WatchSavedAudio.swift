import Foundation
import SwiftData

enum WatchSavedAudioStorageState: String, Codable, Sendable {
    case ready
    case readyWithoutArtwork
    case invalidMetadata
    case invalidAudioPath
}

@Model
final class WatchSavedAudio {
    @Attribute(.unique) var youtubeID: String
    @Attribute(.unique) var transferID: UUID
    var title: String
    var channelTitle: String
    var publishedAt: Date?
    var savedViewCount: Int64
    var duration: TimeInterval
    var audioRelativePath: String
    var thumbnailRelativePath: String?
    var fileSize: Int64
    var receivedAt: Date
    var revision: Int64
    var lastPlaybackPosition: TimeInterval
    var hasBeenPlayed: Bool

    init(
        youtubeID: String,
        transferID: UUID,
        title: String,
        channelTitle: String,
        publishedAt: Date?,
        savedViewCount: Int64,
        duration: TimeInterval,
        audioRelativePath: String,
        thumbnailRelativePath: String? = nil,
        fileSize: Int64,
        receivedAt: Date = .now,
        revision: Int64,
        lastPlaybackPosition: TimeInterval = 0,
        hasBeenPlayed: Bool = false
    ) {
        self.youtubeID = youtubeID
        self.transferID = transferID
        self.title = title
        self.channelTitle = channelTitle
        self.publishedAt = publishedAt
        self.savedViewCount = savedViewCount
        self.duration = duration
        self.audioRelativePath = audioRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.fileSize = fileSize
        self.receivedAt = receivedAt
        self.revision = revision
        self.lastPlaybackPosition = lastPlaybackPosition
        self.hasBeenPlayed = hasBeenPlayed
    }

    var safeAudioRelativePath: String? {
        Self.safeRelativePath(
            audioRelativePath,
            directory: "Audio",
            allowedExtensions: ["m4a"]
        )
    }

    var safeThumbnailRelativePath: String? {
        guard let thumbnailRelativePath else { return nil }
        return Self.safeRelativePath(
            thumbnailRelativePath,
            directory: "Artwork",
            allowedExtensions: ["jpg", "jpeg"]
        )
    }

    var normalizedPlaybackPosition: TimeInterval {
        guard duration.isFinite, duration > 0, lastPlaybackPosition.isFinite else { return 0 }
        return min(max(lastPlaybackPosition, 0), duration)
    }

    var playbackProgress: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(normalizedPlaybackPosition / duration, 0), 1)
    }

    var storageState: WatchSavedAudioStorageState {
        guard Self.isValidYouTubeID(youtubeID),
              transferID != Self.nilUUID,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              duration.isFinite,
              duration > 0,
              fileSize >= 0,
              revision >= 0
        else {
            return .invalidMetadata
        }
        guard safeAudioRelativePath != nil else { return .invalidAudioPath }
        guard thumbnailRelativePath != nil,
              safeThumbnailRelativePath != nil else {
            return .readyWithoutArtwork
        }
        return .ready
    }

    private static func safeRelativePath(
        _ path: String,
        directory: String,
        allowedExtensions: Set<String>
    ) -> String? {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            return nil
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == Substring(directory),
              !components[1].isEmpty,
              components[1] != ".",
              components[1] != ".."
        else {
            return nil
        }

        let filename = String(components[1])
        let fileURL = URL(fileURLWithPath: filename)
        guard fileURL.lastPathComponent == filename,
              allowedExtensions.contains(fileURL.pathExtension.lowercased())
        else {
            return nil
        }
        return path
    }

    private static func isValidYouTubeID(_ value: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        )
        return value.unicodeScalars.count == 11
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static let nilUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
