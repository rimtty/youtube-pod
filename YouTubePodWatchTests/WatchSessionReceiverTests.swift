import Foundation
import SwiftData
import XCTest
@testable import YouTubePodWatch

@MainActor
final class WatchSessionReceiverTests: XCTestCase {
    nonisolated(unsafe) private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSessionReceiverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
        temporaryRoot = nil
    }

    func testStartRecoversReceiptImportsAudioFlushesAckAndPublishesInventory() async throws {
        let fixture = try makeFixture()
        let transferID = UUID()
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver001",
            transferID: transferID,
            revision: 1
        )

        fixture.receiver.start()

        await waitUntil {
            fixture.peer.acknowledgements.count == 1
                && fixture.peer.inventories.last?.entries.count == 1
        }

        let saved = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)
        XCTAssertEqual(saved.youtubeID, "receiver001")
        XCTAssertEqual(saved.transferID, transferID)
        XCTAssertEqual(fixture.peer.acknowledgements.first?.outcome, .imported)
        XCTAssertTrue(try fixture.service.pendingAcknowledgements().isEmpty)
        XCTAssertTrue(try fixture.stager.listStagedFiles().isEmpty)
    }

    func testSuccessfulAudioImportInvalidatesStalePlaybackQueueEntry() async throws {
        var invalidatedVideoIDs: [String] = []
        let fixture = try makeFixture(
            invalidatePlaybackItem: { invalidatedVideoIDs.append($0) }
        )
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver008",
            transferID: UUID(),
            revision: 2
        )

        fixture.receiver.start()
        await waitUntil { fetch(WatchSavedAudio.self, fixture.context).count == 1 }

        XCTAssertEqual(invalidatedVideoIDs, ["receiver008"])
    }

    func testUnsentAcknowledgementRemainsDurableAndRetriesOnActivation() async throws {
        let fixture = try makeFixture()
        fixture.peer.shouldFailAcknowledgements = true
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver002",
            transferID: UUID(),
            revision: 1
        )

        fixture.receiver.start()
        await waitUntil {
            (try? fixture.service.pendingAcknowledgements().first?.attemptCount) == 1
        }
        XCTAssertTrue(fixture.peer.acknowledgements.isEmpty)

        fixture.peer.shouldFailAcknowledgements = false
        fixture.peer.emitActivation()
        await waitUntil {
            fixture.peer.acknowledgements.count == 1
                && (try? fixture.service.pendingAcknowledgements().isEmpty) == true
        }
        XCTAssertNil(fixture.receiver.lastErrorMessage)
    }

    func testDeletionCommandRemovesAudioAndPublishesDeletedAcknowledgement() async throws {
        let fixture = try makeFixture()
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver003",
            transferID: UUID(),
            revision: 1
        )
        fixture.receiver.start()
        await waitUntil { fixture.peer.acknowledgements.contains { $0.outcome == .imported } }

        let command = WatchLibraryCommand(
            commandID: UUID(),
            kind: .delete,
            youtubeID: "receiver003",
            revision: 2
        )
        let stagedCommand = try fixture.stager.stageCommand(userInfo: command.userInfo())
        fixture.peer.emitCommand(stagedCommand)

        await waitUntil {
            fixture.peer.acknowledgements.contains { $0.outcome == .deleted }
                && fetch(WatchSavedAudio.self, fixture.context).isEmpty
        }
        XCTAssertTrue(fixture.peer.inventories.last?.entries.isEmpty == true)
        XCTAssertEqual(fetch(WatchDeletionTombstone.self, fixture.context).first?.revision, 2)
    }

    func testWatchInitiatedDeletionPublishesAcknowledgementAndEmptyInventory() async throws {
        let fixture = try makeFixture()
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver006",
            transferID: UUID(),
            revision: 3
        )
        fixture.receiver.start()
        await waitUntil { fetch(WatchSavedAudio.self, fixture.context).count == 1 }
        let saved = try XCTUnwrap(fetch(WatchSavedAudio.self, fixture.context).first)

        let result = await fixture.receiver.deleteFromWatch(saved)

        XCTAssertEqual(result, .deleted)
        XCTAssertTrue(fetch(WatchSavedAudio.self, fixture.context).isEmpty)
        XCTAssertEqual(fetch(WatchDeletionTombstone.self, fixture.context).first?.revision, 3)
        XCTAssertTrue(fixture.peer.acknowledgements.contains {
            $0.outcome == .deleted
                && $0.transferID == saved.transferID
                && $0.revision == saved.revision
        })
        XCTAssertTrue(fixture.peer.inventories.last?.entries.isEmpty == true)
    }

    func testIncomingDeletionStopsPlaybackBeforeRemovingCurrentFile() async throws {
        var stoppedVideoIDs: [String] = []
        let fixture = try makeFixture(invalidatePlaybackItem: { stoppedVideoIDs.append($0) })
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver007",
            transferID: UUID(),
            revision: 1
        )
        fixture.receiver.start()
        await waitUntil { fetch(WatchSavedAudio.self, fixture.context).count == 1 }
        stoppedVideoIDs.removeAll()
        let command = WatchLibraryCommand(
            commandID: UUID(),
            kind: .delete,
            youtubeID: "receiver007",
            revision: 2
        )
        let stagedCommand = try fixture.stager.stageCommand(userInfo: command.userInfo())

        fixture.peer.emitCommand(stagedCommand)
        await waitUntil { fetch(WatchSavedAudio.self, fixture.context).isEmpty }

        XCTAssertEqual(stoppedVideoIDs, ["receiver007"])
    }

    func testInvalidOutboxRowDoesNotBlockLaterAcknowledgementOrInventory() async throws {
        let fixture = try makeFixture()
        let poison = WatchPendingAcknowledgement(
            transferID: UUID(),
            revision: 1,
            youtubeID: "receiver004",
            outcome: .failed
        )
        poison.outcomeRawValue = "unknown-future-outcome"
        fixture.context.insert(poison)
        fixture.context.insert(WatchPendingAcknowledgement(
            transferID: UUID(),
            revision: 1,
            youtubeID: "receiver005",
            outcome: .imported
        ))
        try fixture.context.save()

        fixture.receiver.start()
        await waitUntil {
            fixture.peer.acknowledgements.count == 1
                && fixture.peer.inventories.count == 1
        }

        XCTAssertEqual(fixture.peer.acknowledgements.first?.youtubeID, "receiver005")
        XCTAssertTrue(try fixture.service.pendingAcknowledgements().isEmpty)
    }

    private func makeFixture(
        invalidatePlaybackItem: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) throws -> ReceiverFixture {
        let container = try ModelContainer(
            for: WatchSavedAudio.self,
            WatchDeletionTombstone.self,
            WatchPendingAcknowledgement.self,
            WatchLibraryMetadata.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let inboxURL = temporaryRoot.appendingPathComponent("Inbox", isDirectory: true)
        let libraryURL = temporaryRoot.appendingPathComponent("Library", isDirectory: true)
        let stager = WatchIncomingFileStager(rootDirectoryURL: inboxURL)
        let service = WatchAudioLibraryService(
            modelContext: container.mainContext,
            validator: ReceiverAudioValidator(),
            capacityChecker: ReceiverCapacityChecker(),
            rootURL: libraryURL,
            minimumCapacityReserve: 0
        )
        let peer = ReceiverPeerStub()
        let receiver = WatchSessionReceiver(
            stager: stager,
            library: service,
            peer: peer,
            availableCapacity: { 123_456 },
            invalidatePlaybackItem: invalidatePlaybackItem
        )
        return ReceiverFixture(
            container: container,
            context: container.mainContext,
            stager: stager,
            service: service,
            peer: peer,
            receiver: receiver
        )
    }

    private func stageAudio(
        with stager: WatchIncomingFileStager,
        videoID: String,
        transferID: UUID,
        revision: Int64
    ) throws -> StagedWatchTransferFile {
        let sourceURL = temporaryRoot.appendingPathComponent("source-\(UUID().uuidString).m4a")
        let data = Data(repeating: 0x41, count: 64)
        try data.write(to: sourceURL)
        let envelope = WatchTransferEnvelope(
            transferID: transferID,
            revision: revision,
            fileKind: .audio,
            youtubeID: videoID,
            title: "Receiver title",
            channel: "Receiver channel",
            publishedAt: nil,
            viewCount: 12,
            duration: 90,
            fileSize: Int64(data.count),
            playbackPosition: 9
        )
        return try stager.stage(fileAt: sourceURL, metadata: envelope.metadata())
    }

    private func fetch<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition(), Date.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private struct ReceiverFixture {
    let container: ModelContainer
    let context: ModelContext
    let stager: WatchIncomingFileStager
    let service: WatchAudioLibraryService
    let peer: ReceiverPeerStub
    let receiver: WatchSessionReceiver
}

private struct ReceiverAudioValidator: WatchAudioValidating {
    func validate(
        fileURL: URL,
        envelope: WatchTransferEnvelope
    ) async throws -> ValidatedWatchAudio {
        let size = Int64(try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return ValidatedWatchAudio(actualFileSize: size, actualDuration: envelope.duration)
    }
}

private struct ReceiverCapacityChecker: WatchCapacityChecking {
    func ensureImportCapacity(
        at libraryURL: URL,
        stagedFileSize: Int64,
        minimumReserve: Int64
    ) async throws {}
}

@MainActor
private final class ReceiverPeerStub: WatchPeerSyncing {
    var stagedFileHandler: (@MainActor @Sendable (StagedWatchTransferFile) -> Void)?
    var commandHandler: (@MainActor @Sendable (StagedWatchLibraryCommand) -> Void)?
    var activationHandler: (@MainActor @Sendable () -> Void)?

    var shouldFailAcknowledgements = false
    private(set) var activationCount = 0
    private(set) var acknowledgements: [WatchTransferAcknowledgement] = []
    private(set) var inventories: [WatchInventorySnapshot] = []

    func activate() {
        activationCount += 1
    }

    func enqueueAcknowledgement(_ acknowledgement: WatchTransferAcknowledgement) throws {
        if shouldFailAcknowledgements {
            throw WatchPeerSyncError.sessionUnavailable
        }
        acknowledgements.append(acknowledgement)
    }

    func publishInventory(_ inventory: WatchInventorySnapshot) throws {
        inventories.append(inventory)
    }

    func emitActivation() {
        activationHandler?()
    }

    func emitCommand(_ command: StagedWatchLibraryCommand) {
        commandHandler?(command)
    }
}
