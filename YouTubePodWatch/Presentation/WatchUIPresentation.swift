import Foundation

enum WatchReceiverErrorLayout: Equatable, Sendable {
    case detailed
    case compact
}

struct WatchPlaybackErrorPresentation: Equatable, Sendable {
    let message: String
    let symbolName: String
}

/// Pure presentation decisions shared by the Watch UI and its unit tests.
enum WatchUIPresentation {
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
