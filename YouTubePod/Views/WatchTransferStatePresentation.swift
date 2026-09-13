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
