import Foundation
import SwiftData

enum WatchIncomingRevisionDisposition: Equatable, Sendable {
    case accept
    case exactDuplicate
    case stale
    case sameRevisionConflict
}

enum WatchLibraryImportResult: Equatable, Sendable {
    case imported
    case artworkAttached
    case artworkPending
    case artworkDiscarded(WatchTransferAcknowledgementErrorCode)
    case duplicate
    case deleted
    case rejected(WatchTransferAcknowledgementErrorCode)
    case persistenceFailed
}

@MainActor
final class WatchAudioLibraryService {
    private static let metadataKey = "primary"
    private static let audioDirectory = "Audio"
    private static let artworkDirectory = "Artwork"
    private static let pendingArtworkDirectory = "PendingArtwork"

    private let modelContext: ModelContext
    private let validator: any WatchAudioValidating
    private let capacityChecker: any WatchCapacityChecking
    private let fileManager: FileManager
    private let rootURL: URL
    private let minimumCapacityReserve: Int64
    private let pendingArtworkTTL: TimeInterval
    private let saveChanges: @MainActor (ModelContext) throws -> Void

    init(
        modelContext: ModelContext,
        validator: any WatchAudioValidating,
        capacityChecker: any WatchCapacityChecking,
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        minimumCapacityReserve: Int64 = 10 * 1_024 * 1_024,
        pendingArtworkTTL: TimeInterval = 24 * 60 * 60,
        saveChanges: (@MainActor (ModelContext) throws -> Void)? = nil
    ) {
        self.modelContext = modelContext
        self.validator = validator
        self.capacityChecker = capacityChecker
        self.fileManager = fileManager
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        self.minimumCapacityReserve = minimumCapacityReserve
        self.pendingArtworkTTL = pendingArtworkTTL
        self.saveChanges = saveChanges ?? { try $0.save() }
    }

    func disposition(for envelope: WatchTransferEnvelope) throws -> WatchIncomingRevisionDisposition {
        if let tombstone = try tombstone(videoID: envelope.youtubeID),
           tombstone.rejects(incomingRevision: envelope.revision) {
            return .stale
        }
        guard let saved = try savedAudio(videoID: envelope.youtubeID) else {
            return .accept
        }
        if envelope.revision < saved.revision { return .stale }
        if envelope.revision == saved.revision {
            return envelope.transferID == saved.transferID ? .exactDuplicate : .sameRevisionConflict
        }
        return .accept
    }

    @discardableResult
    func importStagedFile(_ staged: StagedWatchTransferFile) async -> WatchLibraryImportResult {
        do {
            try createDirectoriesIfNeeded()
            switch staged.envelope.fileKind {
            case .audio:
                return await importAudio(staged)
            case .artwork:
                return await importArtwork(staged)
            }
        } catch {
            return reject(
                staged,
                code: errorCode(for: error),
                message: error.localizedDescription
            )
        }
    }

    @discardableResult
    func delete(_ command: WatchLibraryCommand) -> WatchLibraryImportResult {
        do {
            let command = try command.validated()
            guard command.kind == .delete else {
                return .rejected(.staleRevision)
            }

            if let currentTombstone = try tombstone(videoID: command.youtubeID) {
                if command.revision < currentTombstone.revision
                    || (command.revision == currentTombstone.revision
                        && command.commandID != currentTombstone.transferID) {
                    return persistCommandFailure(command, code: .staleRevision)
                }
                if command.revision == currentTombstone.revision,
                   command.commandID == currentTombstone.transferID {
                    try enqueueAcknowledgementIfMissing(
                        transferID: command.commandID,
                        revision: command.revision,
                        youtubeID: command.youtubeID,
                        outcome: .deleted
                    )
                    return saveOutboxOnly() ? .deleted : .persistenceFailed
                }
            }

            let existing = try savedAudio(videoID: command.youtubeID)
            if let existing, existing.revision > command.revision {
                return persistCommandFailure(command, code: .staleRevision)
            }
            let oldAudioURL = existing.flatMap(audioURL(for:))
            let oldArtworkURL = existing.flatMap(artworkURL(for:))

            if let existing { modelContext.delete(existing) }
            if let current = try tombstone(videoID: command.youtubeID) {
                current.transferID = command.commandID
                current.revision = command.revision
                current.deletedAt = .now
            } else {
                modelContext.insert(WatchDeletionTombstone(
                    youtubeID: command.youtubeID,
                    transferID: command.commandID,
                    revision: command.revision
                ))
            }
            try metadata().advanceGeneration()
            try enqueueAcknowledgementIfMissing(
                transferID: command.commandID,
                revision: command.revision,
                youtubeID: command.youtubeID,
                outcome: .deleted
            )

            guard persist() else { return .persistenceFailed }
            removeFileIfPresent(oldAudioURL)
            removeFileIfPresent(oldArtworkURL)
            removePendingArtwork(
                videoID: command.youtubeID,
                throughRevision: command.revision
            )
            return .deleted
        } catch {
            modelContext.rollback()
            return .persistenceFailed
        }
    }

