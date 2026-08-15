import Foundation
import Testing
@testable import YouTubePodWatch

struct WatchIncomingFileStagerTests {
    @Test func stagesAudioSynchronouslyWithSafeExtension() throws {
        try withFixture { fixture in
            let sourceURL = try fixture.sourceFile(
                named: "callback.untrusted-extension",
                data: Data("audio".utf8)
            )
            let envelope = fixture.envelope(fileKind: .audio, fileSize: 5)

            let staged = try fixture.stager.stage(
                fileAt: sourceURL,
                metadata: envelope.metadata()
            )
            try fixture.fileManager.removeItem(at: sourceURL)

            #expect(staged.fileURL.pathExtension == "m4a")
            #expect(staged.receiptDirectoryURL.lastPathComponent.hasPrefix("ready-"))
            #expect(try Data(contentsOf: staged.fileURL) == Data("audio".utf8))
            #expect(staged.envelope == envelope)
            #expect(
                fixture.fileManager.fileExists(
                    atPath: staged.receiptDirectoryURL.appending(path: "envelope.json").path
                )
            )
        }
    }

    @Test func artworkAlwaysUsesJPGExtension() throws {
        try withFixture { fixture in
            let sourceURL = try fixture.sourceFile(named: "artwork.exe", data: Data([1, 2, 3]))
            let envelope = fixture.envelope(fileKind: .artwork, fileSize: 3)

            let staged = try fixture.stager.stage(
                fileAt: sourceURL,
                metadata: envelope.metadata()
            )

            #expect(staged.fileURL.pathExtension == "jpg")
            #expect(staged.fileURL.lastPathComponent == "payload.jpg")
        }
    }

    @Test func invalidMetadataDoesNotLeavePartialData() throws {
        try withFixture { fixture in
            let sourceURL = try fixture.sourceFile(named: "audio.m4a", data: Data([1]))

            #expect(throws: WatchTransferProtocolError.missingEnvelope) {
                try fixture.stager.stage(fileAt: sourceURL, metadata: [:])
            }
            #expect(try fixture.stager.listStagedFiles().isEmpty)
        }
    }

    @Test func sizeMismatchRemovesTheUniqueStagingDirectory() throws {
        try withFixture { fixture in
            let sourceURL = try fixture.sourceFile(named: "audio.m4a", data: Data([1, 2]))
            let envelope = fixture.envelope(fileKind: .audio, fileSize: 99)

            #expect(throws: WatchIncomingFileStagerError.fileSizeMismatch(expected: 99, actual: 2)) {
                try fixture.stager.stage(fileAt: sourceURL, metadata: envelope.metadata())
            }
            #expect(try fixture.stager.listStagedFiles().isEmpty)
            #expect(try fixture.rootContents().isEmpty)
        }
    }

    @Test func pendingReceiptIsRecoveredAfterCallbackReturnAndProcessRestart() throws {
        try withFixture { fixture in
            let sourceURL = try fixture.sourceFile(named: "audio.m4a", data: Data([4, 5, 6]))
            let envelope = fixture.envelope(fileKind: .audio, fileSize: 3)
            let staged = try fixture.stager.stage(
                fileAt: sourceURL,
                metadata: envelope.metadata()
            )
            let recreated = WatchIncomingFileStager(rootDirectoryURL: fixture.incomingURL)

            // Simulates WatchConnectivity deleting its callback URL immediately
            // after the synchronous delegate callback returns.
            try fixture.fileManager.removeItem(at: sourceURL)

            let listed = try recreated.listStagedFiles()

            #expect(listed == [staged])
            #expect(try Data(contentsOf: listed[0].fileURL) == Data([4, 5, 6]))
            #expect(listed[0].envelope == envelope)
            try recreated.remove(listed[0])
            #expect(try recreated.listStagedFiles().isEmpty)
        }
    }

    @Test func startupCleanupRemovesIncompleteDirectoriesAndKeepsValidFiles() throws {
        try withFixture { fixture in
            let sourceURL = try fixture.sourceFile(named: "audio.m4a", data: Data([7, 8]))
            let envelope = fixture.envelope(fileKind: .audio, fileSize: 2)
            let staged = try fixture.stager.stage(
                fileAt: sourceURL,
                metadata: envelope.metadata()
            )
            let interruptedURL = fixture.incomingURL.appending(
                path: ".staging-interrupted",
                directoryHint: .isDirectory
            )
            try fixture.fileManager.createDirectory(
                at: interruptedURL,
                withIntermediateDirectories: true
            )
            try Data([0]).write(to: interruptedURL.appending(path: "payload.partial"))

            let recovered = try fixture.stager.cleanupOnStartup()

            #expect(recovered == [staged])
            #expect(!fixture.fileManager.fileExists(atPath: interruptedURL.path))
        }
    }

    @Test func startupPromotesCompleteDirectoryLeftBeforeAtomicRename() throws {
        try withFixture { fixture in
            let envelope = fixture.envelope(fileKind: .audio, fileSize: 3)
            let stagingURL = fixture.incomingURL.appending(
                path: ".staging-crash-window",
                directoryHint: .isDirectory
            )
            try fixture.fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: stagingURL.appending(path: "payload.m4a"))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try encoder.encode(envelope).write(
                to: stagingURL.appending(path: "envelope.json"),
                options: .atomic
            )

            let recovered = try fixture.stager.cleanupOnStartup()

            #expect(recovered.count == 1)
            #expect(recovered.first?.envelope == envelope)
            #expect(recovered.first?.receiptDirectoryURL.lastPathComponent.hasPrefix("ready-") == true)
            #expect(!fixture.fileManager.fileExists(atPath: stagingURL.path))
        }
    }

    @Test func corruptReadyReceiptDoesNotBlockValidReceipt() throws {
        try withFixture { fixture in
            let sourceURL = try fixture.sourceFile(named: "valid.m4a", data: Data([7]))
            let envelope = fixture.envelope(fileKind: .audio, fileSize: 1)
            let valid = try fixture.stager.stage(fileAt: sourceURL, metadata: envelope.metadata())
            let corruptURL = fixture.incomingURL.appending(
                path: "ready-corrupt",
                directoryHint: .isDirectory
            )
            try fixture.fileManager.createDirectory(at: corruptURL, withIntermediateDirectories: true)

            #expect(try fixture.stager.listStagedFiles() == [valid])
            #expect(!fixture.fileManager.fileExists(atPath: corruptURL.path))
        }
    }

    @Test func concurrentDelegateCallbacksCreateIndependentCompleteReceipts() async throws {
        let fixture = try Fixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.baseURL) }
        let sourceURLs = try (0..<4).map { index in
            try fixture.sourceFile(named: "audio-\(index).m4a", data: Data([UInt8(index)]))
        }
        let stager = fixture.stager

        let receipts = try await withThrowingTaskGroup(
            of: StagedWatchTransferFile.self,
            returning: [StagedWatchTransferFile].self
        ) { group in
            for (index, sourceURL) in sourceURLs.enumerated() {
                group.addTask {
                    let envelope = WatchTransferEnvelope(
                        transferID: UUID(),
                        revision: Int64(index),
                        fileKind: .audio,
                        youtubeID: "dQw4w9WgXcQ",
                        title: "Concurrent callback \(index)",
                        channel: "YouTube Pod",
                        publishedAt: nil,
                        viewCount: 0,
                        duration: 60,
                        fileSize: 1,
                        playbackPosition: 0
                    )
                    return try stager.stage(
                        fileAt: sourceURL,
                        metadata: envelope.metadata()
                    )
                }
            }

            var results: [StagedWatchTransferFile] = []
            for try await receipt in group {
                results.append(receipt)
            }
            return results
        }

        #expect(receipts.count == 4)
        #expect(Set(receipts.map(\.receiptDirectoryURL)).count == 4)
        #expect(try stager.listStagedFiles().count == 4)
    }

    @Test func deletionCommandIsRecoveredAfterDelegateCallbackAndRestart() throws {
        try withFixture { fixture in
            let command = WatchLibraryCommand(
                commandID: UUID(),
                kind: .delete,
                youtubeID: "dQw4w9WgXcQ",
                revision: 5
            )

            let staged = try fixture.stager.stageCommand(userInfo: command.userInfo())
            let recreated = WatchIncomingFileStager(rootDirectoryURL: fixture.incomingURL)

            #expect(try recreated.listStagedCommands() == [staged])
            try recreated.remove(staged)
            #expect(try recreated.listStagedCommands().isEmpty)
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.baseURL) }
        try body(fixture)
    }

    private struct Fixture {
        let fileManager = FileManager.default
        let baseURL: URL
        let incomingURL: URL
        let stager: WatchIncomingFileStager

        init() throws {
            baseURL = FileManager.default.temporaryDirectory.appending(
                path: "WatchIncomingFileStagerTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            incomingURL = baseURL.appending(path: "WatchIncoming", directoryHint: .isDirectory)
            stager = WatchIncomingFileStager(rootDirectoryURL: incomingURL)
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }

        func sourceFile(named name: String, data: Data) throws -> URL {
            let url = baseURL.appending(path: name)
            try data.write(to: url)
            return url
        }

        func rootContents() throws -> [URL] {
            guard fileManager.fileExists(atPath: incomingURL.path) else {
                return []
            }
            return try fileManager.contentsOfDirectory(
                at: incomingURL,
                includingPropertiesForKeys: nil
            )
        }

        func envelope(
            fileKind: WatchTransferFileKind,
            fileSize: Int64
        ) -> WatchTransferEnvelope {
            WatchTransferEnvelope(
                transferID: UUID(uuidString: "D725B720-D653-4B75-9D9E-772352ABF5C8")!,
                revision: 4,
                fileKind: fileKind,
                youtubeID: "dQw4w9WgXcQ",
                title: "Incoming transfer",
                channel: "YouTube Pod",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                viewCount: 12,
                duration: 120,
                fileSize: fileSize,
                playbackPosition: 15
            )
        }
    }
}
