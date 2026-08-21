import Foundation
import Observation

/// Coordinates the durable WatchConnectivity inbox with the local library.
///
/// `WatchIncomingFileStager` owns the synchronous delegate-callback boundary.
/// This receiver only works with durable receipts, so suspension or process
/// termination after the callback cannot invalidate a temporary WCSession URL.
@MainActor
@Observable
final class WatchSessionReceiver {
    private struct SynchronizationOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let stager: WatchIncomingFileStager
    private let library: WatchAudioLibraryService
    private let peer: any WatchPeerSyncing
    private let availableCapacity: @MainActor @Sendable () -> Int64?
    private let invalidatePlaybackItem: @MainActor @Sendable (String) -> Void

    private var hasStarted = false
    private var synchronizationOperation: SynchronizationOperation?
    private var needsAnotherPass = false

    private(set) var isReceiving = false
    private(set) var lastErrorMessage: String?

#if DEBUG
    /// Installs deterministic presentation state without activating a live
    /// WatchConnectivity session. Only the DEBUG UI-test composition calls it.
    func installUITestFixture(errorMessage: String) {
        guard !hasStarted else { return }
        isReceiving = false
        lastErrorMessage = errorMessage
    }
#endif

    init(
        stager: WatchIncomingFileStager,
        library: WatchAudioLibraryService,
        peer: any WatchPeerSyncing,
        availableCapacity: @escaping @MainActor @Sendable () -> Int64? = { nil },
        invalidatePlaybackItem: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.stager = stager
        self.library = library
        self.peer = peer
        self.availableCapacity = availableCapacity
        self.invalidatePlaybackItem = invalidatePlaybackItem
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        peer.stagedFileHandler = { [weak self] _ in
            self?.requestSynchronization()
        }
        peer.commandHandler = { [weak self] _ in
            self?.requestSynchronization()
        }
        peer.inventoryRequestHandler = { [weak self] _ in
            self?.requestSynchronization()
        }
        peer.activationHandler = { [weak self] in
            self?.requestSynchronization()
        }

        do {
            try library.cleanupOnStartup()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        do {
            _ = try stager.cleanupOnStartup()
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        peer.activate()
        requestSynchronization()
    }

    func synchronizeNow() async {
        let task = ensureSynchronizationTask(requestAnotherPassIfRunning: true)
        await task.value
    }

    /// Keeps the SwiftUI Watch Connectivity background task alive until the
    /// WCSession inbox is drained and every durable receipt has reached an
    /// idle synchronization boundary. Returning from this method completes the
    /// system-owned background task.
    func handleConnectivityBackgroundTask() async {
        start()
        do {
            try await peer.waitForActivation()
            try await peer.waitUntilContentDrained()

            try await synchronizeForBackgroundTask()

            // A WCSession delegate callback stages its receipt synchronously,
            // then schedules its MainActor notification. A second quiet period
            // closes the small gap between those two operations. Always scan
            // the durable inbox again: the notification Task itself may not
            // have run yet, so an in-memory generation cannot prove the inbox
            // stayed unchanged. A duplicate inventory is safe and bounded.
            try await peer.waitUntilContentDrained()
            try await synchronizeForBackgroundTask()
            await waitUntilSynchronizationIdle()
            try Task.checkCancellation()
        } catch is CancellationError {
            cancelSynchronizationForSuspension()
            await waitUntilSynchronizationIdle()
        } catch {
            // An activation/drain failure can race the startup synchronization
            // scheduled by start(). Do not tell the system-owned background
            // task it is complete while that unstructured operation is still
            // touching durable receipts.
            cancelSynchronizationForSuspension()
            await waitUntilSynchronizationIdle()
            lastErrorMessage = error.localizedDescription
        }
    }

    func waitUntilSynchronizationIdle() async {
        while let operation = synchronizationOperation {
            await operation.task.value
        }
    }

    private func ensureSynchronizationTask(
        requestAnotherPassIfRunning: Bool
    ) -> Task<Void, Never> {
        if let operation = synchronizationOperation {
            if requestAnotherPassIfRunning {
                needsAnotherPass = true
            }
            return operation.task
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSynchronizationLoop(operationID: id)
        }
        synchronizationOperation = SynchronizationOperation(id: id, task: task)
        return task
    }

    private func runSynchronizationLoop(operationID: UUID) async {
        isReceiving = true
        defer {
            isReceiving = false
            if synchronizationOperation?.id == operationID {
                synchronizationOperation = nil
            }
        }

        repeat {
            needsAnotherPass = false
            let mayRunAnotherPass = await performSynchronizationPass()
            guard mayRunAnotherPass else { break }
        } while needsAnotherPass
    }

    private func performSynchronizationPass() async -> Bool {
        do {
            try Task.checkCancellation()

            // Do not let a later malformed/persistence-failed receipt starve
            // acknowledgements that were durably committed by an earlier pass.
            _ = flushAcknowledgements()

            for stagedCommand in try stager.listStagedCommands() {
                try Task.checkCancellation()
                invalidatePlaybackItem(stagedCommand.command.youtubeID)
                let result = library.delete(stagedCommand.command)
                if result == .persistenceFailed {
                    lastErrorMessage = "削除操作を保存できませんでした。次回の同期で再試行します。"
                    return false
                }
                // If the system expires the background task after the durable
                // mutation, keep the command receipt. Replaying it is idempotent.
                try Task.checkCancellation()
                try stager.remove(stagedCommand)
            }

            let stagedFiles = try stager.listStagedFiles()
            for stagedFile in stagedFiles {
                try Task.checkCancellation()
                if stagedFile.envelope.fileKind == .audio {
                    // Import may replace and remove the existing file. Clear
                    // any immutable URL captured by AVPlayer/queue first.
                    invalidatePlaybackItem(stagedFile.envelope.youtubeID)
                }
                let result = await library.importStagedFile(stagedFile)
                // Background expiration is retryable, not a terminal transfer
                // failure. Keep the durable receipt and do not flush an ACK.
                if result == .cancelled { return false }
                // A persistence failure intentionally leaves the receipt in
                // place. Stop this pass to avoid a hot retry loop and resume on
                // the next activation, delivery, or explicit synchronization.
                if result == .persistenceFailed {
                    lastErrorMessage = "受信した音声を保存できませんでした。次回の同期で再試行します。"
                    return false
                }
                // Import can commit before an asynchronous cancellation is
                // observed. Retain the receipt so the next pass can reconcile
                // the exact duplicate instead of losing the delivery boundary.
                try Task.checkCancellation()
                try stager.remove(stagedFile)
            }

            guard flushAcknowledgements() else { return false }
            let inventoryRequest = peer.currentInventoryRequest()
            try peer.publishInventory(
                library.inventory(
                    availableCapacity: availableCapacity(),
                    respondingToRequestID: inventoryRequest?.requestID
                )
            )
            lastErrorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Deletes an item initiated on Apple Watch and immediately publishes the
    /// resulting acknowledgement and authoritative inventory to iPhone.
    /// The caller must stop and clear playback before invoking this method.
    @discardableResult
    func deleteFromWatch(_ saved: WatchSavedAudio) async -> WatchLibraryImportResult {
        invalidatePlaybackItem(saved.youtubeID)
        let result = library.delete(WatchLibraryCommand(
            // Watch-originated deletion must acknowledge the same transfer
            // identity that iPhone currently tracks. A new command identity
            // would be ignored by PhoneWatchTransferService as stale.
            commandID: saved.transferID,
            kind: .delete,
            youtubeID: saved.youtubeID,
            revision: saved.revision
        ))
        guard result != .persistenceFailed else {
            lastErrorMessage = "削除操作を保存できませんでした。もう一度お試しください。"
            return result
        }
        await synchronizeNow()
        return result
    }

    private func requestSynchronization() {
        _ = ensureSynchronizationTask(requestAnotherPassIfRunning: true)
    }

    private func synchronizeForBackgroundTask() async throws {
        try await withTaskCancellationHandler {
            await synchronizeNow()
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSynchronizationForSuspension()
            }
        }
    }

    private func cancelSynchronizationForSuspension() {
        synchronizationOperation?.task.cancel()
    }

    private func flushAcknowledgements() -> Bool {
        let pendingAcknowledgements: [WatchPendingAcknowledgement]
        do {
            pendingAcknowledgements = try library.pendingAcknowledgements()
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        for pending in pendingAcknowledgements {
            let acknowledgement: WatchTransferAcknowledgement
            do {
                acknowledgement = try pending.validatedAcknowledgement()
            } catch {
                // A corrupt row can never become sendable. Quarantine it so it
                // cannot poison every later ACK and inventory publication.
                do {
                    try library.acknowledgementSent(id: pending.acknowledgementID)
                } catch {
                    lastErrorMessage = error.localizedDescription
                    return false
                }
                lastErrorMessage = error.localizedDescription
                continue
            }
            do {
                try peer.enqueueAcknowledgement(acknowledgement)
                try library.acknowledgementSent(id: pending.acknowledgementID)
            } catch {
                try? library.acknowledgementAttemptFailed(id: pending.acknowledgementID)
                lastErrorMessage = error.localizedDescription
                return false
            }
        }
        return true
    }
}
