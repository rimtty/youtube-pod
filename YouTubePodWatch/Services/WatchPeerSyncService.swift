import Foundation
@preconcurrency import WatchConnectivity

@MainActor
protocol WatchPeerSyncing: AnyObject {
    var stagedFileHandler: (@MainActor @Sendable (StagedWatchTransferFile) -> Void)? { get set }
    var commandHandler: (@MainActor @Sendable (StagedWatchLibraryCommand) -> Void)? { get set }
    var activationHandler: (@MainActor @Sendable () -> Void)? { get set }
    var hasContentPending: Bool { get }

    func activate()
    func waitForActivation() async throws
    func waitUntilContentDrained() async throws
    func enqueueAcknowledgement(_ acknowledgement: WatchTransferAcknowledgement) throws
    func publishInventory(_ inventory: WatchInventorySnapshot) throws
}

struct WatchConnectivityWaitPolicy: Equatable, Sendable {
    let pollInterval: Duration
    let activationCheckLimit: Int
    let contentCheckLimit: Int
    let requiredConsecutiveEmptyChecks: Int

    static let background = WatchConnectivityWaitPolicy(
        pollInterval: .milliseconds(25),
        activationCheckLimit: 40,
        contentCheckLimit: 80,
        requiredConsecutiveEmptyChecks: 2
    )
}

typealias WatchConnectivityDelay =
    @MainActor @Sendable (Duration) async throws -> Void

@MainActor
final class WatchWCSessionPeerSyncService: NSObject, WatchPeerSyncing {
    nonisolated private let stager: WatchIncomingFileStager
    private let driver: any WatchWCSessionDriving
    private let waitPolicy: WatchConnectivityWaitPolicy
    private let delay: WatchConnectivityDelay
    private var lastActivationFailure: WatchPeerSyncError?
    private var activationRequestIsPending = false

    var stagedFileHandler: (@MainActor @Sendable (StagedWatchTransferFile) -> Void)?
    var commandHandler: (@MainActor @Sendable (StagedWatchLibraryCommand) -> Void)?
    var activationHandler: (@MainActor @Sendable () -> Void)?

    init(
        stager: WatchIncomingFileStager,
        driver: (any WatchWCSessionDriving)? = nil,
        waitPolicy: WatchConnectivityWaitPolicy = .background,
        delay: @escaping WatchConnectivityDelay = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.stager = stager
        self.driver = driver ?? AppleWatchWCSessionDriver()
        self.waitPolicy = waitPolicy
        self.delay = delay
        super.init()
    }

    var hasContentPending: Bool {
        driver.hasContentPending
    }

    func activate() {
        lastActivationFailure = nil
        activationRequestIsPending = true
        driver.installDelegate(self)
        driver.activate()
    }

    func waitForActivation() async throws {
        guard driver.isSupported else {
            throw WatchPeerSyncError.unsupported
        }
        if driver.isActivated {
            activationRequestIsPending = false
            lastActivationFailure = nil
            return
        }
        // `WatchSessionReceiver.start()` is idempotent. A later background
        // wake can arrive after WCSession has become inactive or after an old
        // activation attempt failed. Start a fresh attempt in either case,
        // while avoiding a duplicate activate call for the attempt start()
        // already placed in flight for this wake.
        if !activationRequestIsPending {
            activate()
        }
        defer {
            if !driver.isActivated {
                activationRequestIsPending = false
            }
        }
        let checkLimit = max(1, waitPolicy.activationCheckLimit)
        for index in 0..<checkLimit {
            try Task.checkCancellation()
            if driver.isActivated { return }
            if let lastActivationFailure { throw lastActivationFailure }
            if index + 1 < checkLimit {
                try await delay(waitPolicy.pollInterval)
            }
        }
        throw WatchPeerSyncError.activationTimedOut
    }

    func waitUntilContentDrained() async throws {
        let checkLimit = max(1, waitPolicy.contentCheckLimit)
        let requiredEmptyChecks = max(1, waitPolicy.requiredConsecutiveEmptyChecks)
        var consecutiveEmptyChecks = 0

        for index in 0..<checkLimit {
            try Task.checkCancellation()
            if driver.hasContentPending {
                consecutiveEmptyChecks = 0
            } else {
                consecutiveEmptyChecks += 1
                if consecutiveEmptyChecks >= requiredEmptyChecks { return }
            }
            if index + 1 < checkLimit {
                try await delay(waitPolicy.pollInterval)
            }
        }
        throw WatchPeerSyncError.contentDrainTimedOut
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
        let failure = Self.activationFailure(
            activationState: activationState,
            error: error
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activationRequestIsPending = false
            self.lastActivationFailure = failure
            guard failure == nil else { return }
            self.activationHandler?()
        }
    }

    nonisolated private static func activationFailure(
        activationState: WCSessionActivationState,
        error: (any Error)?
    ) -> WatchPeerSyncError? {
        if let error {
            let nsError = error as NSError
            return .activationFailed(
                code: "\(nsError.domain).\(nsError.code)",
                message: error.localizedDescription
            )
        }
        guard activationState == .activated else {
            return .activationFailed(
                code: "activation-state.\(activationState.rawValue)",
                message: "iPhoneとの同期セッションを開始できませんでした。"
            )
        }
        return nil
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
    case unsupported
    case activationFailed(code: String, message: String)
    case activationTimedOut
    case contentDrainTimedOut

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            "iPhoneとの同期セッションを利用できません。"
        case .unsupported:
            "このApple WatchではiPhoneとの同期を利用できません。"
        case .activationFailed(_, let message):
            message
        case .activationTimedOut:
            "iPhoneとの同期セッションの開始を待機できませんでした。"
        case .contentDrainTimedOut:
            "iPhoneからの受信完了を待機できませんでした。"
        }
    }
}
