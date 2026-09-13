import AVFAudio
import SwiftData
import XCTest
@testable import YouTubePod

@MainActor
final class AudioLibraryServiceTests: XCTestCase {
    func testImportUpdateStatisticsAndDeleteRemainConsistent() async throws {
        let container = try ModelContainer(
            for: SavedAudio.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = AudioLibraryService(modelContext: container.mainContext)
        let source = try makeM4AAudioFile()
        let metadata = video(id: "library0001")
        let extracted = ExtractedAudio(
            fileURL: source,
            videoID: metadata.id,
            title: metadata.title,
            channel: metadata.channelTitle,
            duration: metadata.duration,
            thumbnailURL: nil
        )

        let saved = try await service.importAudio(extracted, metadata: metadata)

        let audioURL = service.audioURL(for: saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(saved.youtubeID, metadata.id)
        XCTAssertEqual(saved.savedViewCount, metadata.viewCount)

        try service.updateStatistics([metadata.id: 999])
        XCTAssertEqual(saved.savedViewCount, 999)

        service.updatePlaybackPosition(videoID: metadata.id, position: 500)
        XCTAssertEqual(saved.lastPlaybackPosition, metadata.duration)

        XCTAssertFalse(saved.hasBeenPlayed)
        service.markPlayed(videoID: metadata.id)
        XCTAssertTrue(saved.hasBeenPlayed)

        saved.thumbnailRelativePath = "Artwork/\(metadata.id).jpg"
        let thumbnailURL = try XCTUnwrap(service.thumbnailURL(for: saved))
        try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
        try container.mainContext.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))

        try service.delete(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<SavedAudio>()).isEmpty)
    }

    func testReimportUpdatesExistingModelWithoutLosingPlaybackState() async throws {
        let container = try ModelContainer(
            for: SavedAudio.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = AudioLibraryService(modelContext: container.mainContext)
        let originalMetadata = video(id: "library0003", title: "Original")
        let firstSource = try makeM4AAudioFile()
        let original = try await service.importAudio(
            ExtractedAudio(
                fileURL: firstSource,
                videoID: originalMetadata.id,
                title: originalMetadata.title,
                channel: originalMetadata.channelTitle,
                duration: originalMetadata.duration,
                thumbnailURL: nil
            ),
            metadata: originalMetadata
        )
        service.updatePlaybackPosition(videoID: original.youtubeID, position: 0.05)
        service.markPlayed(videoID: original.youtubeID)

        let updatedMetadata = video(id: original.youtubeID, title: "Updated")
        let secondSource = try makeM4AAudioFile()
        let updated = try await service.importAudio(
            ExtractedAudio(
                fileURL: secondSource,
                videoID: updatedMetadata.id,
                title: updatedMetadata.title,
                channel: updatedMetadata.channelTitle,
                duration: updatedMetadata.duration,
                thumbnailURL: nil
            ),
            metadata: updatedMetadata
        )

        let stored = try container.mainContext.fetch(FetchDescriptor<SavedAudio>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(updated.title, "Updated")
        XCTAssertEqual(updated.lastPlaybackPosition, 0.05, accuracy: 0.000_001)
        XCTAssertTrue(updated.hasBeenPlayed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.audioURL(for: updated).path))

        try service.delete(updated)
    }

    func testRejectedImportCleansTemporaryDirectory() async throws {
        let container = try ModelContainer(
            for: SavedAudio.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = AudioLibraryService(modelContext: container.mainContext)
        let source = try makeM4AAudioFile()
        let temporaryDirectory = source.deletingLastPathComponent()
        let metadata = video(id: "library0002")
        let extracted = ExtractedAudio(
            fileURL: source,
            videoID: "different01",
            title: metadata.title,
            channel: metadata.channelTitle,
            duration: metadata.duration,
            thumbnailURL: nil
        )

        do {
            _ = try await service.importAudio(extracted, metadata: metadata)
            XCTFail("Expected a video ID mismatch")
        } catch LibraryError.videoIDMismatch {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }

    func testNonM4AImportIsRejectedAndCleansTemporaryDirectory() async throws {
        let container = try ModelContainer(
            for: SavedAudio.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = AudioLibraryService(modelContext: container.mainContext)
        let original = try makeM4AAudioFile()
        let temporaryDirectory = original.deletingLastPathComponent()
        let renamed = temporaryDirectory.appendingPathComponent("source.mp4")
        try FileManager.default.moveItem(at: original, to: renamed)
        let metadata = video(id: "library0004")

        do {
            _ = try await service.importAudio(
                ExtractedAudio(
                    fileURL: renamed,
                    videoID: metadata.id,
                    title: metadata.title,
                    channel: metadata.channelTitle,
                    duration: metadata.duration,
                    thumbnailURL: nil
                ),
                metadata: metadata
            )
            XCTFail("Expected an unsupported format error")
        } catch LibraryError.unsupportedFormat {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<SavedAudio>()).isEmpty)
    }

    func testSavedMetadataAndPlaybackPositionSurvivePersistentStoreReopen() async throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePod-StoreTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let storeURL = storeDirectory.appendingPathComponent("library.store")
        let metadata = video(id: "library0005", title: "Persistent audio")

        do {
            let container = try ModelContainer(
                for: SavedAudio.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            let service = AudioLibraryService(modelContext: container.mainContext)
            let source = try makeM4AAudioFile()
            let saved = try await service.importAudio(
                ExtractedAudio(
                    fileURL: source,
                    videoID: metadata.id,
                    title: metadata.title,
                    channel: metadata.channelTitle,
                    duration: metadata.duration,
                    thumbnailURL: nil
                ),
                metadata: metadata
            )
            service.updatePlaybackPosition(videoID: saved.youtubeID, position: 0.05)
            service.markPlayed(videoID: saved.youtubeID)
        }

        let reopenedContainer = try ModelContainer(
            for: SavedAudio.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let reopenedService = AudioLibraryService(modelContext: reopenedContainer.mainContext)
        let restored = try XCTUnwrap(
            reopenedContainer.mainContext.fetch(FetchDescriptor<SavedAudio>()).first
        )

        XCTAssertEqual(restored.youtubeID, metadata.id)
        XCTAssertEqual(restored.title, "Persistent audio")
        XCTAssertEqual(restored.lastPlaybackPosition, 0.05, accuracy: 0.000_001)
        XCTAssertTrue(restored.hasBeenPlayed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopenedService.audioURL(for: restored).path))

        try reopenedService.delete(restored)
    }

    func testServiceStartupRemovesFilesWithoutLibraryMetadata() throws {
        let container = try ModelContainer(
            for: SavedAudio.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let firstService = AudioLibraryService(modelContext: container.mainContext)
        let orphan = SavedAudio(
            youtubeID: "orphan00001",
            title: "Orphan",
            channelTitle: "Test channel",
            publishedAt: .now,
            savedViewCount: 1,
            duration: 1,
            fileSize: 1,
            audioRelativePath: "Audio/orphan00001.m4a",
            thumbnailRelativePath: "Artwork/orphan00001.jpg"
        )
        let audioURL = firstService.audioURL(for: orphan)
        let thumbnailURL = try XCTUnwrap(firstService.thumbnailURL(for: orphan))
        try Data([0]).write(to: audioURL)
        try Data([0]).write(to: thumbnailURL)

        _ = AudioLibraryService(modelContext: container.mainContext)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
    }

    func testServiceStartupRemovesHiddenStagingFileFromInterruptedImport() throws {
        let container = try ModelContainer(
            for: SavedAudio.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let firstService = AudioLibraryService(modelContext: container.mainContext)
        let placeholder = SavedAudio(
            youtubeID: "staging0001",
            title: "Staging",
            channelTitle: "Test channel",
            publishedAt: .now,
            savedViewCount: 1,
            duration: 1,
            fileSize: 1,
            audioRelativePath: "Audio/.staging0001-interrupted.m4a"
        )
        let hiddenStagingURL = firstService.audioURL(for: placeholder)
        try Data([0]).write(to: hiddenStagingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenStagingURL.path))

        _ = AudioLibraryService(modelContext: container.mainContext)

        XCTAssertFalse(FileManager.default.fileExists(atPath: hiddenStagingURL.path))
    }

    func testServiceStartupRemovesMetadataWhoseAudioFileIsMissing() throws {
        let container = try ModelContainer(
            for: SavedAudio.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        container.mainContext.insert(SavedAudio(
            youtubeID: "missing0001",
            title: "Missing",
            channelTitle: "Test channel",
            publishedAt: .now,
            savedViewCount: 1,
            duration: 1,
            fileSize: 1,
            audioRelativePath: "Audio/missing0001.m4a"
        ))
        try container.mainContext.save()

        _ = AudioLibraryService(modelContext: container.mainContext)

        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<SavedAudio>()).isEmpty)
    }

    func testReimportResetsNormalizationRecordBecauseBytesChanged() async throws {
        let container = try ModelContainer(
            for: SavedAudio.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = AudioLibraryService(modelContext: container.mainContext)
        let metadata = video(id: "library0010")
        let saved = try await service.importAudio(extracted(for: metadata), metadata: metadata)
        try service.recordNormalizedAudio(
            videoID: metadata.id,
            contentSHA256: String(repeating: "d", count: 64),
            fileSize: 4_096,
            normalizationVersion: 1
        )
        XCTAssertTrue(saved.isNormalized(currentVersion: 1))
        XCTAssertEqual(saved.fileSize, 4_096)

        _ = try await service.importAudio(extracted(for: metadata), metadata: metadata)

        XCTAssertNil(saved.audioContentSHA256)
        XCTAssertEqual(saved.audioNormalizationVersion, 0)
        XCTAssertFalse(saved.isNormalized(currentVersion: 1))
        XCTAssertEqual(saved.fileSize, try fileSize(at: service.audioURL(for: saved)))
    }

    func testAudiosRequiringNormalizationListsNewestUnnormalizedFirst() async throws {
        let container = try ModelContainer(
            for: SavedAudio.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = AudioLibraryService(modelContext: container.mainContext)
        let older = video(id: "library0011")
        let newer = video(id: "library0012")
        let normalized = video(id: "library0013")
        let olderSaved = try await service.importAudio(extracted(for: older), metadata: older)
        let newerSaved = try await service.importAudio(extracted(for: newer), metadata: newer)
        let normalizedSaved = try await service.importAudio(extracted(for: normalized), metadata: normalized)
        olderSaved.downloadedAt = Date(timeIntervalSince1970: 100)
        newerSaved.downloadedAt = Date(timeIntervalSince1970: 300)
        normalizedSaved.downloadedAt = Date(timeIntervalSince1970: 200)
        try container.mainContext.save()
        try service.recordNormalizedAudio(
            videoID: normalized.id,
            contentSHA256: String(repeating: "e", count: 64),
            fileSize: 1,
            normalizationVersion: 1
        )

        XCTAssertEqual(
            service.audiosRequiringNormalization(currentVersion: 1).map(\.youtubeID),
            [newer.id, older.id]
        )
        XCTAssertEqual(
            service.audiosRequiringNormalization(currentVersion: 2).map(\.youtubeID),
            [newer.id, normalized.id, older.id]
        )
        XCTAssertEqual(service.savedAudio(videoID: newer.id)?.youtubeID, newer.id)
        XCTAssertNil(service.savedAudio(videoID: "missing0000"))
        XCTAssertThrowsError(
            try service.recordNormalizedAudio(
                videoID: "missing0000",
                contentSHA256: String(repeating: "f", count: 64),
                fileSize: 1,
                normalizationVersion: 1
            )
        )
    }

    private func extracted(for metadata: VideoSummary) throws -> ExtractedAudio {
        ExtractedAudio(
            fileURL: try makeM4AAudioFile(),
            videoID: metadata.id,
            title: metadata.title,
            channel: metadata.channelTitle,
            duration: metadata.duration,
            thumbnailURL: nil
        )
    }

    private func fileSize(at url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private func makeM4AAudioFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePod-LibraryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.m4a")
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
        return url
    }

    private func video(id: String, title: String = "Test audio") -> VideoSummary {
        VideoSummary(
            id: id,
            title: title,
            channelTitle: "Test channel",
            thumbnailURL: nil,
            publishedAt: Date(timeIntervalSince1970: 1_000),
            viewCount: 42,
            duration: 0.1
        )
    }
}