    func inventory(availableCapacity: Int64?) throws -> WatchInventorySnapshot {
        try createDirectoriesIfNeeded()
        let metadata = try metadata()
        if modelContext.hasChanges {
            try saveChanges(modelContext)
        }
        let entries = try fetchSavedAudio()
            .filter { $0.storageState == .ready || $0.storageState == .readyWithoutArtwork }
            .filter { saved in
                guard let url = audioURL(for: saved),
                      let size = try? regularFileSize(at: url) else { return false }
                return size == saved.fileSize
            }
            .sorted { $0.youtubeID < $1.youtubeID }
            .map {
                WatchInventoryEntry(
                    youtubeID: $0.youtubeID,
                    transferID: $0.transferID,
                    revision: $0.revision,
                    fileSize: $0.fileSize
                )
            }
        return try WatchInventorySnapshot(
            libraryInstanceID: metadata.libraryInstanceID,
            generation: metadata.generation,
            generatedAt: .now,
            availableCapacity: availableCapacity,
            entries: entries
        ).validated()
    }

    func audioFileURL(for saved: WatchSavedAudio) -> URL? {
        audioURL(for: saved)
    }

    func artworkFileURL(for saved: WatchSavedAudio) -> URL? {
        artworkURL(for: saved)
    }

    func persistPlaybackPosition(
        videoID: String,
        position: TimeInterval,
        hasBeenPlayed: Bool
    ) throws {
        guard let saved = try savedAudio(videoID: videoID) else { return }
        let safePosition = position.isFinite
            ? min(max(position, 0), max(saved.duration, 0))
            : 0
        saved.lastPlaybackPosition = safePosition
        saved.hasBeenPlayed = saved.hasBeenPlayed || hasBeenPlayed
        try saveChanges(modelContext)
    }

