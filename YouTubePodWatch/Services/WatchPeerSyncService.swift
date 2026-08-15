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
    private let session: WCSession?

    var stagedFileHandler: (@MainActor @Sendable (StagedWatchTransferFile) -> Void)?
    var commandHandler: (@MainActor @Sendable (StagedWatchLibraryCommand) -> Void)?
    var activationHandler: (@MainActor @Sendable () -> Void)?

    init(
        stager: WatchIncomingFileStager,
        session: WCSession? = WCSession.isSupported() ? .default : nil
    ) {
        self.stager = stager
        self.session = session
        super.init()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func enqueueAcknowledgement(_ acknowledgement: WatchTransferAcknowledgement) throws {
        guard let session, session.activationState == .activated else {
            throw WatchPeerSyncError.sessionUnavailable
        }
        session.transferUserInfo(try acknowledgement.userInfo())
    }

    func publishInventory(_ inventory: WatchInventorySnapshot) throws {
        guard let session, session.activationState == .activated else {
            throw WatchPeerSyncError.sessionUnavailable
        }
        try session.updateApplicationContext(inventory.applicationContext())
    }
}

extension WatchWCSessionPeerSyncService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated, error == nil else { return }
        Task { @MainActor [weak self] in
            self?.activationHandler?()
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        do {
            let staged = try stager.stage(
                fileAt: file.fileURL,
                metadata: file.metadata ?? [:]
            )
            Task { @MainActor [weak self] in
                self?.stagedFileHandler?(staged)
            }
        } catch {
            // The callback URL cannot outlive this method. If metadata still
            // identifies the transfer, enqueue a durable failure immediately;
            // malformed metadata has no safe peer identity to acknowledge.
            guard let envelope = try? WatchTransferEnvelope.decode(metadata: file.metadata ?? [:]),
                  let userInfo = try? WatchTransferAcknowledgement(
                    transferID: envelope.transferID,
                    revision: envelope.revision,
                    youtubeID: envelope.youtubeID,
                    outcome: .failed,
                    errorCode: .stagingFailure,
                    message: error.localizedDescription
                  ).userInfo() else { return }
            session.transferUserInfo(userInfo)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        do {
            let stagedCommand = try stager.stageCommand(userInfo: userInfo)
            Task { @MainActor [weak self] in
                self?.commandHandler?(stagedCommand)
            }
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
                  ).userInfo() else { return }
            session.transferUserInfo(acknowledgement)
        }
    }
}

enum WatchPeerSyncError: LocalizedError, Equatable, Sendable {
    case sessionUnavailable

    var errorDescription: String? {
        "iPhoneとの同期セッションを利用できません。"
    }
}
