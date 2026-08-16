import Foundation
@preconcurrency import WatchConnectivity

@MainActor
final class WCSessionAdapter: NSObject, WatchConnectivityTransport {
    private let driver: any PhoneWCSessionDriving
    private var observations: [WatchTransferKey: any PhoneWCSessionProgressObserving] = [:]
    var eventHandler: (@MainActor @Sendable (WatchConnectivityEvent) -> Void)?

    init(driver: (any PhoneWCSessionDriving)? = nil) {
        self.driver = driver ?? ApplePhoneWCSessionDriver()
        super.init()
    }

    var status: WatchConnectionStatus {
        guard driver.isSupported else { return .unsupported }
        let activation = Self.activation(from: driver.activationState)
        let isActivated = activation == .activated
        return WatchConnectionStatus(
            activation: activation,
            isPaired: isActivated ? driver.isPaired : nil,
            isWatchAppInstalled: isActivated ? driver.isWatchAppInstalled : nil
        )
    }

    func activate() {
        guard driver.isSupported else {
            eventHandler?(.statusChanged(.unsupported))
            return
        }
        driver.installDelegate(self)
        if driver.activationState == .activated {
            eventHandler?(.statusChanged(status))
            emitInventory(from: driver.receivedApplicationContext)
            return
        }
        // WCSession's counterpart properties are only documented as correct
        // after activation, so do not surface guessed pairing values here.
        eventHandler?(.statusChanged(WatchConnectionStatus(
            activation: .activating,
            isPaired: nil,
            isWatchAppInstalled: nil
        )))
        driver.activate()
    }

    func outstandingFiles() -> [OutstandingWatchFile] {
        guard driver.isSupported else { return [] }
        return driver.outstandingFileTransfers.compactMap { transfer in
            guard let envelope = try? WatchTransferEnvelope.decode(metadata: transfer.metadata) else {
                return nil
            }
            observeProgress(of: transfer, envelope: envelope)
            return OutstandingWatchFile(
                key: WatchTransferKey(transferID: envelope.transferID, fileKind: envelope.fileKind),
                fileURL: transfer.fileURL,
                progress: transfer.fractionCompleted
            )
        }
    }

    func enqueueFile(at url: URL, envelope: WatchTransferEnvelope) throws {
        guard driver.isSupported else { throw WatchConnectivityAdapterError.unsupported }
        guard status.canTransfer else { throw WatchConnectivityAdapterError.unavailable }
        let transfer = try driver.transferFile(url, metadata: envelope.metadata())
        observeProgress(of: transfer, envelope: envelope)
    }

    func sendDeletionCommand(_ command: WatchLibraryCommand) throws {
        guard driver.isSupported else { throw WatchConnectivityAdapterError.unsupported }
        guard status.canTransfer else { throw WatchConnectivityAdapterError.unavailable }
        try driver.transferUserInfo(command.userInfo())
    }

    func requestInventory(_ request: WatchInventoryRequest) throws {
        guard driver.isSupported else { throw WatchConnectivityAdapterError.unsupported }
        guard status.canTransfer else { throw WatchConnectivityAdapterError.unavailable }
        try driver.updateApplicationContext(request.applicationContext())
    }

    func cancelFiles(transferID: UUID) {
        guard driver.isSupported else { return }
        for transfer in driver.outstandingFileTransfers {
            guard let envelope = try? WatchTransferEnvelope.decode(metadata: transfer.metadata),
                  envelope.transferID == transferID else { continue }
            transfer.cancel()
            let key = WatchTransferKey(
                transferID: envelope.transferID,
                fileKind: envelope.fileKind
            )
            observations.removeValue(forKey: key)?.invalidate()
        }
    }

    private func observeProgress(
        of transfer: any PhoneWCSessionFileTransferDriving,
        envelope: WatchTransferEnvelope
    ) {
        let key = WatchTransferKey(transferID: envelope.transferID, fileKind: envelope.fileKind)
        guard observations[key] == nil else { return }
        observations[key] = transfer.observeProgress { [weak self] value in
            self?.eventHandler?(.progress(key, value))
        }
    }

