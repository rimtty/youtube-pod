import AVFAudio
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
        let digest = try WatchFileDigest.sha256(at: audioURL)
        let store = WatchTransferSnapshotStore(rootURL: root)
        let firstID = UUID()

        let prepared = try await store.prepare(
            source: source(audioURL: audioURL, artworkURL: artworkURL, digest: digest),
            transferID: firstID
        )
        try FileManager.default.removeItem(at: sourceDirectory)

        XCTAssertEqual(try Data(contentsOf: prepared.audioURL), audio)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(prepared.artworkURL)), artwork)
        XCTAssertEqual(prepared.audioContentSHA256, digest)
        XCTAssertEqual(
            prepared.artworkContentSHA256,
            try WatchFileDigest.sha256(at: XCTUnwrap(prepared.artworkURL))
        )

        let secondID = UUID()
        let cloned = try await store.cloneTransfer(from: firstID, to: secondID)
        XCTAssertEqual(try Data(contentsOf: cloned.audioURL), audio)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cloned.artworkURL)), artwork)
        XCTAssertEqual(cloned.audioContentSHA256, prepared.audioContentSHA256)
        XCTAssertEqual(cloned.artworkContentSHA256, prepared.artworkContentSHA256)

        await store.removeTransfer(firstID)
        let removed = await store.preparedTransfer(transferID: firstID)
        let retained = await store.preparedTransfer(transferID: secondID)
        XCTAssertNil(removed)
        XCTAssertNotNil(retained)
    }

    func testPrepareWritesProvidedDigestWithoutRereadingTheAudio() async throws {
        let root = temporaryDirectory(named: "digest-passthrough")
        let sourceDirectory = temporaryDirectory(named: "digest-source")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }
        let audioURL = sourceDirectory.appendingPathComponent("audio.m4a")
        try Data("not-a-real-container".utf8).write(to: audioURL)
        // Deliberately not the digest of the bytes: the store must trust the
        // optimizer's value instead of hashing the file again.
        let providedDigest = String(repeating: "c", count: 64)
        let store = WatchTransferSnapshotStore(rootURL: root)
        let transferID = UUID()

        let prepared = try await store.prepare(
            source: source(audioURL: audioURL, artworkURL: nil, digest: providedDigest),
            transferID: transferID
        )

        XCTAssertEqual(prepared.audioContentSHA256, providedDigest)
        let sidecar = root
            .appendingPathComponent(transferID.uuidString, isDirectory: true)
            .appendingPathComponent("audio.sha256")
        XCTAssertEqual(
            try String(contentsOf: sidecar, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            providedDigest
        )
    }

    func testPrepareWithoutDigestOnlyHashesFlatContainers() async throws {
        let root = temporaryDirectory(named: "digest-fallback")
        let sourceDirectory = temporaryDirectory(named: "digest-fallback-source")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }
        let fragmentedURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "fragmented-aac", withExtension: "m4a")
        )
        let flatURL = try makeFlatM4AAudioFile(in: sourceDirectory)
        let store = WatchTransferSnapshotStore(rootURL: root)

        // A fragmented file must not be advertised as normalized: the Watch
        // would reject its container on the digest fast path.
        let fragmented = try await store.prepare(
            source: source(audioURL: fragmentedURL, artworkURL: nil, digest: nil),
            transferID: UUID()
        )
        XCTAssertNil(fragmented.audioContentSHA256)

        let flat = try await store.prepare(
            source: source(audioURL: flatURL, artworkURL: nil, digest: nil),
            transferID: UUID()
        )
        XCTAssertEqual(flat.audioContentSHA256, try WatchFileDigest.sha256(at: flatURL))
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
                    artworkURL: nil,
                    digest: nil
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
            source: source(audioURL: audioURL, artworkURL: nil, digest: nil),
            transferID: retainedID
        )
        _ = try await store.prepare(
            source: source(audioURL: audioURL, artworkURL: nil, digest: nil),
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

    private func source(audioURL: URL, artworkURL: URL?, digest: String?) -> WatchTransferSource {
        WatchTransferSource(
            youtubeID: "dQw4w9WgXcQ",
            title: "Snapshot",
            channelTitle: "YouTube Pod",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            savedViewCount: 42,
            duration: 120,
            playbackPosition: 30,
            audioURL: audioURL,
            artworkURL: artworkURL,
            audioContentSHA256: digest
        )
    }

    private func makeFlatM4AAudioFile(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("flat.m4a")
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_410)
        )
        buffer.frameLength = 4_410
        try file.write(from: buffer)
        return url
    }

    private func temporaryDirectory(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePod-Watch-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
