import SwiftData
import XCTest
@testable import YouTubePodWatch

@MainActor
final class WatchSavedAudioModelTests: XCTestCase {
    func testSafeRelativePathsAndStorageState() {
        let audio = makeAudio(
            audioRelativePath: "Audio/transfer.m4a",
            thumbnailRelativePath: "Artwork/transfer.jpg"
        )

        XCTAssertEqual(audio.safeAudioRelativePath, "Audio/transfer.m4a")
        XCTAssertEqual(audio.safeThumbnailRelativePath, "Artwork/transfer.jpg")
        XCTAssertEqual(audio.storageState, .ready)

        audio.audioRelativePath = "../Library/secret.m4a"
        XCTAssertNil(audio.safeAudioRelativePath)
        XCTAssertEqual(audio.storageState, .invalidAudioPath)

        audio.audioRelativePath = "Audio/transfer.m4a"
        audio.thumbnailRelativePath = "/tmp/artwork.jpg"
        XCTAssertNil(audio.safeThumbnailRelativePath)
        XCTAssertEqual(audio.storageState, .readyWithoutArtwork)
    }

    func testPlaybackPositionAndProgressAreClamped() {
        let audio = makeAudio(lastPlaybackPosition: 150)
        XCTAssertEqual(audio.normalizedPlaybackPosition, 120)
        XCTAssertEqual(audio.playbackProgress, 1)

        audio.lastPlaybackPosition = -30
        XCTAssertEqual(audio.normalizedPlaybackPosition, 0)
        XCTAssertEqual(audio.playbackProgress, 0)

        audio.lastPlaybackPosition = .nan
        XCTAssertEqual(audio.normalizedPlaybackPosition, 0)
        XCTAssertEqual(audio.playbackProgress, 0)
    }

    func testInvalidMetadataCannotBecomeReady() {
        let audio = makeAudio()
        audio.revision = -1
        XCTAssertEqual(audio.storageState, .invalidMetadata)

        audio.revision = 1
        audio.youtubeID = "too-short"
        XCTAssertEqual(audio.storageState, .invalidMetadata)
    }

    func testDeletionTombstoneRejectsSameAndOlderRevisions() {
        let tombstone = WatchDeletionTombstone(
            youtubeID: "delete00001",
            transferID: UUID(),
            revision: 4
        )

        XCTAssertEqual(tombstone.state, .valid)
        XCTAssertTrue(tombstone.rejects(incomingRevision: 3))
        XCTAssertTrue(tombstone.rejects(incomingRevision: 4))
        XCTAssertFalse(tombstone.rejects(incomingRevision: 5))
        XCTAssertEqual(tombstone.decision(forIncomingRevision: 5), .acceptNewerRevision)
    }

    func testLibraryAndTombstoneSurvivePersistentStoreReopen() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePodWatch-Model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let storeURL = storeDirectory.appendingPathComponent("watch.store")
        let transferID = UUID()

        do {
            let container = try ModelContainer(
                for: WatchSavedAudio.self,
                WatchDeletionTombstone.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            container.mainContext.insert(makeAudio(transferID: transferID, lastPlaybackPosition: 42))
            container.mainContext.insert(
                WatchDeletionTombstone(
                    youtubeID: "delete00001",
                    transferID: UUID(),
                    revision: 7,
                    deletedAt: Date(timeIntervalSince1970: 1_700_000_100)
                )
            )
            try container.mainContext.save()
        }

        let reopened = try ModelContainer(
            for: WatchSavedAudio.self,
            WatchDeletionTombstone.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let audio = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<WatchSavedAudio>()).first)
        let tombstone = try XCTUnwrap(
            reopened.mainContext.fetch(FetchDescriptor<WatchDeletionTombstone>()).first
        )

