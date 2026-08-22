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

    func testForegroundResumeReactivatesPeerAndSynchronizesDurableInbox() async throws {
        let fixture = try makeFixture()
        fixture.receiver.start()
        await fixture.receiver.synchronizeNow()
        XCTAssertEqual(fixture.peer.activationCount, 1)

        let transferID = UUID()
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver017",
            transferID: transferID,
            revision: 1
        )

        await fixture.receiver.resumeFromForeground()

        XCTAssertEqual(fixture.peer.activationCount, 2)
        XCTAssertEqual(fetch(WatchSavedAudio.self, fixture.context).first?.youtubeID, "receiver017")
        XCTAssertEqual(fixture.peer.acknowledgements.last?.transferID, transferID)
        XCTAssertTrue(try fixture.stager.listStagedFiles().isEmpty)
    }

    func testEachSynchronizationPassRereadsRequestAndPublishesCorrelation() async throws {
        let fixture = try makeFixture()
        let first = WatchInventoryRequest(requestID: UUID(), requestedAt: .now)
        let second = WatchInventoryRequest(requestID: UUID(), requestedAt: .now)
        fixture.peer.inventoryRequest = first

        await fixture.receiver.synchronizeNow()

        XCTAssertEqual(fixture.peer.inventories.last?.respondingToRequestID, first.requestID)

        fixture.peer.inventoryRequest = second
        await fixture.receiver.synchronizeNow()

        XCTAssertEqual(fixture.peer.inventories.last?.respondingToRequestID, second.requestID)
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

    func testArtworkCapacityFailureDoesNotBlockAudioImportOrEmitFailedAcknowledgement() async throws {
        let fixture = try makeFixture(
            capacityChecker: SelectiveReceiverCapacityChecker(rejectedSize: 8)
        )
        let transferID = UUID()
        _ = try stageArtwork(
            with: fixture.stager,
            videoID: "receiver009",
            transferID: transferID,
            revision: 1
        )

        fixture.receiver.start()
        await waitUntil { (try? fixture.stager.listStagedFiles().isEmpty) == true }
        XCTAssertTrue(fixture.peer.acknowledgements.isEmpty)

        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver009",
            transferID: transferID,
            revision: 1
        )
        await fixture.receiver.synchronizeNow()

        XCTAssertEqual(fixture.peer.acknowledgements.count, 1)
        XCTAssertEqual(fixture.peer.acknowledgements.first?.outcome, .imported)
        XCTAssertEqual(fixture.peer.inventories.last?.entries.count, 1)
        XCTAssertNil(fetch(WatchSavedAudio.self, fixture.context).first?.thumbnailRelativePath)
        XCTAssertTrue(try fixture.stager.listStagedFiles().isEmpty)
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

    func testBackgroundTaskWaitsForContentDrainBeforeReturning() async throws {
        let gate = ReceiverAsyncGate()
        let fixture = try makeFixture()
        fixture.peer.waitUntilContentDrainedHandler = {
            await gate.waitOnce()
        }
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver010",
            transferID: UUID(),
            revision: 1
        )
        var hasReturned = false

        let task = Task { @MainActor in
            await fixture.receiver.handleConnectivityBackgroundTask()
            hasReturned = true
        }
        await waitUntil { gate.hasWaiter }

        XCTAssertFalse(hasReturned)
        gate.open()
        await task.value

        XCTAssertTrue(hasReturned)
        XCTAssertEqual(fixture.peer.activationWaitCount, 1)
        XCTAssertEqual(fixture.peer.contentDrainWaitCount, 2)
        XCTAssertEqual(fetch(WatchSavedAudio.self, fixture.context).count, 1)
        XCTAssertTrue(try fixture.stager.listStagedFiles().isEmpty)
    }

    func testSecondDrainImportsReceiptBeforeCallbackNotificationRuns() async throws {
        let fixture = try makeFixture()
        fixture.peer.waitUntilContentDrainedHandler = {
            guard fixture.peer.contentDrainWaitCount == 2 else { return }
            _ = try self.stageAudio(
                with: fixture.stager,
                videoID: "receiver016",
                transferID: UUID(),
                revision: 1
            )
        }

        await fixture.receiver.handleConnectivityBackgroundTask()

        XCTAssertEqual(
            fetch(WatchSavedAudio.self, fixture.context).map(\.youtubeID),
            ["receiver016"]
        )
        XCTAssertTrue(try fixture.stager.listStagedFiles().isEmpty)
        XCTAssertEqual(fixture.peer.contentDrainWaitCount, 2)
    }

    func testReceiptArrivingDuringImportRunsInSharedSecondPass() async throws {
        let validator = SuspendingReceiverAudioValidator()
        let fixture = try makeFixture(validator: validator)
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver011",
            transferID: UUID(),
            revision: 1
        )

        fixture.receiver.start()
        await validator.waitUntilFirstValidationStarts()

        let second = try stageAudio(
            with: fixture.stager,
            videoID: "receiver012",
            transferID: UUID(),
            revision: 1
        )
        fixture.peer.emitStagedFile(second)
        await validator.releaseFirstValidation()
        await fixture.receiver.waitUntilSynchronizationIdle()

        XCTAssertEqual(
            Set(fetch(WatchSavedAudio.self, fixture.context).map(\.youtubeID)),
            Set(["receiver011", "receiver012"])
        )
        let validationCount = await validator.validationCount
        XCTAssertEqual(validationCount, 2)
        XCTAssertTrue(try fixture.stager.listStagedFiles().isEmpty)
    }

    func testConcurrentSynchronizationCallersCoalesceIntoOneOperation() async throws {
        let validator = SuspendingReceiverAudioValidator()
        let fixture = try makeFixture(validator: validator)
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver014",
            transferID: UUID(),
            revision: 1
        )

        let first = Task { @MainActor in
            await fixture.receiver.synchronizeNow()
        }
        await validator.waitUntilFirstValidationStarts()
        let second = Task { @MainActor in
            await fixture.receiver.synchronizeNow()
        }
        await Task.yield()
        await validator.releaseFirstValidation()
        await first.value
        await second.value

        let validationCount = await validator.validationCount
        XCTAssertEqual(validationCount, 1)
        XCTAssertEqual(
            fetch(WatchSavedAudio.self, fixture.context).map(\.youtubeID),
            ["receiver014"]
        )
        XCTAssertFalse(fixture.receiver.isReceiving)
    }

    func testCancelledBackgroundDrainKeepsDurableReceiptForNextWake() async throws {
        let validator = CancellableReceiverAudioValidator()
        let fixture = try makeFixture(validator: validator)
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver013",
            transferID: UUID(),
            revision: 1
        )

        let task = Task { @MainActor in
            await fixture.receiver.handleConnectivityBackgroundTask()
        }
        await validator.waitUntilValidationStarts()
        task.cancel()
        await task.value
        await fixture.receiver.waitUntilSynchronizationIdle()

        let hasReceipt = try fixture.stager.listStagedFiles()
            .contains { $0.envelope.youtubeID == "receiver013" }
        XCTAssertTrue(hasReceipt)
        XCTAssertTrue(try fixture.service.pendingAcknowledgements().isEmpty)
        XCTAssertFalse(fixture.receiver.isReceiving)

        await fixture.receiver.handleConnectivityBackgroundTask()

        XCTAssertEqual(
            fetch(WatchSavedAudio.self, fixture.context).map(\.youtubeID),
            ["receiver013"]
        )
        XCTAssertTrue(try fixture.stager.listStagedFiles().isEmpty)
        XCTAssertEqual(fixture.peer.acknowledgements.last?.outcome, .imported)
    }

    func testActivationFailureCancelsSynchronizationAndKeepsDurableReceipt() async throws {
        let validator = CancellableReceiverAudioValidator()
        let fixture = try makeFixture(validator: validator)
        fixture.peer.waitForActivationHandler = {
            await validator.waitUntilValidationStarts()
            throw WatchPeerSyncError.activationTimedOut
        }
        _ = try stageAudio(
            with: fixture.stager,
            videoID: "receiver015",
            transferID: UUID(),
            revision: 1
        )

        await fixture.receiver.handleConnectivityBackgroundTask()

        let hasReceipt = try fixture.stager.listStagedFiles()
            .contains { $0.envelope.youtubeID == "receiver015" }
        XCTAssertTrue(hasReceipt)
        XCTAssertFalse(fixture.receiver.isReceiving)
        XCTAssertEqual(
            fixture.receiver.lastErrorMessage,
            WatchPeerSyncError.activationTimedOut.localizedDescription
        )
    }

    private func makeFixture(
        validator: any WatchAudioValidating = ReceiverAudioValidator(),
        capacityChecker: any WatchCapacityChecking = ReceiverCapacityChecker(),
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
            validator: validator,
            capacityChecker: capacityChecker,
            rootURL: libraryURL,
            minimumCapacityReserve: 0
        )
        let peer = ReceiverPeerStub()
        let receiver = WatchSessionReceiver(
            stager: stager,
            library: service,
            peer: peer,
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

    private func stageArtwork(
        with stager: WatchIncomingFileStager,
        videoID: String,
        transferID: UUID,
        revision: Int64
    ) throws -> StagedWatchTransferFile {
        let sourceURL = temporaryRoot.appendingPathComponent("artwork-\(UUID().uuidString).jpg")
        let data = Data(repeating: 0x42, count: 8)
        try data.write(to: sourceURL)
        let envelope = WatchTransferEnvelope(
            transferID: transferID,
            revision: revision,
            fileKind: .artwork,
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

private actor SuspendingReceiverAudioValidator: WatchAudioValidating {
    private var firstValidationStarted = false
    private var firstValidationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstValidationRelease: CheckedContinuation<Void, Never>?
    private(set) var validationCount = 0

    func validate(
        fileURL: URL,
        envelope: WatchTransferEnvelope
    ) async throws -> ValidatedWatchAudio {
        validationCount += 1
        if validationCount == 1 {
            firstValidationStarted = true
            firstValidationStartWaiters.forEach { $0.resume() }
            firstValidationStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                firstValidationRelease = continuation
            }
        }
        let size = Int64(try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return ValidatedWatchAudio(
            actualFileSize: size,
            actualDuration: envelope.duration
        )
    }

    func waitUntilFirstValidationStarts() async {
        if firstValidationStarted { return }
        await withCheckedContinuation { continuation in
            firstValidationStartWaiters.append(continuation)
        }
    }

    func releaseFirstValidation() {
        firstValidationRelease?.resume()
        firstValidationRelease = nil
    }
}

private actor CancellableReceiverAudioValidator: WatchAudioValidating {
    private var validationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var validationCount = 0

    func validate(
        fileURL: URL,
        envelope: WatchTransferEnvelope
    ) async throws -> ValidatedWatchAudio {
        validationCount += 1
        validationStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if validationCount == 1 {
            try await Task.sleep(for: .seconds(3_600))
        }
        return ValidatedWatchAudio(
            actualFileSize: envelope.fileSize,
            actualDuration: envelope.duration
        )
    }

    func waitUntilValidationStarts() async {
        if validationStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private struct ReceiverCapacityChecker: WatchCapacityChecking {
    func ensureImportCapacity(
        at libraryURL: URL,
        stagedFileSize: Int64,
        minimumReserve: Int64
    ) async throws {}
}

private struct SelectiveReceiverCapacityChecker: WatchCapacityChecking {
    let rejectedSize: Int64

    func ensureImportCapacity(
        at libraryURL: URL,
        stagedFileSize: Int64,
        minimumReserve: Int64
    ) async throws {
        if stagedFileSize == rejectedSize {
            throw WatchCapacityError.insufficientStorage(
                requiredReserve: minimumReserve,
                available: 0
            )
        }
    }
}

@MainActor
private final class ReceiverPeerStub: WatchPeerSyncing {
    var stagedFileHandler: (@MainActor @Sendable (StagedWatchTransferFile) -> Void)?
    var commandHandler: (@MainActor @Sendable (StagedWatchLibraryCommand) -> Void)?
    var inventoryRequestHandler: (@MainActor @Sendable (WatchInventoryRequest) -> Void)?
    var activationHandler: (@MainActor @Sendable () -> Void)?
    var hasContentPending = false

    var shouldFailAcknowledgements = false
    var waitForActivationError: (any Error)?
    var waitForActivationHandler: (@MainActor () async throws -> Void)?
    var waitUntilContentDrainedError: (any Error)?
    var waitUntilContentDrainedHandler: (@MainActor () async throws -> Void)?
    private(set) var activationCount = 0
    private(set) var activationWaitCount = 0
    private(set) var contentDrainWaitCount = 0
    private(set) var acknowledgements: [WatchTransferAcknowledgement] = []
    private(set) var inventories: [WatchInventorySnapshot] = []
    var inventoryRequest: WatchInventoryRequest?

    func activate() {
        activationCount += 1
    }

    func waitForActivation() async throws {
        activationWaitCount += 1
        try await waitForActivationHandler?()
        if let waitForActivationError { throw waitForActivationError }
    }

    func waitUntilContentDrained() async throws {
        contentDrainWaitCount += 1
        if let waitUntilContentDrainedError { throw waitUntilContentDrainedError }
        try await waitUntilContentDrainedHandler?()
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

    func currentInventoryRequest() -> WatchInventoryRequest? {
        inventoryRequest
    }

    func emitActivation() {
        activationHandler?()
    }

    func emitCommand(_ command: StagedWatchLibraryCommand) {
        commandHandler?(command)
    }

    func emitStagedFile(_ file: StagedWatchTransferFile) {
        stagedFileHandler?(file)
    }
}

@MainActor
private final class ReceiverAsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasWaiter = false
    private var hasOpened = false

    func waitOnce() async {
        guard !hasOpened else { return }
        hasWaiter = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        hasOpened = true
        continuation?.resume()
        continuation = nil
    }
}
