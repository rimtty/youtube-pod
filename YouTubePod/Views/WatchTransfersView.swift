import SwiftData
import SwiftUI

enum WatchTransferAction: Equatable, Sendable {
    case enqueue
    case retry
    case cancel
    case deleteFromWatch
}

struct WatchTransfersView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \WatchTransferRecord.updatedAt, order: .reverse) private var records: [WatchTransferRecord]
    @Query private var savedAudios: [SavedAudio]

    @State private var deletionTarget: WatchTransferRecord?
    @State private var retryDiscardTarget: WatchTransferRecord?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                PodScreenBackground()
                List {
                    Section {
                        WatchConnectionCard(
                            status: environment.watchTransfers.connectionStatus,
                            inventory: environment.watchTransfers.latestInventory
                        )
                        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    if visibleRecords.isEmpty {
                        Section {
                            PodEmptyState(
                                icon: "applewatch",
                                title: "Watchはまだ空です",
                                message: "ライブラリのApple Watchボタンから、保存した音声を転送できます。iPhoneがオフラインでも転送操作を続けられます。"
                            )
                            .frame(maxWidth: .infinity, minHeight: 300)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    } else {
                        Section("Watchの音声・\(visibleRecords.count)件") {
                            ForEach(visibleRecords) { record in
                                WatchTransferRow(
                                    record: record,
                                    thumbnailURL: thumbnailURL(for: record.youtubeID),
                                    canRecreateTransfer: savedAudio(for: record.youtubeID) != nil,
                                    liveProgress: environment.watchTransfers.liveProgress[record.youtubeID],
                                    optimizationProgress: environment.optimizer.progress[record.youtubeID],
                                    onRetry: { retry(record) },
                                    onCancel: { environment.watchTransfers.cancel(videoID: record.youtubeID) },
                                    onDiscardRetry: { retryDiscardTarget = record },
                                    onDelete: { deletionTarget = record }
                                )
                                .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Apple Watch")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("状態を再確認", systemImage: "arrow.clockwise") {
                        environment.watchTransfers.refreshState()
                    }
                }
            }
            .alert("Watchから削除しますか？", isPresented: deletionPresented, presenting: deletionTarget) { record in
                Button("Watchから削除", role: .destructive) {
                    requestDeletion(record)
                }
                Button("キャンセル", role: .cancel) { deletionTarget = nil }
            } message: { record in
                Text("「\(record.title)」をApple Watchから削除します。iPhoneのライブラリにある音声は削除されません。")
            }
            .alert("再試行項目を削除しますか？", isPresented: retryDiscardPresented, presenting: retryDiscardTarget) { record in
                Button("削除", role: .destructive) {
                    discardRetry(record)
                }
                Button("キャンセル", role: .cancel) { retryDiscardTarget = nil }
            } message: { record in
                Text("「\(record.title)」の転送エラーと再試行情報を削除します。iPhoneライブラリの音声は残ります。")
            }
            .alert("操作を完了できませんでした", isPresented: errorPresented) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "不明なエラー")
            }
        }
    }

    private var visibleRecords: [WatchTransferRecord] {
        records
            .filter { $0.state != .removedFromWatch }
            .sorted { lhs, rhs in
                if lhs.state.isPendingTransfer != rhs.state.isPendingTransfer {
                    return lhs.state.isPendingTransfer
                }
                if lhs.state.isPendingTransfer {
                    return lhs.queuedAt < rhs.queuedAt
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { deletionTarget != nil },
            set: { if !$0 { deletionTarget = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var retryDiscardPresented: Binding<Bool> {
        Binding(
            get: { retryDiscardTarget != nil },
            set: { if !$0 { retryDiscardTarget = nil } }
        )
    }

    private func thumbnailURL(for videoID: String) -> URL? {
        guard let audio = savedAudio(for: videoID) else { return nil }
        return environment.library.thumbnailURL(for: audio)
    }

    private func savedAudio(for videoID: String) -> SavedAudio? {
        savedAudios.first { $0.youtubeID == videoID }
    }

    private func retry(_ record: WatchTransferRecord) {
        if record.isWatchDeletionFailure {
            requestDeletion(record)
            return
        }
        if record.requiresFreshSnapshotForRetry {
            guard let audio = savedAudio(for: record.youtubeID) else {
                errorMessage = "iPhoneの元音声がないため再転送できません。Watchから削除するか、音声をもう一度iPhoneへ保存してください。"
                return
            }
            Task {
                do {
                    try await environment.watchTransfers.enqueue(
                        WatchTransferSource(
                            youtubeID: audio.youtubeID,
                            title: audio.title,
                            channelTitle: audio.channelTitle,
                            publishedAt: audio.publishedAt,
                            savedViewCount: audio.savedViewCount,
                            duration: audio.duration,
                            playbackPosition: audio.lastPlaybackPosition,
                            audioURL: environment.library.audioURL(for: audio),
                            artworkURL: environment.library.thumbnailURL(for: audio)
                        )
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        Task {
            do {
                try await environment.watchTransfers.retry(videoID: record.youtubeID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func requestDeletion(_ record: WatchTransferRecord) {
        defer { deletionTarget = nil }
        do {
            try environment.watchTransfers.requestDeletion(videoID: record.youtubeID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func discardRetry(_ record: WatchTransferRecord) {
        defer { retryDiscardTarget = nil }
        do {
            try environment.watchTransfers.discardRetry(videoID: record.youtubeID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct WatchTransferActionButton: View {
    let record: WatchTransferRecord?
    let liveProgress: Double?
    let canTransfer: Bool
    let onAction: (WatchTransferAction) -> Void

    var body: some View {
        Group {
            if isWaiting {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(PodPalette.violet)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(statusText)
            } else if action == .cancel {
                Button(action: performAction) {
                    ZStack {
                        if showsIndeterminateProgress {
                            // Nothing measurable happens before transferFile;
                            // a spinning ring reads as "working", 0% as stuck.
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(PodPalette.violet)
                        } else {
                            ProgressView(value: progress)
                                .progressViewStyle(.circular)
                                .tint(PodPalette.violet)
                        }
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(
                    showsIndeterminateProgress
                        ? state?.statusText ?? ""
                        : "\(WatchTransferProgressPresentation.percentage(progress))パーセント"
                )
                .accessibilityHint(accessibilityHint)
            } else {
                Button(action: performAction) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(foregroundStyle)
                        .frame(width: 44, height: 44)
                        .background(backgroundStyle, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(action == nil)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint)
            }
        }
    }

    private var state: WatchTransferState? { record?.state }

    private var isWaiting: Bool {
        state == .cancelling || state == .deletionPending
    }

    private var progress: Double {
        WatchTransferProgressPresentation.displayed(liveProgress ?? record?.lastKnownProgress)
    }

    private var showsIndeterminateProgress: Bool {
        state?.showsIndeterminateProgress == true
    }

    private var action: WatchTransferAction? {
        switch state {
        case nil, .removedFromWatch:
            .enqueue
        case .failed, .reconciliationRequired:
            record?.isWatchDeletionFailure == true ? .deleteFromWatch : .retry
        case .preparing, .queued, .transferring, .awaitingWatchConfirmation:
            .cancel
        case .availableOnWatch, .cancelling, .deletionPending:
            nil
        }
    }

    private var symbol: String {
        switch action {
        case .enqueue: "applewatch"
        case .retry: "arrow.clockwise"
        case .cancel: "xmark"
        case .deleteFromWatch: "trash"
        case nil: "checkmark"
        }
    }

    private var foregroundStyle: AnyShapeStyle {
        if state == .availableOnWatch {
            AnyShapeStyle(PodPalette.sky)
        } else if action == .cancel {
            AnyShapeStyle(Color.red)
        } else {
            AnyShapeStyle(PodPalette.brandGradient)
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        if action == .cancel {
            AnyShapeStyle(Color.red.opacity(0.12))
        } else {
            AnyShapeStyle(PodPalette.violet.opacity(0.12))
        }
    }

    private var statusText: String {
        state == .deletionPending ? "Apple Watchから削除中" : "転送をキャンセル中"
    }

    private var accessibilityLabel: String {
        switch action {
        case .enqueue:
            canTransfer ? "Apple Watchへ転送" : "Apple Watchへ転送、Watchに接続されていません"
        case .retry: "Apple Watchへの転送を再試行"
        case .cancel: "Apple Watchへの転送をキャンセル"
        case .deleteFromWatch: "Apple Watchからの削除を再試行"
        case nil: "Apple Watchに保存済み"
        }
    }

    private var accessibilityHint: String {
        switch action {
        case .enqueue where !canTransfer:
            "Apple Watchがペアリングされ、Watchアプリがインストールされているか確認してください"
        case .enqueue, .retry, .cancel:
            "ダブルタップして実行"
        case .deleteFromWatch:
            "ダブルタップすると確認画面が表示されます"
        case nil:
            ""
        }
    }

    private func performAction() {
        guard let action else { return }
        onAction(action)
    }
}

private struct WatchConnectionCard: View {
    let status: WatchConnectionStatus
    let inventory: WatchInventorySnapshot?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.canTransfer ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
                .font(.title2.bold())
                .foregroundStyle(status.canTransfer ? PodPalette.brandGradient : LinearGradient(colors: [.secondary], startPoint: .leading, endPoint: .trailing))
                .frame(width: 42, height: 42)
                .background(PodPalette.violet.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(status.canTransfer ? "Apple Watchに接続済み" : connectionMessage)
                    .font(.subheadline.bold())
                if let inventory {
                    Text(inventoryText(inventory))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Watchのライブラリ情報を待っています")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .podCard()
        .accessibilityElement(children: .combine)
    }

    private var connectionMessage: String {
        switch status.activation {
        case .unsupported: "この端末ではWatch連携を利用できません"
        case .inactive, .activating: "Apple Watchへ接続中"
        case .activated where status.isPaired != true: "Apple Watchがペアリングされていません"
        case .activated where status.isWatchAppInstalled != true: "Watchアプリをインストールしてください"
        case .activated: "Apple Watchを確認してください"
        }
    }

    private func inventoryText(_ inventory: WatchInventorySnapshot) -> String {
        let time = inventory.generatedAt.formatted(date: .omitted, time: .shortened)
        if let capacity = inventory.availableCapacity {
            return "Watch内 \(inventory.entries.count)件・空き \(ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file))・\(time)更新"
        }
        return "Watch内 \(inventory.entries.count)件・\(time)更新"
    }
}

private struct WatchTransferRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let record: WatchTransferRecord
    let thumbnailURL: URL?
    let canRecreateTransfer: Bool
    let liveProgress: Double?
    let optimizationProgress: LibraryAudioOptimizationProgress?
    let onRetry: () -> Void
    let onCancel: () -> Void
    let onDiscardRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 13))
        VStack(alignment: .leading, spacing: 12) {
            layout {
                PodArtworkImage(url: thumbnailURL, symbol: "applewatch")
                    .frame(width: 92, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Text(record.channelTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Label(stateLabelText, systemImage: record.state.symbolName)
                        .font(.caption.bold())
                        .foregroundStyle(record.state.tint)
                }
                Spacer(minLength: 0)
            }

            if record.state.isPendingTransfer {
                if record.state == .awaitingWatchConfirmation {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(PodPalette.violet)
                        Text("転送済み・Watchの取り込み完了を待っています")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("転送済み。Apple Watchの取り込み完了を待っています")
                } else if let preparation {
                    if let fraction = preparation.fraction {
                        ProgressView(value: fraction) {
                            Text("\(Int((fraction * 100).rounded(.down)))%")
                                .monospacedDigit()
                        }
                        .tint(PodPalette.violet)
                        .accessibilityLabel("Watch用の音声最適化の進捗")
                        .accessibilityValue("\(Int((fraction * 100).rounded(.down)))パーセント")
                    } else {
                        indeterminateProgress(text: "音声を確認しています")
                    }
                } else if record.state.showsIndeterminateProgress {
                    indeterminateProgress(
                        text: record.state == .queued
                            ? "WatchConnectivityの送信開始を待っています"
                            : "転送ファイルを準備しています"
                    )
                } else {
                    ProgressView(value: progress) {
                        Text("\(displayedPercentage)%")
                            .monospacedDigit()
                    }
                    .tint(PodPalette.violet)
                    .accessibilityLabel("転送進捗")
                    .accessibilityValue("\(displayedPercentage)パーセント")
                }
            }

            if let message = record.lastErrorMessage,
               record.state == .failed || record.state == .reconciliationRequired {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actionBar
                .frame(maxWidth: .infinity, alignment: actionBarAlignment)
        }
        .padding(12)
        .podCard()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionBar: some View {
        switch record.state {
        case .preparing, .queued, .transferring, .awaitingWatchConfirmation:
            Button("キャンセル", systemImage: "xmark", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .tint(.red)
        case .failed:
            if record.isWatchDeletionFailure {
                Button("削除を再試行", systemImage: "trash", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(PodPalette.violet)
            } else {
                retryActionBar
            }
        case .reconciliationRequired:
            if record.isWatchDeletionFailure {
                Button("削除を再試行", systemImage: "trash", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(PodPalette.violet)
            } else if canRecreateTransfer {
                retryActionBar
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    Text("iPhoneに元音声がないため再転送できません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("削除", systemImage: "trash", role: .destructive, action: onDiscardRetry)
                            .buttonStyle(.bordered)
                        Button("Watchから削除", systemImage: "applewatch.slash", role: .destructive, action: onDelete)
                            .buttonStyle(.bordered)
                    }
                }
            }
        case .availableOnWatch:
            Button("Watchから削除", systemImage: "trash", role: .destructive, action: onDelete)
                .buttonStyle(.bordered)
        case .cancelling:
            Label("キャンセル中", systemImage: "hourglass")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        case .deletionPending:
            Label("Watchから削除中", systemImage: "hourglass")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        case .removedFromWatch:
            EmptyView()
        }
    }

    private var actionBarAlignment: Alignment {
        record.state == .availableOnWatch ? .leading : .trailing
    }

    private var retryActionBar: some View {
        HStack(spacing: 8) {
            Button("削除", systemImage: "trash", role: .destructive, action: onDiscardRetry)
                .buttonStyle(.bordered)
            Button(
                record.state == .reconciliationRequired ? "再転送" : "再試行",
                systemImage: "arrow.clockwise",
                action: onRetry
            )
                .buttonStyle(.borderedProminent)
                .tint(PodPalette.violet)
        }
    }

    private var progress: Double {
        WatchTransferProgressPresentation.displayed(liveProgress ?? record.lastKnownProgress)
    }

    private var displayedPercentage: Int {
        // WCSession progress can reach (or round to) 100% before the
        // didFinish callback. Reserve 100% for the completed delivery phase
        // so the UI never presents an in-flight transfer as finished.
        WatchTransferProgressPresentation.percentage(liveProgress ?? record.lastKnownProgress)
    }

    /// Optimizer progress applies only while this record is being prepared;
    /// a backfill of the same item after the transfer must not show here.
    private var preparation: WatchTransferPreparationProgress? {
        guard record.state == .preparing, let optimizationProgress else { return nil }
        return WatchTransferPreparationProgress(stage: optimizationProgress)
    }

    private var stateLabelText: String {
        preparation?.statusText ?? record.state.statusText
    }

    private func indeterminateProgress(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(PodPalette.violet)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
