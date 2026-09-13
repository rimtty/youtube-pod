import AVFoundation
import Foundation
import Testing
@testable import YouTubePodWatch

struct WatchAudioValidatorTests {
    @Test func fragmentedM4AUsesAudibleTrackDuration() async throws {
        let url = try #require(
            Bundle(for: WatchAudioValidatorTestBundleToken.self)
                .url(forResource: "fragmented-aac", withExtension: "m4a")
        )
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let declaredDuration = 1.523

        let validated = try await AVFoundationWatchAudioValidator().validate(
            fileURL: url,
            envelope: envelope(fileSize: size, duration: declaredDuration)
        )

        #expect(abs(validated.actualDuration - declaredDuration) < 0.05)
    }

    @Test func declaredDurationMustMatchMovieHeaderTimeline() async throws {
        let url = try #require(
            Bundle(for: WatchAudioValidatorTestBundleToken.self)
                .url(forResource: "fragmented-aac", withExtension: "m4a")
        )
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)

        await #expect(throws: WatchAudioValidationError.self) {
            _ = try await AVFoundationWatchAudioValidator().validate(
                fileURL: url,
                envelope: envelope(fileSize: size, duration: 30)
            )
        }
    }

    @Test func generatedM4AWithAudioOnlyIsAccepted() async throws {
        let url = try makeM4AAudioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let validated = try await AVFoundationWatchAudioValidator().validate(
            fileURL: url,
            envelope: envelope(fileSize: size)
        )

        #expect(validated.actualFileSize == size)
        #expect(validated.actualDuration > 0)
    }

    @Test func iPhoneValidatedFlatM4AUsesDigestAndContainerFastPath() async throws {
        let url = try makeM4AAudioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let duration = try ISOBaseMediaDurationReader.duration(at: url)
        let digest = try WatchFileDigest.sha256(at: url)

        let validated = try await AVFoundationWatchAudioValidator().validate(
            fileURL: url,
            envelope: envelope(
                fileSize: size,
                duration: duration,
                contentSHA256: digest,
                audioValidationProfile: .normalizedFlatM4A
            )
        )

        #expect(validated.actualFileSize == size)
        #expect(abs(validated.actualDuration - duration) < 0.01)
    }

    @Test func iPhoneValidatedAudioRejectsSameSizeCorruption() async throws {
        let url = try makeM4AAudioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let data = try Data(contentsOf: url)
        let size = Int64(data.count)
        let duration = try ISOBaseMediaDurationReader.duration(at: url)
        let digest = try WatchFileDigest.sha256(at: url)
        var corrupted = data
        corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0xff
        try corrupted.write(to: url)

        await #expect(throws: WatchAudioValidationError.digestMismatch) {
            _ = try await AVFoundationWatchAudioValidator().validate(
                fileURL: url,
                envelope: envelope(
                    fileSize: size,
                    duration: duration,
                    contentSHA256: digest,
                    audioValidationProfile: .normalizedFlatM4A
                )
            )
        }
    }

    @Test func nonM4AExtensionIsRejectedBeforeAssetLoading() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio.mp3")

        await #expect(throws: WatchAudioValidationError.unsupportedFormat) {
            _ = try await AVFoundationWatchAudioValidator().validate(
                fileURL: url,
                envelope: envelope(fileSize: 0)
            )
        }
    }

    @Test func declaredAndActualFileSizeMustMatch() async throws {
        let url = try makeM4AAudioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)

        await #expect(throws: WatchAudioValidationError.sizeMismatch(expected: size + 1, actual: size)) {
            _ = try await AVFoundationWatchAudioValidator().validate(
                fileURL: url,
                envelope: envelope(fileSize: size + 1)
            )
        }
    }

    @Test func unreadableM4AIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchAudioValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("broken.m4a")
        try Data("not-media".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: (any Error).self) {
            _ = try await AVFoundationWatchAudioValidator().validate(
                fileURL: url,
                envelope: envelope(fileSize: Int64(Data("not-media".utf8).count))
            )
        }
    }

    @Test func cancellationIsNotWrappedAsInvalidAudio() async throws {
        let url = try makeM4AAudioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let task = Task {
            try await AVFoundationWatchAudioValidator().validate(
                fileURL: url,
                envelope: envelope(fileSize: size)
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    private func envelope(
        fileSize: Int64,
        duration: TimeInterval = 0.1,
        contentSHA256: String? = nil,
        audioValidationProfile: WatchAudioValidationProfile? = nil
    ) -> WatchTransferEnvelope {
        WatchTransferEnvelope(
            transferID: UUID(),
            revision: 1,
            fileKind: .audio,
            youtubeID: "watchaudio1",
            title: "Audio",
            channel: "Channel",
            publishedAt: nil,
            viewCount: 1,
            duration: duration,
            fileSize: fileSize,
            playbackPosition: 0,
            contentSHA256: contentSHA256,
            audioValidationProfile: audioValidationProfile
        )
    }

    private func makeM4AAudioFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchAudioValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("audio.m4a")
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ]
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: 4_410
            ) else {
                throw WatchAudioValidatorTestError.bufferAllocationFailed
            }
            buffer.frameLength = 4_410
            try file.write(from: buffer)
        }
        return url
    }
}

private final class WatchAudioValidatorTestBundleToken {}

private enum WatchAudioValidatorTestError: Error {
    case bufferAllocationFailed
}
