import AVFoundation
import XCTest
@testable import YouTubePod

final class LibraryAudioNormalizerTests: XCTestCase {
    func testNormalizerFlattensFragmentedM4AAndPreservesDuration() async throws {
        let sourceURL = try fragmentedFixtureURL()
        let outputDirectory = temporaryDirectory(named: "normalized-audio")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let destinationURL = outputDirectory.appendingPathComponent("audio.m4a")
        let sourceBoxes = try WatchISOBaseMediaContainerSummary(url: sourceURL)
        XCTAssertGreaterThan(sourceBoxes.count(of: "moof"), 1)
        XCTAssertFalse(AVFoundationLibraryAudioNormalizer.isFlatContainer(at: sourceURL))

        try await AVFoundationLibraryAudioNormalizer().normalize(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )

        let outputAsset = AVURLAsset(url: destinationURL)
        let outputDuration = try await outputAsset.load(.duration).seconds
        let boxes = try WatchISOBaseMediaContainerSummary(url: destinationURL)
        XCTAssertEqual(outputDuration, 1.523, accuracy: 0.05)
        XCTAssertEqual(boxes.count(of: "moov"), 1)
        XCTAssertGreaterThanOrEqual(boxes.count(of: "mdat"), 1)
        XCTAssertEqual(boxes.count(of: "moof"), 0)
        XCTAssertTrue(AVFoundationLibraryAudioNormalizer.isFlatContainer(at: destinationURL))
    }

    func testNormalizedOutputDecodesAtArbitraryPositions() async throws {
        let sourceURL = try fragmentedFixtureURL()
        let outputDirectory = temporaryDirectory(named: "random-access")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let destinationURL = outputDirectory.appendingPathComponent("audio.m4a")
        try await AVFoundationLibraryAudioNormalizer().normalize(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )

        let asset = AVURLAsset(url: destinationURL)
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

    /// The iPhone player resumes from a stored position and drives the seek
    /// bar from AVPlayer time. Both files must map a given time to the same
    /// audio, otherwise replacing the library file would shift playback.
    func testNormalizedOutputKeepsSeekPositionsAndAudioSamplesIdentical() async throws {
        let sourceURL = try fragmentedFixtureURL()
        let outputDirectory = temporaryDirectory(named: "seek-equivalence")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let destinationURL = outputDirectory.appendingPathComponent("audio.m4a")
        try await AVFoundationLibraryAudioNormalizer().normalize(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )

        for seconds in [0.25, 0.75, 1.2] {
            let start = CMTime(seconds: seconds, preferredTimescale: 44_100)
            let range = CMTimeRange(start: start, duration: CMTime(seconds: 0.2, preferredTimescale: 44_100))
            let original = try await decodePCM(at: sourceURL, range: range)
            let normalized = try await decodePCM(at: destinationURL, range: range)
            XCTAssertEqual(
                original.firstPresentationTime,
                normalized.firstPresentationTime,
                accuracy: 1.0 / 44_100,
                "first decoded sample time differs at \(seconds)s"
            )
            XCTAssertEqual(original.samples.count, normalized.samples.count, "frame count differs at \(seconds)s")
            let maximumDifference = zip(original.samples, normalized.samples)
                .map { abs($0 - $1) }
                .max() ?? 0
            XCTAssertLessThan(maximumDifference, 1e-4, "decoded audio differs at \(seconds)s")
        }
    }

    func testProgressStartsIndeterminateThenAdvancesMonotonically() async throws {
        let sourceURL = try fragmentedFixtureURL()
        let outputDirectory = temporaryDirectory(named: "progress")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let destinationURL = outputDirectory.appendingPathComponent("audio.m4a")
        let recorder = ProgressRecorder()

        try await AVFoundationLibraryAudioNormalizer().normalize(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        ) { value in
            recorder.record(value)
        }

        let events = recorder.events
        XCTAssertEqual(events.first, .inspecting)
        XCTAssertEqual(events.last, .verifying)
        let fractions = events.compactMap { event -> Double? in
            if case .remuxing(let fraction) = event { return fraction }
            return nil
        }
        XCTAssertEqual(fractions.first, 0)
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertGreaterThan(fractions.count, 2)
    }

    func testInvalidAudioIsRejectedWithoutLeavingOutput() async throws {
        let outputDirectory = temporaryDirectory(named: "invalid")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let invalidURL = outputDirectory.appendingPathComponent("invalid.m4a")
        try Data("not-an-audio-file".utf8).write(to: invalidURL)
        let destinationURL = outputDirectory.appendingPathComponent("audio.m4a")

        do {
            try await AVFoundationLibraryAudioNormalizer().normalize(
                sourceURL: invalidURL,
                destinationURL: destinationURL
            )
            XCTFail("Expected the normalizer to reject invalid audio")
        } catch is LibraryAudioNormalizationError {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertFalse(AVFoundationLibraryAudioNormalizer.isFlatContainer(at: invalidURL))
    }

    // MARK: - Helpers

    private struct DecodedPCM {
        let firstPresentationTime: Double
        let samples: [Float]
    }

    private func decodePCM(at url: URL, range: CMTimeRange) async throws -> DecodedPCM {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
            ]
        )
        reader.add(output)
        reader.timeRange = range
        XCTAssertTrue(reader.startReading())
        var firstPresentationTime: Double?
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            if firstPresentationTime == nil {
                firstPresentationTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var bytes = [UInt8](repeating: 0, count: length)
            let status = bytes.withUnsafeMutableBytes { pointer in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    destination: pointer.baseAddress!
                )
            }
            XCTAssertEqual(status, noErr)
            bytes.withUnsafeBytes { raw in
                samples.append(contentsOf: raw.bindMemory(to: Float.self))
            }
        }
        XCTAssertEqual(reader.status, .completed)
        return DecodedPCM(firstPresentationTime: try XCTUnwrap(firstPresentationTime), samples: samples)
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [LibraryAudioOptimizationProgress] = []

        func record(_ value: LibraryAudioOptimizationProgress) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }

        var events: [LibraryAudioOptimizationProgress] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func fragmentedFixtureURL() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fragmented-aac", withExtension: "m4a"))
    }

    private func temporaryDirectory(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePod-Normalizer-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
