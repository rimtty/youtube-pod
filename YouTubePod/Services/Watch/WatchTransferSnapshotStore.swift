import AVFoundation
import Foundation
import OSLog

struct WatchTransferSource: Sendable {
    let youtubeID: String
    let title: String
    let channelTitle: String
    let publishedAt: Date
    let savedViewCount: Int64
    let duration: TimeInterval
    let playbackPosition: TimeInterval
    let audioURL: URL
    let artworkURL: URL?
}

struct PreparedWatchTransfer: Sendable, Equatable {
    let transferID: UUID
    let audioURL: URL
    let artworkURL: URL?
    let audioContentSHA256: String?
    let artworkContentSHA256: String?

    init(
        transferID: UUID,
        audioURL: URL,
        artworkURL: URL?,
        audioContentSHA256: String? = nil,
        artworkContentSHA256: String? = nil
    ) {
        self.transferID = transferID
        self.audioURL = audioURL
        self.artworkURL = artworkURL
        self.audioContentSHA256 = audioContentSHA256
        self.artworkContentSHA256 = artworkContentSHA256
    }
}

protocol WatchTransferSnapshotStoring: Sendable {
    func prepare(source: WatchTransferSource, transferID: UUID) async throws -> PreparedWatchTransfer
    func preparedTransfer(transferID: UUID) async -> PreparedWatchTransfer?
    func cloneTransfer(from sourceTransferID: UUID, to destinationTransferID: UUID) async throws -> PreparedWatchTransfer
    func removeTransfer(_ transferID: UUID) async
    func storedTransferIDs() async -> Set<UUID>
    func removeOrphans(retaining transferIDs: Set<UUID>) async
    func removeStagingDirectories() async
}

protocol WatchAudioNormalizing: Sendable {
    func normalize(sourceURL: URL, destinationURL: URL) async throws
}

