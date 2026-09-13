import Foundation

extension WatchPendingTransfersSummary {
    /// Summarizes what WCSession still has to deliver. `.preparing` records
    /// are excluded because nothing has been handed to WCSession yet; audio
    /// already delivered (artwork still in flight) no longer counts.
    static func make(records: [WatchTransferRecord], at now: Date) -> Self {
        let queued = records.filter { $0.state == .queued }
        let transferring = records.filter { $0.state == .transferring && !$0.audioDeliveryFinished }
        // Same rule as WatchTransferQueuePresentation: WCSession sends in
        // submission order, so the oldest undelivered transfer is active.
        let active = transferring.min { $0.queuedAt < $1.queuedAt }
        let totalBytes = (queued + transferring).reduce(Int64(0)) { $0 + max(0, $1.sourceFileSize) }
        return WatchPendingTransfersSummary(
            queuedCount: queued.count,
            transferringCount: transferring.count,
            totalBytes: totalBytes,
            activeYouTubeID: active?.youtubeID,
            activeTitle: active.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 },
            publishedAt: now
        )
    }
}
