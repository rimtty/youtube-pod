import AVFoundation
import Foundation

/// Rewrites an audio-only M4A into a flat ISO BMFF container (one `moov`,
/// no `moof`) without re-encoding, and rebases the sample timeline to zero.
///
/// yt-dlp delivers YouTube audio as fragmented DASH M4A. watchOS reports a
/// wrong duration for some of those files and random-access decoding is
/// slower, so the library keeps the flat form and Apple Watch receives it
/// unchanged, bound to a SHA-256 digest.
protocol LibraryAudioNormalizing: Sendable {
    func normalize(
        sourceURL: URL,
        destinationURL: URL,
        progress: @escaping @Sendable (LibraryAudioOptimizationProgress) -> Void
    ) async throws
}

extension LibraryAudioNormalizing {
    func normalize(sourceURL: URL, destinationURL: URL) async throws {
        try await normalize(sourceURL: sourceURL, destinationURL: destinationURL, progress: { _ in })
    }
}

actor AVFoundationLibraryAudioNormalizer: LibraryAudioNormalizing {
    private let fileManager = FileManager.default
    /// Progress is forwarded to `@Observable` state on the main actor. The
    /// remux loop can emit thousands of samples per second, so only report
    /// changes that would move a progress bar.
    private static let progressStep = 0.01

    init() {}

    /// True when the file already has the flat layout the normalizer
    /// produces. Such files skip the remux and only need hashing.
    nonisolated static func isFlatContainer(at url: URL) -> Bool {
        guard let boxes = try? WatchISOBaseMediaContainerSummary(url: url) else { return false }
        return boxes.count(of: "moov") == 1
            && boxes.count(of: "mdat") >= 1
            && boxes.count(of: "moof") == 0
    }

    func normalize(
        sourceURL: URL,
        destinationURL: URL,
        progress: @escaping @Sendable (LibraryAudioOptimizationProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        progress(.inspecting)
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceAudioTracks: [AVAssetTrack]
        let sourceVideoTracks: [AVAssetTrack]
        let sourceFormat: CMFormatDescription
        let sourceDuration: TimeInterval
        do {
            sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
            sourceVideoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
            guard let audioTrack = sourceAudioTracks.first,
                  let format = try await audioTrack.load(.formatDescriptions).first else {
                throw LibraryAudioNormalizationError.invalidSource
            }
            sourceFormat = format
            // The track time range is reliable for fragmented input where the
            // asset-level duration may double count fragments.
            let trackDuration = try await audioTrack.load(.timeRange).duration.seconds
            if trackDuration.isFinite, trackDuration > 0 {
                sourceDuration = trackDuration
            } else {
                sourceDuration = try await sourceAsset.load(.duration).seconds
            }
        } catch {
            if let normalizationError = error as? LibraryAudioNormalizationError {
                throw normalizationError
            }
            throw LibraryAudioNormalizationError.operationFailed(
                stage: .sourceInspection,
                code: WatchSyncLog.errorCode(error)
            )
        }
        guard !sourceAudioTracks.isEmpty,
              sourceVideoTracks.isEmpty else {
            throw LibraryAudioNormalizationError.invalidSource
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
            throw LibraryAudioNormalizationError.operationFailed(
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
            throw LibraryAudioNormalizationError.copyPipelineUnavailable
        }
        reader.add(readerOutput)
        writer.add(writerInput)
        guard writer.startWriting(), reader.startReading() else {
            let error = writer.error ?? reader.error
            throw LibraryAudioNormalizationError.operationFailed(
                stage: .copyStart,
                code: error.map(WatchSyncLog.errorCode) ?? "unknown"
            )
        }
        progress(.remuxing(0))
        var lastReportedFraction = 0.0
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
                    throw LibraryAudioNormalizationError.operationFailed(
                        stage: .sampleCopy,
                        code: "presentation_\(presentationTime.flags.rawValue)"
                    )
                }
                if sourceTimelineOrigin == nil {
                    sourceTimelineOrigin = presentationTime
                    writer.startSession(atSourceTime: .zero)
                }
                guard let sourceTimelineOrigin else {
                    throw LibraryAudioNormalizationError.operationFailed(
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
                    throw writer.error ?? LibraryAudioNormalizationError.sampleAppendFailed
                }
                let normalizedPresentationTime = presentationTime - sourceTimelineOrigin
                let sampleEndTime = sampleDuration.isNumeric && sampleDuration > .zero
                    ? normalizedPresentationTime + sampleDuration
                    : normalizedPresentationTime
                if lastSampleEndTime.map({ sampleEndTime > $0 }) ?? true {
                    lastSampleEndTime = sampleEndTime
                }
                if sourceDuration > 0 {
                    let fraction = min(max(sampleEndTime.seconds / sourceDuration, 0), 1)
                    if fraction - lastReportedFraction >= Self.progressStep {
                        lastReportedFraction = fraction
                        progress(.remuxing(fraction))
                    }
                }
            }
            guard reader.status == .completed else {
                throw reader.error ?? LibraryAudioNormalizationError.sampleReadFailed
            }
            guard sourceTimelineOrigin != nil,
                  let lastSampleEndTime,
                  lastSampleEndTime > .zero else {
                throw LibraryAudioNormalizationError.operationFailed(
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
                throw writer.error ?? LibraryAudioNormalizationError.writerFinalizationFailed
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            if error is CancellationError { throw error }
            if let normalizationError = error as? LibraryAudioNormalizationError {
                throw normalizationError
            }
            throw LibraryAudioNormalizationError.operationFailed(
                stage: .sampleCopy,
                code: WatchSyncLog.errorCode(error)
            )
        }
        try Task.checkCancellation()
        progress(.remuxing(1))
        progress(.verifying)
        guard sourceTimelineOrigin != nil,
              let lastSampleEndTime else {
            throw LibraryAudioNormalizationError.operationFailed(
                stage: .sampleCopy,
                code: "completed_bounds_missing"
            )
        }
        let copiedDuration = lastSampleEndTime.seconds
        guard copiedDuration.isFinite, copiedDuration > 0 else {
            throw LibraryAudioNormalizationError.invalidSampleTimeline
        }

        // Verification only touches headers: the box scan seeks between box
        // boundaries and the asset load parses `moov`. The single full read
        // of the output is the digest computed by the caller.
        let boxes: WatchISOBaseMediaContainerSummary
        do {
            boxes = try WatchISOBaseMediaContainerSummary(url: destinationURL)
        } catch {
            throw LibraryAudioNormalizationError.operationFailed(
                stage: .containerInspection,
                code: WatchSyncLog.errorCode(error)
            )
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
            throw LibraryAudioNormalizationError.operationFailed(
                stage: .outputInspection,
                code: WatchSyncLog.errorCode(error)
            )
        }
        let durationTolerance = max(1, copiedDuration * 0.001)
        guard !outputAudioTracks.isEmpty,
              outputVideoTracks.isEmpty,
              outputDuration.isFinite,
              outputDuration > 0,
              abs(outputDuration - copiedDuration) <= durationTolerance,
              boxes.count(of: "moov") == 1,
              boxes.count(of: "mdat") >= 1,
              boxes.count(of: "moof") == 0 else {
            throw LibraryAudioNormalizationError.invalidOutput(
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
            throw LibraryAudioNormalizationError.operationFailed(
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
            throw LibraryAudioNormalizationError.operationFailed(
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
            throw LibraryAudioNormalizationError.operationFailed(
                stage: .sampleCopy,
                code: "timing_copy_\(copyStatus)"
            )
        }
        return normalizedSample
    }
}

enum LibraryAudioNormalizationStage: String {
    case sourceInspection = "source"
    case containerSetup = "setup"
    case copyStart = "start"
    case sampleCopy = "copy"
    case outputInspection = "output"
    case containerInspection = "container"
}

enum LibraryAudioNormalizationError: Error {
    case invalidSource
    case copyPipelineUnavailable
    case sampleAppendFailed
    case sampleReadFailed
    case invalidSampleTimeline
    case writerFinalizationFailed
    case invalidOutput(String)
    case invalidContainer
    case operationFailed(stage: LibraryAudioNormalizationStage, code: String)

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
