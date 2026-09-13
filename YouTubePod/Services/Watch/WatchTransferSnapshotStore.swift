import Foundation
import OSLog

struct WatchTransferSource: Sendable {
    let youtubeID: String
    let title: String
    let channelTitle: String
    let publishedAt: Date
    let savedViewCount: Int64
    let duration: TimeInterval
    let playbackPosition: TimeInterval
    let audioURL: URL
    let artworkURL: URL?
    /// Digest of the normalized library file, recorded by
    /// `LibraryAudioOptimizer`. When present the snapshot reuses it instead
    /// of reading the whole file again.
    var audioContentSHA256: String? = nil

    init(
        youtubeID: String,
        title: String,
        channelTitle: String,
        publishedAt: Date,
        savedViewCount: Int64,
        duration: TimeInterval,
        playbackPosition: TimeInterval,
        audioURL: URL,
        artworkURL: URL?,
        audioContentSHA256: String? = nil
    ) {
        self.youtubeID = youtubeID
        self.title = title
        self.channelTitle = channelTitle
        self.publishedAt = publishedAt
        self.savedViewCount = savedViewCount
        self.duration = duration
        self.playbackPosition = playbackPosition
        self.audioURL = audioURL
        self.artworkURL = artworkURL
        self.audioContentSHA256 = audioContentSHA256
    }

    /// The optimizer normalizes the library file in place, so only the digest
    /// changes; `audioURL` already points at that file.
    func withOptimizedAudio(_ audio: OptimizedLibraryAudio) -> WatchTransferSource {
        var copy = self
        copy.audioContentSHA256 = audio.contentSHA256
        return copy
    }
}

struct PreparedWatchTransfer: Sendable, Equatable {
    let transferID: UUID
    let audioURL: URL
    let artworkURL: URL?
    let audioContentSHA256: String?
    let artworkContentSHA256: String?

    init(
        transferID: UUID,
        audioURL: URL,
        artworkURL: URL?,
        audioContentSHA256: String? = nil,
        artworkContentSHA256: String? = nil
    ) {
        self.transferID = transferID
        self.audioURL = audioURL
        self.artworkURL = artworkURL
        self.audioContentSHA256 = audioContentSHA256
        self.artworkContentSHA256 = artworkContentSHA256
    }
}

protocol WatchTransferSnapshotStoring: Sendable {
    func prepare(source: WatchTransferSource, transferID: UUID) async throws -> PreparedWatchTransfer
    func preparedTransfer(transferID: UUID) async -> PreparedWatchTransfer?
    func cloneTransfer(from sourceTransferID: UUID, to destinationTransferID: UUID) async throws -> PreparedWatchTransfer
    func removeTransfer(_ transferID: UUID) async
    func storedTransferIDs() async -> Set<UUID>
    func removeOrphans(retaining transferIDs: Set<UUID>) async
    func removeStagingDirectories() async
}