actor AVFoundationWatchAudioNormalizer: WatchAudioNormalizing {
    private let fileManager = FileManager.default

    init() {}

    func normalize(sourceURL: URL, destinationURL: URL) async throws {
        try Task.checkCancellation()
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceAudioTracks: [AVAssetTrack]
        let sourceVideoTracks: [AVAssetTrack]
        let sourceFormat: CMFormatDescription
        do {
            sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
            sourceVideoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
            guard let audioTrack = sourceAudioTracks.first,
                  let format = try await audioTrack.load(.formatDescriptions).first else {
                throw WatchAudioNormalizationError.invalidSource
            }
            sourceFormat = format
        } catch {
            if let normalizationError = error as? WatchAudioNormalizationError {
                throw normalizationError
            }
            throw WatchAudioNormalizationError.operationFailed(
                stage: .sourceInspection,
                code: WatchSyncLog.errorCode(error)
            )
        }
        guard !sourceAudioTracks.isEmpty,
              sourceVideoTracks.isEmpty else {
            throw WatchAudioNormalizationError.invalidSource
        }
        try? fileManager.removeItem(at: destinationURL)
        var completed = false
        defer {
            if !completed {
                try? fileManager.removeItem(at: destinationURL)
            }
        }

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: sourceAsset)
            writer = try AVAssetWriter(outputURL: destinationURL, fileType: .m4a)
        } catch {
            throw WatchAudioNormalizationError.operationFailed(
                stage: .containerSetup,
                code: WatchSyncLog.errorCode(error)
            )
        }

        let readerOutput = AVAssetReaderTrackOutput(
            track: sourceAudioTracks[0],
            outputSettings: nil
        )
        readerOutput.alwaysCopiesSampleData = false
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: sourceFormat
        )
        writerInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(readerOutput), writer.canAdd(writerInput) else {
            throw WatchAudioNormalizationError.copyPipelineUnavailable
        }
        reader.add(readerOutput)
        writer.add(writerInput)
        guard writer.startWriting(), reader.startReading() else {
            let error = writer.error ?? reader.error
            throw WatchAudioNormalizationError.operationFailed(
                stage: .copyStart,
                code: error.map(WatchSyncLog.errorCode) ?? "unknown"
            )
        }
        var sourceTimelineOrigin: CMTime?
        var lastSampleEndTime: CMTime?
        do {
            while reader.status == .reading {
                try Task.checkCancellation()
                guard writerInput.isReadyForMoreMediaData else {
                    try await Task.sleep(for: .milliseconds(2))
                    continue
                }
                guard let sample = readerOutput.copyNextSampleBuffer() else { break }
                // Fragmented M4A readers can emit an empty marker buffer at a
                // fragment boundary. It has no usable timestamp and must not
                // be treated as an audio sample.
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let sampleDuration = CMSampleBufferGetDuration(sample)
                guard presentationTime.isNumeric else {
                    throw WatchAudioNormalizationError.operationFailed(
                        stage: .sampleCopy,
                        code: "presentation_\(presentationTime.flags.rawValue)"
                    )
                }
                if sourceTimelineOrigin == nil {
                    sourceTimelineOrigin = presentationTime
                    writer.startSession(atSourceTime: .zero)
                }
                guard let sourceTimelineOrigin else {
                    throw WatchAudioNormalizationError.operationFailed(
                        stage: .sampleCopy,
                        code: "origin_missing"
                    )
                }
                let normalizedSample = try Self.sampleBuffer(
                    sample,
                    shiftingTimelineBy: CMTimeMultiplyByFloat64(
                        sourceTimelineOrigin,
                        multiplier: -1
                    )
                )
                guard writerInput.append(normalizedSample) else {
                    throw writer.error ?? WatchAudioNormalizationError.sampleAppendFailed
                }
                let normalizedPresentationTime = presentationTime - sourceTimelineOrigin
                let sampleEndTime = sampleDuration.isNumeric && sampleDuration > .zero
                    ? normalizedPresentationTime + sampleDuration
                    : normalizedPresentationTime
                if lastSampleEndTime.map({ sampleEndTime > $0 }) ?? true {
                    lastSampleEndTime = sampleEndTime
                }
            }
            guard reader.status == .completed else {
                throw reader.error ?? WatchAudioNormalizationError.sampleReadFailed
            }
            guard sourceTimelineOrigin != nil,
                  let lastSampleEndTime,
                  lastSampleEndTime > .zero else {
                throw WatchAudioNormalizationError.operationFailed(
                    stage: .sampleCopy,
                    code: "bounds_\(sourceTimelineOrigin?.seconds ?? -1)_\(lastSampleEndTime?.seconds ?? -1)"
                )
            }
            writerInput.markAsFinished()
            writer.endSession(atSourceTime: lastSampleEndTime)
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
            guard writer.status == .completed else {
                throw writer.error ?? WatchAudioNormalizationError.writerFinalizationFailed
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            if error is CancellationError { throw error }
            if let normalizationError = error as? WatchAudioNormalizationError {
                throw normalizationError
            }
            throw WatchAudioNormalizationError.operationFailed(
                stage: .sampleCopy,
                code: WatchSyncLog.errorCode(error)
            )
        }
        try Task.checkCancellation()
        guard sourceTimelineOrigin != nil,
              let lastSampleEndTime else {
            throw WatchAudioNormalizationError.operationFailed(
                stage: .sampleCopy,
                code: "completed_bounds_missing"
            )
        }
        let copiedDuration = lastSampleEndTime.seconds
        guard copiedDuration.isFinite, copiedDuration > 0 else {
            throw WatchAudioNormalizationError.invalidSampleTimeline
        }

        let outputAsset = AVURLAsset(url: destinationURL)
        let outputAudioTracks: [AVAssetTrack]
        let outputVideoTracks: [AVAssetTrack]
        let outputDuration: TimeInterval
        do {
            outputAudioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
            outputVideoTracks = try await outputAsset.loadTracks(withMediaType: .video)
            outputDuration = try await outputAsset.load(.duration).seconds
        } catch {
            throw WatchAudioNormalizationError.operationFailed(
                stage: .outputInspection,
                code: WatchSyncLog.errorCode(error)
            )
        }
        let durationTolerance = max(1, copiedDuration * 0.001)
        let boxes: ISOBaseMediaFileSummary
        do {
            boxes = try ISOBaseMediaFileSummary(url: destinationURL)
        } catch {
            throw WatchAudioNormalizationError.operationFailed(
                stage: .containerInspection,
                code: WatchSyncLog.errorCode(error)
            )
        }
        guard !outputAudioTracks.isEmpty,
              outputVideoTracks.isEmpty,
              outputDuration.isFinite,
              outputDuration > 0,
              abs(outputDuration - copiedDuration) <= durationTolerance,
              boxes.count(of: "moov") == 1,
              boxes.count(of: "mdat") >= 1,
              boxes.count(of: "moof") == 0 else {
            throw WatchAudioNormalizationError.invalidOutput(
                "audio_\(outputAudioTracks.count).video_\(outputVideoTracks.count)"
                    + ".duration_\(outputDuration).samples_\(copiedDuration)"
                    + ".moov_\(boxes.count(of: "moov"))"
                    + ".mdat_\(boxes.count(of: "mdat"))"
                    + ".moof_\(boxes.count(of: "moof"))"
            )
        }
        completed = true
    }

    private static func sampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        shiftingTimelineBy offset: CMTime
    ) throws -> CMSampleBuffer {
        var timingEntryCount = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingEntryCount
        )
        guard countStatus == noErr, timingEntryCount > 0 else {
            throw WatchAudioNormalizationError.operationFailed(
                stage: .sampleCopy,
                code: "timing_count_\(countStatus)_entries_\(timingEntryCount)"
            )
        }
        var timingEntries = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingEntryCount
        )
        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: timingEntryCount,
            arrayToFill: &timingEntries,
            entriesNeededOut: &timingEntryCount
        )
        guard timingStatus == noErr else {
            throw WatchAudioNormalizationError.operationFailed(
                stage: .sampleCopy,
                code: "timing_read_\(timingStatus)"
            )
        }
        for index in timingEntries.indices {
            if timingEntries[index].presentationTimeStamp.isNumeric {
                timingEntries[index].presentationTimeStamp = CMTimeAdd(
                    timingEntries[index].presentationTimeStamp,
                    offset
                )
            }
            if timingEntries[index].decodeTimeStamp.isNumeric {
                timingEntries[index].decodeTimeStamp = CMTimeAdd(
                    timingEntries[index].decodeTimeStamp,
                    offset
                )
            }
        }
        var normalizedSample: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timingEntries.count,
            sampleTimingArray: &timingEntries,
            sampleBufferOut: &normalizedSample
        )
        guard copyStatus == noErr, let normalizedSample else {
            throw WatchAudioNormalizationError.operationFailed(
                stage: .sampleCopy,
                code: "timing_copy_\(copyStatus)"
            )
        }
        return normalizedSample
    }
}

