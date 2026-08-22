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
            let assetDuration = try await asset.load(.duration).seconds
            let isPlayable = try await asset.load(.isPlayable)
            try Task.checkCancellation()
            guard !audioTracks.isEmpty else {
                throw WatchAudioValidationError.missingAudioTrack
            }
            guard videoTracks.isEmpty else {
                throw WatchAudioValidationError.containsVideoTrack
            }
            guard isPlayable, assetDuration.isFinite, assetDuration > 0 else {
                throw WatchAudioValidationError.invalidDuration
            }
            // watchOS can report roughly twice the real duration for some
            // fragmented M4A files. The ISO movie header retains the correct
            // media timeline, so use it for validation when available.
            let measuredDuration = (try? ISOBaseMediaDurationReader.duration(at: url))
                ?? assetDuration
            let durationTolerance = max(1, min(5, envelope.duration * 0.01))
            guard abs(measuredDuration - envelope.duration) <= durationTolerance else {
                throw WatchAudioValidationError.durationMismatch(
                    expected: envelope.duration,
                    actual: measuredDuration
                )
            }
            return ValidatedWatchAudio(
                actualFileSize: actualFileSize,
                actualDuration: envelope.duration
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
    case durationMismatch(expected: TimeInterval, actual: TimeInterval)
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
        case .durationMismatch:
            "転送された音声の再生時間が一致しません。"
        case .unreadable(let detail):
            "音声ファイルを検証できませんでした: \(detail)"
        }
    }
}

enum ISOBaseMediaDurationReader {
    static func duration(at url: URL) throws -> TimeInterval {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize >= 8 else {
            throw ISOBaseMediaDurationError.invalidContainer
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let totalSize = UInt64(fileSize)

        var offset: UInt64 = 0
        while offset < totalSize {
            let box = try readBox(at: offset, limit: totalSize, from: handle)
            if box.type == "moov" {
                return try movieHeaderDuration(
                    from: handle,
                    start: offset + box.headerSize,
                    end: offset + box.size
                )
            }
            offset += box.size
        }
        throw ISOBaseMediaDurationError.missingMovieHeader
    }

    static func normalizedDuration(at url: URL) throws -> TimeInterval {
        // YouTube duration metadata is expressed in whole seconds. Keep the
        // repaired Watch model on that same display timeline even when AAC
        // encoder priming makes the media header fractionally shorter.
        try duration(at: url).rounded()
    }

    private static func movieHeaderDuration(
        from handle: FileHandle,
        start: UInt64,
        end: UInt64
    ) throws -> TimeInterval {
        var offset = start
        while offset < end {
            let box = try readBox(at: offset, limit: end, from: handle)
            if box.type == "mvhd" {
                try handle.seek(toOffset: offset + box.headerSize)
                let payloadSize = min(Int(box.size - box.headerSize), 32)
                guard let payload = try handle.read(upToCount: payloadSize),
                      payload.count == payloadSize,
                      let version = payload.first else {
                    throw ISOBaseMediaDurationError.invalidMovieHeader
                }
                let timeScale: UInt32
                let rawDuration: UInt64
                switch version {
                case 0:
                    guard payload.count >= 20 else {
                        throw ISOBaseMediaDurationError.invalidMovieHeader
                    }
                    timeScale = uint32(payload[12..<16])
                    rawDuration = UInt64(uint32(payload[16..<20]))
                case 1:
                    guard payload.count >= 32 else {
                        throw ISOBaseMediaDurationError.invalidMovieHeader
                    }
                    timeScale = uint32(payload[20..<24])
                    rawDuration = uint64(payload[24..<32])
                default:
                    throw ISOBaseMediaDurationError.invalidMovieHeader
                }
                guard timeScale > 0, rawDuration > 0 else {
                    throw ISOBaseMediaDurationError.invalidMovieHeader
                }
                let duration = TimeInterval(rawDuration) / TimeInterval(timeScale)
                guard duration.isFinite, duration > 0 else {
                    throw ISOBaseMediaDurationError.invalidMovieHeader
                }
                return duration
            }
            offset += box.size
        }
        throw ISOBaseMediaDurationError.missingMovieHeader
    }

    private static func readBox(
        at offset: UInt64,
        limit: UInt64,
        from handle: FileHandle
    ) throws -> (type: String, size: UInt64, headerSize: UInt64) {
        guard limit - offset >= 8 else {
            throw ISOBaseMediaDurationError.invalidContainer
        }
        try handle.seek(toOffset: offset)
        guard let header = try handle.read(upToCount: 8), header.count == 8,
              let type = String(data: header[4..<8], encoding: .ascii) else {
            throw ISOBaseMediaDurationError.invalidContainer
        }
        let compactSize = uint32(header[0..<4])
        let headerSize: UInt64
        let boxSize: UInt64
        switch compactSize {
        case 0:
            headerSize = 8
            boxSize = limit - offset
        case 1:
            guard let extended = try handle.read(upToCount: 8), extended.count == 8 else {
                throw ISOBaseMediaDurationError.invalidContainer
            }
            headerSize = 16
            boxSize = uint64(extended[0..<8])
        default:
            headerSize = 8
            boxSize = UInt64(compactSize)
        }
        guard boxSize >= headerSize, boxSize <= limit - offset else {
            throw ISOBaseMediaDurationError.invalidContainer
        }
        return (type, boxSize, headerSize)
    }

    private static func uint32(_ bytes: Data.SubSequence) -> UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64(_ bytes: Data.SubSequence) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

private enum ISOBaseMediaDurationError: Error {
    case invalidContainer
    case missingMovieHeader
    case invalidMovieHeader
}
