#if DEBUG
import AVFoundation
import Foundation
import SwiftData

/// Replays the production Watch receive pipeline in Simulator.
///
/// Apple doesn't deliver `WCSession.transferFile` callbacks in Simulator, so
/// this fixture replaces only that system-owned boundary. Staging, media
/// validation, SwiftData persistence, acknowledgements, inventory generation,
/// and the visible Watch library all use their production implementations.
@MainActor
enum WatchSimulatorSyncFixture {
    static let releaseIsolationSentinel = "YOUTUBEPOD_WATCH_SIMULATOR_SYNC_FIXTURE_SENTINEL"
    static let launchArgument = "--watch-sync-simulator-fixture"
    static let youtubeID = "simulator01"

    struct Composition {
        let container: ModelContainer
        let receiver: WatchSessionReceiver
        let player: WatchAudioPlayerService
        let playableAudioURL: (WatchSavedAudio) -> URL?
        let libraryFileURL: (String) -> URL?
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func makeComposition() throws -> Composition {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: WatchSavedAudio.self,
            WatchDeletionTombstone.self,
            WatchPendingAcknowledgement.self,
            WatchLibraryMetadata.self,
            configurations: configuration
        )

        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: releaseIsolationSentinel, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: rootURL)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let callbackURL = rootURL.appending(path: "simulated-wc-callback.m4a")
        try makeSilentM4A(at: callbackURL)
        let fileSize = Int64(
            try callbackURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        let envelope = try WatchTransferEnvelope(
            transferID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            revision: 1,
            fileKind: .audio,
            youtubeID: youtubeID,
            title: "Simulator同期テスト",
            channel: "YouTube Pod",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            viewCount: 12_345,
            duration: 0.5,
            fileSize: fileSize,
            playbackPosition: 0
        ).validated()

        let stager = WatchIncomingFileStager(
            rootDirectoryURL: rootURL.appending(path: "Inbox", directoryHint: .isDirectory)
        )
        let library = WatchAudioLibraryService(
            modelContext: container.mainContext,
            validator: AVFoundationWatchAudioValidator(),
            capacityChecker: FileSystemWatchCapacityChecker(),
            rootURL: rootURL.appending(path: "Library", directoryHint: .isDirectory)
        )
        let player = WatchAudioPlayerService { videoID, position, hasBeenPlayed in
            try library.persistPlaybackPosition(
                videoID: videoID,
                position: position,
                hasBeenPlayed: hasBeenPlayed
            )
        }
        let peer = WatchSimulatorSyncPeer(
            stager: stager,
            callbackURL: callbackURL,
            envelope: envelope
        )
        let receiver = WatchSessionReceiver(
            stager: stager,
            library: library,
            peer: peer,
            invalidatePlaybackItem: { videoID in
                player.removeFromQueue(youtubeID: videoID)
            }
        )

        return Composition(
            container: container,
            receiver: receiver,
            player: player,
            playableAudioURL: { saved in library.audioFileURL(for: saved) },
            libraryFileURL: { relativePath in
                rootURL
                    .appending(path: "Library", directoryHint: .isDirectory)
                    .appending(path: relativePath)
            }
        )
    }

    private static func makeSilentM4A(at url: URL) throws {
        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: 22_050
        ) else {
            throw WatchSimulatorSyncFixtureError.bufferAllocationFailed
        }
        buffer.frameLength = 22_050
        try audioFile.write(from: buffer)
    }
}

@MainActor
private final class WatchSimulatorSyncPeer: WatchPeerSyncing {
    private let stager: WatchIncomingFileStager
    private let callbackURL: URL
    private let envelope: WatchTransferEnvelope
    private var deliveryTask: Task<Void, Never>?
    private var inventoryRequest = WatchInventoryRequest(
        requestID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
        requestedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )

    var stagedFileHandler: (@MainActor @Sendable (StagedWatchTransferFile) -> Void)?
    var commandHandler: (@MainActor @Sendable (StagedWatchLibraryCommand) -> Void)?
    var inventoryRequestHandler: (@MainActor @Sendable (WatchInventoryRequest) -> Void)?
    var pendingTransfersHandler: (@MainActor @Sendable (WatchPendingTransfersSummary) -> Void)?
    var activationHandler: (@MainActor @Sendable () -> Void)?
    private(set) var hasContentPending = true
    private var pendingTransfers: WatchPendingTransfersSummary?

    init(
        stager: WatchIncomingFileStager,
        callbackURL: URL,
        envelope: WatchTransferEnvelope
    ) {
        self.stager = stager
        self.callbackURL = callbackURL
        self.envelope = envelope
    }

    func activate() {
        guard deliveryTask == nil else { return }
        activationHandler?()
        inventoryRequestHandler?(inventoryRequest)
        // Announce the simulated delivery first so the banner transition can
        // be observed, then clear it once the file is staged.
        let announced = WatchPendingTransfersSummary(
            queuedCount: 0,
            transferringCount: 1,
            totalBytes: Int64(envelope.fileSize),
            activeYouTubeID: envelope.youtubeID,
            activeTitle: envelope.title,
            publishedAt: .now
        )
        pendingTransfers = announced
        pendingTransfersHandler?(announced)
        deliveryTask = Task { @MainActor [weak self] in
            do {
                // Leave the empty library visible briefly so a developer can
                // observe the simulated arrival in the Watch Simulator.
                try await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let staged = try stager.stage(
                    fileAt: callbackURL,
                    metadata: envelope.metadata()
                )
                WatchSyncLog.watchPeer.notice(
                    "file_staged boundary=simulator_fixture transfer=\(self.envelope.transferID.uuidString, privacy: .public) revision=\(self.envelope.revision) youtube=\(self.envelope.youtubeID, privacy: .public) kind=\(self.envelope.fileKind.rawValue, privacy: .public)"
                )
                hasContentPending = false
                stagedFileHandler?(staged)
                let cleared = WatchPendingTransfersSummary.none(at: .now)
                pendingTransfers = cleared
                pendingTransfersHandler?(cleared)
            } catch is CancellationError {
                return
            } catch {
                self?.hasContentPending = false
                WatchSyncLog.watchPeer.error(
                    "file_staging_failed boundary=simulator_fixture code=\(WatchSyncLog.errorCode(error), privacy: .public)"
                )
            }
        }
    }

    func waitForActivation() async throws {}
    func waitUntilContentDrained() async throws {
        while hasContentPending {
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    func enqueueAcknowledgement(_ acknowledgement: WatchTransferAcknowledgement) throws {
        WatchSyncLog.watchPeer.notice(
            "ack_enqueued boundary=simulator_fixture transfer=\(acknowledgement.transferID.uuidString, privacy: .public) revision=\(acknowledgement.revision) youtube=\(acknowledgement.youtubeID, privacy: .public) outcome=\(acknowledgement.outcome.rawValue, privacy: .public)"
        )
    }
    func publishInventory(_ inventory: WatchInventorySnapshot) throws {
        WatchSyncLog.watchPeer.notice(
            "inventory_published boundary=simulator_fixture generation=\(inventory.generation) entries=\(inventory.entries.count)"
        )
    }
    func currentInventoryRequest() -> WatchInventoryRequest? { inventoryRequest }
    func currentPendingTransfers() -> WatchPendingTransfersSummary? { pendingTransfers }
}

private enum WatchSimulatorSyncFixtureError: Error {
    case bufferAllocationFailed
}
#endif
