import Foundation

struct StagedWatchTransferFile: Equatable, Sendable {
    let envelope: WatchTransferEnvelope
    let fileURL: URL
    let receiptDirectoryURL: URL
}

struct StagedWatchLibraryCommand: Equatable, Sendable {
    let command: WatchLibraryCommand
    let receiptURL: URL
}

enum WatchIncomingFileStagerError: Error, Equatable, LocalizedError, Sendable {
    case sourceIsNotARegularFile
    case fileSizeMismatch(expected: Int64, actual: Int64)
    case corruptStagingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .sourceIsNotARegularFile:
            "受信ファイルを読み取れません。"
        case let .fileSizeMismatch(expected, actual):
            "受信ファイルのサイズが一致しません（expected: \(expected), actual: \(actual)）。"
        case let .corruptStagingDirectory(name):
            "受信待機データが破損しています（\(name)）。"
        }
    }
}

/// Synchronously preserves the temporary URL supplied by WatchConnectivity.
///
/// `WCSessionDelegate` can invoke file callbacks concurrently and from a nonisolated
/// context. This type is therefore `@unchecked Sendable`: its configuration is
/// immutable after initialization and every filesystem operation is serialized by
/// `lock`. Incoming metadata is decoded synchronously and is never retained.
final class WatchIncomingFileStager: @unchecked Sendable {
    private static let envelopeFileName = "envelope.json"
    private static let partialFileName = "payload.partial"

    private let fileManager: FileManager
    private let rootDirectoryURL: URL
    private let lock = NSLock()

    init(
        fileManager: FileManager = .default,
        rootDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rootDirectoryURL = rootDirectoryURL
            ?? Self.defaultRootDirectoryURL(fileManager: fileManager)
    }

    /// Copies `sourceURL` before returning, because WatchConnectivity owns and may
    /// delete that URL as soon as its delegate callback completes.
    func stage(
        fileAt sourceURL: URL,
        metadata: [String: Any]
    ) throws -> StagedWatchTransferFile {
        let envelope = try WatchTransferEnvelope.decode(metadata: metadata)

        return try synchronized {
            try createRootDirectoryIfNeeded()

            let receiptNonce = UUID().uuidString
            let stagingDirectoryURL = rootDirectoryURL.appending(
                path: ".staging-\(receiptNonce)",
                directoryHint: .isDirectory
            )
            let readyDirectoryURL = rootDirectoryURL.appending(
                path: "ready-\(envelope.transferID.uuidString)-\(envelope.revision)-\(envelope.fileKind.rawValue)-\(receiptNonce)",
                directoryHint: .isDirectory
            )

            do {
                try fileManager.createDirectory(
                    at: stagingDirectoryURL,
                    withIntermediateDirectories: false
                )

                let partialURL = stagingDirectoryURL.appending(path: Self.partialFileName)
                try fileManager.copyItem(at: sourceURL, to: partialURL)

                let actualSize = try regularFileSize(at: partialURL)
                guard actualSize == envelope.fileSize else {
                    throw WatchIncomingFileStagerError.fileSizeMismatch(
                        expected: envelope.fileSize,
                        actual: actualSize
                    )
                }

                let fileURL = stagingDirectoryURL.appending(
                    path: "payload.\(safeFileExtension(for: envelope.fileKind))"
                )
                try fileManager.moveItem(at: partialURL, to: fileURL)

                let envelopeURL = stagingDirectoryURL.appending(path: Self.envelopeFileName)
                try encode(envelope).write(to: envelopeURL, options: .atomic)

                // Renaming a directory on the same volume is atomic. Consumers
                // therefore observe either no receipt or a complete payload and
                // durable envelope sidecar, never an intermediate combination.
                try fileManager.moveItem(at: stagingDirectoryURL, to: readyDirectoryURL)

                return StagedWatchTransferFile(
                    envelope: envelope,
                    fileURL: readyDirectoryURL.appending(path: fileURL.lastPathComponent),
                    receiptDirectoryURL: readyDirectoryURL
                )
            } catch {
                try? fileManager.removeItem(at: stagingDirectoryURL)
                try? fileManager.removeItem(at: readyDirectoryURL)
                throw error
            }
        }
    }

