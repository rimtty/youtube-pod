import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PhoneWatchTransferService: WatchTransferManaging {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let transport: any WatchConnectivityTransport
    private let snapshots: any WatchTransferSnapshotStoring
    private let inventoryCursorStore: any WatchInventoryCursorStoring
    private let inventoryRequestStore: any WatchInventoryRequestStoring
    private let makeInventoryRequest: @MainActor () -> WatchInventoryRequest
    private let automaticRetryDelays: [Duration]
    private let confirmationTimeout: TimeInterval
    private var isDrainingQueuedTransfers = false
    private var lastProgressSaveAt: [UUID: Date] = [:]
    private var automaticRetryTasks: [String: Task<Void, Never>] = [:]
    private var confirmationTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var hasStarted = false
    private var sessionStartedTransferIDs: Set<UUID> = []
    private var pendingInventoryRequest: WatchInventoryRequest?
    private var publishedInventoryRequestID: UUID?

    private(set) var connectionStatus: WatchConnectionStatus
    private(set) var liveProgress: [String: Double] = [:]
    private(set) var lastPersistenceError: String?
    private(set) var latestInventory: WatchInventorySnapshot?

    init(
        modelContext: ModelContext,
        transport: any WatchConnectivityTransport,
        snapshots: any WatchTransferSnapshotStoring,
        inventoryCursorStore: any WatchInventoryCursorStoring = UserDefaultsWatchInventoryCursorStore(),
        inventoryRequestStore: any WatchInventoryRequestStoring = UserDefaultsWatchInventoryRequestStore(),
        makeInventoryRequest: @escaping @MainActor () -> WatchInventoryRequest = {
            WatchInventoryRequest(requestID: UUID(), requestedAt: .now)
        },
        automaticRetryDelays: [Duration] = [.seconds(2), .seconds(10)],
        confirmationTimeout: TimeInterval = 30 * 60
    ) {
        self.modelContainer = modelContext.container
        self.modelContext = modelContext
        self.transport = transport
        self.snapshots = snapshots
        self.inventoryCursorStore = inventoryCursorStore
        self.inventoryRequestStore = inventoryRequestStore
        self.makeInventoryRequest = makeInventoryRequest
        self.automaticRetryDelays = automaticRetryDelays
        self.confirmationTimeout = confirmationTimeout
        connectionStatus = transport.status
        pendingInventoryRequest = inventoryRequestStore.load()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        WatchSyncLog.phoneService.notice("service_started")
        transport.eventHandler = { [weak self] event in
            self?.handle(event)
        }
        transport.activate()
    }

    func refreshState() {
        if pendingInventoryRequest == nil {
            let request = makeInventoryRequest()
            do {
                try inventoryRequestStore.save(request)
                pendingInventoryRequest = request
            } catch {
                lastPersistenceError = error.localizedDescription
                return
            }
        }
        transport.activate()
        publishPendingInventoryRequestIfPossible()
    }

    func enqueue(_ source: WatchTransferSource) async throws {
        guard connectionStatus.canTransfer else {
            throw WatchTransferServiceError.watchUnavailable
        }
        if let existing = record(videoID: source.youtubeID),
           existing.state.isTransferActive || existing.state == .availableOnWatch {
            return
        }
        cancelScheduledTasks(videoID: source.youtubeID)

        let previous = record(videoID: source.youtubeID)
        let previousTransferID = previous?.transferID
        let previousRevision = previous?.revision
        let transferID = UUID()
        let revision = max(1, (previous?.revision ?? 0) + 1)
        WatchSyncLog.phoneService.notice(
            "prepare_started transfer=\(transferID.uuidString, privacy: .public) revision=\(revision) youtube=\(source.youtubeID, privacy: .public)"
        )
        let record: WatchTransferRecord
        if let previous {
            record = previous
            record.title = source.title
            record.channelTitle = source.channelTitle
            record.publishedAt = source.publishedAt
            record.duration = source.duration
            record.savedViewCount = source.savedViewCount
            record.playbackPosition = source.playbackPosition
            record.transferID = transferID
            record.revision = revision
            resetForPreparation(record)
        } else {
            record = WatchTransferRecord(
                youtubeID: source.youtubeID,
                title: source.title,
                channelTitle: source.channelTitle,
                publishedAt: source.publishedAt,
                duration: source.duration,
                savedViewCount: source.savedViewCount,
                sourceFileSize: 0,
                playbackPosition: source.playbackPosition,
                transferID: transferID,
                revision: revision,
                state: .preparing
            )
            modelContext.insert(record)
        }
        do {
            try modelContext.save()
            lastPersistenceError = nil
        } catch {
            modelContext.rollback()
            throw WatchTransferServiceError.persistence(error.localizedDescription)
        }

        let prepared: PreparedWatchTransfer
        do {
            prepared = try await snapshots.prepare(source: source, transferID: transferID)
            record.sourceFileSize = try fileSize(at: prepared.audioURL)
            WatchSyncLog.phoneService.notice(
                "prepare_completed transfer=\(transferID.uuidString, privacy: .public) bytes=\(record.sourceFileSize) artwork=\(prepared.artworkURL != nil)"
            )
        } catch {
            WatchSyncLog.phoneService.error(
                "prepare_failed transfer=\(transferID.uuidString, privacy: .public) code=\(WatchSyncLog.errorCode(error), privacy: .public)"
            )
            await snapshots.removeTransfer(transferID)
            restorePreviousIdentity(
                of: record,
                transferID: previousTransferID,
                revision: previousRevision
            )
            markFailed(record, code: "snapshot", message: error.localizedDescription)
            _ = persistChanges()
            throw error
        }

        do {
            record.artworkExpected = prepared.artworkURL != nil
            record.artworkDeliveryFinished = prepared.artworkURL == nil
            record.state = .queued
            record.queuedAt = .now
            record.updatedAt = .now
            try modelContext.save()
            if let previousTransferID, previousTransferID != transferID {
                await snapshots.removeTransfer(previousTransferID)
            }
            await drainQueuedTransfersIfPossible()
        } catch {
            modelContext.rollback()
            await snapshots.removeTransfer(transferID)
            restorePreviousIdentity(
                of: record,
                transferID: previousTransferID,
                revision: previousRevision
            )
            markFailed(record, code: "persistence", message: error.localizedDescription)
            _ = persistChanges()
            throw WatchTransferServiceError.persistence(error.localizedDescription)
        }
    }

    func cancel(videoID: String) {
        guard let record = record(videoID: videoID) else { return }
        let hadPendingRetry = automaticRetryTasks[videoID] != nil
        let hadPendingConfirmation = confirmationTimeoutTasks[videoID] != nil
        cancelScheduledTasks(videoID: videoID)
        guard record.state.isTransferActive || hadPendingRetry || hadPendingConfirmation else { return }
        record.state = .cancelling
        record.senderFailed = true
        record.updatedAt = .now
        transport.cancelFiles(transferID: record.transferID)
        markFailed(record, code: "cancelled", message: "転送をキャンセルしました。")
        liveProgress[videoID] = nil
        if persistChanges() {
            sessionStartedTransferIDs.remove(record.transferID)
            scheduleQueuedTransfersIfNeeded()
        }
    }

    func retry(videoID: String) async throws {
        guard connectionStatus.canTransfer else {
            throw WatchTransferServiceError.watchUnavailable
        }
        guard let record = record(videoID: videoID),
              record.state == .failed || record.state == .reconciliationRequired else {
            throw WatchTransferServiceError.retryUnavailable
        }
        cancelScheduledTasks(videoID: videoID)
        let oldTransferID = record.transferID
        let expectedRevision = record.revision
        let newTransferID = UUID()
        let prepared = try await snapshots.cloneTransfer(from: oldTransferID, to: newTransferID)
        do {
            try Task.checkCancellation()
        } catch {
            await snapshots.removeTransfer(newTransferID)
            throw error
        }
        guard let current = self.record(videoID: videoID),
              current.transferID == oldTransferID,
              current.revision == expectedRevision,
              current.state == .failed || current.state == .reconciliationRequired else {
            await snapshots.removeTransfer(newTransferID)
            throw WatchTransferServiceError.retryUnavailable
        }
        let preparedFileSize: Int64
        do {
            preparedFileSize = try fileSize(at: prepared.audioURL)
        } catch {
            await snapshots.removeTransfer(newTransferID)
            throw error
        }
        current.transferID = newTransferID
        current.revision += 1
        current.retryCount += 1
        current.sourceFileSize = preparedFileSize
        current.artworkExpected = prepared.artworkURL != nil
        current.audioDeliveryFinished = false
        current.artworkDeliveryFinished = prepared.artworkURL == nil
        current.senderFailed = false
        current.watchImportConfirmed = false
        current.watchImportFailed = false
        current.lastKnownProgress = 0
        current.lastErrorCode = nil
        current.lastErrorMessage = nil
        current.state = .queued
        current.queuedAt = .now
        current.updatedAt = .now
        do {
            try modelContext.save()
            lastPersistenceError = nil
        } catch {
            modelContext.rollback()
            await snapshots.removeTransfer(newTransferID)
            throw WatchTransferServiceError.persistence(error.localizedDescription)
        }
        await snapshots.removeTransfer(oldTransferID)
        await drainQueuedTransfersIfPossible()
    }

    func requestDeletion(videoID: String) throws {
        guard connectionStatus.canTransfer else {
            throw WatchTransferServiceError.watchUnavailable
        }
        guard let record = record(videoID: videoID) else {
            throw WatchTransferServiceError.deletionUnavailable
        }
        guard record.state == .availableOnWatch
                || record.state == .deletionPending
                || record.state == .reconciliationRequired
                || (record.state == .failed && record.lastErrorCode == "delete-send") else {
            if record.state == .removedFromWatch { return }
            throw WatchTransferServiceError.deletionUnavailable
        }

        cancelScheduledTasks(videoID: videoID)
        record.state = .deletionPending
        record.lastErrorCode = nil
        record.lastErrorMessage = nil
        record.updatedAt = .now
        guard persistChanges() else {
            throw WatchTransferServiceError.persistence(
                lastPersistenceError ?? "Apple Watch削除状態を保存できませんでした。"
            )
        }
        transport.cancelFiles(transferID: record.transferID)

        do {
            try sendDeletionCommand(for: record)
        } catch {
            // Keep the durable intent. The same identity is safe to resend on
            // retry or after WCSession activation.
            record.lastErrorCode = "delete-send"
            record.lastErrorMessage = error.localizedDescription
            record.updatedAt = .now
            _ = persistChanges()
            throw error
        }
    }

    private func handle(_ event: WatchConnectivityEvent) {
        switch event {
        case .statusChanged(let status):
            connectionStatus = status
            WatchSyncLog.phoneService.notice(
                "status_changed activation=\(String(describing: status.activation), privacy: .public) paired=\(String(describing: status.isPaired), privacy: .public) installed=\(String(describing: status.isWatchAppInstalled), privacy: .public) can_transfer=\(status.canTransfer)"
            )
            // A status callback defines a new reconciliation boundary. Any
            // transfer remembered only by this process must now be proven by
            // WCSession.outstandingFileTransfers, otherwise a missed
            // didFinish callback could hold the serial queue forever.
            sessionStartedTransferIDs.removeAll()
            if status.canTransfer {
                publishPendingInventoryRequestIfPossible()
                resendPendingDeletionCommands()
                Task { @MainActor [weak self] in
                    await self?.reconcileAndResumeTransfers()
                }
            }

        case .progress(let key, let progress):
            guard key.fileKind == .audio,
                  let record = record(transferID: key.transferID),
                  !record.senderFailed,
                  record.state != .removedFromWatch else { return }
            let normalized = normalizedProgress(progress)
            liveProgress[record.youtubeID] = max(
                liveProgress[record.youtubeID] ?? record.lastKnownProgress,
                normalized
            )
            let now = Date.now
            let crossedTenPercentBoundary = Int(normalized * 10) > Int(record.lastKnownProgress * 10)
            let fiveSecondsElapsed = now.timeIntervalSince(lastProgressSaveAt[key.transferID] ?? .distantPast) >= 5
            if crossedTenPercentBoundary || fiveSecondsElapsed || normalized >= 1 {
                record.lastKnownProgress = max(record.lastKnownProgress, normalized)
                record.updatedAt = now
                lastProgressSaveAt[key.transferID] = now
                _ = persistChanges()
            }

        case .fileFinished(let key, let failure):
            guard let record = record(transferID: key.transferID),
                  record.state != .removedFromWatch else { return }
            if record.senderFailed { return }
            if let failure {
                WatchSyncLog.phoneService.error(
                    "delivery_failed transfer=\(key.transferID.uuidString, privacy: .public) kind=\(key.fileKind.rawValue, privacy: .public) code=\(failure.code, privacy: .public)"
                )
                if key.fileKind == .artwork {
                    // Artwork is optional. Keep the audio transfer usable even
                    // when WatchConnectivity cannot deliver the thumbnail.
                    record.artworkDeliveryFinished = true
                    record.lastErrorCode = "artwork.\(failure.code)"
                    record.lastErrorMessage = failure.message
                    completeEvent(for: record)
                    return
                }
                transport.cancelFiles(transferID: key.transferID)
                record.senderFailed = true
                markFailed(record, code: failure.code, message: failure.message)
                reduceState(of: record)
                liveProgress[record.youtubeID] = nil
                lastProgressSaveAt[key.transferID] = nil
                if persistChanges() {
                    sessionStartedTransferIDs.remove(key.transferID)
                    if record.state == .failed {
                        scheduleAutomaticRetryIfPossible(for: record, failure: failure)
                    } else if record.state == .availableOnWatch {
                        Task { await snapshots.removeTransfer(key.transferID) }
                    }
                    scheduleQueuedTransfersIfNeeded()
                }
                return
            }
            switch key.fileKind {
            case .audio:
                record.audioDeliveryFinished = true
                record.lastKnownProgress = 1
                liveProgress[record.youtubeID] = 1
            case .artwork: record.artworkDeliveryFinished = true
            }
            WatchSyncLog.phoneService.notice(
                "delivery_completed transfer=\(key.transferID.uuidString, privacy: .public) kind=\(key.fileKind.rawValue, privacy: .public)"
            )
            completeEvent(for: record)

        case .acknowledgement(let acknowledgement):
            handleAcknowledgement(acknowledgement)

        case .inventory(let inventory):
            handleInventory(inventory)
        }
    }

    private func handleAcknowledgement(_ acknowledgement: WatchTransferAcknowledgement) {
        guard let record = record(videoID: acknowledgement.youtubeID),
              record.transferID == acknowledgement.transferID,
              record.revision == acknowledgement.revision else { return }
        WatchSyncLog.phoneService.notice(
            "ack_correlated transfer=\(acknowledgement.transferID.uuidString, privacy: .public) revision=\(acknowledgement.revision) youtube=\(acknowledgement.youtubeID, privacy: .public) outcome=\(acknowledgement.outcome.rawValue, privacy: .public)"
        )
        cancelScheduledTasks(videoID: acknowledgement.youtubeID)

        switch acknowledgement.outcome {
        case .imported:
            // A delayed import acknowledgement cannot undo a persisted user
            // deletion intent (or a deletion already confirmed).
            guard record.state != .deletionPending,
                  record.state != .removedFromWatch else { return }
            record.watchImportConfirmed = true
            record.watchImportFailed = false
            record.confirmedAt = .now
            record.lastErrorCode = nil
            record.lastErrorMessage = nil
            completeEvent(for: record)
        case .failed:
            // Once deletion is confirmed, a delayed failure from an older
            // import/command delivery must not resurrect the record.
            guard record.state != .removedFromWatch else { return }
            if record.state == .deletionPending {
                record.state = .reconciliationRequired
                record.lastErrorCode = "watch-delete"
                record.lastErrorMessage = acknowledgement.message
                    ?? "Apple Watchで音声を削除できませんでした。"
                record.updatedAt = .now
                _ = persistChanges()
                return
            }
            record.watchImportFailed = true
            record.senderFailed = true
            transport.cancelFiles(transferID: record.transferID)
            markFailed(
                record,
                code: "watch-import",
                message: acknowledgement.message ?? "Apple Watchで音声を取り込めませんでした。"
            )
            liveProgress[record.youtubeID] = nil
            lastProgressSaveAt[record.transferID] = nil
            if persistChanges() {
                sessionStartedTransferIDs.remove(record.transferID)
                scheduleQueuedTransfersIfNeeded()
            }
        case .deleted:
            transport.cancelFiles(transferID: record.transferID)
            record.state = .removedFromWatch
            record.confirmedAt = .now
            record.watchImportConfirmed = false
            record.watchImportFailed = false
            liveProgress[record.youtubeID] = nil
            if persistChanges() {
                sessionStartedTransferIDs.remove(record.transferID)
                Task { await snapshots.removeTransfer(acknowledgement.transferID) }
                scheduleQueuedTransfersIfNeeded()
            }
        }
    }

    private func handleInventory(_ inventory: WatchInventorySnapshot) {
        WatchSyncLog.phoneService.notice(
            "inventory_applying generation=\(inventory.generation) entries=\(inventory.entries.count)"
        )
        guard inventoryEntriesAreUnique(inventory.entries) else { return }
        let previousCursor = inventoryCursorStore.load()
        guard shouldAccept(inventory, after: previousCursor) else { return }

        let records = fetchRecords()
        guard lastPersistenceError == nil else { return }
        let entries = Dictionary(uniqueKeysWithValues: inventory.entries.map { ($0.youtubeID, $0) })

        for record in records {
            if let entry = entries[record.youtubeID] {
                if record.state == .removedFromWatch {
                    // A delayed application context can outlive the deleted
                    // acknowledgement that superseded it.
                    continue
                }
                guard entry.transferID == record.transferID,
                      entry.revision == record.revision else {
                    // A different identity is never allowed to overwrite the
                    // phone's durable transfer identity. Only flag a record
                    // that had previously claimed Watch availability.
                    if record.state == .availableOnWatch {
                        record.state = .reconciliationRequired
                        record.lastErrorCode = "watch-inventory-conflict"
                        record.lastErrorMessage = "Apple Watch上の項目と転送履歴が一致しません。"
                        record.updatedAt = .now
                    }
                    continue
                }

                if record.state == .deletionPending {
                    // The Watch still reports the item. Keep the deletion
                    // intent and await its deleted acknowledgement or a later
                    // inventory that no longer contains the item.
                    continue
                }
                guard entry.fileSize == record.sourceFileSize else {
                    record.state = .reconciliationRequired
                    record.lastErrorCode = "watch-inventory-size"
                    record.lastErrorMessage = "Apple Watch上の音声サイズが転送履歴と一致しません。"
                    record.updatedAt = .now
                    continue
                }
                cancelScheduledTasks(videoID: record.youtubeID)
                transport.cancelFiles(transferID: record.transferID)
                record.watchImportConfirmed = true
                record.watchImportFailed = false
                record.senderFailed = false
                record.audioDeliveryFinished = true
                record.artworkDeliveryFinished = true
                record.lastKnownProgress = 1
                record.confirmedAt = max(record.confirmedAt ?? .distantPast, inventory.generatedAt)
                record.lastErrorCode = nil
                record.lastErrorMessage = nil
                record.state = .availableOnWatch
                sessionStartedTransferIDs.remove(record.transferID)
                liveProgress[record.youtubeID] = nil
                record.updatedAt = .now
            } else {
                switch record.state {
                case .deletionPending:
                    // Absence is authoritative only when the user has already
                    // requested this exact record be deleted.
                    record.state = .removedFromWatch
                    record.watchImportConfirmed = false
                    record.watchImportFailed = false
                    record.confirmedAt = inventory.generatedAt
                    record.lastErrorCode = nil
                    record.lastErrorMessage = nil
                    liveProgress[record.youtubeID] = nil
                case .availableOnWatch:
                    // A missing entry alone is not proof of deletion: an
                    // incomplete/corrupt Watch library can omit a file. Keep
                    // the record and require reconciliation instead.
                    record.state = .reconciliationRequired
                    record.lastErrorCode = "watch-inventory-missing"
                    record.lastErrorMessage = "Apple Watch上の音声を確認できません。"
                    record.updatedAt = .now
                default:
                    break
                }
            }
        }

        guard persistChanges() else { return }
        do {
            try inventoryCursorStore.save(WatchInventoryCursor(snapshot: inventory))
            latestInventory = inventory
        } catch {
            lastPersistenceError = error.localizedDescription
            return
        }

        if let requestID = inventory.respondingToRequestID,
           requestID == pendingInventoryRequest?.requestID {
            do {
                try inventoryRequestStore.clear()
                pendingInventoryRequest = nil
                publishedInventoryRequestID = nil
            } catch {
                lastPersistenceError = error.localizedDescription
            }
        }

        for record in records where record.state == .removedFromWatch {
            let transferID = record.transferID
            Task { await snapshots.removeTransfer(transferID) }
        }
    }

    private func resendPendingDeletionCommands() {
        for record in fetchRecords() where record.state == .deletionPending {
            do {
                try sendDeletionCommand(for: record)
                record.lastErrorCode = nil
                record.lastErrorMessage = nil
            } catch {
                record.lastErrorCode = "delete-send"
                record.lastErrorMessage = error.localizedDescription
            }
            record.updatedAt = .now
        }
        _ = persistChanges()
    }

    private func publishPendingInventoryRequestIfPossible() {
        guard connectionStatus.canTransfer,
              let request = pendingInventoryRequest,
              publishedInventoryRequestID != request.requestID else { return }
        do {
            try transport.requestInventory(request)
            publishedInventoryRequestID = request.requestID
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }

    private func sendDeletionCommand(for record: WatchTransferRecord) throws {
        try transport.sendDeletionCommand(WatchLibraryCommand(
            commandID: record.transferID,
            kind: .delete,
            youtubeID: record.youtubeID,
            revision: record.revision
        ))
    }

    private func inventoryEntriesAreUnique(_ entries: [WatchInventoryEntry]) -> Bool {
        Set(entries.map(\.youtubeID)).count == entries.count
    }

    private func shouldAccept(
        _ inventory: WatchInventorySnapshot,
        after cursor: WatchInventoryCursor?
    ) -> Bool {
        guard let cursor else { return true }
        if inventory.libraryInstanceID == cursor.libraryInstanceID {
            if inventory.generation > cursor.generation { return true }
            guard inventory.generation == cursor.generation else { return false }
            // A generation identifies one library mutation boundary. Refuse
            // conflicting contents or an older publication carrying the same
            // generation number.
            return inventory.generatedAt >= cursor.generatedAt
                && normalizedEntries(inventory.entries) == normalizedEntries(cursor.entries)
        }
        // Generations are scoped to a library instance. A timestamp prevents
        // a delayed snapshot from the previous Watch library switching the
        // phone back after a reinstall/reset.
        return inventory.generatedAt > cursor.generatedAt
    }

    private func normalizedEntries(_ entries: [WatchInventoryEntry]) -> [WatchInventoryEntry] {
        entries.sorted {
            if $0.youtubeID == $1.youtubeID {
                if $0.revision == $1.revision {
                    return $0.transferID.uuidString < $1.transferID.uuidString
                }
                return $0.revision < $1.revision
            }
            return $0.youtubeID < $1.youtubeID
        }
    }

    private func drainQueuedTransfersIfPossible() async {
        guard !isDrainingQueuedTransfers, connectionStatus.canTransfer else { return }
        isDrainingQueuedTransfers = true
        defer { isDrainingQueuedTransfers = false }

        while connectionStatus.canTransfer {
            guard let record = fetchRecords()
                .filter({ $0.state == .queued })
                .sorted(by: { $0.queuedAt < $1.queuedAt })
                .first else { return }
            guard let prepared = await snapshots.preparedTransfer(transferID: record.transferID) else {
                record.senderFailed = true
                markFailed(
                    record,
                    code: "snapshot-missing",
                    message: WatchTransferSnapshotError.sourceMissing.localizedDescription
                )
                _ = persistChanges()
                continue
            }
            // Queue every prepared file with WatchConnectivity while the phone
            // app is active. WCSession owns the durable background ordering, so
            // later items do not depend on this process receiving the previous
            // item's completion callback before suspension or termination.
            guard connectionStatus.canTransfer else { return }

            record.state = .transferring
            record.senderFailed = false
            record.updatedAt = .now
            do {
                WatchSyncLog.phoneService.notice(
                    "enqueue_started transfer=\(record.transferID.uuidString, privacy: .public) revision=\(record.revision) youtube=\(record.youtubeID, privacy: .public)"
                )
                try transport.enqueueFile(
                    at: prepared.audioURL,
                    envelope: try envelope(for: record, fileKind: .audio, fileURL: prepared.audioURL)
                )
            } catch {
                WatchSyncLog.phoneService.error(
                    "enqueue_failed transfer=\(record.transferID.uuidString, privacy: .public) code=\(WatchSyncLog.errorCode(error), privacy: .public)"
                )
                transport.cancelFiles(transferID: record.transferID)
                record.senderFailed = true
                markFailed(record, code: "enqueue", message: error.localizedDescription)
                sessionStartedTransferIDs.remove(record.transferID)
                _ = persistChanges()
                continue
            }

            if let artworkURL = prepared.artworkURL {
                do {
                    try transport.enqueueFile(
                        at: artworkURL,
                        envelope: try envelope(for: record, fileKind: .artwork, fileURL: artworkURL)
                    )
                } catch {
                    // Artwork is optional. An audio file that has already been
                    // accepted by WatchConnectivity must remain transferable.
                    record.artworkDeliveryFinished = true
                    record.lastErrorCode = "artwork.enqueue"
                    record.lastErrorMessage = error.localizedDescription
                }
            }

            do {
                try modelContext.save()
                sessionStartedTransferIDs.insert(record.transferID)
                lastPersistenceError = nil
            } catch {
                transport.cancelFiles(transferID: record.transferID)
                record.senderFailed = true
                markFailed(record, code: "enqueue", message: error.localizedDescription)
                sessionStartedTransferIDs.remove(record.transferID)
                _ = persistChanges()
            }
        }
    }

    private func reconcileAndResumeTransfers() async {
        let outstanding = transport.outstandingFiles()
        let grouped = Dictionary(grouping: outstanding, by: \.key.transferID)
        let records = fetchRecords()
        guard lastPersistenceError == nil else { return }
        for record in records {
            let files = grouped[record.transferID] ?? []
            let outstandingKinds = Set(files.map(\.key.fileKind))
            switch record.state {
            case .transferring where record.watchImportConfirmed:
                if !outstandingKinds.contains(.audio) {
                    record.audioDeliveryFinished = true
                }
                if !record.artworkExpected || !outstandingKinds.contains(.artwork) {
                    record.artworkDeliveryFinished = true
                }
                reduceState(of: record)
                if record.state == .transferring {
                    updateReconciledAudioProgress(for: record, files: files)
                }
            case .transferring where files.isEmpty && !sessionStartedTransferIDs.contains(record.transferID):
                record.state = .reconciliationRequired
                liveProgress[record.youtubeID] = nil
            case .transferring:
                updateReconciledAudioProgress(for: record, files: files)
            case .preparing:
                record.state = .reconciliationRequired
            case .awaitingWatchConfirmation
                where Date.now.timeIntervalSince(record.updatedAt) >= confirmationTimeout:
                record.state = .reconciliationRequired
            default:
                break
            }
        }
        guard persistChanges() else { return }
        for record in records where record.state == .awaitingWatchConfirmation {
            let elapsed = Date.now.timeIntervalSince(record.updatedAt)
            scheduleConfirmationTimeout(for: record, after: max(0, confirmationTimeout - elapsed))
        }

        await snapshots.removeStagingDirectories()
        // Refetch immediately before orphan collection. Enqueue can finish its
        // actor-backed snapshot preparation while the staging cleanup awaits;
        // using the earlier snapshot of records could delete that new transfer.
        let latestRecords = fetchRecords()
        guard lastPersistenceError == nil else { return }
        let latestOutstanding = transport.outstandingFiles()
        let retryableStates: Set<WatchTransferState> = [
            .preparing, .queued, .transferring, .awaitingWatchConfirmation,
            .failed, .reconciliationRequired
        ]
        let retainedRecordIDs = Set(latestRecords.compactMap {
            retryableStates.contains($0.state) ? $0.transferID : nil
        })
        let outstandingIDs = Set(latestOutstanding.map(\.key.transferID))
        await snapshots.removeOrphans(retaining: retainedRecordIDs.union(outstandingIDs))
        await drainQueuedTransfersIfPossible()
    }

    private func completeEvent(for record: WatchTransferRecord) {
        reduceState(of: record)
        record.updatedAt = .now
        guard persistChanges() else { return }

        if record.state == .awaitingWatchConfirmation {
            scheduleConfirmationTimeout(for: record)
        } else {
            confirmationTimeoutTasks[record.youtubeID]?.cancel()
            confirmationTimeoutTasks[record.youtubeID] = nil
        }

        let senderFinished = record.senderFailed || (
            record.audioDeliveryFinished && record.artworkDeliveryFinished
        )
        if senderFinished {
            sessionStartedTransferIDs.remove(record.transferID)
            lastProgressSaveAt[record.transferID] = nil
            scheduleQueuedTransfersIfNeeded()
        }
        if record.state == .availableOnWatch || record.state == .removedFromWatch {
            let transferID = record.transferID
            Task { await snapshots.removeTransfer(transferID) }
        }
    }

    private func updateReconciledAudioProgress(
        for record: WatchTransferRecord,
        files: [OutstandingWatchFile]
    ) {
        let progress: Double
        if record.audioDeliveryFinished {
            progress = 1
        } else if let audio = files.first(where: { $0.key.fileKind == .audio }) {
            progress = max(record.lastKnownProgress, normalizedProgress(audio.progress))
        } else {
            progress = record.lastKnownProgress
        }
        record.lastKnownProgress = progress
        liveProgress[record.youtubeID] = progress
    }

    private func normalizedProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }

    private func reduceState(of record: WatchTransferRecord) {
        if record.state == .removedFromWatch { return }
        if record.watchImportFailed {
            record.state = .failed
            liveProgress[record.youtubeID] = nil
            return
        }
        if record.senderFailed {
            if record.watchImportConfirmed {
                record.state = .availableOnWatch
                record.lastErrorCode = nil
                record.lastErrorMessage = nil
            } else {
                record.state = .failed
            }
            liveProgress[record.youtubeID] = nil
            return
        }
        let senderFinished = record.audioDeliveryFinished && record.artworkDeliveryFinished
        guard senderFinished else {
            record.state = .transferring
            return
        }
        record.lastKnownProgress = 1
        if record.watchImportConfirmed {
            record.state = .availableOnWatch
            liveProgress[record.youtubeID] = nil
        } else {
            record.state = .awaitingWatchConfirmation
            liveProgress[record.youtubeID] = 1
        }
    }

    private func scheduleQueuedTransfersIfNeeded() {
        guard fetchRecords().contains(where: { $0.state == .queued }) else { return }
        Task { @MainActor [weak self] in
            await self?.drainQueuedTransfersIfPossible()
        }
    }

    private func scheduleAutomaticRetryIfPossible(
        for record: WatchTransferRecord,
        failure: WatchTransportFailure
    ) {
        guard failure.isRetryable,
              record.retryCount < automaticRetryDelays.count else { return }
        let videoID = record.youtubeID
        let expectedTransferID = record.transferID
        let expectedRevision = record.revision
        let delay = automaticRetryDelays[record.retryCount]
        automaticRetryTasks[videoID]?.cancel()
        automaticRetryTasks[videoID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
                guard let self,
                      let current = self.record(videoID: videoID),
                      current.transferID == expectedTransferID,
                      current.revision == expectedRevision,
                      current.state == .failed,
                      !current.watchImportConfirmed else { return }
                self.automaticRetryTasks[videoID] = nil
                try await self.retry(videoID: videoID)
            } catch is CancellationError {
                // An explicit cancellation or a newer retry owns the state.
            } catch {
                guard let self,
                      let current = self.record(videoID: videoID),
                      current.transferID == expectedTransferID,
                      current.revision == expectedRevision,
                      current.state == .failed,
                      !current.watchImportConfirmed else { return }
                self.markFailed(current, code: "automatic-retry", message: error.localizedDescription)
                _ = self.persistChanges()
                self.automaticRetryTasks[videoID] = nil
            }
        }
    }

    private func scheduleConfirmationTimeout(
        for record: WatchTransferRecord,
        after delay: TimeInterval? = nil
    ) {
        let videoID = record.youtubeID
        let expectedTransferID = record.transferID
        let expectedRevision = record.revision
        let timeout = max(0, delay ?? confirmationTimeout)
        confirmationTimeoutTasks[videoID]?.cancel()
        confirmationTimeoutTasks[videoID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
                guard let self,
                      let current = self.record(videoID: videoID),
                      current.transferID == expectedTransferID,
                      current.revision == expectedRevision,
                      current.state == .awaitingWatchConfirmation else { return }
                current.state = .reconciliationRequired
                current.lastErrorCode = "watch-confirmation-timeout"
                current.lastErrorMessage = "Apple Watchからの取り込み確認を待っています。"
                current.updatedAt = .now
                _ = self.persistChanges()
                self.confirmationTimeoutTasks[videoID] = nil
            } catch is CancellationError {
                // A matching acknowledgement or a newer transfer owns state.
            } catch {
                guard let self else { return }
                self.confirmationTimeoutTasks[videoID] = nil
            }
        }
    }

    private func cancelScheduledTasks(videoID: String) {
        automaticRetryTasks[videoID]?.cancel()
        automaticRetryTasks[videoID] = nil
        confirmationTimeoutTasks[videoID]?.cancel()
        confirmationTimeoutTasks[videoID] = nil
    }

    private func envelope(
        for record: WatchTransferRecord,
        fileKind: WatchTransferFileKind,
        fileURL: URL
    ) throws -> WatchTransferEnvelope {
        try WatchTransferEnvelope(
            transferID: record.transferID,
            revision: record.revision,
            fileKind: fileKind,
            youtubeID: record.youtubeID,
            title: record.title,
            channel: record.channelTitle,
            publishedAt: record.publishedAt,
            viewCount: record.savedViewCount,
            duration: record.duration,
            fileSize: fileSize(at: fileURL),
            playbackPosition: record.playbackPosition
        ).validated()
    }

    private func record(videoID: String) -> WatchTransferRecord? {
        fetchRecords().first { $0.youtubeID == videoID }
    }

    private func record(transferID: UUID) -> WatchTransferRecord? {
        fetchRecords().first { $0.transferID == transferID }
    }

    private func fetchRecords() -> [WatchTransferRecord] {
        do {
            let records = try modelContext.fetch(FetchDescriptor<WatchTransferRecord>())
            lastPersistenceError = nil
            return records
        } catch {
            lastPersistenceError = error.localizedDescription
            return []
        }
    }

    @discardableResult
    private func persistChanges() -> Bool {
        do {
            try modelContext.save()
            lastPersistenceError = nil
            return true
        } catch {
            lastPersistenceError = error.localizedDescription
            modelContext.rollback()
            return false
        }
    }

    private func resetForPreparation(_ record: WatchTransferRecord) {
        record.sourceFileSize = 0
        record.lastKnownProgress = 0
        record.artworkExpected = false
        record.audioDeliveryFinished = false
        record.artworkDeliveryFinished = false
        record.senderFailed = false
        record.watchImportConfirmed = false
        record.watchImportFailed = false
        record.confirmedAt = nil
        record.lastErrorCode = nil
        record.lastErrorMessage = nil
        record.state = .preparing
        record.updatedAt = .now
    }

    private func restorePreviousIdentity(
        of record: WatchTransferRecord,
        transferID: UUID?,
        revision: Int64?
    ) {
        guard let transferID, let revision else { return }
        record.transferID = transferID
        record.revision = revision
    }

    private func markFailed(_ record: WatchTransferRecord, code: String, message: String) {
        record.state = .failed
        record.lastErrorCode = code
        record.lastErrorMessage = message
        record.updatedAt = .now
    }

    private func fileSize(at url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
}

