import Foundation
import Observation
import OSLog
import UIKit

/// Ends a background-execution grant obtained from `beginBackgroundExecution`.
typealias LibraryAudioBackgroundExecutionEnd = @MainActor () -> Void

/// Rewrites library audio into flat M4A files bound to a SHA-256 digest.
///
/// Jobs run one at a time. `optimize(videoID:)` callers (download completion,
/// Apple Watch enqueue) always take precedence over the launch/foreground
/// backfill of older library items. The library file is replaced atomically
/// only after the normalized copy passed verification and hashing, so a
/// cancelled or failed job leaves the raw download untouched and playable.
@MainActor
@Observable
final class LibraryAudioOptimizer: LibraryAudioOptimizing {
    static let currentNormalizationVersion = 1

    private(set) var progress: [String: LibraryAudioOptimizationProgress] = [:]
    private(set) var activeVideoID: String?

    private let library: any AudioLibraryManaging
    private let normalizer: any LibraryAudioNormalizing
    private let shouldDeferBackfill: @MainActor () -> Bool
    private let isCurrentlyPlaying: @MainActor (String) -> Bool
    private let beginBackgroundExecution: @MainActor (
        _ name: String,
        _ expiration: @escaping @MainActor () -> Void
    ) -> LibraryAudioBackgroundExecutionEnd
    private let backfillItemInterval: Duration
    private let logger = Logger(subsystem: WatchSyncLog.subsystem, category: "LibraryOptimizer")

    @MainActor
    private final class Job {
        let task: Task<OptimizedLibraryAudio, Error>
        var isBackfillOnly: Bool

        init(task: Task<OptimizedLibraryAudio, Error>, isBackfillOnly: Bool) {
            self.task = task
            self.isBackfillOnly = isBackfillOnly
        }
    }

    private var jobs: [String: Job] = [:]
    private var serialTail: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    private var backfillRequested = false
    private var failedVideoIDs: Set<String> = []

    init(
        library: any AudioLibraryManaging,
        normalizer: any LibraryAudioNormalizing = AVFoundationLibraryAudioNormalizer(),
        shouldDeferBackfill: @escaping @MainActor () -> Bool = { false },
        isCurrentlyPlaying: @escaping @MainActor (String) -> Bool = { _ in false },
        beginBackgroundExecution: (@MainActor (
            _ name: String,
            _ expiration: @escaping @MainActor () -> Void
        ) -> LibraryAudioBackgroundExecutionEnd)? = nil,
        backfillItemInterval: Duration = .seconds(1)
    ) {
        self.library = library
        self.normalizer = normalizer
        self.shouldDeferBackfill = shouldDeferBackfill
        self.isCurrentlyPlaying = isCurrentlyPlaying
        self.beginBackgroundExecution = beginBackgroundExecution ?? Self.applicationBackgroundExecution
        self.backfillItemInterval = backfillItemInterval
    }

    var isOptimizing: Bool { !jobs.isEmpty }

    func optimize(videoID: String) async throws -> OptimizedLibraryAudio {
        try await optimize(videoID: videoID, isBackfill: false)
    }

    func resumeBackfill() {
        backfillRequested = true
        startBackfillIfNeeded()
    }

    func pauseBackfill() {
        backfillRequested = false
        backfillTask?.cancel()
        backfillTask = nil
        for (videoID, job) in jobs where job.isBackfillOnly {
            logger.notice("backfill_job_cancelled video=\(videoID, privacy: .public)")
            job.task.cancel()
        }
    }

    // MARK: - Job scheduling

    private func optimize(videoID: String, isBackfill: Bool) async throws -> OptimizedLibraryAudio {
        if let existing = jobs[videoID] {
            if !isBackfill { existing.isBackfillOnly = false }
            return try await existing.task.value
        }
        // Chain behind the previous job so at most one remux touches the disk
        // at a time. Cancelling this task before its turn makes `run` throw
        // at its first cancellation check.
        let previous = serialTail
        let task = Task(priority: .utility) { @MainActor [weak self] in
            await previous?.value
            guard let self else { throw CancellationError() }
            return try await self.run(videoID: videoID)
        }
        let job = Job(task: task, isBackfillOnly: isBackfill)
        jobs[videoID] = job
        serialTail = Task { @MainActor in
            _ = try? await task.value
        }
        defer {
            if jobs[videoID] === job {
                jobs.removeValue(forKey: videoID)
            }
            startBackfillIfNeeded()
        }
        return try await task.value
    }

