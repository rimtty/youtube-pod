import Foundation

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
}

struct PreparedWatchTransfer: Sendable, Equatable {
    let transferID: UUID
    let audioURL: URL
    let artworkURL: URL?
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

actor WatchTransferSnapshotStore: WatchTransferSnapshotStoring {
    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
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
            try fileManager.copyItem(at: source.audioURL, to: staging.appendingPathComponent("audio.m4a"))
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
        return PreparedWatchTransfer(
            transferID: transferID,
            audioURL: audioURL,
            artworkURL: fileManager.fileExists(atPath: artworkURL.path) ? artworkURL : nil
        )
    }

    private func directory(for transferID: UUID) -> URL {
        rootURL.appendingPathComponent(transferID.uuidString, isDirectory: true)
    }
}

enum WatchTransferSnapshotError: LocalizedError {
    case sourceMissing

    var errorDescription: String? {
        "転送元の音声ファイルが見つかりません。"
    }
}
