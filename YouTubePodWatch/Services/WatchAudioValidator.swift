import AVFoundation
import Foundation

protocol WatchAudioValidating: Sendable {
    func validate(fileURL: URL, envelope: WatchTransferEnvelope) async throws -> ValidatedWatchAudio
}

struct ValidatedWatchAudio: Equatable, Sendable {
    let actualFileSize: Int64
    let actualDuration: TimeInterval
}

struct AVFoundationWatchAudioValidator: WatchAudioValidating {
    func validate(
        fileURL url: URL,
        envelope: WatchTransferEnvelope
    ) async throws -> ValidatedWatchAudio {
        try Task.checkCancellation()
        guard envelope.fileKind == .audio, url.pathExtension.lowercased() == "m4a" else {
            throw WatchAudioValidationError.unsupportedFormat
        }

        let actualFileSize = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard actualFileSize == envelope.fileSize else {
            throw WatchAudioValidationError.sizeMismatch(expected: envelope.fileSize, actual: actualFileSize)
        }

        let asset = AVURLAsset(url: url)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration).seconds
            let isPlayable = try await asset.load(.isPlayable)
            try Task.checkCancellation()
            guard !audioTracks.isEmpty else {
                throw WatchAudioValidationError.missingAudioTrack
            }
            guard videoTracks.isEmpty else {
                throw WatchAudioValidationError.containsVideoTrack
            }
            guard isPlayable, duration.isFinite, duration > 0 else {
                throw WatchAudioValidationError.invalidDuration
            }
            return ValidatedWatchAudio(
                actualFileSize: actualFileSize,
                actualDuration: duration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WatchAudioValidationError {
            throw error
        } catch {
            throw WatchAudioValidationError.unreadable(error.localizedDescription)
        }
    }
}

enum WatchAudioValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case sizeMismatch(expected: Int64, actual: Int64)
    case missingAudioTrack
    case containsVideoTrack
    case invalidDuration
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "M4A形式の音声だけを転送できます。"
        case .sizeMismatch:
            "転送されたファイルサイズが一致しません。"
        case .missingAudioTrack:
            "音声トラックがありません。"
        case .containsVideoTrack:
            "動画トラックを含むファイルは保存できません。"
        case .invalidDuration:
            "再生時間が正しくありません。"
        case .unreadable(let detail):
            "音声ファイルを検証できませんでした: \(detail)"
        }
    }
}
