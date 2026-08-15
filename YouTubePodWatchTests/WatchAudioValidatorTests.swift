import AVFoundation
import Foundation
import Testing
@testable import YouTubePodWatch

struct WatchAudioValidatorTests {
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

    private func envelope(fileSize: Int64) -> WatchTransferEnvelope {
        WatchTransferEnvelope(
            transferID: UUID(),
            revision: 1,
            fileKind: .audio,
            youtubeID: "watchaudio1",
            title: "Audio",
            channel: "Channel",
            publishedAt: nil,
            viewCount: 1,
            duration: 0.1,
            fileSize: fileSize,
            playbackPosition: 0
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

private enum WatchAudioValidatorTestError: Error {
    case bufferAllocationFailed
}
