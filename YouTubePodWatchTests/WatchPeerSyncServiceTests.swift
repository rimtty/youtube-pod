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

        #expect(driver.isActivated == false)
        #expect(throws: WatchPeerSyncError.sessionUnavailable) {
            try driver.updateApplicationContext([:])
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
        try FileManager.default.removeItem(at: sourceURL)
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
        isActivated: Bool = false,
        blockStagingRoot: Bool = false
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
        let driver = WatchWCSessionDriverStub(isActivated: isActivated)
        let service = WatchWCSessionPeerSyncService(stager: stager, driver: driver)
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
    var isActivated: Bool
    private(set) weak var installedDelegate: (any WCSessionDelegate)?
    private(set) var activationCount = 0
    private(set) var userInfos: [[String: Any]] = []
    private(set) var applicationContexts: [[String: Any]] = []
    var applicationContextError: TestDriverError?

    init(isActivated: Bool) {
        self.isActivated = isActivated
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
}

private enum TestDriverError: Error, Equatable {
    case forced
}