    func pendingAcknowledgements() throws -> [WatchPendingAcknowledgement] {
        try fetchAcknowledgements().sorted {
            if $0.createdAt == $1.createdAt {
                return $0.acknowledgementID.uuidString < $1.acknowledgementID.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    func acknowledgementSent(id: UUID) throws {
        guard let pending = try fetchAcknowledgements().first(where: { $0.acknowledgementID == id }) else {
            return
        }
        modelContext.delete(pending)
        do {
            try saveChanges(modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func acknowledgementAttemptFailed(id: UUID) throws {
        guard let pending = try fetchAcknowledgements().first(where: { $0.acknowledgementID == id }) else {
            return
        }
        pending.attemptCount = pending.normalizedAttemptCount + 1
        do {
            try saveChanges(modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func cleanupOnStartup(now: Date = .now) throws {
        try createDirectoriesIfNeeded()
        // Never interpret a SwiftData read failure as an empty library: doing
        // so would turn a transient/corrupt-store error into media deletion.
        let savedAudio = try modelContext.fetch(FetchDescriptor<WatchSavedAudio>())
        let retainedAudio = Set(savedAudio.compactMap(\.safeAudioRelativePath))
        let retainedArtwork = Set(savedAudio.compactMap(\.safeThumbnailRelativePath))
        try removeOrphans(in: Self.audioDirectory, retaining: retainedAudio)
        try removeOrphans(in: Self.artworkDirectory, retaining: retainedArtwork)

        let pendingDirectory = directory(Self.pendingArtworkDirectory)
        let entries = try fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for artworkURL in entries where artworkURL.pathExtension.lowercased() == "jpg" {
            let transferID = UUID(uuidString: artworkURL.deletingPathExtension().lastPathComponent)
            let sidecarURL = artworkURL.deletingPathExtension().appendingPathExtension("json")
            guard let transferID,
                  let envelope = try? decodeEnvelope(at: sidecarURL),
                  envelope.transferID == transferID,
                  envelope.fileKind == .artwork else {
                removeFileIfPresent(artworkURL)
                removeFileIfPresent(sidecarURL)
                continue
            }
            let modified = (try? artworkURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            let expired = now.timeIntervalSince(modified) > pendingArtworkTTL
            let disposition = try disposition(for: envelope)
            if expired || disposition == .stale || disposition == .sameRevisionConflict {
                removeFileIfPresent(artworkURL)
                removeFileIfPresent(sidecarURL)
            }
        }
        for sidecarURL in entries where sidecarURL.pathExtension.lowercased() == "json" {
            let artworkURL = sidecarURL.deletingPathExtension().appendingPathExtension("jpg")
            if !fileManager.fileExists(atPath: artworkURL.path) {
                removeFileIfPresent(sidecarURL)
            }
        }
    }

    private func importAudio(_ staged: StagedWatchTransferFile) async -> WatchLibraryImportResult {
        let envelope = staged.envelope
        do {
            switch try disposition(for: envelope) {
            case .exactDuplicate:
                if let saved = try savedAudio(videoID: envelope.youtubeID),
                   hasValidAudioFile(saved) {
                    try enqueueAcknowledgementIfMissing(for: envelope, outcome: .imported)
                    guard saveOutboxOnly() else { return .persistenceFailed }
                    return .duplicate
                }
            case .stale, .sameRevisionConflict:
                return reject(staged, code: .staleRevision, message: "古い転送revisionです。")
            case .accept:
                break
            }
            try await capacityChecker.ensureImportCapacity(
                at: rootURL,
                stagedFileSize: envelope.fileSize,
                minimumReserve: minimumCapacityReserve
            )
            let validated = try await validator.validate(fileURL: staged.fileURL, envelope: envelope)

            // Validation is an actor suspension point. A newer revision or a
            // deletion may have committed while AVFoundation was loading.
            let refreshedDisposition = try disposition(for: envelope)
            let savedAfterValidation = try savedAudio(videoID: envelope.youtubeID)
            let repairsMissingExactDuplicate = refreshedDisposition == .exactDuplicate
                && savedAfterValidation.map { !hasValidAudioFile($0) } == true
            guard refreshedDisposition == .accept || repairsMissingExactDuplicate else {
                return reject(staged, code: .staleRevision, message: "検証中に新しいrevisionが保存されました。")
            }

            let finalAudioURL = audioFileURL(transferID: envelope.transferID)
            guard !fileManager.fileExists(atPath: finalAudioURL.path) else {
                return reject(staged, code: .persistenceFailure, message: "同じ転送IDの音声が既に存在します。")
            }
            // The receipt is the crash-recovery journal. Keep its payload
            // intact until the SwiftData transaction commits; on relaunch an
            // orphan final copy is removed and the receipt is imported again.
            try fileManager.copyItem(at: staged.fileURL, to: finalAudioURL)

            let pendingArtworkURL = pendingArtworkFileURL(transferID: envelope.transferID)
            let pendingSidecarURL = pendingArtworkEnvelopeURL(transferID: envelope.transferID)
            let finalArtworkURL = artworkFileURL(transferID: envelope.transferID)
            var installedArtwork = false
            if fileManager.fileExists(atPath: pendingArtworkURL.path),
               let pendingEnvelope = try? decodeEnvelope(at: pendingSidecarURL),
               matchingIdentity(pendingEnvelope, envelope) {
                do {
                    try fileManager.copyItem(at: pendingArtworkURL, to: finalArtworkURL)
                    installedArtwork = true
                } catch {
                    // Artwork is optional. A damaged or unwritable image must
                    // never roll back a fully validated audio import.
                    removeFileIfPresent(finalArtworkURL)
                    removeFileIfPresent(pendingArtworkURL)
                    removeFileIfPresent(pendingSidecarURL)
                }
            }

            let previous = try savedAudio(videoID: envelope.youtubeID)
            let oldAudioURL = previous.flatMap(audioURL(for:))
            let oldArtworkURL = previous.flatMap(artworkURL(for:))
            let audioRelativePath = relativePath(for: finalAudioURL)
            let artworkRelativePath = installedArtwork ? relativePath(for: finalArtworkURL) : nil

            if let previous {
                previous.transferID = envelope.transferID
                previous.title = envelope.title
                previous.channelTitle = envelope.channel
                previous.publishedAt = envelope.publishedAt
                previous.savedViewCount = envelope.viewCount
                previous.duration = validated.actualDuration
                previous.audioRelativePath = audioRelativePath
                previous.thumbnailRelativePath = artworkRelativePath
                previous.fileSize = validated.actualFileSize
                previous.receivedAt = .now
                previous.revision = envelope.revision
                previous.lastPlaybackPosition = envelope.normalizedPlaybackPosition
                previous.hasBeenPlayed = envelope.normalizedPlaybackPosition > 0
            } else {
                modelContext.insert(WatchSavedAudio(
                    youtubeID: envelope.youtubeID,
                    transferID: envelope.transferID,
                    title: envelope.title,
                    channelTitle: envelope.channel,
                    publishedAt: envelope.publishedAt,
                    savedViewCount: envelope.viewCount,
                    duration: validated.actualDuration,
                    audioRelativePath: audioRelativePath,
                    thumbnailRelativePath: artworkRelativePath,
                    fileSize: validated.actualFileSize,
                    revision: envelope.revision,
                    lastPlaybackPosition: envelope.normalizedPlaybackPosition,
                    hasBeenPlayed: envelope.normalizedPlaybackPosition > 0
                ))
            }
            try metadata().advanceGeneration()
            try enqueueAcknowledgementIfMissing(for: envelope, outcome: .imported)

            guard persist() else {
                removeFileIfPresent(finalAudioURL)
                if installedArtwork { removeFileIfPresent(finalArtworkURL) }
                return persistFailureAcknowledgement(for: staged)
            }
            if installedArtwork {
                removeFileIfPresent(pendingArtworkURL)
                removeFileIfPresent(pendingSidecarURL)
            }
            if oldAudioURL != finalAudioURL { removeFileIfPresent(oldAudioURL) }
            if oldArtworkURL != finalArtworkURL { removeFileIfPresent(oldArtworkURL) }
            return .imported
        } catch {
            return reject(staged, code: errorCode(for: error), message: error.localizedDescription)
        }
    }

    private func importArtwork(_ staged: StagedWatchTransferFile) async -> WatchLibraryImportResult {
        let envelope = staged.envelope
        do {
            let initialDisposition = try disposition(for: envelope)
            if initialDisposition == .stale || initialDisposition == .sameRevisionConflict {
                return reject(staged, code: .staleRevision, message: "古い転送revisionです。")
            }
            try await capacityChecker.ensureImportCapacity(
                at: rootURL,
                stagedFileSize: envelope.fileSize,
                minimumReserve: minimumCapacityReserve
            )
            let refreshedDisposition = try disposition(for: envelope)
            guard refreshedDisposition != .stale,
                  refreshedDisposition != .sameRevisionConflict else {
                return reject(staged, code: .staleRevision, message: "新しいrevisionが保存されています。")
            }

            if let saved = try savedAudio(videoID: envelope.youtubeID),
               saved.transferID == envelope.transferID,
               saved.revision == envelope.revision {
                if let currentArtwork = artworkURL(for: saved),
                   fileManager.fileExists(atPath: currentArtwork.path) {
                    return .duplicate
                }
                let finalURL = artworkFileURL(transferID: envelope.transferID)
                try fileManager.copyItem(at: staged.fileURL, to: finalURL)
                saved.thumbnailRelativePath = relativePath(for: finalURL)
                try metadata().advanceGeneration()
                guard persist() else {
                    removeFileIfPresent(finalURL)
                    return persistFailureAcknowledgement(for: staged)
                }
                return .artworkAttached
            }

            let pendingURL = pendingArtworkFileURL(transferID: envelope.transferID)
            let sidecarURL = pendingArtworkEnvelopeURL(transferID: envelope.transferID)
            if fileManager.fileExists(atPath: pendingURL.path) {
                return .duplicate
            }
            try encodeEnvelope(envelope).write(to: sidecarURL, options: .atomic)
            do {
                try fileManager.copyItem(at: staged.fileURL, to: pendingURL)
            } catch {
                removeFileIfPresent(sidecarURL)
                throw error
            }
            return .artworkPending
        } catch {
            return reject(staged, code: errorCode(for: error), message: error.localizedDescription)
        }
    }

    private func reject(
        _ staged: StagedWatchTransferFile,
        code: WatchTransferAcknowledgementErrorCode,
        message: String
    ) -> WatchLibraryImportResult {
        guard staged.envelope.fileKind == .audio else {
            modelContext.rollback()
            removePendingArtwork(transferID: staged.envelope.transferID)
            return .artworkDiscarded(code)
        }
        do {
            try enqueueAcknowledgementIfMissing(
                for: staged.envelope,
                outcome: .failed,
                errorCode: code,
                message: message
            )
        } catch {
            return .persistenceFailed
        }
        guard persist() else { return .persistenceFailed }
        return .rejected(code)
    }

    private func persistFailureAcknowledgement(
        for staged: StagedWatchTransferFile
    ) -> WatchLibraryImportResult {
        modelContext.rollback()
        guard staged.envelope.fileKind == .audio else {
            removePendingArtwork(transferID: staged.envelope.transferID)
            return .artworkDiscarded(.persistenceFailure)
        }
        do {
            try enqueueAcknowledgementIfMissing(
                for: staged.envelope,
                outcome: .failed,
                errorCode: .persistenceFailure,
                message: "Watchライブラリを保存できませんでした。"
            )
        } catch {
            return .persistenceFailed
        }
        guard persist() else { return .persistenceFailed }
        removePendingArtwork(transferID: staged.envelope.transferID)
        return .rejected(.persistenceFailure)
    }

    private func persistCommandFailure(
        _ command: WatchLibraryCommand,
        code: WatchTransferAcknowledgementErrorCode
    ) -> WatchLibraryImportResult {
        do {
            try enqueueAcknowledgementIfMissing(
                transferID: command.commandID,
                revision: command.revision,
                youtubeID: command.youtubeID,
                outcome: .failed,
                errorCode: code,
                message: "削除命令のrevisionが古いため適用しませんでした。"
            )
        } catch {
            return .persistenceFailed
        }
        return persist() ? .rejected(code) : .persistenceFailed
    }

    private func saveOutboxOnly() -> Bool {
        guard modelContext.hasChanges else { return true }
        return persist()
    }

    private func persist() -> Bool {
        do {
            try saveChanges(modelContext)
            return true
        } catch {
            modelContext.rollback()
            return false
        }
    }

    private func enqueueAcknowledgementIfMissing(
        for envelope: WatchTransferEnvelope,
        outcome: WatchTransferAcknowledgementOutcome,
        errorCode: WatchTransferAcknowledgementErrorCode? = nil,
        message: String? = nil
    ) throws {
        try enqueueAcknowledgementIfMissing(
            transferID: envelope.transferID,
            revision: envelope.revision,
            youtubeID: envelope.youtubeID,
            outcome: outcome,
            errorCode: errorCode,
            message: message
        )
    }

    private func enqueueAcknowledgementIfMissing(
        transferID: UUID,
        revision: Int64,
        youtubeID: String,
        outcome: WatchTransferAcknowledgementOutcome,
        errorCode: WatchTransferAcknowledgementErrorCode? = nil,
        message: String? = nil
    ) throws {
        let exists = try fetchAcknowledgements().contains {
            $0.transferID == transferID
                && $0.revision == revision
                && $0.youtubeID == youtubeID
                && $0.outcome == outcome
        }
        guard !exists else { return }
        modelContext.insert(WatchPendingAcknowledgement(
            transferID: transferID,
            revision: revision,
            youtubeID: youtubeID,
            outcome: outcome,
            errorCode: errorCode,
            message: message
        ))
    }

    private func metadata() throws -> WatchLibraryMetadata {
        if let value = try fetchMetadata().first(where: { $0.key == Self.metadataKey }) {
            return value
        }
        let value = WatchLibraryMetadata(key: Self.metadataKey)
        modelContext.insert(value)
        return value
    }

    private func savedAudio(videoID: String) throws -> WatchSavedAudio? {
        try fetchSavedAudio().first { $0.youtubeID == videoID }
    }

    private func tombstone(videoID: String) throws -> WatchDeletionTombstone? {
        try fetchTombstones().first { $0.youtubeID == videoID }
    }

    private func fetchSavedAudio() throws -> [WatchSavedAudio] {
        try modelContext.fetch(FetchDescriptor<WatchSavedAudio>())
    }

    private func fetchTombstones() throws -> [WatchDeletionTombstone] {
        try modelContext.fetch(FetchDescriptor<WatchDeletionTombstone>())
    }

    private func fetchAcknowledgements() throws -> [WatchPendingAcknowledgement] {
        try modelContext.fetch(FetchDescriptor<WatchPendingAcknowledgement>())
    }

    private func fetchMetadata() throws -> [WatchLibraryMetadata] {
        try modelContext.fetch(FetchDescriptor<WatchLibraryMetadata>())
    }

    private func audioURL(for audio: WatchSavedAudio) -> URL? {
        audio.safeAudioRelativePath.map { rootURL.appending(path: $0) }
    }

    private func artworkURL(for audio: WatchSavedAudio) -> URL? {
        audio.safeThumbnailRelativePath.map { rootURL.appending(path: $0) }
    }

    private func regularFileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return Int64(size)
    }

    private func hasValidAudioFile(_ saved: WatchSavedAudio) -> Bool {
        guard let url = audioURL(for: saved),
              let size = try? regularFileSize(at: url) else { return false }
        return size == saved.fileSize
    }

    private func audioFileURL(transferID: UUID) -> URL {
        directory(Self.audioDirectory).appending(path: "\(transferID.uuidString).m4a")
    }

    private func artworkFileURL(transferID: UUID) -> URL {
        directory(Self.artworkDirectory).appending(path: "\(transferID.uuidString).jpg")
    }

    private func pendingArtworkFileURL(transferID: UUID) -> URL {
        directory(Self.pendingArtworkDirectory).appending(path: "\(transferID.uuidString).jpg")
    }

    private func pendingArtworkEnvelopeURL(transferID: UUID) -> URL {
        directory(Self.pendingArtworkDirectory).appending(path: "\(transferID.uuidString).json")
    }

    private func removePendingArtwork(transferID: UUID?) {
        guard let transferID else { return }
        removeFileIfPresent(pendingArtworkFileURL(transferID: transferID))
        removeFileIfPresent(pendingArtworkEnvelopeURL(transferID: transferID))
    }

    private func removePendingArtwork(videoID: String, throughRevision revision: Int64) {
        guard let sidecars = try? fileManager.contentsOfDirectory(
            at: directory(Self.pendingArtworkDirectory),
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for sidecarURL in sidecars where sidecarURL.pathExtension.lowercased() == "json" {
            guard let envelope = try? decodeEnvelope(at: sidecarURL),
                  envelope.youtubeID == videoID,
                  envelope.revision <= revision else { continue }
            removePendingArtwork(transferID: envelope.transferID)
        }
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        return String(fullPath.dropFirst(rootPath.count + 1))
    }

    private func directory(_ name: String) -> URL {
        rootURL.appending(path: name, directoryHint: .isDirectory)
    }

    private func createDirectoriesIfNeeded() throws {
        for name in [Self.audioDirectory, Self.artworkDirectory, Self.pendingArtworkDirectory] {
            try fileManager.createDirectory(at: directory(name), withIntermediateDirectories: true)
        }
    }

    private func removeFileIfPresent(_ url: URL?) {
        guard let url, fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func removeOrphans(in directoryName: String, retaining paths: Set<String>) throws {
        for url in try fileManager.contentsOfDirectory(
            at: directory(directoryName),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            if !paths.contains(relativePath(for: url)) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func matchingIdentity(
        _ artwork: WatchTransferEnvelope,
        _ audio: WatchTransferEnvelope
    ) -> Bool {
        artwork.fileKind == .artwork
            && artwork.transferID == audio.transferID
            && artwork.revision == audio.revision
            && artwork.youtubeID == audio.youtubeID
    }

    private func encodeEnvelope(_ envelope: WatchTransferEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(envelope)
    }

    private func decodeEnvelope(at url: URL) throws -> WatchTransferEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WatchTransferEnvelope.self, from: Data(contentsOf: url)).validated()
    }

    private func errorCode(for error: Error) -> WatchTransferAcknowledgementErrorCode {
        if error is WatchCapacityError { return .capacityInsufficient }
        if let validationError = error as? WatchAudioValidationError {
            switch validationError {
            case .containsVideoTrack: return .containsVideo
            case .sizeMismatch: return .sizeMismatch
            default: return .invalidAudio
            }
        }
        return .persistenceFailure
    }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let support = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appending(path: "WatchLibrary", directoryHint: .isDirectory)
    }
}