private extension WatchTransferState {
    var isTransferActive: Bool {
        switch self {
        case .preparing, .queued, .transferring, .awaitingWatchConfirmation, .cancelling:
            true
        case .availableOnWatch, .deletionPending, .failed, .reconciliationRequired, .removedFromWatch:
            false
        }
    }
}

enum WatchTransferServiceError: LocalizedError {
    case watchUnavailable
    case retryUnavailable
    case deletionUnavailable
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .watchUnavailable:
            "ペアリング済みApple WatchとWatchアプリを確認してください。"
        case .retryUnavailable:
            "この転送は再試行できません。"
        case .deletionUnavailable:
            "この項目はApple Watchから削除できません。"
        case .persistence(let message):
            "転送状態を保存できませんでした: \(message)"
        }
    }
}

struct WatchInventoryCursor: Codable, Equatable, Sendable {
    let libraryInstanceID: UUID
    let generation: Int64
    let generatedAt: Date
    let entries: [WatchInventoryEntry]

    init(snapshot: WatchInventorySnapshot) {
        libraryInstanceID = snapshot.libraryInstanceID
        generation = snapshot.generation
        generatedAt = snapshot.generatedAt
        entries = snapshot.entries
    }
}

@MainActor
protocol WatchInventoryCursorStoring: AnyObject {
    func load() -> WatchInventoryCursor?
    func save(_ cursor: WatchInventoryCursor) throws
}

@MainActor
protocol WatchInventoryRequestStoring: AnyObject {
    func load() -> WatchInventoryRequest?
    func save(_ request: WatchInventoryRequest) throws
    func clear() throws
}

@MainActor
final class UserDefaultsWatchInventoryRequestStore: WatchInventoryRequestStoring {
    private static let key = "com.rimtty.YouTubePod.pendingWatchInventoryRequest"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WatchInventoryRequest? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder()
            .decode(WatchInventoryRequest.self, from: data)
            .validated()
    }

    func save(_ request: WatchInventoryRequest) throws {
        defaults.set(try JSONEncoder().encode(request.validated()), forKey: Self.key)
    }

    func clear() throws {
        defaults.removeObject(forKey: Self.key)
    }
}

@MainActor
final class UserDefaultsWatchInventoryCursorStore: WatchInventoryCursorStoring {
    private static let key = "com.rimtty.YouTubePod.watchInventoryCursor"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WatchInventoryCursor? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(WatchInventoryCursor.self, from: data)
    }

    func save(_ cursor: WatchInventoryCursor) throws {
        defaults.set(try JSONEncoder().encode(cursor), forKey: Self.key)
    }
}
