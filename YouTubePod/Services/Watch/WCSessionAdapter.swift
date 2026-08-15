import Foundation
import Observation
@preconcurrency import WatchConnectivity

@MainActor
final class WCSessionAdapter: NSObject, WatchConnectivityTransport {
    private let session: WCSession?
    private var observations: [WatchTransferKey: NSKeyValueObservation] = [:]
    var eventHandler: (@MainActor @Sendable (WatchConnectivityEvent) -> Void)?

    init(session: WCSession? = WCSession.isSupported() ? .default : nil) {
        self.session = session
        super.init()
    }

    var status: WatchConnectionStatus {
        guard let session else { return .unsupported }
        let activation = Self.activation(from: session.activationState)
        let isActivated = activation == .activated
        return WatchConnectionStatus(
            activation: activation,
            isPaired: isActivated ? session.isPaired : nil,
            isWatchAppInstalled: isActivated ? session.isWatchAppInstalled : nil
        )
    }

    func activate() {
        guard let session else {
            eventHandler?(.statusChanged(.unsupported))
            return
        }
        session.delegate = self
        if session.activationState == .activated {
            eventHandler?(.statusChanged(status))
            emitInventory(from: session.receivedApplicationContext)
            return
        }
        eventHandler?(.statusChanged(WatchConnectionStatus(
            activation: .activating,
            isPaired: session.isPaired,
            isWatchAppInstalled: session.isWatchAppInstalled
        )))
        session.activate()
    }

    func outstandingFiles() -> [OutstandingWatchFile] {
        guard let session else { return [] }
        return session.outstandingFileTransfers.compactMap { transfer in
            guard let envelope = try? WatchTransferEnvelope.decode(metadata: transfer.file.metadata ?? [:]) else {
                return nil
            }
            observeProgress(of: transfer, envelope: envelope)
            return OutstandingWatchFile(
                key: WatchTransferKey(transferID: envelope.transferID, fileKind: envelope.fileKind),
                fileURL: transfer.file.fileURL,
                progress: transfer.progress.fractionCompleted
            )
        }
    }

    func enqueueFile(at url: URL, envelope: WatchTransferEnvelope) throws {
        guard let session else { throw WatchConnectivityAdapterError.unsupported }
        guard status.canTransfer else { throw WatchConnectivityAdapterError.unavailable }
        let transfer = session.transferFile(url, metadata: try envelope.metadata())
        observeProgress(of: transfer, envelope: envelope)
    }

    func sendDeletionCommand(_ command: WatchLibraryCommand) throws {
        guard let session else { throw WatchConnectivityAdapterError.unsupported }
        guard status.canTransfer else { throw WatchConnectivityAdapterError.unavailable }
        session.transferUserInfo(try command.userInfo())
    }

    func cancelFiles(transferID: UUID) {
        guard let session else { return }
        for transfer in session.outstandingFileTransfers {
            guard let envelope = try? WatchTransferEnvelope.decode(metadata: transfer.file.metadata ?? [:]),
                  envelope.transferID == transferID else { continue }
            transfer.cancel()
            observations[WatchTransferKey(
                transferID: envelope.transferID,
                fileKind: envelope.fileKind
            )] = nil
        }
    }

    private func observeProgress(of transfer: WCSessionFileTransfer, envelope: WatchTransferEnvelope) {
        let key = WatchTransferKey(transferID: envelope.transferID, fileKind: envelope.fileKind)
        guard observations[key] == nil else { return }
        observations[key] = transfer.progress.observe(\.fractionCompleted, options: [.initial, .new]) {
            [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor [weak self] in
                self?.eventHandler?(.progress(key, value))
            }
        }
    }

    private func handleFinished(key: WatchTransferKey, failure: WatchTransportFailure?) {
        observations[key] = nil
        eventHandler?(.fileFinished(key, failure))
    }

    private func emitInventory(from applicationContext: [String: Any]) {
        guard let inventory = try? WatchInventorySnapshot.decode(
            applicationContext: applicationContext
        ) else { return }
        eventHandler?(.inventory(inventory))
    }

    private static func activation(from state: WCSessionActivationState) -> WatchSessionActivation {
        switch state {
        case .notActivated: .inactive
        case .inactive: .inactive
        case .activated: .activated
        @unknown default: .inactive
        }
    }
}

extension WCSessionAdapter: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.eventHandler?(.statusChanged(self.status))
            if activationState == .activated, error == nil {
                self.emitInventory(from: session.receivedApplicationContext)
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.eventHandler?(.statusChanged(self.status))
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.eventHandler?(.statusChanged(self.status))
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.eventHandler?(.statusChanged(self.status))
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: (any Error)?
    ) {
        guard let envelope = try? WatchTransferEnvelope.decode(
            metadata: fileTransfer.file.metadata ?? [:]
        ) else { return }
        let key = WatchTransferKey(
            transferID: envelope.transferID,
            fileKind: envelope.fileKind
        )
        let failure = error.map {
            let nsError = $0 as NSError
            return WatchTransportFailure(
                code: "\(nsError.domain).\(nsError.code)",
                message: $0.localizedDescription,
                isRetryable: ![7005, 7006].contains(nsError.code)
            )
        }
        Task { @MainActor [weak self] in
            self?.handleFinished(key: key, failure: failure)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let acknowledgement = try? WatchTransferAcknowledgement.decode(userInfo: userInfo) else { return }
        Task { @MainActor [weak self] in
            self?.eventHandler?(.acknowledgement(acknowledgement))
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let inventory = try? WatchInventorySnapshot.decode(
            applicationContext: applicationContext
        ) else { return }
        Task { @MainActor [weak self] in
            self?.eventHandler?(.inventory(inventory))
        }
    }
}

enum WatchConnectivityAdapterError: LocalizedError {
    case unsupported
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: "この端末ではApple Watch転送を利用できません。"
        case .unavailable: "ペアリング済みApple WatchとWatchアプリを確認してください。"
        }
    }
}