    /// Persists a user-info command before the WatchConnectivity delegate
    /// callback returns. WCSession considers userInfo delivered after that
    /// callback, so deferring persistence to an async Task can lose a delete
    /// command if the process is suspended in between.
    func stageCommand(userInfo: [String: Any]) throws -> StagedWatchLibraryCommand {
        let command = try WatchLibraryCommand.decode(userInfo: userInfo)
        return try synchronized {
            try createRootDirectoryIfNeeded()
            let receiptURL = commandReceiptURL(commandID: command.commandID)
            try encode(command).write(to: receiptURL, options: .atomic)
            return StagedWatchLibraryCommand(command: command, receiptURL: receiptURL)
        }
    }

    /// Removes incomplete or corrupt directories left by an interrupted import,
    /// then returns every recoverable staged file.
    @discardableResult
    func cleanupOnStartup() throws -> [StagedWatchTransferFile] {
        try synchronized {
            try createRootDirectoryIfNeeded()

            var validFiles: [StagedWatchTransferFile] = []
            for directoryURL in try allDirectoryURLs() {
                if directoryURL.lastPathComponent.hasPrefix(".staging-") {
                    do {
                        validFiles.append(try promoteCompleteStagingDirectory(directoryURL))
                    } catch {
                        try fileManager.removeItem(at: directoryURL)
                    }
                    continue
                }
                guard directoryURL.lastPathComponent.hasPrefix("ready-") else {
                    try fileManager.removeItem(at: directoryURL)
                    continue
                }
                do {
                    validFiles.append(try stagedFile(in: directoryURL))
                } catch {
                    try fileManager.removeItem(at: directoryURL)
                }
            }
            for receiptURL in try commandReceiptURLs() {
                do {
                    _ = try stagedCommand(at: receiptURL)
                } catch {
                    try fileManager.removeItem(at: receiptURL)
                }
            }
            return sorted(validFiles)
        }
    }

    func listStagedFiles() throws -> [StagedWatchTransferFile] {
        try synchronized {
            guard fileManager.fileExists(atPath: rootDirectoryURL.path) else {
                return []
            }
            var validFiles: [StagedWatchTransferFile] = []
            for directoryURL in try readyDirectoryURLs() {
                do {
                    validFiles.append(try stagedFile(in: directoryURL))
                } catch {
                    // Quarantine-by-removal prevents one corrupt receipt from
                    // starving every later valid delivery in the same pass.
                    try fileManager.removeItem(at: directoryURL)
                }
            }
            return sorted(validFiles)
        }
    }

    func listStagedCommands() throws -> [StagedWatchLibraryCommand] {
        try synchronized {
            guard fileManager.fileExists(atPath: rootDirectoryURL.path) else {
                return []
            }
            var validCommands: [StagedWatchLibraryCommand] = []
            for receiptURL in try commandReceiptURLs() {
                do {
                    validCommands.append(try stagedCommand(at: receiptURL))
                } catch {
                    try fileManager.removeItem(at: receiptURL)
                }
            }
            return validCommands.sorted {
                $0.receiptURL.lastPathComponent < $1.receiptURL.lastPathComponent
            }
        }
    }

    func remove(_ stagedFile: StagedWatchTransferFile) throws {
        try synchronized {
            let knownDirectory = rootDirectoryURL
                .appending(path: stagedFile.receiptDirectoryURL.lastPathComponent, directoryHint: .isDirectory)
                .standardizedFileURL
            guard knownDirectory == stagedFile.receiptDirectoryURL.standardizedFileURL else {
                throw WatchIncomingFileStagerError.corruptStagingDirectory(
                    stagedFile.receiptDirectoryURL.lastPathComponent
                )
            }
            guard fileManager.fileExists(atPath: knownDirectory.path) else {
                return
            }
            try fileManager.removeItem(at: knownDirectory)
        }
    }

    func remove(_ stagedCommand: StagedWatchLibraryCommand) throws {
        try synchronized {
            let knownURL = commandReceiptURL(commandID: stagedCommand.command.commandID)
                .standardizedFileURL
            guard knownURL == stagedCommand.receiptURL.standardizedFileURL else {
                throw WatchIncomingFileStagerError.corruptStagingDirectory(
                    stagedCommand.receiptURL.lastPathComponent
                )
            }
            guard fileManager.fileExists(atPath: knownURL.path) else { return }
            try fileManager.removeItem(at: knownURL)
        }
    }

