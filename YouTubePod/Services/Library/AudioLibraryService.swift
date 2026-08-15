import AVFoundation
import Foundation
import SwiftData

@MainActor
final class AudioLibraryService: AudioLibraryManaging {
    private let modelContext: ModelContext
    private let rootURL: URL
    private let audioDirectory: URL
    private let artworkDirectory: URL

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        let base = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Library", isDirectory: true)
        rootURL = base
        audioDirectory = base.appendingPathComponent("Audio", isDirectory: true)
        artworkDirectory = base.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        removeOrphanedFiles()
    }

    func importAudio(_ extracted: ExtractedAudio, metadata: VideoSummary) async throws -> SavedAudio {
        let temporaryDirectory = extracted.fileURL.deletingLastPathComponent().standardizedFileURL
        defer {
            let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"
            if temporaryDirectory.path.hasPrefix(temporaryRoot) {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }

        guard extracted.videoID == metadata.id || extracted.videoID.isEmpty else { throw LibraryError.videoIDMismatch }
        guard extracted.fileURL.pathExtension.lowercased() == "m4a" else {
            throw LibraryError.unsupportedFormat
        }
        let asset = AVURLAsset(url: extracted.fileURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard videoTracks.isEmpty, !audioTracks.isEmpty else { throw LibraryError.notAudioOnly }

        let capacity = try audioDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let sourceSize = try extracted.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if let capacity, capacity <= Int64(sourceSize + 10_000_000) {
            throw LibraryError.insufficientStorage
        }

        let audioName = "\(metadata.id).m4a"
        let destination = audioDirectory.appendingPathComponent(audioName)
        let staged = audioDirectory.appendingPathComponent(".\(metadata.id)-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.moveItem(at: extracted.fileURL, to: staged)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }

        var artworkRelativePath: String?
        if let source = metadata.thumbnailURL ?? extracted.thumbnailURL,
           let (data, _) = try? await URLSession.shared.data(from: source), !data.isEmpty {
            let artworkName = "\(metadata.id).jpg"
            try? data.write(to: artworkDirectory.appendingPathComponent(artworkName), options: .atomic)
            artworkRelativePath = "Artwork/\(artworkName)"
        }

        var descriptor = FetchDescriptor<SavedAudio>(
            predicate: #Predicate { $0.youtubeID == metadata.id }
        )
        descriptor.fetchLimit = 1
        let saved: SavedAudio
        if let existing = try modelContext.fetch(descriptor).first {
            saved = existing
            existing.title = metadata.title.isEmpty ? extracted.title : metadata.title
            existing.channelTitle = metadata.channelTitle.isEmpty ? extracted.channel : metadata.channelTitle
            existing.publishedAt = metadata.publishedAt
            existing.savedViewCount = metadata.viewCount
            existing.duration = metadata.duration > 0 ? metadata.duration : extracted.duration
            existing.downloadedAt = .now
            existing.fileSize = Int64(sourceSize)
            existing.audioRelativePath = "Audio/\(audioName)"
            existing.thumbnailRelativePath = artworkRelativePath ?? existing.thumbnailRelativePath
        } else {
            saved = SavedAudio(
                youtubeID: metadata.id,
                title: metadata.title.isEmpty ? extracted.title : metadata.title,
                channelTitle: metadata.channelTitle.isEmpty ? extracted.channel : metadata.channelTitle,
                publishedAt: metadata.publishedAt,
                savedViewCount: metadata.viewCount,
                duration: metadata.duration > 0 ? metadata.duration : extracted.duration,
                fileSize: Int64(sourceSize),
                audioRelativePath: "Audio/\(audioName)",
                thumbnailRelativePath: artworkRelativePath
            )
            modelContext.insert(saved)
        }
        try modelContext.save()
        return saved
    }

    func delete(_ audio: SavedAudio) throws {
        let files = [audioURL(for: audio), thumbnailURL(for: audio)].compactMap { $0 }
        modelContext.delete(audio)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        // Commit the model deletion before removing files. If the process is
        // interrupted in this tiny window, orphan cleanup on the next launch
        // removes the invisible files without leaving a broken library row.
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    func updateStatistics(_ counts: [String: Int64]) throws {
        guard !counts.isEmpty else { return }
        let ids = Set(counts.keys)
        let audios = try modelContext.fetch(FetchDescriptor<SavedAudio>())
        for audio in audios where ids.contains(audio.youtubeID) {
            if let count = counts[audio.youtubeID] { audio.savedViewCount = count }
        }
        try modelContext.save()
    }

    func updatePlaybackPosition(videoID: String, position: TimeInterval) {
        var descriptor = FetchDescriptor<SavedAudio>(predicate: #Predicate { $0.youtubeID == videoID })
        descriptor.fetchLimit = 1
        guard let audio = try? modelContext.fetch(descriptor).first else { return }
        audio.lastPlaybackPosition = min(max(0, position), max(0, audio.duration))
        try? modelContext.save()
    }

    func markPlayed(videoID: String) {
        var descriptor = FetchDescriptor<SavedAudio>(predicate: #Predicate { $0.youtubeID == videoID })
        descriptor.fetchLimit = 1
        guard let audio = try? modelContext.fetch(descriptor).first,
              !audio.hasBeenPlayed else { return }
        audio.hasBeenPlayed = true
        try? modelContext.save()
    }

    func audioURL(for audio: SavedAudio) -> URL { rootURL.appendingPathComponent(audio.audioRelativePath) }
    func thumbnailURL(for audio: SavedAudio) -> URL? {
        audio.thumbnailRelativePath.map { rootURL.appendingPathComponent($0) }
    }

    private func removeOrphanedFiles() {
        guard let savedAudios = try? modelContext.fetch(FetchDescriptor<SavedAudio>()) else { return }
        var retainedPaths = Set<String>()
        var changedModel = false
        for audio in savedAudios {
            let audioFile = audioURL(for: audio)
            guard FileManager.default.fileExists(atPath: audioFile.path) else {
                modelContext.delete(audio)
                changedModel = true
                continue
            }
            retainedPaths.insert(audioFile.standardizedFileURL.path)
            if let thumbnail = thumbnailURL(for: audio) {
                if FileManager.default.fileExists(atPath: thumbnail.path) {
                    retainedPaths.insert(thumbnail.standardizedFileURL.path)
                } else {
                    audio.thumbnailRelativePath = nil
                    changedModel = true
                }
            }
        }
        if changedModel { try? modelContext.save() }

        for directory in [audioDirectory, artworkDirectory] {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            for file in files where !retainedPaths.contains(file.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

enum LibraryError: LocalizedError {
    case videoIDMismatch, unsupportedFormat, notAudioOnly, insufficientStorage
    var errorDescription: String? {
        switch self {
        case .videoIDMismatch: "選択した動画と取得結果が一致しません。"
        case .unsupportedFormat: "M4A形式以外の音声は保存できません。"
        case .notAudioOnly: "保存ファイルに動画トラックが含まれているか、音声トラックがありません。"
        case .insufficientStorage: "端末の空き容量が不足しています。"
        }
    }
}
