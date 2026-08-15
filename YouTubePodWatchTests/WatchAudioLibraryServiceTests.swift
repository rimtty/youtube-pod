import Foundation
import SwiftData
import XCTest
@testable import YouTubePodWatch

@MainActor
final class WatchAudioLibraryServiceTests: XCTestCase {
    nonisolated(unsafe) private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchAudioLibraryServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
        temporaryRoot = nil
    }

    func testExactDuplicateIsIdempotentAndInventoryCarriesIdentity() async throws {
        let fixture = try makeFixture()
        let transferID = UUID()
        let first = try makeStaged(
            videoID: "duplicate01",
            transferID: transferID,
            revision: 1,
            kind: .audio
        )
        let duplicate = try makeStaged(
            videoID: "duplicate01",
            transferID: transferID,
            revision: 1,
            kind: .audio
        )

        let firstResult = await fixture.service.importStagedFile(first)
        let duplicateResult = await fixture.service.importStagedFile(duplicate)
        XCTAssertEqual(firstResult, .imported)
        XCTAssertEqual(duplicateResult, .duplicate)

        let saved = fetch(WatchSavedAudio.self, fixture.context)
        let acknowledgements = fetch(WatchPendingAcknowledgement.self, fixture.context)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.revision, 1)
        XCTAssertEqual(acknowledgements.count, 1)
        XCTAssertEqual(acknowledgements.first?.outcome, .imported)

        let inventory = try fixture.service.inventory(availableCapacity: 55_000)
        XCTAssertNotEqual(inventory.libraryInstanceID, nilUUID)
        XCTAssertEqual(inventory.generation, 1)
        XCTAssertEqual(inventory.availableCapacity, 55_000)
        XCTAssertEqual(inventory.entries, [WatchInventoryEntry(
            youtubeID: "duplicate01",
            transferID: transferID,
            revision: 1,
            fileSize: 64
        )])

        let pending = try XCTUnwrap(fixture.service.pendingAcknowledgements().first)
        try fixture.service.acknowledgementAttemptFailed(id: pending.acknowledgementID)
        XCTAssertEqual(try fixture.service.pendingAcknowledgements().first?.attemptCount, 1)
        try fixture.service.acknowledgementSent(id: pending.acknowledgementID)
        XCTAssertTrue(try fixture.service.pendingAcknowledgements().isEmpty)
    }

    func testInventoryDoesNotAdvertiseMissingAudioFile() async throws {
        let fixture = try makeFixture()
        let staged = try makeStaged(
            videoID: "inventory01",
            transferID: UUID(),
            revision: 1,
            kind: .audio
        )
        let result = await fixture.service.importStagedFile(staged)
        XCTAssertEqual(result, .imported)
        let saved = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        try FileManager.default.removeItem(
            at: fixture.rootURL.appendingPathComponent(saved.audioRelativePath)
        )

        let inventory = try fixture.service.inventory(availableCapacity: nil)

        XCTAssertTrue(inventory.entries.isEmpty)
    }

    func testPlaybackPositionPersistsAndClampsWithoutClearingPlayedState() async throws {
        let fixture = try makeFixture()
        let staged = try makeStaged(
            videoID: "playback001",
            transferID: UUID(),
            revision: 1,
            kind: .audio
        )
        let importResult = await fixture.service.importStagedFile(staged)
        XCTAssertEqual(importResult, .imported)

        try fixture.service.persistPlaybackPosition(
            videoID: "playback001",
            position: 999,
            hasBeenPlayed: true
        )
        try fixture.service.persistPlaybackPosition(
            videoID: "playback001",
            position: 12,
            hasBeenPlayed: false
        )

        let saved = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        XCTAssertEqual(saved.lastPlaybackPosition, 12)
        XCTAssertTrue(saved.hasBeenPlayed)
        XCTAssertNotNil(fixture.service.audioFileURL(for: saved))
    }

    func testNewerRevisionWinsWhenOlderValidationResumesLate() async throws {
        let validator = BlockingRevisionValidator(blockedRevision: 1)
        let fixture = try makeFixture(validator: validator)
        let older = try makeStaged(
            videoID: "revision001",
            transferID: UUID(),
            revision: 1,
            kind: .audio
        )
        let newer = try makeStaged(
            videoID: "revision001",
            transferID: UUID(),
            revision: 2,
            kind: .audio
        )

        let olderTask = Task { @MainActor in
            await fixture.service.importStagedFile(older)
        }
        await validator.waitUntilBlockedValidationStarts()

        let newerResult = await fixture.service.importStagedFile(newer)
        XCTAssertEqual(newerResult, .imported)
        await validator.releaseBlockedValidation()
        let olderResult = await olderTask.value
        XCTAssertEqual(olderResult, .rejected(.staleRevision))

        let saved = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        XCTAssertEqual(saved.revision, 2)
        XCTAssertEqual(saved.transferID, newer.envelope.transferID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rootURL
            .appendingPathComponent(saved.audioRelativePath).path))
        XCTAssertEqual(
            fetch(WatchPendingAcknowledgement.self, fixture.context)
                .filter { $0.errorCode == .staleRevision }.count,
            1
        )
    }

    func testTombstoneRejectsDeletedRevisionAndAllowsNewerRevision() async throws {
        let fixture = try makeFixture()
        fixture.context.insert(WatchDeletionTombstone(
            youtubeID: "tombstone01",
            transferID: UUID(),
            revision: 4
        ))
        try fixture.context.save()

        let stale = try makeStaged(
            videoID: "tombstone01",
            transferID: UUID(),
            revision: 4,
            kind: .audio
        )
        let staleResult = await fixture.service.importStagedFile(stale)
        XCTAssertEqual(staleResult, .rejected(.staleRevision))

        let newer = try makeStaged(
            videoID: "tombstone01",
            transferID: UUID(),
            revision: 5,
            kind: .audio
        )
        let newerResult = await fixture.service.importStagedFile(newer)
        XCTAssertEqual(newerResult, .imported)
        XCTAssertEqual(fetch(WatchSavedAudio.self, fixture.context).first?.revision, 5)
        XCTAssertEqual(fetch(WatchDeletionTombstone.self, fixture.context).first?.revision, 4)
    }

    func testSameRevisionDifferentTransferIsRejected() async throws {
        let fixture = try makeFixture()
        let first = try makeStaged(
            videoID: "conflict001",
            transferID: UUID(),
            revision: 3,
            kind: .audio
        )
        let conflict = try makeStaged(
            videoID: "conflict001",
            transferID: UUID(),
            revision: 3,
            kind: .audio
        )
        let firstResult = await fixture.service.importStagedFile(first)
        let conflictResult = await fixture.service.importStagedFile(conflict)
        XCTAssertEqual(firstResult, .imported)
        XCTAssertEqual(conflictResult, .rejected(.staleRevision))
        XCTAssertEqual(fetch(WatchSavedAudio.self, fixture.context).first?.transferID, first.envelope.transferID)
    }

    func testCapacityFailurePreservesExistingRevisionAndFile() async throws {
        let fixture = try makeFixture()
        let first = try makeStaged(
            videoID: "capacity001",
            transferID: UUID(),
            revision: 1,
            kind: .audio
        )
        let firstResult = await fixture.service.importStagedFile(first)
        XCTAssertEqual(firstResult, .imported)
        let existing = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        let existingURL = fixture.rootURL.appendingPathComponent(existing.audioRelativePath)

        let rejectingService = WatchAudioLibraryService(
            modelContext: fixture.context,
            validator: PassthroughAudioValidator(),
            capacityChecker: RejectingCapacityChecker(),
            rootURL: fixture.rootURL,
            minimumCapacityReserve: 0
        )
        let replacement = try makeStaged(
            videoID: "capacity001",
            transferID: UUID(),
            revision: 2,
            kind: .audio
        )
        let replacementResult = await rejectingService.importStagedFile(replacement)
        XCTAssertEqual(replacementResult, .rejected(.capacityInsufficient))

        let retained = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        XCTAssertEqual(retained.revision, 1)
        XCTAssertEqual(retained.transferID, first.envelope.transferID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingURL.path))
        XCTAssertEqual(
            fetch(WatchPendingAcknowledgement.self, fixture.context)
                .filter { $0.errorCode == .capacityInsufficient }.count,
            1
        )
    }

    func testArtworkCapacityFailureIsDiscardedWithoutFailureAcknowledgement() async throws {
        let fixture = try makeFixture(capacityChecker: RejectingCapacityChecker())
        let artwork = try makeStaged(
            videoID: "artcapacity",
            transferID: UUID(),
            revision: 1,
            kind: .artwork
        )

        let result = await fixture.service.importStagedFile(artwork)

        XCTAssertEqual(result, .artworkDiscarded(.capacityInsufficient))
        XCTAssertTrue(fetch(WatchPendingAcknowledgement.self, fixture.context).isEmpty)
        XCTAssertTrue(fetch(WatchSavedAudio.self, fixture.context).isEmpty)
    }

    func testArtworkPersistenceFailureKeepsAudioAndEmitsNoFailedAcknowledgement() async throws {
        let fixture = try makeFixture()
        let transferID = UUID()
        let audio = try makeStaged(
            videoID: "artpersist1",
            transferID: transferID,
            revision: 1,
            kind: .audio
        )
        let audioResult = await fixture.service.importStagedFile(audio)
        XCTAssertEqual(audioResult, .imported)
        let acknowledgementCount = fetch(WatchPendingAcknowledgement.self, fixture.context).count
        let saveController = SaveFailureController(failures: 1)
        let failingService = WatchAudioLibraryService(
            modelContext: fixture.context,
            validator: PassthroughAudioValidator(),
            capacityChecker: AllowingCapacityChecker(),
            rootURL: fixture.rootURL,
            minimumCapacityReserve: 0,
            saveChanges: { try saveController.save($0) }
        )
        let artwork = try makeStaged(
            videoID: "artpersist1",
            transferID: transferID,
            revision: 1,
            kind: .artwork
        )

        let result = await failingService.importStagedFile(artwork)

        XCTAssertEqual(result, .artworkDiscarded(.persistenceFailure))
        let saved = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        XCTAssertNil(saved.thumbnailRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.rootURL.appendingPathComponent(saved.audioRelativePath).path
        ))
        XCTAssertEqual(
            fetch(WatchPendingAcknowledgement.self, fixture.context).count,
            acknowledgementCount
        )
    }

    func testPendingArtworkCopyFailureStillImportsAudioWithoutArtwork() async throws {
        let fixture = try makeFixture()
        let transferID = UUID()
        let artwork = try makeStaged(
            videoID: "artcopyfail",
            transferID: transferID,
            revision: 1,
            kind: .artwork
        )
        let artworkResult = await fixture.service.importStagedFile(artwork)
        XCTAssertEqual(artworkResult, .artworkPending)
        let blockedArtworkURL = fixture.rootURL
            .appendingPathComponent("Artwork/\(transferID.uuidString).jpg", isDirectory: true)
        try FileManager.default.createDirectory(
            at: blockedArtworkURL,
            withIntermediateDirectories: true
        )
        let audio = try makeStaged(
            videoID: "artcopyfail",
            transferID: transferID,
            revision: 1,
            kind: .audio
        )

        let result = await fixture.service.importStagedFile(audio)

        XCTAssertEqual(result, .imported)
        let saved = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        XCTAssertNil(saved.thumbnailRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.rootURL.appendingPathComponent(saved.audioRelativePath).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.rootURL
                .appendingPathComponent("PendingArtwork/\(transferID.uuidString).jpg").path
        ))
        let acknowledgements = fetch(WatchPendingAcknowledgement.self, fixture.context)
            .filter { $0.transferID == transferID }
        XCTAssertEqual(acknowledgements.count, 1)
        XCTAssertEqual(acknowledgements.first?.outcome, .imported)
    }

    func testArtworkMayArriveBeforeOrAfterAudio() async throws {
        let fixture = try makeFixture()

        let firstTransferID = UUID()
        let artworkFirst = try makeStaged(
            videoID: "artorder001",
            transferID: firstTransferID,
            revision: 1,
            kind: .artwork
        )
        let artworkFirstResult = await fixture.service.importStagedFile(artworkFirst)
        XCTAssertEqual(artworkFirstResult, .artworkPending)
        let firstAudio = try makeStaged(
            videoID: "artorder001",
            transferID: firstTransferID,
            revision: 1,
            kind: .audio
        )
        let firstAudioResult = await fixture.service.importStagedFile(firstAudio)
        XCTAssertEqual(firstAudioResult, .imported)
        let firstSaved = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context)
            .first { $0.youtubeID == "artorder001" })
        XCTAssertEqual(firstSaved.thumbnailRelativePath, "Artwork/\(firstTransferID.uuidString).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rootURL
            .appendingPathComponent(firstSaved.thumbnailRelativePath!).path))

        let secondTransferID = UUID()
        let audioFirst = try makeStaged(
            videoID: "artorder002",
            transferID: secondTransferID,
            revision: 1,
            kind: .audio
        )
        let audioFirstResult = await fixture.service.importStagedFile(audioFirst)
        XCTAssertEqual(audioFirstResult, .imported)
        let artworkLast = try makeStaged(
            videoID: "artorder002",
            transferID: secondTransferID,
            revision: 1,
            kind: .artwork
        )
        let artworkLastResult = await fixture.service.importStagedFile(artworkLast)
        XCTAssertEqual(artworkLastResult, .artworkAttached)
        let secondSaved = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context)
            .first { $0.youtubeID == "artorder002" })
        XCTAssertEqual(secondSaved.thumbnailRelativePath, "Artwork/\(secondTransferID.uuidString).jpg")
    }

    func testDeleteCommitsTombstoneAcknowledgementAndRemovesFiles() async throws {
        let fixture = try makeFixture()
        let transferID = UUID()
        let audio = try makeStaged(
            videoID: "deletion001",
            transferID: transferID,
            revision: 1,
            kind: .audio
        )
        let audioResult = await fixture.service.importStagedFile(audio)
        XCTAssertEqual(audioResult, .imported)
        let audioURL = fixture.rootURL
            .appendingPathComponent("Audio/\(transferID.uuidString).m4a")

        let commandID = UUID()
        let command = WatchLibraryCommand(
            commandID: commandID,
            kind: .delete,
            youtubeID: "deletion001",
            revision: 2
        )
        XCTAssertEqual(fixture.service.delete(command), .deleted)

        XCTAssertTrue(fetch(WatchSavedAudio.self, fixture.context).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        let tombstone = try XCTUnwrap(fetch(WatchDeletionTombstone.self, fixture.context).first)
        XCTAssertEqual(tombstone.transferID, commandID)
        XCTAssertEqual(tombstone.revision, 2)
        XCTAssertTrue(fetch(WatchPendingAcknowledgement.self, fixture.context).contains {
            $0.transferID == commandID && $0.outcome == .deleted
        })

        let stale = try makeStaged(
            videoID: "deletion001",
            transferID: transferID,
            revision: 1,
            kind: .audio
        )
        let staleResult = await fixture.service.importStagedFile(stale)
        XCTAssertEqual(staleResult, .rejected(.staleRevision))
    }

    func testDeleteRemovesArtworkThatArrivedBeforeItsAudio() async throws {
        let fixture = try makeFixture()
        let transferID = UUID()
        let artwork = try makeStaged(
            videoID: "deletion002",
            transferID: transferID,
            revision: 1,
            kind: .artwork
        )
        let artworkResult = await fixture.service.importStagedFile(artwork)
        XCTAssertEqual(artworkResult, .artworkPending)
        let pendingURL = fixture.rootURL
            .appendingPathComponent("PendingArtwork/\(transferID.uuidString).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path))

        let result = fixture.service.delete(WatchLibraryCommand(
            commandID: UUID(),
            kind: .delete,
            youtubeID: "deletion002",
            revision: 2
        ))

        XCTAssertEqual(result, .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pendingURL.deletingPathExtension().appendingPathExtension("json").path
        ))
    }

    func testDeletePersistenceFailureKeepsAudioAndSignalsRetry() async throws {
        let fixture = try makeFixture()
        let transferID = UUID()
        let audio = try makeStaged(
            videoID: "deletefail1",
            transferID: transferID,
            revision: 1,
            kind: .audio
        )
        let importResult = await fixture.service.importStagedFile(audio)
        XCTAssertEqual(importResult, .imported)
        let audioURL = fixture.rootURL
            .appendingPathComponent("Audio/\(transferID.uuidString).m4a")
        let saveController = SaveFailureController(failures: 1)
        let failingService = WatchAudioLibraryService(
            modelContext: fixture.context,
            validator: PassthroughAudioValidator(),
            capacityChecker: AllowingCapacityChecker(),
            rootURL: fixture.rootURL,
            minimumCapacityReserve: 0,
            saveChanges: { try saveController.save($0) }
        )

        let result = failingService.delete(WatchLibraryCommand(
            commandID: UUID(),
            kind: .delete,
            youtubeID: "deletefail1",
            revision: 2
        ))

        XCTAssertEqual(result, .persistenceFailed)
        XCTAssertEqual(fetch(WatchSavedAudio.self, fixture.context).first?.transferID, transferID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(fetch(WatchDeletionTombstone.self, fixture.context).isEmpty)
    }

    func testSaveFailurePreservesExistingAudioAndPersistsTerminalFailure() async throws {
        let fixture = try makeFixture()
        let original = try makeStaged(
            videoID: "savefailure1",
            transferID: UUID(),
            revision: 1,
            kind: .audio
        )
        let originalResult = await fixture.service.importStagedFile(original)
        XCTAssertEqual(originalResult, .imported)
        let originalModel = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        let originalURL = fixture.rootURL.appendingPathComponent(originalModel.audioRelativePath)

        let replacementID = UUID()
        let pendingArtwork = try makeStaged(
            videoID: "savefailure1",
            transferID: replacementID,
            revision: 2,
            kind: .artwork
        )
        let artworkResult = await fixture.service.importStagedFile(pendingArtwork)
        XCTAssertEqual(artworkResult, .artworkPending)

        let saveController = SaveFailureController(failures: 1)
        let failingService = WatchAudioLibraryService(
            modelContext: fixture.context,
            validator: PassthroughAudioValidator(),
            capacityChecker: AllowingCapacityChecker(),
            rootURL: fixture.rootURL,
            minimumCapacityReserve: 0,
            saveChanges: { try saveController.save($0) }
        )
        let replacement = try makeStaged(
            videoID: "savefailure1",
            transferID: replacementID,
            revision: 2,
            kind: .audio
        )

        let result = await failingService.importStagedFile(replacement)

        XCTAssertEqual(result, .rejected(.persistenceFailure))
        let retained = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        XCTAssertEqual(retained.transferID, original.envelope.transferID)
        XCTAssertEqual(retained.revision, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL
            .appendingPathComponent("Audio/\(replacementID.uuidString).m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.receiptDirectoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL
            .appendingPathComponent("PendingArtwork/\(replacementID.uuidString).jpg").path))
        XCTAssertTrue(try failingService.pendingAcknowledgements().contains {
            $0.transferID == replacementID && $0.errorCode == .persistenceFailure
        })
    }

    func testOutboxSaveFailureRestoresReceiptAndCorrectArtworkSidecar() async throws {
        let fixture = try makeFixture()
        let original = try makeStaged(
            videoID: "savefailure2",
            transferID: UUID(),
            revision: 1,
            kind: .audio
        )
        let originalResult = await fixture.service.importStagedFile(original)
        XCTAssertEqual(originalResult, .imported)
        let originalModel = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        let originalURL = fixture.rootURL.appendingPathComponent(originalModel.audioRelativePath)

        let replacementID = UUID()
        let pendingArtwork = try makeStaged(
            videoID: "savefailure2",
            transferID: replacementID,
            revision: 2,
            kind: .artwork
        )
        let artworkResult = await fixture.service.importStagedFile(pendingArtwork)
        XCTAssertEqual(artworkResult, .artworkPending)

        let saveController = SaveFailureController(failures: 2)
        let failingService = WatchAudioLibraryService(
            modelContext: fixture.context,
            validator: PassthroughAudioValidator(),
            capacityChecker: AllowingCapacityChecker(),
            rootURL: fixture.rootURL,
            minimumCapacityReserve: 0,
            saveChanges: { try saveController.save($0) }
        )
        let replacement = try makeStaged(
            videoID: "savefailure2",
            transferID: replacementID,
            revision: 2,
            kind: .audio
        )

        let result = await failingService.importStagedFile(replacement)

        XCTAssertEqual(result, .persistenceFailed)
        let retained = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        XCTAssertEqual(retained.transferID, original.envelope.transferID)
        XCTAssertEqual(retained.revision, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL
            .appendingPathComponent("Audio/\(replacementID.uuidString).m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.receiptDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.fileURL.path))
        XCTAssertFalse(try failingService.pendingAcknowledgements().contains {
            $0.transferID == replacementID && $0.errorCode == .persistenceFailure
        })

        let sidecarURL = fixture.rootURL
            .appendingPathComponent("PendingArtwork/\(replacementID.uuidString).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let sidecar = try decoder.decode(
            WatchTransferEnvelope.self,
            from: Data(contentsOf: sidecarURL)
        )
        XCTAssertEqual(sidecar.fileKind, .artwork)
        XCTAssertEqual(sidecar.transferID, replacementID)
    }

    func testReceiptPayloadRemainsAvailableUntilSwiftDataCommit() async throws {
        let fixture = try makeFixture()
        let staged = try makeStaged(
            videoID: "crashsafe01",
            transferID: UUID(),
            revision: 1,
            kind: .audio
        )
        var receiptWasAvailableDuringCommit = false
        let service = WatchAudioLibraryService(
            modelContext: fixture.context,
            validator: PassthroughAudioValidator(),
            capacityChecker: AllowingCapacityChecker(),
            rootURL: fixture.rootURL,
            minimumCapacityReserve: 0,
            saveChanges: { context in
                receiptWasAvailableDuringCommit = FileManager.default.fileExists(
                    atPath: staged.fileURL.path
                )
                try context.save()
            }
        )

        let result = await service.importStagedFile(staged)
        XCTAssertEqual(result, .imported)
        XCTAssertTrue(receiptWasAvailableDuringCommit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.receiptDirectoryURL.path))
    }

    func testStartupCleanupRemovesOrphansAndExpiredPendingArtwork() async throws {
        let fixture = try makeFixture(pendingArtworkTTL: 10)
        let saved = try makeStaged(
            videoID: "cleanup0001",
            transferID: UUID(),
            revision: 1,
            kind: .audio
        )
        let savedResult = await fixture.service.importStagedFile(saved)
        XCTAssertEqual(savedResult, .imported)

        let orphanAudio = fixture.rootURL.appendingPathComponent("Audio/orphan.m4a")
        try Data([1]).write(to: orphanAudio)
        let pending = try makeStaged(
            videoID: "cleanup0002",
            transferID: UUID(),
            revision: 1,
            kind: .artwork
        )
        let pendingResult = await fixture.service.importStagedFile(pending)
        XCTAssertEqual(pendingResult, .artworkPending)
        let pendingURL = fixture.rootURL
            .appendingPathComponent("PendingArtwork/\(pending.envelope.transferID.uuidString).jpg")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: pendingURL.path
        )

        try fixture.service.cleanupOnStartup(now: Date(timeIntervalSince1970: 100))

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        let retained = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rootURL
            .appendingPathComponent(retained.audioRelativePath).path))
    }

    private func makeFixture(
        validator: any WatchAudioValidating = PassthroughAudioValidator(),
        capacityChecker: any WatchCapacityChecking = AllowingCapacityChecker(),
        pendingArtworkTTL: TimeInterval = 24 * 60 * 60
    ) throws -> Fixture {
        let container = try ModelContainer(
            for: WatchSavedAudio.self,
            WatchDeletionTombstone.self,
            WatchPendingAcknowledgement.self,
            WatchLibraryMetadata.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let rootURL = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = WatchAudioLibraryService(
            modelContext: container.mainContext,
            validator: validator,
            capacityChecker: capacityChecker,
            rootURL: rootURL,
            minimumCapacityReserve: 0,
            pendingArtworkTTL: pendingArtworkTTL
        )
        return Fixture(
            container: container,
            context: container.mainContext,
            rootURL: rootURL,
            service: service
        )
    }

    private func makeStaged(
        videoID: String,
        transferID: UUID,
        revision: Int64,
        kind: WatchTransferFileKind
    ) throws -> StagedWatchTransferFile {
        let receiptURL = temporaryRoot
            .appendingPathComponent("receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: true)
        let fileURL = receiptURL.appendingPathComponent(kind == .audio ? "payload.m4a" : "payload.jpg")
        try Data(repeating: kind == .audio ? 0x41 : 0x42, count: 64).write(to: fileURL)
        let envelope = WatchTransferEnvelope(
            transferID: transferID,
            revision: revision,
            fileKind: kind,
            youtubeID: videoID,
            title: "Title \(videoID)",
            channel: "Channel",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            viewCount: 42,
            duration: 120,
            fileSize: 64,
            playbackPosition: 20
        )
        return StagedWatchTransferFile(
            envelope: envelope,
            fileURL: fileURL,
            receiptDirectoryURL: receiptURL
        )
    }

    private func fetch<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private var nilUUID: UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}

@MainActor
private struct Fixture {
    let container: ModelContainer
    let context: ModelContext
    let rootURL: URL
    let service: WatchAudioLibraryService
}

@MainActor
private final class SaveFailureController {
    private var failuresRemaining: Int

    init(failures: Int) {
        failuresRemaining = failures
    }

    func save(_ context: ModelContext) throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw SaveFailure.forced
        }
        try context.save()
    }
}