/// Keeps a per-transfer copy of the library audio so an in-flight
/// WatchConnectivity transfer survives the user deleting the item from the
/// iPhone library. The library file is already a normalized flat M4A (see
/// `LibraryAudioOptimizer`), so preparing a transfer is a clone plus a digest
/// sidecar; nothing is remuxed or hashed here on the normal path.
actor WatchTransferSnapshotStore: WatchTransferSnapshotStoring {
    private static let audioDigestFileName = "audio.sha256"
    private static let artworkDigestFileName = "artwork.sha256"
    private let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = try! fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.rootURL = base.appendingPathComponent("WatchTransfers", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    func prepare(source: WatchTransferSource, transferID: UUID) async throws -> PreparedWatchTransfer {
        guard fileManager.fileExists(atPath: source.audioURL.path) else {
            throw WatchTransferSnapshotError.sourceMissing
        }
        let destination = directory(for: transferID)
        let staging = rootURL.appendingPathComponent(".\(transferID.uuidString)-\(UUID().uuidString)")
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let audioURL = staging.appendingPathComponent("audio.m4a")
            // On APFS this is a copy-on-write clone: constant time, no extra
            // disk usage until one side changes.
            try fileManager.copyItem(at: source.audioURL, to: audioURL)
            if let digest = source.audioContentSHA256,
               WatchFileDigest.isValidSHA256(digest) {
                try digest.write(
                    to: staging.appendingPathComponent(Self.audioDigestFileName),
                    atomically: true,
                    encoding: .utf8
                )
            } else {
                WatchSyncLog.phoneService.notice(
                    "snapshot_digest_missing transfer=\(transferID.uuidString, privacy: .public) bytes=\(audioURL.fileSizeForWatchLog)"
                )
            }
            if let artworkURL = source.artworkURL,
               fileManager.fileExists(atPath: artworkURL.path) {
                try fileManager.copyItem(at: artworkURL, to: staging.appendingPathComponent("artwork.jpg"))
            }
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
            return try preparedTransferRequired(transferID: transferID)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func preparedTransfer(transferID: UUID) async -> PreparedWatchTransfer? {
        try? preparedTransferRequired(transferID: transferID)
    }

    func cloneTransfer(
        from sourceTransferID: UUID,
        to destinationTransferID: UUID
    ) async throws -> PreparedWatchTransfer {
        let source = directory(for: sourceTransferID)
        guard fileManager.fileExists(atPath: source.appendingPathComponent("audio.m4a").path) else {
            throw WatchTransferSnapshotError.sourceMissing
        }
        let destination = directory(for: destinationTransferID)
        let staging = rootURL.appendingPathComponent(".\(destinationTransferID.uuidString)-\(UUID().uuidString)")
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.copyItem(at: source, to: staging)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
            return try preparedTransferRequired(transferID: destinationTransferID)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func removeTransfer(_ transferID: UUID) async {
        try? fileManager.removeItem(at: directory(for: transferID))
    }

    func storedTransferIDs() async -> Set<UUID> {
        Set((try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.compactMap { UUID(uuidString: $0.lastPathComponent) } ?? [])
    }

    func removeOrphans(retaining transferIDs: Set<UUID>) async {
        for transferID in await storedTransferIDs() where !transferIDs.contains(transferID) {
            try? fileManager.removeItem(at: directory(for: transferID))
        }
    }

    func removeStagingDirectories() async {
        let entries = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(".") {
            try? fileManager.removeItem(at: entry)
        }
    }

    private func preparedTransferRequired(transferID: UUID) throws -> PreparedWatchTransfer {
        let directory = directory(for: transferID)
        let audioURL = directory.appendingPathComponent("audio.m4a")
        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw WatchTransferSnapshotError.sourceMissing
        }
        let artworkURL = directory.appendingPathComponent("artwork.jpg")
        let hasArtwork = fileManager.fileExists(atPath: artworkURL.path)
        return PreparedWatchTransfer(
            transferID: transferID,
            audioURL: audioURL,
            artworkURL: hasArtwork ? artworkURL : nil,
            audioContentSHA256: try audioDigest(
                for: audioURL,
                sidecarURL: directory.appendingPathComponent(Self.audioDigestFileName)
            ),
            artworkContentSHA256: hasArtwork ? try digest(
                for: artworkURL,
                sidecarURL: directory.appendingPathComponent(Self.artworkDigestFileName)
            ) : nil
        )
    }

    /// The audio digest doubles as the `.normalizedFlatM4A` claim, which the
    /// Watch verifies with a flat-container check. A snapshot prepared from a
    /// file that was never normalized therefore ships without a digest and
    /// falls back to the Watch's AVFoundation validation.
    private func audioDigest(for fileURL: URL, sidecarURL: URL) throws -> String? {
        if let stored = storedDigest(at: sidecarURL) {
            return stored
        }
        guard AVFoundationLibraryAudioNormalizer.isFlatContainer(at: fileURL) else {
            return nil
        }
        return try digest(for: fileURL, sidecarURL: sidecarURL)
    }

    /// Reads the cached digest, computing and caching it only for snapshots
    /// prepared without one.
    private func digest(for fileURL: URL, sidecarURL: URL) throws -> String {
        if let stored = storedDigest(at: sidecarURL) {
            return stored
        }
        let value = try WatchFileDigest.sha256(at: fileURL)
        try value.write(to: sidecarURL, atomically: true, encoding: .utf8)
        return value
    }

    private func storedDigest(at sidecarURL: URL) -> String? {
        guard let stored = try? String(contentsOf: sidecarURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              WatchFileDigest.isValidSHA256(stored) else {
            return nil
        }
        return stored
    }

    private func directory(for transferID: UUID) -> URL {
        rootURL.appendingPathComponent(transferID.uuidString, isDirectory: true)
    }
}

enum WatchTransferSnapshotError: LocalizedError {
    case sourceMissing
    case normalizationFailed

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "転送元の音声ファイルが見つかりません。"
        case .normalizationFailed:
            "Watch用の音声ファイルを準備できませんでした。"
        }
    }
}

private extension URL {
    var fileSizeForWatchLog: Int64 {
        Int64((try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
    }
}
