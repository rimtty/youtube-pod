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