    private func stagedFile(in directoryURL: URL) throws -> StagedWatchTransferFile {
        let directoryName = directoryURL.lastPathComponent
        let envelopeURL = directoryURL.appending(path: Self.envelopeFileName)
        let envelope: WatchTransferEnvelope
        do {
            envelope = try decode(Data(contentsOf: envelopeURL)).validated()
        } catch {
            throw WatchIncomingFileStagerError.corruptStagingDirectory(directoryName)
        }

        let fileURL = directoryURL.appending(
            path: "payload.\(safeFileExtension(for: envelope.fileKind))"
        )
        let actualSize: Int64
        do {
            actualSize = try regularFileSize(at: fileURL)
        } catch {
            throw WatchIncomingFileStagerError.corruptStagingDirectory(directoryName)
        }
        guard actualSize == envelope.fileSize else {
            throw WatchIncomingFileStagerError.corruptStagingDirectory(directoryName)
        }

        return StagedWatchTransferFile(
            envelope: envelope,
            fileURL: fileURL,
            receiptDirectoryURL: directoryURL
        )
    }

    private func promoteCompleteStagingDirectory(
        _ stagingDirectoryURL: URL
    ) throws -> StagedWatchTransferFile {
        let staged = try stagedFile(in: stagingDirectoryURL)
        let nonce = stagingDirectoryURL.lastPathComponent
            .replacingOccurrences(of: ".staging-", with: "")
        let envelope = staged.envelope
        let readyDirectoryURL = rootDirectoryURL.appending(
            path: "ready-\(envelope.transferID.uuidString)-\(envelope.revision)-\(envelope.fileKind.rawValue)-\(nonce)",
            directoryHint: .isDirectory
        )
        try fileManager.moveItem(at: stagingDirectoryURL, to: readyDirectoryURL)
        return try stagedFile(in: readyDirectoryURL)
    }

    private func stagedCommand(at receiptURL: URL) throws -> StagedWatchLibraryCommand {
        do {
            let command = try decodeCommand(Data(contentsOf: receiptURL)).validated()
            guard commandReceiptURL(commandID: command.commandID).standardizedFileURL
                    == receiptURL.standardizedFileURL else {
                throw WatchIncomingFileStagerError.corruptStagingDirectory(
                    receiptURL.lastPathComponent
                )
            }
            return StagedWatchLibraryCommand(command: command, receiptURL: receiptURL)
        } catch let error as WatchIncomingFileStagerError {
            throw error
        } catch {
            throw WatchIncomingFileStagerError.corruptStagingDirectory(
                receiptURL.lastPathComponent
            )
        }
    }

    private func allDirectoryURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: rootDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func readyDirectoryURLs() throws -> [URL] {
        try allDirectoryURLs().filter { $0.lastPathComponent.hasPrefix("ready-") }
    }

    private func commandReceiptURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: rootDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ).filter {
            $0.lastPathComponent.hasPrefix("command-")
                && $0.pathExtension.lowercased() == "json"
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func commandReceiptURL(commandID: UUID) -> URL {
        rootDirectoryURL.appending(path: "command-\(commandID.uuidString).json")
    }

    private func regularFileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw WatchIncomingFileStagerError.sourceIsNotARegularFile
        }
        return Int64(fileSize)
    }

    private func safeFileExtension(for fileKind: WatchTransferFileKind) -> String {
        switch fileKind {
        case .audio:
            "m4a"
        case .artwork:
            "jpg"
        }
    }

    private func encode(_ envelope: WatchTransferEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(envelope)
    }

    private func encode(_ command: WatchLibraryCommand) throws -> Data {
        try JSONEncoder().encode(command)
    }

    private func decode(_ data: Data) throws -> WatchTransferEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WatchTransferEnvelope.self, from: data)
    }

    private func decodeCommand(_ data: Data) throws -> WatchLibraryCommand {
        try JSONDecoder().decode(WatchLibraryCommand.self, from: data)
    }

    private func createRootDirectoryIfNeeded() throws {
        try fileManager.createDirectory(
            at: rootDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func sorted(_ files: [StagedWatchTransferFile]) -> [StagedWatchTransferFile] {
        files.sorted {
            $0.receiptDirectoryURL.lastPathComponent < $1.receiptDirectoryURL.lastPathComponent
        }
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func defaultRootDirectoryURL(fileManager: FileManager) -> URL {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupportURL.appending(path: "WatchIncoming", directoryHint: .isDirectory)
    }
}
