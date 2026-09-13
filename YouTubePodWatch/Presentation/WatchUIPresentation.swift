import Foundation

enum WatchReceiverErrorLayout: Equatable, Sendable {
    case detailed
    case compact
}

struct WatchPlaybackErrorPresentation: Equatable, Sendable {
    let message: String
    let symbolName: String
}

struct WatchPendingTransfersBanner: Equatable, Sendable {
    let headline: String
    let detail: String
    let settingsHint: String
    let activeTitle: String?
}

/// Pure presentation decisions shared by the Watch UI and its unit tests.
enum WatchUIPresentation {
    /// A stale announcement (iPhone app removed, never relaunched) must not
    /// keep the banner up forever.
    static let pendingTransfersStaleAfter: TimeInterval = 24 * 60 * 60

    static func pendingTransfersBanner(
        summary: WatchPendingTransfersSummary?,
        now: Date
    ) -> WatchPendingTransfersBanner? {
        guard let summary, summary.pendingCount > 0,
              now.timeIntervalSince(summary.publishedAt) <= pendingTransfersStaleAfter else {
            return nil
        }
        let size = ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)
        return WatchPendingTransfersBanner(
            headline: "iPhoneから\(summary.pendingCount)件受信中（\(size)）",
            detail: "Watchを開いたままにしてください",
            settingsHint: "設定 > 一般 > 時計に戻る で YouTube Pod を1時間にすると途切れにくくなります",
            activeTitle: summary.activeTitle
        )
    }

    static func receiverErrorLayout(isAccessibilitySize: Bool) -> WatchReceiverErrorLayout {
        isAccessibilitySize ? .compact : .detailed
    }

    static func playbackProgress(
        duration: TimeInterval,
        persistedProgress: Double,
        isCurrent: Bool,
        currentTime: TimeInterval
    ) -> Double {
        let persisted = clampedUnitInterval(persistedProgress)
        guard isCurrent,
              duration.isFinite,
              duration > 0,
              currentTime.isFinite
        else { return persisted }
        return clampedUnitInterval(currentTime / duration)
    }

    static func showsPlaybackProgress(hasBeenPlayed: Bool, isCurrent: Bool) -> Bool {
        hasBeenPlayed || isCurrent
    }

    static func playbackPercentage(progress: Double) -> Int {
        Int((clampedUnitInterval(progress) * 100).rounded())
    }

    static func shouldAnimatePlaybackSymbol(isPlaying: Bool, reduceMotion: Bool) -> Bool {
        isPlaying && !reduceMotion
    }

    static func playbackError(_ error: WatchAudioPlayerError) -> WatchPlaybackErrorPresentation {
        switch error {
        case .audioSessionConfigurationFailed:
            WatchPlaybackErrorPresentation(
                message: "オーディオを設定できませんでした",
                symbolName: "exclamationmark.triangle.fill"
            )
        case .audioRouteUnavailable:
            WatchPlaybackErrorPresentation(
                message: "イヤホンの接続を確認してください",
                symbolName: "airpodspro"
            )
        case .fileUnavailable:
            WatchPlaybackErrorPresentation(
                message: "音声ファイルが見つかりません",
                symbolName: "doc.badge.xmark"
            )
        case .playbackFailed:
            WatchPlaybackErrorPresentation(
                message: "音声を再生できませんでした",
                symbolName: "speaker.slash.fill"
            )
        case .persistenceFailed:
            WatchPlaybackErrorPresentation(
                message: "再生位置を保存できませんでした",
                symbolName: "externaldrive.badge.exclamationmark"
            )
        }
    }

    private static func clampedUnitInterval(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
