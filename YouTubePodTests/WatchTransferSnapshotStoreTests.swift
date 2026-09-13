import AVFoundation
import XCTest
@testable import YouTubePod

final class WatchTransferSnapshotStoreTests: XCTestCase {
    func testNormalizerFlattensFragmentedM4AAndPreservesDuration() async throws {
        let sourceURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "fragmented-aac", withExtension: "m4a")
        )
        let outputDirectory = temporaryDirectory(named: "normalized-audio")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let destinationURL = outputDirectory.appendingPathComponent("audio.m4a")

        try await AVFoundationWatchAudioNormalizer().normalize(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )

        let outputAsset = AVURLAsset(url: destinationURL)
        let outputDuration = try await outputAsset.load(.duration).seconds
        let boxes = try ISOBaseMediaFileSummary(url: destinationURL)
        XCTAssertEqual(outputDuration, 1.523, accuracy: 0.05)
        XCTAssertEqual(boxes.count(of: "moov"), 1)
        XCTAssertGreaterThanOrEqual(boxes.count(of: "mdat"), 1)
        XCTAssertEqual(boxes.count(of: "moof"), 0)
    }

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
        let store = WatchTransferSnapshotStore(
            rootURL: root,
            audioNormalizer: CopyingWatchAudioNormalizer()
        )
        let firstID = UUID()

        let prepared = try await store.prepare(
            source: source(audioURL: audioURL, artworkURL: artworkURL),
            transferID: firstID
        )
        try FileManager.default.removeItem(at: sourceDirectory)

        XCTAssertEqual(try Data(contentsOf: prepared.audioURL), audio)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(prepared.artworkURL)), artwork)
        XCTAssertEqual(prepared.audioContentSHA256, try WatchFileDigest.sha256(at: prepared.audioURL))
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

    func testMissingAudioSourceIsRejectedWithoutCreatingTransferDirectory() async throws {
        let root = temporaryDirectory(named: "missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WatchTransferSnapshotStore(
            rootURL: root,
            audioNormalizer: CopyingWatchAudioNormalizer()
        )
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
        let store = WatchTransferSnapshotStore(
            rootURL: root,
            audioNormalizer: CopyingWatchAudioNormalizer()
        )
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

    func testPrepareNormalizesFragmentedM4AForArbitraryPositionDecoding() async throws {
        let root = temporaryDirectory(named: "fragmented-normalization")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "fragmented-aac", withExtension: "m4a")
        )
        let sourceBoxes = try ISOBaseMediaFileSummary(url: fixtureURL)
        XCTAssertGreaterThan(sourceBoxes.count(of: "moof"), 1)
        XCTAssertGreaterThan(sourceBoxes.count(of: "mdat"), 1)
        let store = WatchTransferSnapshotStore(rootURL: root)

        let prepared = try await store.prepare(
            source: source(audioURL: fixtureURL, artworkURL: nil),
            transferID: UUID()
        )

        let outputBoxes = try ISOBaseMediaFileSummary(url: prepared.audioURL)
        XCTAssertEqual(outputBoxes.count(of: "moof"), 0)
        XCTAssertEqual(outputBoxes.count(of: "moov"), 1)
        XCTAssertEqual(outputBoxes.count(of: "mdat"), 1)

        let asset = AVURLAsset(url: prepared.audioURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
        )
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        let target = CMTimeMultiplyByFloat64(duration, multiplier: 0.75)
        reader.timeRange = CMTimeRange(
            start: target,
            duration: CMTime(seconds: 0.2, preferredTimescale: 600)
        )
        XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        XCTAssertGreaterThanOrEqual(
            CMSampleBufferGetPresentationTimeStamp(sample).seconds,
            target.seconds - 0.1
        )
        XCTAssertNotEqual(reader.status, .failed)
    }

    func testProductionNormalizerRejectsInvalidAudioWithoutLeavingSnapshot() async throws {
        let root = temporaryDirectory(named: "invalid-normalization")
        let sourceDirectory = temporaryDirectory(named: "invalid-normalization-source")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }
        let invalidAudioURL = sourceDirectory.appendingPathComponent("invalid.m4a")
        try Data("not-an-audio-file".utf8).write(to: invalidAudioURL)
        let store = WatchTransferSnapshotStore(rootURL: root)

        do {
            _ = try await store.prepare(
                source: source(audioURL: invalidAudioURL, artworkURL: nil),
                transferID: UUID()
            )
            XCTFail("Expected normalization to reject invalid audio")
        } catch WatchTransferSnapshotError.normalizationFailed {
            // Expected.
        }

        let remaining = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remaining.isEmpty)
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

private struct CopyingWatchAudioNormalizer: WatchAudioNormalizing {
    func normalize(sourceURL: URL, destinationURL: URL) async throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}