struct ISOBaseMediaFileSummary: Equatable, Sendable {
    private let boxCounts: [String: Int]

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize >= 8 else {
            throw WatchAudioNormalizationError.invalidContainer
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var counts: [String: Int] = [:]
        let totalSize = UInt64(fileSize)
        while offset < totalSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8,
                  let type = String(data: header[4..<8], encoding: .ascii) else {
                throw WatchAudioNormalizationError.invalidContainer
            }
            let compactSize = Self.uint32(header[0..<4])
            let headerSize: UInt64
            let boxSize: UInt64
            switch compactSize {
            case 0:
                headerSize = 8
                boxSize = totalSize - offset
            case 1:
                guard let extended = try handle.read(upToCount: 8), extended.count == 8 else {
                    throw WatchAudioNormalizationError.invalidContainer
                }
                headerSize = 16
                boxSize = Self.uint64(extended[0..<8])
            default:
                headerSize = 8
                boxSize = UInt64(compactSize)
            }
            guard boxSize >= headerSize,
                  boxSize <= totalSize - offset else {
                throw WatchAudioNormalizationError.invalidContainer
            }
            counts[type, default: 0] += 1
            offset += boxSize
        }
        guard offset == totalSize else {
            throw WatchAudioNormalizationError.invalidContainer
        }
        boxCounts = counts
    }

    func count(of type: String) -> Int {
        boxCounts[type, default: 0]
    }

    private static func uint32(_ bytes: Data.SubSequence) -> UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64(_ bytes: Data.SubSequence) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