private enum SaveFailure: Error {
    case forced
}

private struct PassthroughAudioValidator: WatchAudioValidating {
    func validate(
        fileURL: URL,
        envelope: WatchTransferEnvelope
    ) async throws -> ValidatedWatchAudio {
        let size = Int64(try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return ValidatedWatchAudio(actualFileSize: size, actualDuration: envelope.duration)
    }
}

private actor BlockingRevisionValidator: WatchAudioValidating {
    private let blockedRevision: Int64
    private var didStart = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(blockedRevision: Int64) {
        self.blockedRevision = blockedRevision
    }

    func validate(
        fileURL: URL,
        envelope: WatchTransferEnvelope
    ) async throws -> ValidatedWatchAudio {
        if envelope.revision == blockedRevision {
            didStart = true
            await withCheckedContinuation { continuation = $0 }
        }
        let size = Int64(try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return ValidatedWatchAudio(actualFileSize: size, actualDuration: envelope.duration)
    }

    func waitUntilBlockedValidationStarts() async {
        while !didStart { await Task.yield() }
    }

    func releaseBlockedValidation() {
        continuation?.resume()
        continuation = nil
    }
}

private struct AllowingCapacityChecker: WatchCapacityChecking {
    func ensureImportCapacity(
        at libraryURL: URL,
        stagedFileSize: Int64,
        minimumReserve: Int64
    ) async throws {}
}

private struct RejectingCapacityChecker: WatchCapacityChecking {
    func ensureImportCapacity(
        at libraryURL: URL,
        stagedFileSize: Int64,
        minimumReserve: Int64
    ) async throws {
        throw WatchCapacityError.insufficientStorage(requiredReserve: minimumReserve, available: 0)
    }
}