    private func handleFinished(key: WatchTransferKey, failure: WatchTransportFailure?) {
        observations.removeValue(forKey: key)?.invalidate()
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

    func handleActivationCompletion(
        succeeded: Bool,
        inventory: WatchInventorySnapshot?
    ) {
        eventHandler?(.statusChanged(status))
        guard succeeded, let inventory else { return }
        eventHandler?(.inventory(inventory))
    }

    func handleStatusChange() {
        eventHandler?(.statusChanged(status))
    }

    func handleDeactivation() {
        driver.activate()
        eventHandler?(.statusChanged(status))
    }

    func emit(_ event: WatchConnectivityEvent) {
        switch event {
        case let .fileFinished(key, failure):
            handleFinished(key: key, failure: failure)
        default:
            eventHandler?(event)
        }
    }

    nonisolated static func normalizedFinishedEvent(
        metadata: [String: Any],
        error: (any Error)?
    ) -> WatchConnectivityEvent? {
        guard let envelope = try? WatchTransferEnvelope.decode(metadata: metadata) else {
            return nil
        }
        return .fileFinished(
            WatchTransferKey(
                transferID: envelope.transferID,
                fileKind: envelope.fileKind
            ),
            transportFailure(from: error)
        )
    }

    nonisolated static func normalizedAcknowledgementEvent(
        userInfo: [String: Any]
    ) -> WatchConnectivityEvent? {
        guard let acknowledgement = try? WatchTransferAcknowledgement.decode(
            userInfo: userInfo
        ) else { return nil }
        return .acknowledgement(acknowledgement)
    }

    nonisolated static func normalizedInventoryEvent(
        applicationContext: [String: Any]
    ) -> WatchConnectivityEvent? {
        guard let inventory = try? WatchInventorySnapshot.decode(
            applicationContext: applicationContext
        ) else { return nil }
        return .inventory(inventory)
    }

    nonisolated static func transportFailure(
        from error: (any Error)?
    ) -> WatchTransportFailure? {
        guard let error else { return nil }
        let nsError = error as NSError
        return WatchTransportFailure(
            code: "\(nsError.domain).\(nsError.code)",
            message: error.localizedDescription,
            isRetryable: isRetryable(nsError)
        )
    }

    nonisolated private static func isRetryable(_ error: NSError) -> Bool {
        guard error.domain == WCErrorDomain,
              let code = WCError.Code(rawValue: error.code) else {
            // Unknown and non-WatchConnectivity errors may represent a
            // transient underlying transport failure. The service still caps
            // automatic retries at two attempts.
            return true
        }
        switch code {
        case .sessionNotSupported,
             .sessionMissingDelegate,
             .deviceNotPaired,
             .watchAppNotInstalled,
             .invalidParameter,
             .payloadTooLarge,
             .payloadUnsupportedTypes,
             .fileAccessDenied,
             .insufficientSpace,
             .companionAppNotInstalled,
             .watchOnlyApp:
            return false
        case .genericError,
             .sessionNotActivated,
             .notReachable,
             .messageReplyFailed,
             .messageReplyTimedOut,
             .deliveryFailed,
             .sessionInactive,
             .transferTimedOut:
            return true
        @unknown default:
            return true
        }
    }
}

extension WCSessionAdapter: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let succeeded = activationState == .activated && error == nil
        let inventory: WatchInventorySnapshot?
        if succeeded,
           case let .inventory(value)? = Self.normalizedInventoryEvent(
            applicationContext: session.receivedApplicationContext
           ) {
            inventory = value
        } else {
            inventory = nil
        }
        Task { @MainActor [weak self] in
            self?.handleActivationCompletion(
                succeeded: succeeded,
                inventory: inventory
            )
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.handleStatusChange()
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.handleDeactivation()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.handleStatusChange()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: (any Error)?
    ) {
        guard let event = Self.normalizedFinishedEvent(
            metadata: fileTransfer.file.metadata ?? [:],
            error: error
        ) else { return }
        Task { @MainActor [weak self] in
            self?.emit(event)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let event = Self.normalizedAcknowledgementEvent(userInfo: userInfo) else { return }
        Task { @MainActor [weak self] in
            self?.emit(event)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let event = Self.normalizedInventoryEvent(
            applicationContext: applicationContext
        ) else { return }
        Task { @MainActor [weak self] in
            self?.emit(event)
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