    private func run(videoID: String) async throws -> OptimizedLibraryAudio {
        try Task.checkCancellation()
        guard let audio = library.savedAudio(videoID: videoID) else {
            throw LibraryError.missingAudio
        }
        let audioURL = library.audioURL(for: audio)
        let onDiskSize = Self.fileSize(at: audioURL)
        if audio.isNormalized(currentVersion: Self.currentNormalizationVersion),
           let digest = audio.audioContentSHA256,
           onDiskSize == audio.fileSize {
            return OptimizedLibraryAudio(audioURL: audioURL, contentSHA256: digest, fileSize: onDiskSize)
        }

        activeVideoID = videoID
        progress[videoID] = .inspecting
        let stagedURL = audioURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(videoID)-optimize-\(UUID().uuidString).m4a")
        let job = jobs[videoID]
        let endBackgroundExecution = beginBackgroundExecution("LibraryAudioOptimizer.\(videoID)") { [weak self] in
            self?.logger.error("background_expired video=\(videoID, privacy: .public)")
            job?.task.cancel()
        }
        defer {
            try? FileManager.default.removeItem(at: stagedURL)
            progress[videoID] = nil
            if activeVideoID == videoID { activeVideoID = nil }
            endBackgroundExecution()
        }
        logger.notice(
            "optimize_started video=\(videoID, privacy: .public) source_bytes=\(onDiskSize)"
        )

        do {
            let isAlreadyFlat = await Task.detached(priority: .utility) {
                AVFoundationLibraryAudioNormalizer.isFlatContainer(at: audioURL)
            }.value
            try Task.checkCancellation()

            let candidateURL: URL
            if isAlreadyFlat {
                candidateURL = audioURL
            } else {
                try await normalizer.normalize(
                    sourceURL: audioURL,
                    destinationURL: stagedURL
                ) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.progress[videoID] != nil else { return }
                        self.progress[videoID] = value
                    }
                }
                candidateURL = stagedURL
            }
            try Task.checkCancellation()

            progress[videoID] = .hashing(0)
            let digest = try await Task.detached(priority: .utility) { [weak self] in
                var lastReported = 0.0
                return try WatchFileDigest.sha256(at: candidateURL) { fraction in
                    guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
                    lastReported = fraction
                    Task { @MainActor [weak self] in
                        guard let self, self.progress[videoID] != nil else { return }
                        self.progress[videoID] = .hashing(fraction)
                    }
                }
            }.value
            try Task.checkCancellation()

            if candidateURL != audioURL {
                _ = try FileManager.default.replaceItemAt(audioURL, withItemAt: stagedURL)
            }
            let normalizedSize = Self.fileSize(at: audioURL)
            try library.recordNormalizedAudio(
                videoID: videoID,
                contentSHA256: digest,
                fileSize: normalizedSize,
                normalizationVersion: Self.currentNormalizationVersion
            )
            failedVideoIDs.remove(videoID)
            logger.notice(
                "optimize_completed video=\(videoID, privacy: .public) output_bytes=\(normalizedSize) remuxed=\(!isAlreadyFlat)"
            )
            return OptimizedLibraryAudio(
                audioURL: audioURL,
                contentSHA256: digest,
                fileSize: normalizedSize
            )
        } catch is CancellationError {
            logger.notice("optimize_cancelled video=\(videoID, privacy: .public)")
            throw CancellationError()
        } catch {
            let diagnostic = (error as? LibraryAudioNormalizationError)?.diagnosticCode
                ?? WatchSyncLog.errorCode(error)
            logger.error(
                "optimize_failed video=\(videoID, privacy: .public) diagnostic=\(diagnostic, privacy: .public)"
            )
            failedVideoIDs.insert(videoID)
            throw error
        }
    }

    // MARK: - Backfill

    private func startBackfillIfNeeded() {
        guard backfillRequested, backfillTask == nil, jobs.isEmpty else { return }
        backfillTask = Task(priority: .utility) { @MainActor [weak self] in
            defer { self?.backfillTask = nil }
            await self?.runBackfill()
        }
    }

    private func runBackfill() async {
        while !Task.isCancelled, backfillRequested {
            guard jobs.isEmpty, !shouldDeferBackfill() else {
                // An on-demand job or a download owns the disk. The next job
                // completion (or foreground transition) restarts this loop.
                return
            }
            let candidate = library
                .audiosRequiringNormalization(currentVersion: Self.currentNormalizationVersion)
                .first { !failedVideoIDs.contains($0.youtubeID) && !isCurrentlyPlaying($0.youtubeID) }
            guard let candidate else {
                backfillRequested = false
                return
            }
            let videoID = candidate.youtubeID
            do {
                _ = try await optimize(videoID: videoID, isBackfill: true)
            } catch is CancellationError {
                return
            } catch {
                // Recorded in `failedVideoIDs` by `run`; move on to the next item.
            }
            guard backfillRequested, !Task.isCancelled else { return }
            try? await Task.sleep(for: backfillItemInterval)
        }
    }

    // MARK: - Helpers

    private static func fileSize(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Lets a remux that was running when the app left the foreground finish
    /// within the system's background grant. On expiration the job is
    /// cancelled; the raw file stays in place and the backfill retries later.
    private static func applicationBackgroundExecution(
        name: String,
        expiration: @escaping @MainActor () -> Void
    ) -> LibraryAudioBackgroundExecutionEnd {
        let token = BackgroundExecutionToken()
        token.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in
                expiration()
                token.end()
            }
        }
        return { token.end() }
    }
}

@MainActor
private final class BackgroundExecutionToken {
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
