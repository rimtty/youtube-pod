import Foundation
@preconcurrency import WatchConnectivity

@MainActor
protocol WatchPeerSyncing: AnyObject {
    var stagedFileHandler: (@MainActor @Sendable (StagedWatchTransferFile) -> Void)? { get set }
    var commandHandler: (@MainActor @Sendable (StagedWatchLibraryCommand) -> Void)? { get set }
    var activationHandler: (@MainActor @Sendable () -> Void)? { get set }

    func activate()
    func enqueueAcknowledgement(_ acknowledgement: WatchTransferAcknowledgement) throws
    func publishInventory(_ inventory: WatchInventorySnapshot) throws
}

@MainActor
final class WatchWCSessionPeerSyncService: NSObject, WatchPeerSyncing {
    nonisolated private let stager: WatchIncomingFileStager
    private let driver: any WatchWCSessionDriving

    var stagedFileHandler: (@MainActor @Sendable (StagedWatchTransferFile) -> Void)?
    var commandHandler: (@MainActor @Sendable (StagedWatchLibraryCommand) -> Void)?
    var activationHandler: (@MainActor @Sendable () -> Void)?

    init(
        stager: WatchIncomingFileStager,
        driver: (any WatchWCSessionDriving)? = nil
    ) {
        self.stager = stager
        self.driver = driver ?? AppleWatchWCSessionDriver()
        super.init()
    }

    func activate() {
        driver.installDelegate(self)
        driver.activate()
    }

    func enqueueAcknowledgement(_ acknowledgement: WatchTransferAcknowledgement) throws {
        guard driver.isActivated else {
            throw WatchPeerSyncError.sessionUnavailable
        }
        driver.transferUserInfo(try acknowledgement.userInfo())
    }

    func publishInventory(_ inventory: WatchInventorySnapshot) throws {
        guard driver.isActivated else {
            throw WatchPeerSyncError.sessionUnavailable
        }
        try driver.updateApplicationContext(inventory.applicationContext())
    }
}

extension WatchWCSessionPeerSyncService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        handleActivationCompletion(
            activationState: activationState,
            error: error
        )
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        if let failureUserInfo = handleReceivedFile(
            at: file.fileURL,
            metadata: file.metadata ?? [:]
        ) {
            session.transferUserInfo(failureUserInfo)
        }
    }

    /// Normalized file callback core that is intentionally synchronous.
    ///
    /// WatchConnectivity owns `fileURL` and may delete it when its delegate
    /// callback returns. Staging must therefore complete in this method before
    /// the MainActor handler is scheduled.
    nonisolated func handleReceivedFile(
        at fileURL: URL,
        metadata: [String: Any]
    ) -> [String: Any]? {
        do {
            let staged = try stager.stage(
                fileAt: fileURL,
                metadata: metadata
            )
            Task { @MainActor [weak self] in
                self?.stagedFileHandler?(staged)
            }
            return nil
        } catch {
            // The callback URL cannot outlive this method. If metadata still
            // identifies an audio transfer, enqueue a durable failure
            // immediately. Artwork is optional and malformed metadata has no
            // safe peer identity to acknowledge.
            return Self.stagingFailureUserInfo(
                metadata: metadata,
                message: error.localizedDescription
            )
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        if let failureUserInfo = handleReceivedUserInfo(userInfo) {
            session.transferUserInfo(failureUserInfo)
        }
    }

    /// Persists a deletion command before the delegate callback returns.
    /// Returning a payload lets the thin Apple delegate method deliver a
    /// deterministic failure acknowledgement without exposing `WCSession` to
    /// unit tests.
    nonisolated func handleReceivedUserInfo(
        _ userInfo: [String: Any]
    ) -> [String: Any]? {
        do {
            let stagedCommand = try stager.stageCommand(userInfo: userInfo)
            Task { @MainActor [weak self] in
                self?.commandHandler?(stagedCommand)
            }
            return nil
        } catch {
            // If the command identity is valid but the durable receipt cannot
            // be written, tell iPhone to retry instead of silently accepting a
            // deletion that was never applied.
            guard let command = try? WatchLibraryCommand.decode(userInfo: userInfo),
                  let acknowledgement = try? WatchTransferAcknowledgement(
                    transferID: command.commandID,
                    revision: command.revision,
                    youtubeID: command.youtubeID,
                    outcome: .failed,
                    errorCode: .stagingFailure,
                    message: error.localizedDescription
                  ).userInfo() else { return nil }
            return acknowledgement
        }
    }

    nonisolated func handleActivationCompletion(
        activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated, error == nil else { return }
        Task { @MainActor [weak self] in
            self?.activationHandler?()
        }
    }

    nonisolated static func stagingFailureUserInfo(
        metadata: [String: Any],
        message: String
    ) -> [String: Any]? {
        guard let envelope = try? WatchTransferEnvelope.decode(metadata: metadata),
              envelope.fileKind == .audio else { return nil }
        return try? WatchTransferAcknowledgement(
            transferID: envelope.transferID,
            revision: envelope.revision,
            youtubeID: envelope.youtubeID,
            outcome: .failed,
            errorCode: .stagingFailure,
            message: message
        ).userInfo()
    }
}

enum WatchPeerSyncError: LocalizedError, Equatable, Sendable {
    case sessionUnavailable

    var errorDescription: String? {
        "iPhoneとの同期セッションを利用できません。"
    }
}
