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
    private let automaticRetryDelays: [Duration]
    private let confirmationTimeout: TimeInterval
    private var activeTransferID: UUID?
    private var lastProgressSaveAt: [UUID: Date] = [:]
    private var automaticRetryTasks: [String: Task<Void, Never>] = [:]
    private var confirmationTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var hasStarted = false
    private var sessionStartedTransferIDs: Set<UUID> = []

    private(set) var connectionStatus: WatchConnectionStatus
    private(set) var liveProgress: [String: Double] = [:]
    private(set) var lastPersistenceError: String?

    init(
        modelContext: ModelContext,
        transport: any WatchConnectivityTransport,
        snapshots: any WatchTransferSnapshotStoring,
        automaticRetryDelays: [Duration] = [.seconds(2), .seconds(10)],
        confirmationTimeout: TimeInterval = 30 * 60
    ) {
        self.modelContainer = modelContext.container
        self.modelContext = modelContext
        self.transport = transport
        self.snapshots = snapshots
        self.automaticRetryDelays = automaticRetryDelays
        self.confirmationTimeout = confirmationTimeout
        connectionStatus = transport.status
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        transport.eventHandler = { [weak self] event in
            self?.handle(event)
        }
        transport.activate()
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
        } catch {
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
            await startNextQueuedTransferIfPossible()
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
            if activeTransferID == record.transferID { activeTransferID = nil }
            sessionStartedTransferIDs.remove(record.transferID)
            scheduleNextQueuedTransferIfNeeded()
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
        await startNextQueuedTransferIfPossible()
    }

    private func handle(_ event: WatchConnectivityEvent) {
        switch event {
        case .statusChanged(let status):
            connectionStatus = status
            // A status callback defines a new reconciliation boundary. Any
            // transfer remembered only by this process must now be proven by
            // WCSession.outstandingFileTransfers, otherwise a missed
            // didFinish callback could hold the serial queue forever.
            sessionStartedTransferIDs.removeAll()
            if status.canTransfer {
                Task { @MainActor [weak self] in
                    await self?.reconcileAndResumeTransfers()
                }
            }

        case .progress(let key, let progress):
            guard let record = record(transferID: key.transferID),
                  !record.senderFailed,
                  record.state != .removedFromWatch else { return }
            let normalized = min(max(progress, 0), 1)
            liveProgress[record.youtubeID] = max(liveProgress[record.youtubeID] ?? 0, normalized)
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
                    if activeTransferID == key.transferID { activeTransferID = nil }
                    sessionStartedTransferIDs.remove(key.transferID)
                    if record.state == .failed {
                        scheduleAutomaticRetryIfPossible(for: record, failure: failure)
                    } else if record.state == .availableOnWatch {
                        Task { await snapshots.removeTransfer(key.transferID) }
                    }
                    scheduleNextQueuedTransferIfNeeded()
                }
                return
            }
            switch key.fileKind {
            case .audio: record.audioDeliveryFinished = true
            case .artwork: record.artworkDeliveryFinished = true
            }
            completeEvent(for: record)

        case .acknowledgement(let acknowledgement):
            handleAcknowledgement(acknowledgement)
        }
    }

    private func handleAcknowledgement(_ acknowledgement: WatchTransferAcknowledgement) {
        guard let record = record(videoID: acknowledgement.youtubeID),
              record.transferID == acknowledgement.transferID,
              record.revision == acknowledgement.revision else { return }
        cancelScheduledTasks(videoID: acknowledgement.youtubeID)

        switch acknowledgement.outcome {
        case .imported:
            record.watchImportConfirmed = true
            record.watchImportFailed = false
            record.confirmedAt = .now
            record.lastErrorCode = nil
            record.lastErrorMessage = nil
            completeEvent(for: record)
        case .failed:
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
                if activeTransferID == record.transferID { activeTransferID = nil }
                sessionStartedTransferIDs.remove(record.transferID)
                scheduleNextQueuedTransferIfNeeded()
            }
        case .deleted:
            transport.cancelFiles(transferID: record.transferID)
            record.state = .removedFromWatch
            record.confirmedAt = .now
            record.watchImportConfirmed = false
            record.watchImportFailed = false
            liveProgress[record.youtubeID] = nil
            if persistChanges() {
                if activeTransferID == record.transferID { activeTransferID = nil }
                sessionStartedTransferIDs.remove(record.transferID)
                Task { await snapshots.removeTransfer(acknowledgement.transferID) }
                scheduleNextQueuedTransferIfNeeded()
            }
        }
    }

    private func startNextQueuedTransferIfPossible() async {
        guard activeTransferID == nil, connectionStatus.canTransfer else { return }
        while activeTransferID == nil {
            guard let record = fetchRecords()
                .filter({ $0.state == .queued })
                .sorted(by: { $0.queuedAt < $1.queuedAt })
                .first else { return }
            // Reserve the serial slot before awaiting the actor-backed
            // snapshot store; multiple status/queue tasks may arrive together.
            activeTransferID = record.transferID
            guard let prepared = await snapshots.preparedTransfer(transferID: record.transferID) else {
                activeTransferID = nil
                record.senderFailed = true
                markFailed(
                    record,
                    code: "snapshot-missing",
                    message: WatchTransferSnapshotError.sourceMissing.localizedDescription
                )
                _ = persistChanges()
                continue
            }

            do {
                record.state = .transferring
                record.senderFailed = false
                record.updatedAt = .now
                try transport.enqueueFile(
                    at: prepared.audioURL,
                    envelope: try envelope(for: record, fileKind: .audio, fileURL: prepared.audioURL)
                )
                if let artworkURL = prepared.artworkURL {
                    try transport.enqueueFile(
                        at: artworkURL,
                        envelope: try envelope(for: record, fileKind: .artwork, fileURL: artworkURL)
                    )
                }
                try modelContext.save()
                sessionStartedTransferIDs.insert(record.transferID)
                lastPersistenceError = nil
                return
            } catch {
                transport.cancelFiles(transferID: record.transferID)
                record.senderFailed = true
                markFailed(record, code: "enqueue", message: error.localizedDescription)
                activeTransferID = nil
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
                    activeTransferID = activeTransferID ?? record.transferID
                    liveProgress[record.youtubeID] = files.map(\.progress).max() ?? 0
                }
            case .transferring where files.isEmpty && !sessionStartedTransferIDs.contains(record.transferID):
                record.state = .reconciliationRequired
                if activeTransferID == record.transferID { activeTransferID = nil }
                liveProgress[record.youtubeID] = nil
            case .transferring:
                activeTransferID = activeTransferID ?? record.transferID
                let progress = files.map(\.progress).max() ?? 0
                liveProgress[record.youtubeID] = progress
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
        await startNextQueuedTransferIfPossible()
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
            if activeTransferID == record.transferID { activeTransferID = nil }
            sessionStartedTransferIDs.remove(record.transferID)
            lastProgressSaveAt[record.transferID] = nil
            scheduleNextQueuedTransferIfNeeded()
        }
        if record.state == .availableOnWatch || record.state == .removedFromWatch {
            let transferID = record.transferID
            Task { await snapshots.removeTransfer(transferID) }
        }
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

    private func scheduleNextQueuedTransferIfNeeded() {
        guard fetchRecords().contains(where: { $0.state == .queued }) else { return }
        Task { @MainActor [weak self] in
            await self?.startNextQueuedTransferIfPossible()
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
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .watchUnavailable:
            "ペアリング済みApple WatchとWatchアプリを確認してください。"
        case .retryUnavailable:
            "この転送は再試行できません。"
        case .persistence(let message):
            "転送状態を保存できませんでした: \(message)"
        }
    }
}