actor WatchTransferSnapshotStore: WatchTransferSnapshotStoring {
    private static let audioDigestFileName = "audio.sha256"
    private static let artworkDigestFileName = "artwork.sha256"
    private let rootURL: URL
    private let fileManager: FileManager
    private let audioNormalizer: any WatchAudioNormalizing

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        audioNormalizer: (any WatchAudioNormalizing)? = nil
    ) {
        self.fileManager = fileManager
        self.audioNormalizer = audioNormalizer ?? AVFoundationWatchAudioNormalizer()
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = try! fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.rootURL = base.appendingPathComponent("WatchTransfers", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    func prepare(source: WatchTransferSource, transferID: UUID) async throws -> PreparedWatchTransfer {
        guard fileManager.fileExists(atPath: source.audioURL.path) else {
            throw WatchTransferSnapshotError.sourceMissing
        }
        let destination = directory(for: transferID)
        let staging = rootURL.appendingPathComponent(".\(transferID.uuidString)-\(UUID().uuidString)")
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let normalizedAudioURL = staging.appendingPathComponent("audio.m4a")
            let sourceBytes = source.audioURL.fileSizeForWatchLog
            WatchSyncLog.phoneService.notice(
                "audio_normalization_started transfer=\(transferID.uuidString, privacy: .public) source_bytes=\(sourceBytes)"
            )
            do {
                try await audioNormalizer.normalize(
                    sourceURL: source.audioURL,
                    destinationURL: normalizedAudioURL
                )
            } catch {
                let diagnostic = (error as? WatchAudioNormalizationError)?.diagnosticCode
                    ?? WatchSyncLog.errorCode(error)
                WatchSyncLog.phoneService.error(
                    "audio_normalization_failed transfer=\(transferID.uuidString, privacy: .public) diagnostic=\(diagnostic, privacy: .public)"
                )
                throw WatchTransferSnapshotError.normalizationFailed
            }
            WatchSyncLog.phoneService.notice(
                "audio_normalization_completed transfer=\(transferID.uuidString, privacy: .public) source_bytes=\(sourceBytes) output_bytes=\(normalizedAudioURL.fileSizeForWatchLog)"
            )
            if let artworkURL = source.artworkURL,
               fileManager.fileExists(atPath: artworkURL.path) {
                try fileManager.copyItem(at: artworkURL, to: staging.appendingPathComponent("artwork.jpg"))
            }
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
            return try preparedTransferRequired(transferID: transferID)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func preparedTransfer(transferID: UUID) async -> PreparedWatchTransfer? {
        try? preparedTransferRequired(transferID: transferID)
    }

    func cloneTransfer(
        from sourceTransferID: UUID,
        to destinationTransferID: UUID
    ) async throws -> PreparedWatchTransfer {
        let source = directory(for: sourceTransferID)
        guard fileManager.fileExists(atPath: source.appendingPathComponent("audio.m4a").path) else {
            throw WatchTransferSnapshotError.sourceMissing
        }
        let destination = directory(for: destinationTransferID)
        let staging = rootURL.appendingPathComponent(".\(destinationTransferID.uuidString)-\(UUID().uuidString)")
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.copyItem(at: source, to: staging)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
            return try preparedTransferRequired(transferID: destinationTransferID)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func removeTransfer(_ transferID: UUID) async {
        try? fileManager.removeItem(at: directory(for: transferID))
    }

    func storedTransferIDs() async -> Set<UUID> {
        Set((try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.compactMap { UUID(uuidString: $0.lastPathComponent) } ?? [])
    }

    func removeOrphans(retaining transferIDs: Set<UUID>) async {
        for transferID in await storedTransferIDs() where !transferIDs.contains(transferID) {
            try? fileManager.removeItem(at: directory(for: transferID))
        }
    }

    func removeStagingDirectories() async {
        let entries = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(".") {
            try? fileManager.removeItem(at: entry)
        }
    }

    private func preparedTransferRequired(transferID: UUID) throws -> PreparedWatchTransfer {
        let directory = directory(for: transferID)
        let audioURL = directory.appendingPathComponent("audio.m4a")
        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw WatchTransferSnapshotError.sourceMissing
        }
        let artworkURL = directory.appendingPathComponent("artwork.jpg")
        let hasArtwork = fileManager.fileExists(atPath: artworkURL.path)
        return PreparedWatchTransfer(
            transferID: transferID,
            audioURL: audioURL,
            artworkURL: hasArtwork ? artworkURL : nil,
            audioContentSHA256: try digest(
                for: audioURL,
                sidecarURL: directory.appendingPathComponent(Self.audioDigestFileName)
            ),
            artworkContentSHA256: hasArtwork ? try digest(
                for: artworkURL,
                sidecarURL: directory.appendingPathComponent(Self.artworkDigestFileName)
            ) : nil
        )
    }

    private func digest(for fileURL: URL, sidecarURL: URL) throws -> String {
        if let stored = try? String(contentsOf: sidecarURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           WatchFileDigest.isValidSHA256(stored) {
            return stored
        }
        let value = try WatchFileDigest.sha256(at: fileURL)
        try value.write(to: sidecarURL, atomically: true, encoding: .utf8)
        return value
    }

    private func directory(for transferID: UUID) -> URL {
        rootURL.appendingPathComponent(transferID.uuidString, isDirectory: true)
    }
}

enum WatchTransferSnapshotError: LocalizedError {
    case sourceMissing
    case normalizationFailed

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "転送元の音声ファイルが見つかりません。"
        case .normalizationFailed:
            "Watch用の音声ファイルを準備できませんでした。"
        }
    }
}

enum WatchAudioNormalizationStage: String {
    case sourceInspection = "source"
    case containerSetup = "setup"
    case copyStart = "start"
    case sampleCopy = "copy"
    case outputInspection = "output"
    case containerInspection = "container"
}

enum WatchAudioNormalizationError: Error {
    case invalidSource
    case copyPipelineUnavailable
    case sampleAppendFailed
    case sampleReadFailed
    case invalidSampleTimeline
    case writerFinalizationFailed
    case invalidOutput(String)
    case invalidContainer
    case operationFailed(stage: WatchAudioNormalizationStage, code: String)

    var diagnosticCode: String {
        switch self {
        case .invalidSource:
            "source.invalid"
        case .copyPipelineUnavailable:
            "copy.unavailable"
        case .sampleAppendFailed:
            "copy.append"
        case .sampleReadFailed:
            "copy.read"
        case .invalidSampleTimeline:
            "copy.timeline"
        case .writerFinalizationFailed:
            "copy.finish"
        case .invalidOutput(let details):
            "output.invalid.\(details)"
        case .invalidContainer:
            "container.invalid"
        case .operationFailed(let stage, let code):
            "\(stage.rawValue).\(code)"
        }
    }
}

private extension URL {
    var fileSizeForWatchLog: Int64 {
        Int64((try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
    }
}