        XCTAssertEqual(audio.transferID, transferID)
        XCTAssertEqual(audio.revision, 1)
        XCTAssertEqual(audio.lastPlaybackPosition, 42)
        XCTAssertEqual(audio.storageState, .ready)
        XCTAssertEqual(tombstone.revision, 7)
        XCTAssertTrue(tombstone.rejects(incomingRevision: 7))
    }

    func testPendingAcknowledgementConvertsToValidatedEnvelope() throws {
        let acknowledgementID = UUID()
        let transferID = UUID()
        let pending = WatchPendingAcknowledgement(
            acknowledgementID: acknowledgementID,
            transferID: transferID,
            revision: 3,
            youtubeID: "watch000001",
            outcome: .imported,
            errorCode: .sizeMismatch,
            message: "saved",
            createdAt: Date(timeIntervalSince1970: 1_700_000_300),
            attemptCount: 2
        )

        XCTAssertEqual(pending.acknowledgementID, acknowledgementID)
        XCTAssertEqual(pending.outcome, .imported)
        XCTAssertEqual(pending.normalizedAttemptCount, 2)

        let acknowledgement = try pending.validatedAcknowledgement()
        XCTAssertEqual(acknowledgement.transferID, transferID)
        XCTAssertEqual(acknowledgement.revision, 3)
        XCTAssertEqual(acknowledgement.youtubeID, "watch000001")
        XCTAssertEqual(acknowledgement.outcome, .imported)
        XCTAssertEqual(acknowledgement.errorCode, .sizeMismatch)
        XCTAssertEqual(acknowledgement.message, "saved")
    }

    func testPendingAcknowledgementRejectsUnknownOutcomeAndInvalidEnvelope() {
        let pending = WatchPendingAcknowledgement(
            transferID: UUID(),
            revision: 1,
            youtubeID: "watch000001",
            outcome: .failed
        )

        pending.outcomeRawValue = "future-outcome"
        XCTAssertNil(pending.outcome)
        XCTAssertThrowsError(try pending.validatedAcknowledgement()) { error in
            XCTAssertEqual(
                error as? WatchPendingAcknowledgementError,
                .invalidOutcome("future-outcome")
            )
        }

        pending.outcome = .deleted
        pending.revision = -1
        XCTAssertThrowsError(try pending.validatedAcknowledgement()) { error in
            XCTAssertEqual(error as? WatchTransferProtocolError, .invalidRevision)
        }
    }

    func testPendingAcknowledgementSurvivesPersistentStoreReopen() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePodWatch-Outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let storeURL = storeDirectory.appendingPathComponent("watch.store")
        let acknowledgementID = UUID()

        do {
            let container = try ModelContainer(
                for: WatchSavedAudio.self,
                WatchDeletionTombstone.self,
                WatchPendingAcknowledgement.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            container.mainContext.insert(
                WatchPendingAcknowledgement(
                    acknowledgementID: acknowledgementID,
                    transferID: UUID(),
                    revision: 8,
                    youtubeID: "watch000001",
                    outcome: .deleted,
                    message: "removed",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_400),
                    attemptCount: 4
                )
            )
            try container.mainContext.save()
        }

        let reopened = try ModelContainer(
            for: WatchSavedAudio.self,
            WatchDeletionTombstone.self,
            WatchPendingAcknowledgement.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let pending = try XCTUnwrap(
            reopened.mainContext.fetch(FetchDescriptor<WatchPendingAcknowledgement>()).first
        )

        XCTAssertEqual(pending.acknowledgementID, acknowledgementID)
        XCTAssertEqual(pending.revision, 8)
        XCTAssertEqual(pending.outcome, .deleted)
        XCTAssertEqual(pending.message, "removed")
        XCTAssertEqual(pending.attemptCount, 4)
        XCTAssertNoThrow(try pending.validatedAcknowledgement())
    }

    private func makeAudio(
        transferID: UUID = UUID(),
        audioRelativePath: String = "Audio/transfer.m4a",
        thumbnailRelativePath: String? = "Artwork/transfer.jpg",
        lastPlaybackPosition: TimeInterval = 0
    ) -> WatchSavedAudio {
        WatchSavedAudio(
            youtubeID: "watch000001",
            transferID: transferID,
            title: "Saved audio",
            channelTitle: "Channel",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            savedViewCount: 42,
            duration: 120,
            audioRelativePath: audioRelativePath,
            thumbnailRelativePath: thumbnailRelativePath,
            fileSize: 1_024,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_200),
            revision: 1,
            lastPlaybackPosition: lastPlaybackPosition,
            hasBeenPlayed: true
        )
    }
}
