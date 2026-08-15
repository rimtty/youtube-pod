import SwiftData
import XCTest
@testable import YouTubePod

@MainActor
final class PhoneWatchTransferServiceTests: XCTestCase {
    nonisolated(unsafe) private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneWatchTransferServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
        temporaryRoot = nil
    }

    func testEnqueueCreatesTransferAndSuppressesDuplicateRequest() async throws {
        let fixture = try makeFixture()
        let source = try makeSource(id: "transfer001", artwork: true)

        try await fixture.service.enqueue(source)
        try await fixture.service.enqueue(source)

        XCTAssertEqual(fixture.transport.sent.count, 2)
        let envelopes = fixture.transport.sent.map(\.envelope)
        XCTAssertEqual(Set(envelopes.map(\.fileKind)), [.audio, .artwork])
        XCTAssertEqual(Set(envelopes.map(\.revision)), [1])
        XCTAssertEqual(Set(envelopes.map(\.youtubeID)), [source.youtubeID])

        let record = try XCTUnwrap(fetchRecords(fixture.context).first)
        XCTAssertEqual(record.state, .transferring)
        XCTAssertEqual(record.playbackPosition, source.playbackPosition)
        XCTAssertTrue(record.artworkExpected)
    }

    func testWatchAcknowledgementIsRequiredBeforeTransferBecomesAvailable() async throws {
        let fixture = try makeFixture()
        let source = try makeSource(id: "transfer002", artwork: false)
        try await fixture.service.enqueue(source)
        let envelope = try XCTUnwrap(fixture.transport.sent.first?.envelope)

        fixture.transport.emit(.fileFinished(
            WatchTransferKey(transferID: envelope.transferID, fileKind: .audio),
            nil
        ))
        XCTAssertEqual(fetchRecords(fixture.context).first?.state, .awaitingWatchConfirmation)

        fixture.transport.emit(.acknowledgement(WatchTransferAcknowledgement(
            transferID: envelope.transferID,
            revision: envelope.revision,
            youtubeID: envelope.youtubeID,
            outcome: .imported
        )))

        let record = try XCTUnwrap(fetchRecords(fixture.context).first)
        XCTAssertEqual(record.state, .availableOnWatch)
        XCTAssertNotNil(record.confirmedAt)
        XCTAssertNil(fixture.service.liveProgress[source.youtubeID])
    }

    func testImportedAcknowledgementArrivingBeforeSenderFinishDoesNotStallQueue() async throws {
        let fixture = try makeFixture()
        let firstSource = try makeSource(id: "ackfirst001", artwork: false)
        let secondSource = try makeSource(id: "ackfirst002", artwork: false)
        try await fixture.service.enqueue(firstSource)
        try await fixture.service.enqueue(secondSource)
        let first = try XCTUnwrap(fixture.transport.sent.first?.envelope)

        fixture.transport.emit(.acknowledgement(WatchTransferAcknowledgement(
            transferID: first.transferID,
            revision: first.revision,
            youtubeID: first.youtubeID,
            outcome: .imported
        )))
        XCTAssertEqual(record(firstSource.youtubeID, in: fixture.context)?.state, .transferring)
        XCTAssertEqual(fixture.transport.sent.count, 1)

        fixture.transport.emit(.fileFinished(
            WatchTransferKey(transferID: first.transferID, fileKind: .audio),
            nil
        ))
        try await waitUntil { fixture.transport.sent.count == 2 }

        XCTAssertEqual(record(firstSource.youtubeID, in: fixture.context)?.state, .availableOnWatch)
        XCTAssertEqual(fixture.transport.sent.last?.envelope.youtubeID, secondSource.youtubeID)
    }

    func testFailedAcknowledgementBeforeLateSenderCallbackRemainsFailedAndAdvancesQueue() async throws {
        let fixture = try makeFixture()
        let firstSource = try makeSource(id: "ackfail0001", artwork: false)
        let secondSource = try makeSource(id: "ackfail0002", artwork: false)
        try await fixture.service.enqueue(firstSource)
        try await fixture.service.enqueue(secondSource)
        let first = try XCTUnwrap(fixture.transport.sent.first?.envelope)

        fixture.transport.emit(.acknowledgement(WatchTransferAcknowledgement(
            transferID: first.transferID,
            revision: first.revision,
            youtubeID: first.youtubeID,
            outcome: .failed,
            message: "Watch import failed"
        )))
        try await waitUntil { fixture.transport.sent.count == 2 }
        fixture.transport.emit(.fileFinished(
            WatchTransferKey(transferID: first.transferID, fileKind: .audio),
            nil
        ))

        XCTAssertEqual(record(firstSource.youtubeID, in: fixture.context)?.state, .failed)
        XCTAssertEqual(record(firstSource.youtubeID, in: fixture.context)?.lastErrorCode, "watch-import")
        XCTAssertEqual(fixture.transport.sent.last?.envelope.youtubeID, secondSource.youtubeID)
    }

    func testStaleAcknowledgementCannotCompleteNewerRevision() async throws {
        let fixture = try makeFixture()
        let source = try makeSource(id: "transfer003", artwork: false)
        try await fixture.service.enqueue(source)
        let firstEnvelope = try XCTUnwrap(fixture.transport.sent.first?.envelope)
        fixture.service.cancel(videoID: source.youtubeID)
        try await fixture.service.retry(videoID: source.youtubeID)

        fixture.transport.emit(.acknowledgement(WatchTransferAcknowledgement(
            transferID: firstEnvelope.transferID,
            revision: firstEnvelope.revision,
            youtubeID: firstEnvelope.youtubeID,
            outcome: .imported
        )))

        let record = try XCTUnwrap(fetchRecords(fixture.context).first)
        XCTAssertEqual(record.state, .transferring)
        XCTAssertEqual(record.revision, 2)
        XCTAssertNotEqual(record.transferID, firstEnvelope.transferID)
    }

    func testCancellationRetainsSnapshotForRetryWithNewTransferID() async throws {
        let fixture = try makeFixture()
        let source = try makeSource(id: "transfer004", artwork: false)
        try await fixture.service.enqueue(source)
        let firstTransferID = try XCTUnwrap(fixture.transport.sent.first?.envelope.transferID)

        fixture.service.cancel(videoID: source.youtubeID)
        XCTAssertEqual(fixture.transport.cancelledTransferIDs, [firstTransferID])
        XCTAssertEqual(fetchRecords(fixture.context).first?.state, .failed)

        try await fixture.service.retry(videoID: source.youtubeID)

        let record = try XCTUnwrap(fetchRecords(fixture.context).first)
        XCTAssertEqual(record.state, .transferring)
        XCTAssertEqual(record.revision, 2)
        XCTAssertEqual(record.retryCount, 1)
        XCTAssertNotEqual(record.transferID, firstTransferID)
        XCTAssertEqual(fixture.transport.sent.count, 2)
    }

    func testTransfersAreQueuedSerially() async throws {
        let fixture = try makeFixture()
        try await fixture.service.enqueue(makeSource(id: "transfer005", artwork: false))
        try await fixture.service.enqueue(makeSource(id: "transfer006", artwork: false))
        XCTAssertEqual(fixture.transport.sent.count, 1)

        let first = try XCTUnwrap(fixture.transport.sent.first?.envelope)
        fixture.transport.emit(.fileFinished(
            WatchTransferKey(transferID: first.transferID, fileKind: .audio),
            nil
        ))
        try await waitUntil { fixture.transport.sent.count == 2 }

        XCTAssertEqual(fixture.transport.sent.map(\.envelope.youtubeID), ["transfer005", "transfer006"])
    }

    func testArtworkFailureDoesNotFailCompletedAudioDelivery() async throws {
        let fixture = try makeFixture()
        let source = try makeSource(id: "transfer007", artwork: true)
        try await fixture.service.enqueue(source)
        let transferID = try XCTUnwrap(fixture.transport.sent.first?.envelope.transferID)

        fixture.transport.emit(.fileFinished(
            WatchTransferKey(transferID: transferID, fileKind: .audio),
            nil
        ))
        fixture.transport.emit(.fileFinished(
            WatchTransferKey(transferID: transferID, fileKind: .artwork),
            WatchTransportFailure(code: "artwork-failed", message: "optional", isRetryable: false)
        ))

        let record = try XCTUnwrap(fetchRecords(fixture.context).first)
        XCTAssertEqual(record.state, .awaitingWatchConfirmation)
        XCTAssertEqual(record.lastErrorCode, "artwork.artwork-failed")
        XCTAssertTrue(record.audioDeliveryFinished)
        XCTAssertTrue(record.artworkDeliveryFinished)
    }

    func testProgressFromSecondFileCannotMoveVisibleProgressBackward() async throws {
        let fixture = try makeFixture()
        let source = try makeSource(id: "transfer009", artwork: true)
        try await fixture.service.enqueue(source)
        let transferID = try XCTUnwrap(fixture.transport.sent.first?.envelope.transferID)

        fixture.transport.emit(.progress(
            WatchTransferKey(transferID: transferID, fileKind: .audio),
            0.8
        ))
        fixture.transport.emit(.progress(
            WatchTransferKey(transferID: transferID, fileKind: .artwork),
            0.1
        ))

        XCTAssertEqual(fixture.service.liveProgress[source.youtubeID], 0.8)
        XCTAssertEqual(fetchRecords(fixture.context).first?.lastKnownProgress, 0.8)
    }

    func testRetryableFailuresAutomaticallyRetryAtMostTwice() async throws {
        let fixture = try makeFixture(automaticRetryDelays: [.zero, .zero])
        let source = try makeSource(id: "transfer010", artwork: false)
        try await fixture.service.enqueue(source)

        for expectedCount in 2...3 {
            let current = try XCTUnwrap(fixture.transport.sent.last?.envelope)
            fixture.transport.emit(.fileFinished(
                WatchTransferKey(transferID: current.transferID, fileKind: .audio),
                WatchTransportFailure(code: "temporary", message: "retry", isRetryable: true)
            ))
            try await waitUntil { fixture.transport.sent.count == expectedCount }
        }

        let final = try XCTUnwrap(fixture.transport.sent.last?.envelope)
        fixture.transport.emit(.fileFinished(
            WatchTransferKey(transferID: final.transferID, fileKind: .audio),
            WatchTransportFailure(code: "temporary", message: "stop", isRetryable: true)
        ))
        try await Task.sleep(for: .milliseconds(50))

        let record = try XCTUnwrap(fetchRecords(fixture.context).first)
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.retryCount, 2)
        XCTAssertEqual(fixture.transport.sent.count, 3)
    }

    func testImportedAcknowledgementCancelsScheduledAutomaticRetry() async throws {
        let fixture = try makeFixture(automaticRetryDelays: [.milliseconds(150)])
        let source = try makeSource(id: "ackretry001", artwork: false)
        try await fixture.service.enqueue(source)
        let first = try XCTUnwrap(fixture.transport.sent.first?.envelope)

        fixture.transport.emit(.fileFinished(
            WatchTransferKey(transferID: first.transferID, fileKind: .audio),
            WatchTransportFailure(code: "temporary", message: "retry", isRetryable: true)
        ))
        fixture.transport.emit(.acknowledgement(WatchTransferAcknowledgement(
            transferID: first.transferID,
            revision: first.revision,
            youtubeID: first.youtubeID,
            outcome: .imported
        )))
        try await Task.sleep(for: .milliseconds(220))

        let record = try XCTUnwrap(record(source.youtubeID, in: fixture.context))
        XCTAssertEqual(record.state, .availableOnWatch)
        XCTAssertEqual(record.retryCount, 0)
        XCTAssertEqual(fixture.transport.sent.count, 1)
    }

    func testLateAcknowledgementWhileAutomaticRetryClonesCannotOverwriteConfirmedState() async throws {
        let fixture = try makeFixture(
            automaticRetryDelays: [.zero],
            cloneDelay: .milliseconds(180)
        )
        let source = try makeSource(id: "cloneack001", artwork: false)
        try await fixture.service.enqueue(source)
        let first = try XCTUnwrap(fixture.transport.sent.first?.envelope)

        fixture.transport.emit(.fileFinished(
            WatchTransferKey(transferID: first.transferID, fileKind: .audio),
            WatchTransportFailure(code: "temporary", message: "retry", isRetryable: true)
        ))
        try await waitUntilAsync {
            await fixture.snapshots.hasStartedClone(from: first.transferID)
        }
        fixture.transport.emit(.acknowledgement(WatchTransferAcknowledgement(
            transferID: first.transferID,
            revision: first.revision,
            youtubeID: first.youtubeID,
            outcome: .imported
        )))
        try await Task.sleep(for: .milliseconds(240))

        let record = try XCTUnwrap(record(source.youtubeID, in: fixture.context))
        XCTAssertEqual(record.state, .availableOnWatch)
        XCTAssertEqual(record.transferID, first.transferID)
        XCTAssertEqual(record.revision, first.revision)
        XCTAssertEqual(record.retryCount, 0)
        XCTAssertEqual(fixture.transport.sent.count, 1)
    }

    func testFreshEnqueueCancelsScheduledAutomaticRetryForOlderRevision() async throws {
        let fixture = try makeFixture(automaticRetryDelays: [.milliseconds(150)])
        let source = try makeSource(id: "newretry001", artwork: false)
        try await fixture.service.enqueue(source)
        let first = try XCTUnwrap(fixture.transport.sent.first?.envelope)

        fixture.transport.emit(.fileFinished(
            WatchTransferKey(transferID: first.transferID, fileKind: .audio),
            WatchTransportFailure(code: "temporary", message: "retry", isRetryable: true)
        ))
        try await fixture.service.enqueue(source)
        try await waitUntil { fixture.transport.sent.count == 2 }
        try await Task.sleep(for: .milliseconds(220))

        let latest = try XCTUnwrap(record(source.youtubeID, in: fixture.context))
        XCTAssertEqual(latest.state, .transferring)
        XCTAssertEqual(latest.revision, 2)
        XCTAssertEqual(latest.retryCount, 0)
        XCTAssertEqual(fixture.transport.sent.count, 2)
    }

    func testConfirmationTimeoutRequiresReconciliationAndAcceptsLateAcknowledgement() async throws {
        let fixture = try makeFixture(confirmationTimeout: 0.05)
        let source = try makeSource(id: "acktimeout1", artwork: false)
        try await fixture.service.enqueue(source)
        let envelope = try XCTUnwrap(fixture.transport.sent.first?.envelope)

        fixture.transport.emit(.fileFinished(
            WatchTransferKey(transferID: envelope.transferID, fileKind: .audio),
            nil
        ))
        try await waitUntil {
            self.record(source.youtubeID, in: fixture.context)?.state == .reconciliationRequired
        }
        XCTAssertEqual(
            record(source.youtubeID, in: fixture.context)?.lastErrorCode,
            "watch-confirmation-timeout"
        )

        fixture.transport.emit(.acknowledgement(WatchTransferAcknowledgement(
            transferID: envelope.transferID,
            revision: envelope.revision,
            youtubeID: envelope.youtubeID,
            outcome: .imported
        )))
        XCTAssertEqual(record(source.youtubeID, in: fixture.context)?.state, .availableOnWatch)
    }

    func testUnavailableWatchRejectsTransferWithoutCreatingRecord() async throws {
        let status = WatchConnectionStatus(
            activation: .inactive,
            isPaired: true,
            isWatchAppInstalled: true
        )
        let fixture = try makeFixture(status: status)

        do {
            try await fixture.service.enqueue(makeSource(id: "transfer008", artwork: false))
            XCTFail("Expected an unavailable Watch error")
        } catch let error as WatchTransferServiceError {
            guard case .watchUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(fetchRecords(fixture.context).isEmpty)
        XCTAssertTrue(fixture.transport.sent.isEmpty)
    }

    func testMissingFirstSnapshotDoesNotBlockNextQueuedTransfer() async throws {
        let fixture = try makeFixture(start: false)
        let missing = WatchTransferRecord(
            youtubeID: "missing0001",
            title: "Missing",
            channelTitle: "Channel",
            publishedAt: .now,
            duration: 60,
            savedViewCount: 1,
            sourceFileSize: 64,
            transferID: UUID(),
            revision: 1,
            state: .queued,
            artworkDeliveryFinished: true,
            queuedAt: Date(timeIntervalSince1970: 1)
        )
        let validSource = try makeSource(id: "validnext01", artwork: false)
        let valid = WatchTransferRecord(
            youtubeID: validSource.youtubeID,
            title: validSource.title,
            channelTitle: validSource.channelTitle,
            publishedAt: validSource.publishedAt,
            duration: validSource.duration,
            savedViewCount: validSource.savedViewCount,
            sourceFileSize: 64,
            transferID: UUID(),
            revision: 1,
            state: .queued,
            artworkDeliveryFinished: true,
            queuedAt: Date(timeIntervalSince1970: 2)
        )
        fixture.context.insert(missing)
        fixture.context.insert(valid)
        try fixture.context.save()
        await fixture.snapshots.seed(
            PreparedWatchTransfer(
                transferID: valid.transferID,
                audioURL: validSource.audioURL,
                artworkURL: nil
            )
        )

        fixture.service.start()
        try await waitUntil { fixture.transport.sent.count == 1 }

        XCTAssertEqual(record(missing.youtubeID, in: fixture.context)?.state, .failed)
        XCTAssertEqual(fixture.transport.sent.first?.envelope.youtubeID, valid.youtubeID)
    }

    func testDeletedAcknowledgementRetainsRevisionForFutureRetransfer() async throws {
        let fixture = try makeFixture()
        let source = try makeSource(id: "deleted0001", artwork: false)
        try await fixture.service.enqueue(source)
        let first = try XCTUnwrap(fixture.transport.sent.first?.envelope)

        fixture.transport.emit(.acknowledgement(WatchTransferAcknowledgement(
            transferID: first.transferID,
            revision: first.revision,
            youtubeID: first.youtubeID,
            outcome: .deleted
        )))
        XCTAssertEqual(record(source.youtubeID, in: fixture.context)?.state, .removedFromWatch)

        try await fixture.service.enqueue(source)
        let latest = try XCTUnwrap(fixture.transport.sent.last?.envelope)
        XCTAssertEqual(latest.revision, 2)
        XCTAssertNotEqual(latest.transferID, first.transferID)
    }

    func testActivationReconcilesPersistedOutstandingTransfer() async throws {
        let fixture = try makeFixture(start: false)
        let source = try makeSource(id: "restart0001", artwork: false)
        let transferID = UUID()
        let persisted = WatchTransferRecord(
            youtubeID: source.youtubeID,
            title: source.title,
            channelTitle: source.channelTitle,
            publishedAt: source.publishedAt,
            duration: source.duration,
            savedViewCount: source.savedViewCount,
            sourceFileSize: 64,
            transferID: transferID,
            revision: 1,
            state: .transferring,
            artworkDeliveryFinished: true
        )
        fixture.context.insert(persisted)
        try fixture.context.save()
        fixture.transport.outstanding = [OutstandingWatchFile(
            key: WatchTransferKey(transferID: transferID, fileKind: .audio),
            fileURL: source.audioURL,
            progress: 0.4
        )]

        fixture.service.start()
        try await waitUntil { fixture.service.liveProgress[source.youtubeID] == 0.4 }

        XCTAssertEqual(record(source.youtubeID, in: fixture.context)?.state, .transferring)
    }

    func testActivationMarksLostPersistedTransferForReconciliation() async throws {
        let fixture = try makeFixture(start: false)
        let persisted = WatchTransferRecord(
            youtubeID: "restart0002",
            title: "Lost transfer",
            channelTitle: "Channel",
            publishedAt: .now,
            duration: 60,
            savedViewCount: 1,
            sourceFileSize: 64,
            transferID: UUID(),
            revision: 1,
            state: .transferring,
            artworkDeliveryFinished: true
        )
        fixture.context.insert(persisted)
        try fixture.context.save()

        fixture.service.start()
        try await waitUntil {
            self.record(persisted.youtubeID, in: fixture.context)?.state == .reconciliationRequired
        }

        XCTAssertTrue(fixture.transport.sent.isEmpty)
    }

    func testReactivationDoesNotLeaveMissedSenderCompletionBlockingQueue() async throws {
        let fixture = try makeFixture()
        let firstSource = try makeSource(id: "reactivate1", artwork: false)
        let secondSource = try makeSource(id: "reactivate2", artwork: false)
        try await fixture.service.enqueue(firstSource)
        try await fixture.service.enqueue(secondSource)
        XCTAssertEqual(fixture.transport.sent.count, 1)

        // Simulate WCSession losing its didFinish callback across a session
        // transition even though no file transfer remains outstanding.
        fixture.transport.outstanding = []
        fixture.transport.emit(.statusChanged(fixture.transport.status))
        try await waitUntil { fixture.transport.sent.count == 2 }

        XCTAssertEqual(
            record(firstSource.youtubeID, in: fixture.context)?.state,
            .reconciliationRequired
        )
        XCTAssertEqual(fixture.transport.sent.last?.envelope.youtubeID, secondSource.youtubeID)
    }

    func testActivationUsesPersistedWatchConfirmationWhenSenderCallbackWasLost() async throws {
        let fixture = try makeFixture(start: false)
        let source = try makeSource(id: "restart0003", artwork: true)
        let transferID = UUID()
        let persisted = WatchTransferRecord(
            youtubeID: source.youtubeID,
            title: source.title,
            channelTitle: source.channelTitle,
            publishedAt: source.publishedAt,
            duration: source.duration,
            savedViewCount: source.savedViewCount,
            sourceFileSize: 64,
            transferID: transferID,
            revision: 1,
            state: .transferring,
            artworkExpected: true,
            watchImportConfirmed: true
        )
        fixture.context.insert(persisted)
        try fixture.context.save()
        await fixture.snapshots.seed(PreparedWatchTransfer(
            transferID: transferID,
            audioURL: source.audioURL,
            artworkURL: source.artworkURL
        ))

        fixture.service.start()
        try await waitUntil {
            self.record(source.youtubeID, in: fixture.context)?.state == .availableOnWatch
        }
        try await waitUntilAsync {
            await fixture.snapshots.contains(transferID) == false
        }

        XCTAssertNil(fixture.service.liveProgress[source.youtubeID])
    }

    private func makeFixture(
        status: WatchConnectionStatus = WatchConnectionStatus(
            activation: .activated,
            isPaired: true,
            isWatchAppInstalled: true
        ),
        automaticRetryDelays: [Duration] = [],
        cloneDelay: Duration? = nil,
        confirmationTimeout: TimeInterval = 30 * 60,
        start: Bool = true
    ) throws -> Fixture {
        let container = try ModelContainer(
            for: SavedAudio.self,
            WatchTransferRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let transport = WatchTransportStub(status: status)
        let snapshots = WatchSnapshotStoreStub(cloneDelay: cloneDelay)
        let service = PhoneWatchTransferService(
            modelContext: container.mainContext,
            transport: transport,
            snapshots: snapshots,
            automaticRetryDelays: automaticRetryDelays,
            confirmationTimeout: confirmationTimeout
        )
        if start { service.start() }
        return Fixture(
            container: container,
            context: container.mainContext,
            transport: transport,
            snapshots: snapshots,
            service: service
        )
    }

    private func makeSource(id: String, artwork: Bool) throws -> WatchTransferSource {
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("audio.m4a")
        try Data(repeating: 0x41, count: 64).write(to: audioURL)
        let artworkURL = directory.appendingPathComponent("artwork.jpg")
        if artwork { try Data(repeating: 0x42, count: 16).write(to: artworkURL) }
        return WatchTransferSource(
            youtubeID: id,
            title: "Title \(id)",
            channelTitle: "Channel",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            savedViewCount: 42,
            duration: 120,
            playbackPosition: 37,
            audioURL: audioURL,
            artworkURL: artwork ? artworkURL : nil
        )
    }

    private func fetchRecords(_ context: ModelContext) -> [WatchTransferRecord] {
        (try? context.fetch(FetchDescriptor<WatchTransferRecord>())) ?? []
    }

    private func record(_ videoID: String, in context: ModelContext) -> WatchTransferRecord? {
        fetchRecords(context).first { $0.youtubeID == videoID }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for Watch transfer state")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for asynchronous Watch transfer state")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private struct Fixture {
    let container: ModelContainer
    let context: ModelContext
    let transport: WatchTransportStub
    let snapshots: WatchSnapshotStoreStub
    let service: PhoneWatchTransferService
}

@MainActor
private final class WatchTransportStub: WatchConnectivityTransport {
    var status: WatchConnectionStatus
    var eventHandler: (@MainActor @Sendable (WatchConnectivityEvent) -> Void)?
    private(set) var sent: [(url: URL, envelope: WatchTransferEnvelope)] = []
    private(set) var cancelledTransferIDs: [UUID] = []
    var outstanding: [OutstandingWatchFile] = []

    init(status: WatchConnectionStatus) {
        self.status = status
    }

    func activate() {
        eventHandler?(.statusChanged(status))
    }

    func outstandingFiles() -> [OutstandingWatchFile] { outstanding }

    func enqueueFile(at url: URL, envelope: WatchTransferEnvelope) throws {
        sent.append((url, envelope))
        outstanding.append(OutstandingWatchFile(
            key: WatchTransferKey(transferID: envelope.transferID, fileKind: envelope.fileKind),
            fileURL: url,
            progress: 0
        ))
    }

    func cancelFiles(transferID: UUID) {
        cancelledTransferIDs.append(transferID)
    }

    func emit(_ event: WatchConnectivityEvent) {
        if case .fileFinished(let key, _) = event {
            outstanding.removeAll { $0.key == key }
        }
        eventHandler?(event)
    }
}

private actor WatchSnapshotStoreStub: WatchTransferSnapshotStoring {
    private var prepared: [UUID: PreparedWatchTransfer] = [:]
    private var cloneSourceIDs: Set<UUID> = []
    private let cloneDelay: Duration?

    init(cloneDelay: Duration? = nil) {
        self.cloneDelay = cloneDelay
    }

    func prepare(source: WatchTransferSource, transferID: UUID) async throws -> PreparedWatchTransfer {
        let value = PreparedWatchTransfer(
            transferID: transferID,
            audioURL: source.audioURL,
            artworkURL: source.artworkURL
        )
        prepared[transferID] = value
        return value
    }

    func preparedTransfer(transferID: UUID) async -> PreparedWatchTransfer? {
        prepared[transferID]
    }

    func cloneTransfer(from sourceTransferID: UUID, to destinationTransferID: UUID) async throws -> PreparedWatchTransfer {
        guard let source = prepared[sourceTransferID] else {
            throw WatchTransferSnapshotError.sourceMissing
        }
        cloneSourceIDs.insert(sourceTransferID)
        if let cloneDelay {
            try await Task.sleep(for: cloneDelay)
        }
        let value = PreparedWatchTransfer(
            transferID: destinationTransferID,
            audioURL: source.audioURL,
            artworkURL: source.artworkURL
        )
        prepared[destinationTransferID] = value
        return value
    }

    func removeTransfer(_ transferID: UUID) async {
        prepared[transferID] = nil
    }

    func storedTransferIDs() async -> Set<UUID> {
        Set(prepared.keys)
    }

    func removeOrphans(retaining transferIDs: Set<UUID>) async {
        prepared = prepared.filter { transferIDs.contains($0.key) }
    }

    func removeStagingDirectories() async {}

    func seed(_ transfer: PreparedWatchTransfer) {
        prepared[transfer.transferID] = transfer
    }

    func contains(_ transferID: UUID) -> Bool {
        prepared[transferID] != nil
    }

    func hasStartedClone(from transferID: UUID) -> Bool {
        cloneSourceIDs.contains(transferID)
    }
}
