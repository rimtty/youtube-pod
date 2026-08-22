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
    private let extractionRetryDelays: [Duration]
    private let maximumConcurrentDownloads: Int

    init(
        extractor: any AudioExtracting,
        library: any AudioLibraryManaging,
        extractionRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
        // The embedded CPython/WebKit challenge runtime is process-global.
        // Keep user taps queued instead of constructing overlapping web views.
        maximumConcurrentDownloads: Int = 1
    ) {
        precondition(maximumConcurrentDownloads > 0)
        self.extractor = extractor
        self.library = library
        self.extractionRetryDelays = extractionRetryDelays
        self.maximumConcurrentDownloads = maximumConcurrentDownloads
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
        guard phases[videoID]?.isActive == true else { return }
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
        let activeVideoIDs = Array(activeTasks.keys)
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
            phases[video.id] = .completed
        } catch {
            phases[video.id] = .failed(
                cancelledVideoIDs.contains(video.id) ? "キャンセルしました" : error.localizedDescription
            )
        }
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
