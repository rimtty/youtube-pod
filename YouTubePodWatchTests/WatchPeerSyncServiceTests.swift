import Foundation
import Testing
@preconcurrency import WatchConnectivity
@testable import YouTubePodWatch

struct WatchPeerSyncServiceTests {
    @Test func audioStagingFailureProducesRetryableAcknowledgement() throws {
        let envelope = makeEnvelope(kind: .audio)
        let metadata = try envelope.metadata()

        let userInfo = WatchWCSessionPeerSyncService.stagingFailureUserInfo(
            metadata: metadata,
            message: "staging failed"
        )
        let acknowledgement = try WatchTransferAcknowledgement.decode(
            userInfo: #require(userInfo)
        )

        #expect(acknowledgement.transferID == envelope.transferID)
        #expect(acknowledgement.youtubeID == envelope.youtubeID)
        #expect(acknowledgement.outcome == .failed)
        #expect(acknowledgement.errorCode == .stagingFailure)
    }

    @Test func artworkStagingFailureIsNonTerminal() throws {
        let envelope = makeEnvelope(kind: .artwork)
        let metadata = try envelope.metadata()

        #expect(WatchWCSessionPeerSyncService.stagingFailureUserInfo(
            metadata: metadata,
            message: "optional artwork failed"
        ) == nil)
    }

    @Test func malformedStagingMetadataCannotBeAcknowledged() {
        #expect(WatchWCSessionPeerSyncService.stagingFailureUserInfo(
            metadata: [:],
            message: "missing identity"
        ) == nil)
    }

    @Test @MainActor
    func activationInstallsDelegateAndStartsDriver() throws {
        let fixture = try makeFixture()

        fixture.service.activate()

        #expect(fixture.driver.installedDelegate === fixture.service)
        #expect(fixture.driver.activationCount == 1)
    }

    @Test @MainActor
    func unsupportedAppleDriverKeepsActivationNoOpAndRejectsInventory() {
        let driver = AppleWatchWCSessionDriver(session: nil)

        driver.installDelegate(nil)
        driver.activate()
        driver.transferUserInfo([:])

        #expect(driver.isSupported == false)
        #expect(driver.isActivated == false)
        #expect(driver.hasContentPending == false)
        #expect(throws: WatchPeerSyncError.sessionUnavailable) {
            try driver.updateApplicationContext([:])
        }
    }

    @Test @MainActor
    func activationWaiterReturnsImmediatelyForActivatedDriver() async throws {
        let fixture = try makeFixture(isActivated: true)
        fixture.service.activate()

        try await fixture.service.waitForActivation()

        #expect(fixture.driver.delayCallCount == 0)
    }

    @Test @MainActor
    func activationWaiterReactivatesAfterActivatedSessionBecomesInactive() async throws {
        let fixture = try makeFixture(isActivated: true)
        fixture.service.activate()
        try await fixture.service.waitForActivation()

        fixture.driver.isActivated = false
        fixture.driver.activateOnDelayCall = 1
        try await fixture.service.waitForActivation()

        #expect(fixture.driver.activationCount == 2)
        #expect(fixture.driver.isActivated)
    }

    @Test @MainActor
    func activationWaiterRejectsUnsupportedDriverWithoutPolling() async throws {
        let fixture = try makeFixture(isSupported: false)
        fixture.service.activate()

        do {
            try await fixture.service.waitForActivation()
            Issue.record("Expected unsupported Watch Connectivity")
        } catch {
            #expect(error as? WatchPeerSyncError == .unsupported)
        }
        #expect(fixture.driver.delayCallCount == 0)
    }

    @Test @MainActor
    func activationWaiterObservesDriverAfterDeterministicDelay() async throws {
        let fixture = try makeFixture()
        fixture.driver.activateOnDelayCall = 2
        fixture.service.activate()

        try await fixture.service.waitForActivation()

        #expect(fixture.driver.delayCallCount == 2)
    }

    @Test @MainActor
    func activationWaiterPropagatesDelegateFailure() async throws {
        let fixture = try makeFixture(waitPolicy: .init(
            pollInterval: .zero,
            activationCheckLimit: 100,
            contentCheckLimit: 3,
            requiredConsecutiveEmptyChecks: 2
        ))
        fixture.service.activate()
        let waiter = Task { @MainActor in
            try await fixture.service.waitForActivation()
        }
        while fixture.driver.delayCallCount == 0 {
            await Task.yield()
        }
        fixture.service.handleActivationCompletion(
            activationState: .activated,
            error: TestDriverError.forced
        )

        do {
            try await waiter.value
            Issue.record("Expected activation failure")
        } catch let error as WatchPeerSyncError {
            guard case .activationFailed(let code, let message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(code.contains("TestDriverError"))
            #expect(!message.isEmpty)
        }
    }

    @Test @MainActor
    func activationWaiterRetriesAfterPreviousAttemptFailed() async throws {
        let fixture = try makeFixture()
        fixture.service.activate()
        fixture.service.handleActivationCompletion(
            activationState: .inactive,
            error: TestDriverError.forced
        )
        await Task.yield()
        fixture.driver.activateOnDelayCall = fixture.driver.delayCallCount + 1

        try await fixture.service.waitForActivation()

        #expect(fixture.driver.activationCount == 2)
        #expect(fixture.driver.isActivated)
    }

    @Test @MainActor
    func activationWaiterTimesOutAtConfiguredBound() async throws {
        let fixture = try makeFixture(waitPolicy: .init(
            pollInterval: .zero,
            activationCheckLimit: 3,
            contentCheckLimit: 3,
            requiredConsecutiveEmptyChecks: 2
        ))
        fixture.service.activate()

        do {
            try await fixture.service.waitForActivation()
            Issue.record("Expected activation timeout")
        } catch {
            #expect(error as? WatchPeerSyncError == .activationTimedOut)
        }
        #expect(fixture.driver.delayCallCount == 2)
    }

    @Test @MainActor
    func contentDrainRequiresTwoConsecutiveEmptyChecks() async throws {
        let fixture = try makeFixture(hasContentPending: false)
        fixture.driver.pendingValuesAfterDelay = [true, false, false]

        try await fixture.service.waitUntilContentDrained()

        #expect(fixture.driver.delayCallCount == 3)
        #expect(fixture.service.hasContentPending == false)
    }

    @Test @MainActor
    func contentDrainTimesOutWhileContentRemainsPending() async throws {
        let fixture = try makeFixture(
            hasContentPending: true,
            waitPolicy: .init(
                pollInterval: .zero,
                activationCheckLimit: 2,
                contentCheckLimit: 4,
                requiredConsecutiveEmptyChecks: 2
            )
        )

        do {
            try await fixture.service.waitUntilContentDrained()
            Issue.record("Expected content drain timeout")
        } catch {
            #expect(error as? WatchPeerSyncError == .contentDrainTimedOut)
        }
        #expect(fixture.driver.delayCallCount == 3)
    }

    @Test @MainActor
    func contentDrainPropagatesCancellation() async throws {
        let fixture = try makeFixture(hasContentPending: true)
        fixture.driver.delayError = CancellationError()

        do {
            try await fixture.service.waitUntilContentDrained()
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test @MainActor
    func successfulActivationInvokesHandlerButFailureDoesNot() async throws {
        let fixture = try makeFixture()
        let recorder = PeerCallbackRecorder()
        fixture.service.activationHandler = {
            recorder.activationCount += 1
        }

        fixture.service.handleActivationCompletion(
            activationState: .activated,
            error: nil
        )
        await Task.yield()
        #expect(recorder.activationCount == 1)

        fixture.service.handleActivationCompletion(
            activationState: .inactive,
            error: nil
        )
        fixture.service.handleActivationCompletion(
            activationState: .activated,
            error: TestDriverError.forced
        )
        await Task.yield()
        #expect(recorder.activationCount == 1)
    }

    @Test @MainActor
    func acknowledgementUsesDriverAndPreservesPayload() throws {
        let fixture = try makeFixture(isActivated: true)
        let acknowledgement = WatchTransferAcknowledgement(
            transferID: UUID(),
            revision: 2,
            youtubeID: "dQw4w9WgXcQ",
            outcome: .imported
        )

        try fixture.service.enqueueAcknowledgement(acknowledgement)

        let sent = try #require(fixture.driver.userInfos.first)
        #expect(try WatchTransferAcknowledgement.decode(userInfo: sent) == acknowledgement)
    }

    @Test @MainActor
    func inventoryUsesDriverAndPreservesPayload() throws {
        let fixture = try makeFixture(isActivated: true)
        let inventory = WatchInventorySnapshot(
            libraryInstanceID: UUID(),
            generation: 4,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            availableCapacity: 42_000,
            entries: [WatchInventoryEntry(
                youtubeID: "dQw4w9WgXcQ",
                transferID: UUID(),
                revision: 2,
                fileSize: 64
            )]
        )

        try fixture.service.publishInventory(inventory)

        let sent = try #require(fixture.driver.applicationContexts.first)
        #expect(try WatchInventorySnapshot.decode(applicationContext: sent) == inventory)
    }

    @Test @MainActor
    func currentInventoryRequestRereadsDriverApplicationContext() throws {
        let fixture = try makeFixture(isActivated: true)
        let first = WatchInventoryRequest(
            requestID: UUID(),
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = WatchInventoryRequest(
            requestID: UUID(),
            requestedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        fixture.driver.receivedApplicationContext = try first.applicationContext()

        #expect(fixture.service.currentInventoryRequest() == first)

        fixture.driver.receivedApplicationContext = try second.applicationContext()
        #expect(fixture.service.currentInventoryRequest() == second)
    }

    @Test @MainActor
    func applicationContextCallbackNormalizesRequestAndNotifiesHandler() async throws {
        let fixture = try makeFixture()
        let recorder = PeerCallbackRecorder()
        fixture.service.inventoryRequestHandler = { request in
            recorder.inventoryRequests.append(request)
        }
        let request = WatchInventoryRequest(
            requestID: UUID(),
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        fixture.service.handleReceivedApplicationContext(try request.applicationContext())
        fixture.service.handleReceivedApplicationContext(["malformed": Data()])
        await Task.yield()

        #expect(recorder.inventoryRequests == [request])
        #expect(WatchWCSessionPeerSyncService.normalizedInventoryRequest(
            applicationContext: [:]
        ) == nil)
    }

    @Test @MainActor
    func applicationContextDeliversPendingTransfersIndependentlyOfInventoryRequest() async throws {
        let fixture = try makeFixture(isActivated: true)
        let recorder = PeerCallbackRecorder()
        fixture.service.inventoryRequestHandler = { request in
            recorder.inventoryRequests.append(request)
        }
        fixture.service.pendingTransfersHandler = { summary in
            recorder.pendingTransfers.append(summary)
        }
        let request = WatchInventoryRequest(
            requestID: UUID(),
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let summary = WatchPendingTransfersSummary(
            queuedCount: 2,
            transferringCount: 1,
            totalBytes: 12_345,
            activeYouTubeID: "dQw4w9WgXcQ",
            activeTitle: "Active",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let merged = try WatchPhoneApplicationContext(
            inventoryRequest: request,
            pendingTransfers: summary
        ).applicationContext()

        // Summary only: must not be dropped because the request key is absent.
        fixture.service.handleReceivedApplicationContext(try summary.applicationContext())
        // Both keys in one dictionary: both handlers fire.
        fixture.service.handleReceivedApplicationContext(merged)
        // Malformed summary bytes: neither handler fires.
        fixture.service.handleReceivedApplicationContext(
            [WatchPendingTransfersSummary.applicationContextKey: Data("junk".utf8)]
        )
        await Task.yield()
        await Task.yield()

        #expect(recorder.pendingTransfers == [summary, summary])
        #expect(recorder.inventoryRequests == [request])

        fixture.driver.receivedApplicationContext = merged
        #expect(fixture.service.currentPendingTransfers() == summary)
        #expect(fixture.service.currentInventoryRequest() == request)
        fixture.driver.receivedApplicationContext = [:]
        #expect(fixture.service.currentPendingTransfers() == nil)
    }

    @Test @MainActor
    func outboundDeliveryRequiresActivatedSession() throws {
        let fixture = try makeFixture(isActivated: false)
        let acknowledgement = WatchTransferAcknowledgement(
            transferID: UUID(),
            revision: 1,
            youtubeID: "dQw4w9WgXcQ",
            outcome: .imported
        )
        let inventory = WatchInventorySnapshot(
            libraryInstanceID: UUID(),
            generation: 1,
            generatedAt: .now,
            availableCapacity: nil,
            entries: []
        )

        #expect(throws: WatchPeerSyncError.sessionUnavailable) {
            try fixture.service.enqueueAcknowledgement(acknowledgement)
        }
        #expect(throws: WatchPeerSyncError.sessionUnavailable) {
            try fixture.service.publishInventory(inventory)
        }
        #expect(fixture.driver.userInfos.isEmpty)
        #expect(fixture.driver.applicationContexts.isEmpty)
    }

    @Test @MainActor
    func driverInventoryFailureIsPropagated() throws {
        let fixture = try makeFixture(isActivated: true)
        fixture.driver.applicationContextError = .forced
        let inventory = WatchInventorySnapshot(
            libraryInstanceID: UUID(),
            generation: 1,
            generatedAt: .now,
            availableCapacity: nil,
            entries: []
        )

        #expect(throws: TestDriverError.forced) {
            try fixture.service.publishInventory(inventory)
        }
    }

    @Test @MainActor
    func fileCallbackStagesBeforeReturningAndSurvivesSourceRemoval() async throws {
        let fixture = try makeFixture()
        let recorder = PeerCallbackRecorder()
        fixture.service.stagedFileHandler = { staged in
            recorder.stagedFiles.append(staged)
        }
        let sourceURL = fixture.rootURL.appending(path: "incoming.m4a")
        let payload = Data(repeating: 0x41, count: 64)
        try payload.write(to: sourceURL)
        let envelope = makeEnvelope(kind: .audio, fileSize: Int64(payload.count))

        let failure = fixture.service.handleReceivedFile(
            at: sourceURL,
            metadata: try envelope.metadata()
        )

        #expect(failure == nil)
        let stagedBeforeReturn = try #require(fixture.stager.listStagedFiles().first)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try Data(contentsOf: stagedBeforeReturn.fileURL) == payload)

        await Task.yield()
        #expect(recorder.stagedFiles == [stagedBeforeReturn])
    }

    @Test @MainActor
    func audioFileCallbackStagingFailureReturnsFailureAcknowledgement() throws {
        let fixture = try makeFixture()
        let envelope = makeEnvelope(kind: .audio, fileSize: 64)
        let missingSource = fixture.rootURL.appending(path: "missing.m4a")

        let response = fixture.service.handleReceivedFile(
            at: missingSource,
            metadata: try envelope.metadata()
        )
        let acknowledgement = try WatchTransferAcknowledgement.decode(
            userInfo: #require(response)
        )

        #expect(acknowledgement.transferID == envelope.transferID)
        #expect(acknowledgement.revision == envelope.revision)
        #expect(acknowledgement.youtubeID == envelope.youtubeID)
        #expect(acknowledgement.outcome == .failed)
        #expect(acknowledgement.errorCode == .stagingFailure)
        #expect(try fixture.stager.listStagedFiles().isEmpty)
    }

    @Test @MainActor
    func artworkFileCallbackStagingFailureIsNonTerminal() throws {
        let fixture = try makeFixture()
        let envelope = makeEnvelope(kind: .artwork, fileSize: 64)

        let response = fixture.service.handleReceivedFile(
            at: fixture.rootURL.appending(path: "missing.jpg"),
            metadata: try envelope.metadata()
        )

        #expect(response == nil)
        #expect(try fixture.stager.listStagedFiles().isEmpty)
    }

    @Test @MainActor
    func malformedFileCallbackCannotBeAcknowledged() throws {
        let fixture = try makeFixture()

        let response = fixture.service.handleReceivedFile(
            at: fixture.rootURL.appending(path: "missing.m4a"),
            metadata: [:]
        )

        #expect(response == nil)
    }

    @Test @MainActor
    func deletionCommandIsPersistedBeforeCallbackReturns() async throws {
        let fixture = try makeFixture()
        let recorder = PeerCallbackRecorder()
        fixture.service.commandHandler = { staged in
            recorder.commands.append(staged)
        }
        let command = WatchLibraryCommand(
            commandID: UUID(),
            kind: .delete,
            youtubeID: "dQw4w9WgXcQ",
            revision: 3
        )

        let failure = fixture.service.handleReceivedUserInfo(try command.userInfo())

        #expect(failure == nil)
        let stagedBeforeReturn = try #require(fixture.stager.listStagedCommands().first)
        #expect(stagedBeforeReturn.command == command)

        await Task.yield()
        #expect(recorder.commands == [stagedBeforeReturn])
    }

    @Test @MainActor
    func deletionCommandPersistenceFailureReturnsFailureAcknowledgement() throws {
        let fixture = try makeFixture(blockStagingRoot: true)
        let command = WatchLibraryCommand(
            commandID: UUID(),
            kind: .delete,
            youtubeID: "dQw4w9WgXcQ",
            revision: 5
        )

        let response = fixture.service.handleReceivedUserInfo(try command.userInfo())
        let acknowledgement = try WatchTransferAcknowledgement.decode(
            userInfo: #require(response)
        )

        #expect(acknowledgement.transferID == command.commandID)
        #expect(acknowledgement.revision == command.revision)
        #expect(acknowledgement.youtubeID == command.youtubeID)
        #expect(acknowledgement.outcome == .failed)
        #expect(acknowledgement.errorCode == .stagingFailure)
    }

    @Test @MainActor
    func malformedDeletionCommandCannotBeAcknowledged() throws {
        let fixture = try makeFixture(blockStagingRoot: true)

        #expect(fixture.service.handleReceivedUserInfo([:]) == nil)
    }

    @MainActor
    private func makeFixture(
        isSupported: Bool = true,
        isActivated: Bool = false,
        hasContentPending: Bool = false,
        blockStagingRoot: Bool = false,
        waitPolicy: WatchConnectivityWaitPolicy = .init(
            pollInterval: .zero,
            activationCheckLimit: 5,
            contentCheckLimit: 8,
            requiredConsecutiveEmptyChecks: 2
        )
    ) throws -> PeerFixture {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: "WatchPeerSyncServiceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let inboxURL = rootURL.appending(path: "Inbox", directoryHint: .isDirectory)
        if blockStagingRoot {
            try Data("not-a-directory".utf8).write(to: inboxURL)
        }
        let stager = WatchIncomingFileStager(rootDirectoryURL: inboxURL)
        let driver = WatchWCSessionDriverStub(
            isSupported: isSupported,
            isActivated: isActivated,
            hasContentPending: hasContentPending
        )
        let service = WatchWCSessionPeerSyncService(
            stager: stager,
            driver: driver,
            waitPolicy: waitPolicy,
            delay: { _ in
                try driver.advanceDelay()
                await Task.yield()
            }
        )
        return PeerFixture(
            rootURL: rootURL,
            stager: stager,
            driver: driver,
            service: service
        )
    }

    private func makeEnvelope(
        kind: WatchTransferFileKind,
        fileSize: Int64 = 64
    ) -> WatchTransferEnvelope {
        WatchTransferEnvelope(
            transferID: UUID(),
            revision: 1,
            fileKind: kind,
            youtubeID: "dQw4w9WgXcQ",
            title: "Title",
            channel: "Channel",
            publishedAt: nil,
            viewCount: 1,
            duration: 60,
            fileSize: fileSize,
            playbackPosition: 0
        )
    }
}

@MainActor
private final class PeerFixture {
    let rootURL: URL
    let stager: WatchIncomingFileStager
    let driver: WatchWCSessionDriverStub
    let service: WatchWCSessionPeerSyncService

    init(
        rootURL: URL,
        stager: WatchIncomingFileStager,
        driver: WatchWCSessionDriverStub,
        service: WatchWCSessionPeerSyncService
    ) {
        self.rootURL = rootURL
        self.stager = stager
        self.driver = driver
        self.service = service
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

@MainActor
private final class WatchWCSessionDriverStub: WatchWCSessionDriving {
    var isSupported: Bool
    var isActivated: Bool
    var hasContentPending: Bool
    var receivedApplicationContext: [String: Any] = [:]
    private(set) weak var installedDelegate: (any WCSessionDelegate)?
    private(set) var activationCount = 0
    private(set) var delayCallCount = 0
    private(set) var userInfos: [[String: Any]] = []
    private(set) var applicationContexts: [[String: Any]] = []
    var applicationContextError: TestDriverError?
    var activateOnDelayCall: Int?
    var pendingValuesAfterDelay: [Bool] = []
    var delayError: (any Error)?

    init(
        isSupported: Bool,
        isActivated: Bool,
        hasContentPending: Bool
    ) {
        self.isSupported = isSupported
        self.isActivated = isActivated
        self.hasContentPending = hasContentPending
    }

    func advanceDelay() throws {
        delayCallCount += 1
        if activateOnDelayCall == delayCallCount {
            isActivated = true
        }
        if !pendingValuesAfterDelay.isEmpty {
            hasContentPending = pendingValuesAfterDelay.removeFirst()
        }
        if let delayError { throw delayError }
    }

    func installDelegate(_ delegate: (any WCSessionDelegate)?) {
        installedDelegate = delegate
    }

    func activate() {
        activationCount += 1
    }

    func transferUserInfo(_ userInfo: [String: Any]) {
        userInfos.append(userInfo)
    }

    func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        if let applicationContextError { throw applicationContextError }
        applicationContexts.append(applicationContext)
    }
}

@MainActor
private final class PeerCallbackRecorder {
    var activationCount = 0
    var stagedFiles: [StagedWatchTransferFile] = []
    var commands: [StagedWatchLibraryCommand] = []
    var inventoryRequests: [WatchInventoryRequest] = []
    var pendingTransfers: [WatchPendingTransfersSummary] = []
}

private enum TestDriverError: Error, Equatable {
    case forced
}
