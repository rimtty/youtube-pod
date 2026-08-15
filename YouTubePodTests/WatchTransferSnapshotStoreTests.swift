import XCTest
@testable import YouTubePod

final class WatchTransferSnapshotStoreTests: XCTestCase {
    func testPreparedSnapshotSurvivesSourceDeletionAndCanBeCloned() async throws {
        let root = temporaryDirectory(named: "snapshots")
        let sourceDirectory = temporaryDirectory(named: "source")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }
        let audioURL = sourceDirectory.appendingPathComponent("source.m4a")
        let artworkURL = sourceDirectory.appendingPathComponent("source.jpg")
        let audio = Data("audio-payload".utf8)
        let artwork = Data("artwork-payload".utf8)
        try audio.write(to: audioURL)
        try artwork.write(to: artworkURL)
        let store = WatchTransferSnapshotStore(rootURL: root)
        let firstID = UUID()

        let prepared = try await store.prepare(
            source: source(audioURL: audioURL, artworkURL: artworkURL),
            transferID: firstID
        )
        try FileManager.default.removeItem(at: sourceDirectory)

        XCTAssertEqual(try Data(contentsOf: prepared.audioURL), audio)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(prepared.artworkURL)), artwork)

        let secondID = UUID()
        let cloned = try await store.cloneTransfer(from: firstID, to: secondID)
        XCTAssertEqual(try Data(contentsOf: cloned.audioURL), audio)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cloned.artworkURL)), artwork)

        await store.removeTransfer(firstID)
        let removed = await store.preparedTransfer(transferID: firstID)
        let retained = await store.preparedTransfer(transferID: secondID)
        XCTAssertNil(removed)
        XCTAssertNotNil(retained)
    }

    func testMissingAudioSourceIsRejectedWithoutCreatingTransferDirectory() async throws {
        let root = temporaryDirectory(named: "missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WatchTransferSnapshotStore(rootURL: root)
        let transferID = UUID()

        do {
            _ = try await store.prepare(
                source: source(
                    audioURL: root.appendingPathComponent("does-not-exist.m4a"),
                    artworkURL: nil
                ),
                transferID: transferID
            )
            XCTFail("Expected a missing source error")
        } catch WatchTransferSnapshotError.sourceMissing {
            // Expected.
        }

        let prepared = await store.preparedTransfer(transferID: transferID)
        XCTAssertNil(prepared)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty)
    }

    func testOrphanAndInterruptedStagingCleanupRetainsOnlyReferencedSnapshot() async throws {
        let root = temporaryDirectory(named: "cleanup")
        let sourceDirectory = temporaryDirectory(named: "cleanup-source")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }
        let audioURL = sourceDirectory.appendingPathComponent("audio.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let store = WatchTransferSnapshotStore(rootURL: root)
        let retainedID = UUID()
        let orphanID = UUID()
        _ = try await store.prepare(
            source: source(audioURL: audioURL, artworkURL: nil),
            transferID: retainedID
        )
        _ = try await store.prepare(
            source: source(audioURL: audioURL, artworkURL: nil),
            transferID: orphanID
        )
        let interrupted = root.appendingPathComponent(".interrupted-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)

        await store.removeOrphans(retaining: [retainedID])
        let storedIDs = await store.storedTransferIDs()
        XCTAssertEqual(storedIDs, [retainedID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.path))

        await store.removeStagingDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
    }

    private func source(audioURL: URL, artworkURL: URL?) -> WatchTransferSource {
        WatchTransferSource(
            youtubeID: "dQw4w9WgXcQ",
            title: "Snapshot",
            channelTitle: "YouTube Pod",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            savedViewCount: 42,
            duration: 120,
            playbackPosition: 30,
            audioURL: audioURL,
            artworkURL: artworkURL
        )
    }

    private func temporaryDirectory(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePod-Watch-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
