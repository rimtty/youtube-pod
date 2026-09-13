import SwiftData
import XCTest
@testable import YouTubePod

final class YouTubePodSchemaTests: XCTestCase {
    @MainActor
    func testLegacySavedAudioStoreExpandsWithoutDataLoss() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePod-SchemaMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let storeURL = storeDirectory.appendingPathComponent("library.store")
        let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let downloadedAt = Date(timeIntervalSince1970: 1_700_000_100)

        do {
            // This is the unversioned configuration shipped before Watch support.
            let legacyContainer = try ModelContainer(
                for: SavedAudio.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            legacyContainer.mainContext.insert(
                SavedAudio(
                    youtubeID: "migrate0001",
                    title: "Existing audio",
                    channelTitle: "Existing channel",
                    publishedAt: publishedAt,
                    savedViewCount: 12_345,
                    duration: 321,
                    downloadedAt: downloadedAt,
                    fileSize: 98_765,
                    audioRelativePath: "Audio/migrate0001.m4a",
                    thumbnailRelativePath: "Artwork/migrate0001.jpg",
                    lastPlaybackPosition: 123,
                    hasBeenPlayed: true
                )
            )
            try legacyContainer.mainContext.save()
        }

        let migratedContainer = try ModelContainer(
            for: SavedAudio.self,
            WatchTransferRecord.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let saved = try XCTUnwrap(
            migratedContainer.mainContext.fetch(FetchDescriptor<SavedAudio>()).first
        )

        XCTAssertEqual(saved.youtubeID, "migrate0001")
        XCTAssertEqual(saved.title, "Existing audio")
        XCTAssertEqual(saved.channelTitle, "Existing channel")
        XCTAssertEqual(saved.publishedAt, publishedAt)
        XCTAssertEqual(saved.savedViewCount, 12_345)
        XCTAssertEqual(saved.duration, 321)
        XCTAssertEqual(saved.downloadedAt, downloadedAt)
        XCTAssertEqual(saved.fileSize, 98_765)
        XCTAssertEqual(saved.audioRelativePath, "Audio/migrate0001.m4a")
        XCTAssertEqual(saved.thumbnailRelativePath, "Artwork/migrate0001.jpg")
        XCTAssertEqual(saved.lastPlaybackPosition, 123)
        XCTAssertTrue(saved.hasBeenPlayed)
        // Pre-normalization rows must read as "not yet optimized".
        XCTAssertNil(saved.audioContentSHA256)
        XCTAssertEqual(saved.audioNormalizationVersion, 0)
        XCTAssertFalse(saved.isNormalized(currentVersion: LibraryAudioOptimizer.currentNormalizationVersion))
        XCTAssertTrue(try migratedContainer.mainContext.fetch(FetchDescriptor<WatchTransferRecord>()).isEmpty)
    }

    @MainActor
    func testNormalizationFieldsRoundTripThroughReopenedStore() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePod-SchemaNormalization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let storeURL = storeDirectory.appendingPathComponent("library.store")
        let digest = String(repeating: "b", count: 64)

        do {
            let container = try ModelContainer(
                for: SavedAudio.self,
                WatchTransferRecord.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            container.mainContext.insert(
                SavedAudio(
                    youtubeID: "digest00001",
                    title: "Normalized audio",
                    channelTitle: "Channel",
                    publishedAt: .now,
                    savedViewCount: 1,
                    duration: 60,
                    fileSize: 2_048,
                    audioRelativePath: "Audio/digest00001.m4a",
                    audioContentSHA256: digest,
                    audioNormalizationVersion: 1
                )
            )
            try container.mainContext.save()
        }

        let reopened = try ModelContainer(
            for: SavedAudio.self,
            WatchTransferRecord.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let saved = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<SavedAudio>()).first)
        XCTAssertEqual(saved.audioContentSHA256, digest)
        XCTAssertEqual(saved.audioNormalizationVersion, 1)
        XCTAssertTrue(saved.isNormalized(currentVersion: 1))
    }

    @MainActor
    func testExpandedUnversionedStoreReopensWithSavedAudioAndWatchTransferRecord() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePod-SchemaReopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let storeURL = storeDirectory.appendingPathComponent("library.store")
        let transferID = UUID()

        do {
            let container = try ModelContainer(
                for: SavedAudio.self,
                WatchTransferRecord.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            container.mainContext.insert(
                SavedAudio(
                    youtubeID: "reopen00001",
                    title: "Saved audio",
                    channelTitle: "Channel",
                    publishedAt: .now,
                    savedViewCount: 42,
                    duration: 60,
                    fileSize: 1_024,
                    audioRelativePath: "Audio/reopen00001.m4a"
                )
            )
            container.mainContext.insert(
                WatchTransferRecord(
                    youtubeID: "reopen00001",
                    title: "Saved audio",
                    channelTitle: "Channel",
                    publishedAt: .now,
                    duration: 60,
                    savedViewCount: 42,
                    sourceFileSize: 1_024,
                    playbackPosition: 15,
                    transferID: transferID,
                    revision: 3,
                    state: .awaitingWatchConfirmation,
                    lastKnownProgress: 1,
                    artworkExpected: true,
                    audioDeliveryFinished: true,
                    artworkDeliveryFinished: true,
                    retryCount: 1
                )
            )
            try container.mainContext.save()
        }

        let reopenedContainer = try ModelContainer(
            for: SavedAudio.self,
            WatchTransferRecord.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let savedItems = try reopenedContainer.mainContext.fetch(FetchDescriptor<SavedAudio>())
        let transfers = try reopenedContainer.mainContext.fetch(FetchDescriptor<WatchTransferRecord>())

        XCTAssertEqual(savedItems.map(\.youtubeID), ["reopen00001"])
        let transfer = try XCTUnwrap(transfers.first)
        XCTAssertEqual(transfer.transferID, transferID)
        XCTAssertEqual(transfer.revision, 3)
        XCTAssertEqual(transfer.state, .awaitingWatchConfirmation)
        XCTAssertEqual(transfer.lastKnownProgress, 1)
        XCTAssertEqual(transfer.playbackPosition, 15)
        XCTAssertTrue(transfer.audioDeliveryFinished)
        XCTAssertTrue(transfer.artworkDeliveryFinished)
        XCTAssertEqual(transfer.retryCount, 1)
    }

    @MainActor
    func testUnknownPersistedStateRequiresReconciliation() throws {
        let container = try ModelContainer(
            for: SavedAudio.self,
            WatchTransferRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let record = WatchTransferRecord(
            youtubeID: "state000001",
            title: "Audio",
            channelTitle: "Channel",
            publishedAt: .now,
            duration: 1,
            savedViewCount: 1,
            sourceFileSize: 1
        )
        container.mainContext.insert(record)

        record.stateRawValue = "futureState"
        XCTAssertEqual(record.state, .reconciliationRequired)

        record.state = .availableOnWatch
        XCTAssertEqual(record.stateRawValue, WatchTransferState.availableOnWatch.rawValue)
    }
}
