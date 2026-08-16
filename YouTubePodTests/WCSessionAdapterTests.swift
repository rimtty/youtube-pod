import Foundation
import WatchConnectivity
import XCTest
@testable import YouTubePod

@MainActor
final class WCSessionAdapterTests: XCTestCase {
    func testUnsupportedDriverEmitsUnsupportedAndRejectsOutboundWork() throws {
        let driver = PhoneWCSessionDriverStub(isSupported: false)
        let adapter = WCSessionAdapter(driver: driver)
        let recorder = PhoneWCEventRecorder()
        adapter.eventHandler = recorder.record

        adapter.activate()

        XCTAssertEqual(adapter.status, .unsupported)
        XCTAssertEqual(driver.activationCount, 0)
        XCTAssertNil(driver.installedDelegate)
        XCTAssertEqual(recorder.statuses, [.unsupported])
        XCTAssertTrue(adapter.outstandingFiles().isEmpty)
        XCTAssertThrowsError(try adapter.enqueueFile(
            at: URL(fileURLWithPath: "/tmp/audio.m4a"),
            envelope: makeEnvelope()
        )) { error in
            guard case WatchConnectivityAdapterError.unsupported = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUnsupportedAppleDriverIsSafeWithoutFabricatingWCSession() throws {
        let driver = ApplePhoneWCSessionDriver(session: nil)

        XCTAssertFalse(driver.isSupported)
        XCTAssertEqual(driver.activationState, .notActivated)
        XCTAssertTrue(driver.outstandingFileTransfers.isEmpty)
        driver.installDelegate(nil)
        driver.activate()
        XCTAssertThrowsError(try driver.transferUserInfo([:]))
        XCTAssertThrowsError(try driver.transferFile(
            URL(fileURLWithPath: "/tmp/audio.m4a"),
            metadata: [:]
        ))
    }

    func testInactiveActivationInstallsDelegateWithoutReadingPairState() {
        let driver = PhoneWCSessionDriverStub(
            activationState: .notActivated,
            isPaired: true,
            isWatchAppInstalled: true
        )
        let adapter = WCSessionAdapter(driver: driver)
        let recorder = PhoneWCEventRecorder()
        adapter.eventHandler = recorder.record

        adapter.activate()

        XCTAssertTrue(driver.installedDelegate === adapter)
        XCTAssertEqual(driver.activationCount, 1)
        XCTAssertEqual(driver.pairedReadCount, 0)
        XCTAssertEqual(driver.watchAppInstalledReadCount, 0)
        XCTAssertEqual(recorder.statuses, [WatchConnectionStatus(
            activation: .activating,
            isPaired: nil,
            isWatchAppInstalled: nil
        )])
    }

    func testAlreadyActivatedEmitsStatusAndInitialInventoryWithoutReactivation() throws {
        let inventory = makeInventory()
        let driver = PhoneWCSessionDriverStub(
            activationState: .activated,
            isPaired: true,
            isWatchAppInstalled: true,
            receivedApplicationContext: try inventory.applicationContext()
        )
        let adapter = WCSessionAdapter(driver: driver)
        let recorder = PhoneWCEventRecorder()
        adapter.eventHandler = recorder.record

        adapter.activate()

        XCTAssertTrue(driver.installedDelegate === adapter)
        XCTAssertEqual(driver.activationCount, 0)
        XCTAssertEqual(recorder.statuses, [WatchConnectionStatus(
            activation: .activated,
            isPaired: true,
            isWatchAppInstalled: true
        )])
        XCTAssertEqual(recorder.inventories, [inventory])
    }

    func testEnqueueForwardsEnvelopeAndEmitsProgressOnlyOncePerKey() throws {
        let driver = activatedDriver()
        let adapter = WCSessionAdapter(driver: driver)
        let recorder = PhoneWCEventRecorder()
        adapter.eventHandler = recorder.record
        let envelope = makeEnvelope()
        let url = URL(fileURLWithPath: "/tmp/audio.m4a")

        try adapter.enqueueFile(at: url, envelope: envelope)

        let sent = try XCTUnwrap(driver.transferredFiles.first)
        XCTAssertEqual(sent.url, url)
        XCTAssertEqual(try WatchTransferEnvelope.decode(metadata: sent.metadata), envelope)
        XCTAssertEqual(sent.transfer.observationCount, 1)
        sent.transfer.emitProgress(0.42)
        XCTAssertEqual(recorder.progressValues.count, 1)
        XCTAssertEqual(recorder.progressValues.first?.key, WatchTransferKey(
            transferID: envelope.transferID,
            fileKind: envelope.fileKind
        ))
        XCTAssertEqual(recorder.progressValues.first?.value, 0.42)

        driver.outstanding = [sent.transfer]
        _ = adapter.outstandingFiles()
        XCTAssertEqual(sent.transfer.observationCount, 1)
    }

    func testOutstandingFilesMapsValidTransfersAndSkipsMalformedMetadata() throws {
        let driver = activatedDriver()
        let validEnvelope = makeEnvelope(fileKind: .artwork)
        let valid = PhoneWCFileTransferDriverStub(
            fileURL: URL(fileURLWithPath: "/tmp/art.jpg"),
            metadata: try validEnvelope.metadata(),
            fractionCompleted: 0.7
        )
        let malformed = PhoneWCFileTransferDriverStub(
            fileURL: URL(fileURLWithPath: "/tmp/bad.m4a"),
            metadata: [:],
            fractionCompleted: 1
        )
        driver.outstanding = [valid, malformed]
        let adapter = WCSessionAdapter(driver: driver)

        let files = adapter.outstandingFiles()

        XCTAssertEqual(files, [OutstandingWatchFile(
            key: WatchTransferKey(
                transferID: validEnvelope.transferID,
                fileKind: .artwork
            ),
            fileURL: valid.fileURL,
            progress: 0.7
        )])
        XCTAssertEqual(valid.observationCount, 1)
        XCTAssertEqual(malformed.observationCount, 0)
    }

    func testCancelOnlyCancelsMatchingTransfersAndInvalidatesObservation() throws {
        let driver = activatedDriver()
        let matchingEnvelope = makeEnvelope(fileKind: .audio)
        let otherEnvelope = makeEnvelope(fileKind: .artwork)
        let matching = PhoneWCFileTransferDriverStub(
            fileURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            metadata: try matchingEnvelope.metadata()
        )
        let other = PhoneWCFileTransferDriverStub(
            fileURL: URL(fileURLWithPath: "/tmp/art.jpg"),
            metadata: try otherEnvelope.metadata()
        )
        let malformed = PhoneWCFileTransferDriverStub(
            fileURL: URL(fileURLWithPath: "/tmp/bad"),
            metadata: [:]
        )
        driver.outstanding = [matching, other, malformed]
        let adapter = WCSessionAdapter(driver: driver)
        _ = adapter.outstandingFiles()
        let matchingObservation = try XCTUnwrap(matching.lastObservation)

        adapter.cancelFiles(transferID: matchingEnvelope.transferID)

        XCTAssertEqual(matching.cancelCount, 1)
        XCTAssertEqual(other.cancelCount, 0)
        XCTAssertEqual(malformed.cancelCount, 0)
        XCTAssertEqual(matchingObservation.invalidateCount, 1)
    }

    func testDeletionCommandIsEncodedAndUnavailableStatusRejectsOutboundWork() throws {
        let driver = activatedDriver()
        let adapter = WCSessionAdapter(driver: driver)
        let command = WatchLibraryCommand(
            commandID: UUID(),
            kind: .delete,
            youtubeID: "dQw4w9WgXcQ",
            revision: 2
        )

        try adapter.sendDeletionCommand(command)

        XCTAssertEqual(
            try WatchLibraryCommand.decode(userInfo: XCTUnwrap(driver.userInfos.first)),
            command
        )

        driver.activationState = .inactive
        XCTAssertThrowsError(try adapter.sendDeletionCommand(command)) { error in
            guard case WatchConnectivityAdapterError.unavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testActivationCompletionPublishesInventoryOnlyOnSuccess() {
        let inventory = makeInventory()
        let driver = activatedDriver()
        let adapter = WCSessionAdapter(driver: driver)
        let recorder = PhoneWCEventRecorder()
        adapter.eventHandler = recorder.record

        adapter.handleActivationCompletion(succeeded: true, inventory: inventory)
        adapter.handleActivationCompletion(succeeded: false, inventory: inventory)

        XCTAssertEqual(recorder.statuses.count, 2)
        XCTAssertEqual(recorder.inventories, [inventory])
    }

    func testDeactivationReactivatesDriverAndStatusChangesUseCurrentState() {
        let driver = activatedDriver()
        let adapter = WCSessionAdapter(driver: driver)
        let recorder = PhoneWCEventRecorder()
        adapter.eventHandler = recorder.record

        adapter.handleStatusChange()
        driver.activationState = .inactive
        adapter.handleDeactivation()

        XCTAssertEqual(driver.activationCount, 1)
        XCTAssertEqual(recorder.statuses.map(\.activation), [.activated, .inactive])
    }

    func testFinishedCallbackNormalizationPreservesIdentityAndSuccess() throws {
        let envelope = makeEnvelope(fileKind: .audio)

        let event = try XCTUnwrap(WCSessionAdapter.normalizedFinishedEvent(
            metadata: envelope.metadata(),
            error: nil
        ))

        guard case let .fileFinished(key, failure) = event else {
            return XCTFail("Expected fileFinished")
        }
        XCTAssertEqual(key, WatchTransferKey(
            transferID: envelope.transferID,
            fileKind: .audio
        ))
        XCTAssertNil(failure)
        XCTAssertNil(WCSessionAdapter.normalizedFinishedEvent(metadata: [:], error: nil))
    }

    func testWCErrorClassificationUsesDomainAndSeparatesPermanentFailures() throws {
        let temporary = try XCTUnwrap(WCSessionAdapter.transportFailure(from: NSError(
            domain: WCErrorDomain,
            code: WCError.Code.deliveryFailed.rawValue
        )))
        XCTAssertTrue(temporary.isRetryable)

        let permanentCodes: [WCError.Code] = [
            .deviceNotPaired,
            .watchAppNotInstalled,
            .invalidParameter,
            .payloadTooLarge,
            .payloadUnsupportedTypes,
            .fileAccessDenied,
            .insufficientSpace
        ]
        for code in permanentCodes {
            let failure = try XCTUnwrap(WCSessionAdapter.transportFailure(from: NSError(
                domain: WCErrorDomain,
                code: code.rawValue
            )))
            XCTAssertFalse(failure.isRetryable, "Expected \(code) to be permanent")
        }

        let foreignSameNumber = try XCTUnwrap(WCSessionAdapter.transportFailure(from: NSError(
            domain: "ExampleTransport",
            code: WCError.Code.deviceNotPaired.rawValue
        )))
        XCTAssertTrue(foreignSameNumber.isRetryable)
        XCTAssertEqual(
            foreignSameNumber.code,
            "ExampleTransport.\(WCError.Code.deviceNotPaired.rawValue)"
        )
    }

    func testFinishedEventInvalidatesProgressObservationBeforeDelivery() throws {
        let driver = activatedDriver()
        let adapter = WCSessionAdapter(driver: driver)
        let recorder = PhoneWCEventRecorder()
        adapter.eventHandler = recorder.record
        let envelope = makeEnvelope()
        try adapter.enqueueFile(
            at: URL(fileURLWithPath: "/tmp/audio.m4a"),
            envelope: envelope
        )
        let transfer = try XCTUnwrap(driver.transferredFiles.first?.transfer)
        let observation = try XCTUnwrap(transfer.lastObservation)
        let event = try XCTUnwrap(WCSessionAdapter.normalizedFinishedEvent(
            metadata: envelope.metadata(),
            error: nil
        ))

        adapter.emit(event)

        XCTAssertEqual(observation.invalidateCount, 1)
        XCTAssertEqual(recorder.finishedKeys, [WatchTransferKey(
            transferID: envelope.transferID,
            fileKind: .audio
        )])
    }

    func testAcknowledgementAndInventoryCallbacksNormalizeValidPayloads() throws {
        let acknowledgement = WatchTransferAcknowledgement(
            transferID: UUID(),
            revision: 1,
            youtubeID: "dQw4w9WgXcQ",
            outcome: .imported
        )
        let inventory = makeInventory()

        let acknowledgementEvent = try XCTUnwrap(
            WCSessionAdapter.normalizedAcknowledgementEvent(
                userInfo: acknowledgement.userInfo()
            )
        )
        guard case let .acknowledgement(decodedAcknowledgement) = acknowledgementEvent else {
            return XCTFail("Expected acknowledgement")
        }
        XCTAssertEqual(decodedAcknowledgement, acknowledgement)

        let inventoryEvent = try XCTUnwrap(WCSessionAdapter.normalizedInventoryEvent(
            applicationContext: inventory.applicationContext()
        ))
        guard case let .inventory(decodedInventory) = inventoryEvent else {
            return XCTFail("Expected inventory")
        }
        XCTAssertEqual(decodedInventory, inventory)
        XCTAssertNil(WCSessionAdapter.normalizedAcknowledgementEvent(userInfo: [:]))
        XCTAssertNil(WCSessionAdapter.normalizedInventoryEvent(applicationContext: [:]))
    }

    private func activatedDriver() -> PhoneWCSessionDriverStub {
        PhoneWCSessionDriverStub(
            activationState: .activated,
            isPaired: true,
            isWatchAppInstalled: true
        )
    }

    private func makeEnvelope(
        fileKind: WatchTransferFileKind = .audio
    ) -> WatchTransferEnvelope {
        WatchTransferEnvelope(
            transferID: UUID(),
            revision: 1,
            fileKind: fileKind,
            youtubeID: "dQw4w9WgXcQ",
            title: "Title",
            channel: "Channel",
            publishedAt: nil,
            viewCount: 1,
            duration: 60,
            fileSize: 64,
            playbackPosition: 0
        )
    }

    private func makeInventory() -> WatchInventorySnapshot {
        WatchInventorySnapshot(
            libraryInstanceID: UUID(),
            generation: 2,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            availableCapacity: 42_000,
            entries: []
        )
    }
}

@MainActor
private final class PhoneWCSessionDriverStub: PhoneWCSessionDriving {
    let isSupported: Bool
    var activationState: WCSessionActivationState
    private var pairedValue: Bool
    private var watchAppInstalledValue: Bool
    var receivedApplicationContext: [String: Any]
    var outstanding: [any PhoneWCSessionFileTransferDriving] = []
    var outstandingFileTransfers: [any PhoneWCSessionFileTransferDriving] { outstanding }

    private(set) weak var installedDelegate: (any WCSessionDelegate)?
    private(set) var activationCount = 0
    private(set) var pairedReadCount = 0
    private(set) var watchAppInstalledReadCount = 0
    private(set) var transferredFiles: [(
        url: URL,
        metadata: [String: Any],
        transfer: PhoneWCFileTransferDriverStub
    )] = []
    private(set) var userInfos: [[String: Any]] = []

    var isPaired: Bool {
        pairedReadCount += 1
        return pairedValue
    }
    var isWatchAppInstalled: Bool {
        watchAppInstalledReadCount += 1
        return watchAppInstalledValue
    }

    init(
        isSupported: Bool = true,
        activationState: WCSessionActivationState = .notActivated,
        isPaired: Bool = false,
        isWatchAppInstalled: Bool = false,
        receivedApplicationContext: [String: Any] = [:]
    ) {
        self.isSupported = isSupported
        self.activationState = activationState
        pairedValue = isPaired
        watchAppInstalledValue = isWatchAppInstalled
        self.receivedApplicationContext = receivedApplicationContext
    }

    func installDelegate(_ delegate: (any WCSessionDelegate)?) {
        installedDelegate = delegate
    }

    func activate() {
        activationCount += 1
    }

    func transferFile(
        _ fileURL: URL,
        metadata: [String: Any]
    ) throws -> any PhoneWCSessionFileTransferDriving {
        let transfer = PhoneWCFileTransferDriverStub(
            fileURL: fileURL,
            metadata: metadata
        )
        transferredFiles.append((fileURL, metadata, transfer))
        return transfer
    }

    func transferUserInfo(_ userInfo: [String: Any]) throws {
        userInfos.append(userInfo)
    }
}

@MainActor
private final class PhoneWCFileTransferDriverStub: PhoneWCSessionFileTransferDriving {
    let fileURL: URL
    let metadata: [String: Any]
    var fractionCompleted: Double
    private(set) var cancelCount = 0
    private(set) var observationCount = 0
    private(set) var lastObservation: PhoneWCProgressObservationStub?
    private var progressHandler: (@MainActor @Sendable (Double) -> Void)?

    init(
        fileURL: URL,
        metadata: [String: Any],
        fractionCompleted: Double = 0
    ) {
        self.fileURL = fileURL
        self.metadata = metadata
        self.fractionCompleted = fractionCompleted
    }

    func cancel() {
        cancelCount += 1
    }

    func observeProgress(
        _ handler: @escaping @MainActor @Sendable (Double) -> Void
    ) -> any PhoneWCSessionProgressObserving {
        observationCount += 1
        progressHandler = handler
        let observation = PhoneWCProgressObservationStub()
        lastObservation = observation
        return observation
    }

    func emitProgress(_ value: Double) {
        fractionCompleted = value
        progressHandler?(value)
    }
}

@MainActor
private final class PhoneWCProgressObservationStub: PhoneWCSessionProgressObserving {
    private(set) var invalidateCount = 0

    func invalidate() {
        invalidateCount += 1
    }
}

@MainActor
private final class PhoneWCEventRecorder {
    private(set) var statuses: [WatchConnectionStatus] = []
    private(set) var progressValues: [(key: WatchTransferKey, value: Double)] = []
    private(set) var finishedKeys: [WatchTransferKey] = []
    private(set) var acknowledgements: [WatchTransferAcknowledgement] = []
    private(set) var inventories: [WatchInventorySnapshot] = []

    func record(_ event: WatchConnectivityEvent) {
        switch event {
        case let .statusChanged(status):
            statuses.append(status)
        case let .progress(key, value):
            progressValues.append((key, value))
        case let .fileFinished(key, _):
            finishedKeys.append(key)
        case let .acknowledgement(acknowledgement):
            acknowledgements.append(acknowledgement)
        case let .inventory(inventory):
            inventories.append(inventory)
        }
    }
}
