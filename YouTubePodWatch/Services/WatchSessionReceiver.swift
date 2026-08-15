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
    private let stager: WatchIncomingFileStager
    private let library: WatchAudioLibraryService
    private let peer: any WatchPeerSyncing
    private let availableCapacity: @MainActor @Sendable () -> Int64?
    private let invalidatePlaybackItem: @MainActor @Sendable (String) -> Void

    private var hasStarted = false
    private var isSynchronizing = false
    private var needsAnotherPass = false

    private(set) var isReceiving = false
    private(set) var lastErrorMessage: String?

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
        guard !isSynchronizing else {
            needsAnotherPass = true
            return
        }

        isSynchronizing = true
        isReceiving = true
        defer {
            isSynchronizing = false
            isReceiving = false
            if needsAnotherPass {
                needsAnotherPass = false
                requestSynchronization()
            }
        }

        do {
            // Do not let a later malformed/persistence-failed receipt starve
            // acknowledgements that were durably committed by an earlier pass.
            _ = flushAcknowledgements()

            for stagedCommand in try stager.listStagedCommands() {
                invalidatePlaybackItem(stagedCommand.command.youtubeID)
                let result = library.delete(stagedCommand.command)
                if result == .persistenceFailed {
                    lastErrorMessage = "削除操作を保存できませんでした。次回の同期で再試行します。"
                    return
                }
                try stager.remove(stagedCommand)
            }

            let stagedFiles = try stager.listStagedFiles()
            for stagedFile in stagedFiles {
                if stagedFile.envelope.fileKind == .audio {
                    // Import may replace and remove the existing file. Clear
                    // any immutable URL captured by AVPlayer/queue first.
                    invalidatePlaybackItem(stagedFile.envelope.youtubeID)
                }
                let result = await library.importStagedFile(stagedFile)
                // A persistence failure intentionally leaves the receipt in
                // place. Stop this pass to avoid a hot retry loop and resume on
                // the next activation, delivery, or explicit synchronization.
                if result == .persistenceFailed {
                    lastErrorMessage = "受信した音声を保存できませんでした。次回の同期で再試行します。"
                    return
                }
                try stager.remove(stagedFile)
            }

            guard flushAcknowledgements() else { return }
            try peer.publishInventory(
                library.inventory(availableCapacity: availableCapacity())
            )
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
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
        if isSynchronizing {
            needsAnotherPass = true
            return
        }
        Task { @MainActor [weak self] in
            await self?.synchronizeNow()
        }
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
