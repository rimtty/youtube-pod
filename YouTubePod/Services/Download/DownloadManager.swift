import Foundation
import Observation

@MainActor
@Observable
final class DownloadManager {
    private(set) var phases: [String: DownloadPhase] = [:]
    private var queue: [VideoSummary] = []
    private var workerTask: Task<Void, Never>?
    private var activeVideoID: String?
    private var cancelledVideoIDs = Set<String>()
    private let extractor: any AudioExtracting
    private let library: any AudioLibraryManaging

    init(extractor: any AudioExtracting, library: any AudioLibraryManaging) {
        self.extractor = extractor
        self.library = library
    }

    func enqueue(_ video: VideoSummary) {
        guard video.supportsAudioExtraction else { return }
        guard phases[video.id]?.isActive != true else { return }
        cancelledVideoIDs.remove(video.id)
        phases[video.id] = .queued
        queue.append(video)
        startWorkerIfNeeded()
    }

    func cancel(videoID: String) async {
        guard phases[videoID]?.isActive == true else { return }
        cancelledVideoIDs.insert(videoID)
        if activeVideoID == videoID {
            await extractor.cancel()
        } else {
            queue.removeAll { $0.id == videoID }
            phases[videoID] = .failed("キャンセルしました")
        }
    }

    func cancelAll() async {
        let queuedIDs = queue.map(\.id)
        cancelledVideoIDs.formUnion(queuedIDs)
        queue.removeAll()
        for id in queuedIDs {
            phases[id] = .failed("バックグラウンド移行のためキャンセルしました")
        }
        if let activeVideoID {
            cancelledVideoIDs.insert(activeVideoID)
            await extractor.cancel()
        }
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in await self?.drainQueue() }
    }

    private func drainQueue() async {
        defer { workerTask = nil; activeVideoID = nil }
        while !queue.isEmpty {
            let video = queue.removeFirst()
            activeVideoID = video.id
            phases[video.id] = .downloading(0)
            do {
                let extracted = try await extractor.extract(from: video.watchURL) { [weak self] value in
                    Task { @MainActor in
                        guard self?.cancelledVideoIDs.contains(video.id) == false else { return }
                        self?.phases[video.id] = .downloading(min(max(value, 0), 1))
                    }
                }
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
            cancelledVideoIDs.remove(video.id)
            activeVideoID = nil
        }
    }
}
