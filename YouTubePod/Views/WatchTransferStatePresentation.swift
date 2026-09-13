import SwiftUI

/// Single source of truth for how a Watch transfer state is described in
/// the library and on the Apple Watch screen.
extension WatchTransferState {
    var statusText: String {
        switch self {
        case .preparing: "Watch転送を準備中"
        case .queued: "Watchへ転送待ち"
        case .transferring: "Watchへ転送中"
        case .awaitingWatchConfirmation: "Watchで取り込み中"
        case .availableOnWatch: "Watchで利用できます"
        case .cancelling: "キャンセル中"
        case .deletionPending: "Watchから削除中"
        case .failed: "Watch転送に失敗"
        case .reconciliationRequired: "Watchと再同期が必要"
        case .removedFromWatch: "Watchから削除済み"
        }
    }

    var symbolName: String {
        switch self {
        case .availableOnWatch: "checkmark.circle.fill"
        case .failed, .reconciliationRequired: "exclamationmark.triangle.fill"
        case .deletionPending, .cancelling: "hourglass"
        case .preparing, .queued, .transferring, .awaitingWatchConfirmation: "arrow.up.circle.fill"
        case .removedFromWatch: "trash.circle"
        }
    }

    var tint: Color {
        switch self {
        case .availableOnWatch: PodPalette.sky
        case .failed, .reconciliationRequired: .red
        default: PodPalette.violet
        }
    }

    /// WCSession only reports progress once `transferFile` has been called.
    /// Before that a determinate bar would sit at 0%, which reads as stuck.
    var showsIndeterminateProgress: Bool {
        switch self {
        case .preparing, .queued, .cancelling, .deletionPending: true
        default: false
        }
    }
}

enum WatchTransferProgressPresentation {
    /// Clamps a raw progress value for display. WCSession delivery can reach
    /// 100% before the Watch confirms the import, so in-flight rows stay
    /// below 100% until the record becomes available on the Watch.
    static func displayed(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite else { return 0 }
        return min(max(raw, 0), 0.99)
    }

    static func percentage(_ raw: Double?) -> Int {
        Int((displayed(raw) * 100).rounded(.down))
    }
}

/// Progress of the library optimizer for the item a transfer is preparing.
struct WatchTransferPreparationProgress: Equatable {
    let stage: LibraryAudioOptimizationProgress

    var statusText: String { "Watch用に音声を最適化中" }
    var fraction: Double? { stage.isIndeterminate ? nil : stage.overallFraction }
}

enum WatchTransferEstimatePresentation {
    /// Short label placed next to the transfer state, e.g. 「残り約3分」.
    static func text(for estimate: WatchTransferEstimate?) -> String? {
        guard let estimate else { return nil }
        guard let remaining = estimate.remainingSeconds else { return "一時停止中" }
        if remaining < 60 { return "残り1分未満" }
        let minutes = Int((remaining / 60).rounded(.up))
        if minutes < 60 { return "残り約\(minutes)分" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "残り約\(hours)時間" : "残り約\(hours)時間\(rest)分"
    }
}

/// WCSession delivers queued file transfers one at a time in submission
/// order. Records behind the active one are `.transferring` too, but their
/// progress stays at 0 until their turn, which reads as a stall.
enum WatchTransferQueuePresentation {
    /// 0 for the transfer WCSession is sending now, 1+ for those behind it,
    /// nil when the record is not waiting on audio delivery.
    static func position(of record: WatchTransferRecord, in records: [WatchTransferRecord]) -> Int? {
        guard record.state == .transferring, !record.audioDeliveryFinished else { return nil }
        let pending = records
            .filter { $0.state == .transferring && !$0.audioDeliveryFinished }
            .sorted { $0.queuedAt < $1.queuedAt }
        return pending.firstIndex { $0.transferID == record.transferID }
    }

    static func isWaitingForTurn(position: Int?, rawProgress: Double?) -> Bool {
        guard let position, position > 0 else { return false }
        return (rawProgress ?? 0) <= 0
    }

    static func waitingText(position: Int) -> String {
        "Watchへ転送待ち（\(position + 1)番目）"
    }
}
