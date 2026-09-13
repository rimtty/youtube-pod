import Foundation
import Observation

@MainActor
@Observable
final class DownloadManager {
    private(set) var phases: [String: DownloadPhase] = [:]
    private var queue: [VideoSummary] = []
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var cancelledVideoIDs = Set<String>()
    private let extractor: any AudioExtracting
    private let library: any AudioLibraryManaging
    private let optimizer: (any LibraryAudioOptimizing)?
    private let extractionRetryDelays: [Duration]
    private let maximumConcurrentDownloads: Int

    init(
        extractor: any AudioExtracting,
        library: any AudioLibraryManaging,
        optimizer: (any LibraryAudioOptimizing)? = nil,
        extractionRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
        // The embedded CPython/WebKit challenge runtime is process-global.
        // Keep user taps queued instead of constructing overlapping web views.
        maximumConcurrentDownloads: Int = 1
    ) {
        precondition(maximumConcurrentDownloads > 0)
        self.extractor = extractor
        self.library = library
        self.optimizer = optimizer
        self.extractionRetryDelays = extractionRetryDelays
        self.maximumConcurrentDownloads = maximumConcurrentDownloads
    }

    /// True while any download still owns its file (before the audio is in
    /// the library). Optimization of an already saved item does not count.
    var isExtracting: Bool {
        phases.values.contains { $0.isExtracting }
    }

    func enqueue(_ video: VideoSummary) {
        guard video.supportsAudioExtraction else { return }
        guard phases[video.id]?.isActive != true else { return }
        cancelledVideoIDs.remove(video.id)
        phases[video.id] = .queued
        queue.append(video)
        startDownloadsIfPossible()
    }

    func cancel(videoID: String) async {
        // Once the audio is saved there is nothing to abort: the optimization
        // pass keeps the library item playable whether or not it finishes.
        guard phases[videoID]?.isExtracting == true else { return }
        cancelledVideoIDs.insert(videoID)
        if activeTasks[videoID] != nil {
            await extractor.cancel(requestID: videoID)
        } else {
            queue.removeAll { $0.id == videoID }
            phases[videoID] = .failed("キャンセルしました")
            cancelledVideoIDs.remove(videoID)
        }
    }

    func cancelAll() async {
        let queuedIDs = queue.map(\.id)
        cancelledVideoIDs.formUnion(queuedIDs)
        queue.removeAll()
        for id in queuedIDs {
            phases[id] = .failed("バックグラウンド移行のためキャンセルしました")
        }
        // Items in `.optimizing` are already saved; their job continues under
        // the optimizer's own background grant instead of being abandoned.
        let activeVideoIDs = activeTasks.keys.filter { phases[$0]?.isExtracting == true }
        cancelledVideoIDs.formUnion(activeVideoIDs)
        for videoID in activeVideoIDs {
            await extractor.cancel(requestID: videoID)
        }
    }

    func discardTerminalPhase(videoID: String) {
        guard phases[videoID]?.isActive != true else { return }
        phases.removeValue(forKey: videoID)
    }

    private func startDownloadsIfPossible() {
        while activeTasks.count < maximumConcurrentDownloads, !queue.isEmpty {
            let video = queue.removeFirst()
            activeTasks[video.id] = Task { @MainActor [weak self] in
                await self?.process(video)
            }
        }
    }

    private func process(_ video: VideoSummary) async {
        defer {
            cancelledVideoIDs.remove(video.id)
            activeTasks.removeValue(forKey: video.id)
            startDownloadsIfPossible()
        }
        phases[video.id] = .downloading(0)
        do {
            let extracted = try await extractWithRetry(video)
            guard !cancelledVideoIDs.contains(video.id) else {
                try? FileManager.default.removeItem(at: extracted.fileURL.deletingLastPathComponent())
                throw CancellationError()
            }
            phases[video.id] = .validating
            let saved = try await library.importAudio(extracted, metadata: video)
            guard !cancelledVideoIDs.contains(video.id) else {
                try? library.delete(saved)
                throw CancellationError()
            }
            await optimizeSavedAudio(videoID: saved.youtubeID)
            phases[video.id] = .completed
        } catch {
            phases[video.id] = .failed(
                cancelledVideoIDs.contains(video.id) ? "キャンセルしました" : error.localizedDescription
            )
        }
    }

    /// Flattens the saved file while this download still holds the serial
    /// slot, so the remux never competes with the next yt-dlp run for disk
    /// bandwidth. Failures are not surfaced here: the item is playable as is
    /// and the optimizer's backfill retries it later.
    private func optimizeSavedAudio(videoID: String) async {
        guard let optimizer else { return }
        phases[videoID] = .optimizing(0)
        let observation = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let value = optimizer.progress[videoID] {
                    self?.phases[videoID] = .optimizing(value.overallFraction)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { observation.cancel() }
        _ = try? await optimizer.optimize(videoID: videoID)
    }

    private func extractWithRetry(_ video: VideoSummary) async throws -> ExtractedAudio {
        var retryIndex = 0
        while true {
            guard !cancelledVideoIDs.contains(video.id) else { throw CancellationError() }
            phases[video.id] = .downloading(0)
            do {
                return try await extractor.extract(requestID: video.id, from: video.watchURL) { [weak self] value in
                    Task { @MainActor in
                        guard self?.cancelledVideoIDs.contains(video.id) == false else { return }
                        self?.phases[video.id] = .downloading(min(max(value, 0), 1))
                    }
                }
            } catch {
                guard !cancelledVideoIDs.contains(video.id) else { throw CancellationError() }
                guard error.isRetryableExtractionFailure,
                      retryIndex < extractionRetryDelays.count else { throw error }

                phases[video.id] = .retrying(
                    attempt: retryIndex + 1,
                    maximumRetries: extractionRetryDelays.count
                )
                try await waitForRetry(
                    extractionRetryDelays[retryIndex],
                    videoID: video.id
                )
                retryIndex += 1
            }
        }
    }

    private func waitForRetry(_ delay: Duration, videoID: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: delay)
        while clock.now < deadline {
            guard !cancelledVideoIDs.contains(videoID) else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

private extension Error {
    var isRetryableExtractionFailure: Bool {
        if self is CancellationError { return false }
        guard let extractionError = self as? ExtractionError else { return true }
        switch extractionError {
        case .cancelled, .runtimeMissing, .invalidResult:
            return false
        case .failed(let message):
            let value = message.lowercased()
            let permanentFailureMarkers = [
                "requested format is not available",
                "m4a audio format is unavailable",
                "video unavailable",
                "this video is unavailable",
                "private video",
                "members-only",
                "members only",
                "age-restricted",
                "age restricted",
                "sign in",
                "live event",
                "livestream",
                "is live",
            ]
            return !permanentFailureMarkers.contains(where: value.contains)
        }
    }
}
