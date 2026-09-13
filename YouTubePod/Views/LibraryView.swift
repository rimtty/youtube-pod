import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \SavedAudio.downloadedAt, order: .reverse) private var audios: [SavedAudio]
    @Query private var watchTransferRecords: [WatchTransferRecord]

    @State private var deletionTarget: SavedAudio?
    @State private var watchDeletionTarget: WatchTransferRecord?
    @State private var selectedAudioIDs: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var confirmsBatchDeletion = false
    @State private var errorMessage: String?

    var allowsOnlineActions = true
    var closeOfflineLibrary: (() -> Void)?
    var signIn: (() -> Void)?
    var onSelectionModeChange: (Bool) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            ZStack {
                PodScreenBackground()
                Group {
                    if audios.isEmpty {
                        PodEmptyState(
                            icon: "headphones",
                            title: "まだ静かです",
                            message: "気になる動画の「音声を保存」を押すと、オフラインで聴ける音声がここに並びます。"
                        )
                    } else {
                        List(selection: $selectedAudioIDs) {
                            Section {
                                ForEach(audios) { audio in
                                    LibraryAudioRow(
                                        audio: audio,
                                        thumbnailURL: environment.library.thumbnailURL(for: audio),
                                        isCurrentItem: environment.player.currentItem?.id == audio.youtubeID,
                                        isPlaying: environment.player.isPlaying,
                                        isSelectionMode: editMode.isEditing,
                                        watchTransferRecord: watchTransferRecord(for: audio.youtubeID),
                                        watchTransferProgress: environment.watchTransfers.liveProgress[audio.youtubeID],
                                        optimizationProgress: environment.optimizer.progress[audio.youtubeID],
                                        watchCanTransfer: environment.watchTransfers.connectionStatus.canTransfer,
                                        onPlay: { play(audio) },
                                        onWatchAction: { action in
                                            performWatchAction(action, for: audio)
                                        }
                                    )
                                    .tag(audio.youtubeID)
                                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .swipeActions(edge: .trailing) {
                                        if !editMode.isEditing {
                                            Button("削除", systemImage: "trash", role: .destructive) {
                                                deletionTarget = audio
                                            }
                                        }
                                    }
                                    .contextMenu {
                                        if !editMode.isEditing {
                                            Button("再生", systemImage: "play.fill") { play(audio) }
                                            Button("削除", systemImage: "trash", role: .destructive) {
                                                deletionTarget = audio
                                            }
                                        }
                                    }
                                }
                            } header: {
                                Text("\(audios.count)件・\(totalSizeText)")
                            }
                        }
                        .environment(\.editMode, $editMode)
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle(allowsOnlineActions ? "ライブラリ" : "保存済みライブラリ")
            .toolbar {
                if let closeOfflineLibrary {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("戻る", systemImage: "chevron.backward", action: closeOfflineLibrary)
                    }
                }
                if allowsOnlineActions && !editMode.isEditing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("複数選択", systemImage: "checkmark.circle") {
                                beginMultipleSelection()
                            }
                            Button("視聴回数を更新", systemImage: "arrow.clockwise") {
                                Task { await refreshStatistics() }
                            }
                        } label: {
                            Label("ライブラリの操作", systemImage: "ellipsis.circle")
                        }
                        .disabled(audios.isEmpty)
                    }
                } else if let signIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Googleにログイン", systemImage: "person.crop.circle.badge.checkmark", action: signIn)
                            .disabled(environment.auth.isWorking || !environment.auth.isConfigured)
                    }
                }
                if editMode.isEditing {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("キャンセル", action: endMultipleSelection)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完了", action: endMultipleSelection)
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Text("\(selectedAudioIDs.count)件選択")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("削除", systemImage: "trash", role: .destructive) {
                            confirmsBatchDeletion = true
                        }
                        .disabled(selectedAudioIDs.isEmpty)
                    }
                }
            }
            .alert("この音声を削除しますか？", isPresented: deletionPresented, presenting: deletionTarget) { audio in
                Button("削除", role: .destructive) { delete(audio) }
                Button("キャンセル", role: .cancel) { deletionTarget = nil }
            } message: { audio in
                Text("「\(audio.title)」の音声とサムネイルをこの端末から削除します。")
            }
            .alert("選択した音声を削除しますか？", isPresented: $confirmsBatchDeletion) {
                Button("\(selectedAudioIDs.count)件を削除", role: .destructive) {
                    deleteSelectedAudios()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("選択した音声とサムネイルをこの端末から削除します。この操作は取り消せません。")
            }
            .alert("Watchから削除しますか？", isPresented: watchDeletionPresented, presenting: watchDeletionTarget) { record in
                Button("Watchから削除", role: .destructive) {
                    do {
                        try environment.watchTransfers.requestDeletion(videoID: record.youtubeID)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    watchDeletionTarget = nil
                }
                Button("キャンセル", role: .cancel) { watchDeletionTarget = nil }
            } message: { record in
                Text("「\(record.title)」をApple Watchから削除します。iPhoneの音声は残ります。")
            }
            .alert("操作を完了できませんでした", isPresented: errorPresented) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "不明なエラー")
            }
        }
    }

    private var totalSizeText: String {
        ByteCountFormatter.string(
            fromByteCount: audios.reduce(0) { $0 + $1.fileSize },
            countStyle: .file
        )
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

    private var watchDeletionPresented: Binding<Bool> {
        Binding(
            get: { watchDeletionTarget != nil },
            set: { if !$0 { watchDeletionTarget = nil } }
        )
    }

    private func play(_ audio: SavedAudio) {
        guard !editMode.isEditing else { return }
        let queue = audios.map(playbackItem)
        environment.player.play(playbackItem(audio), queue: queue)
    }

    private func watchTransferRecord(for videoID: String) -> WatchTransferRecord? {
        watchTransferRecords.first { $0.youtubeID == videoID }
    }

    private func performWatchAction(_ action: WatchTransferAction, for audio: SavedAudio) {
        switch action {
        case .enqueue:
            enqueueOnWatch(audio)
        case .retry:
            if watchTransferRecord(for: audio.youtubeID)?.requiresFreshSnapshotForRetry == true {
                // Confirmed transfers no longer retain their staging snapshot.
                // Reconciliation and snapshot preparation failures need a fresh
                // snapshot from the iPhone library instead of clone-based retry.
                enqueueOnWatch(audio)
                return
            }
            Task {
                do {
                    try await environment.watchTransfers.retry(videoID: audio.youtubeID)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .cancel:
            environment.watchTransfers.cancel(videoID: audio.youtubeID)
        case .deleteFromWatch:
            watchDeletionTarget = watchTransferRecord(for: audio.youtubeID)
        }
    }

    private func enqueueOnWatch(_ audio: SavedAudio) {
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
    }

    private func playbackItem(_ audio: SavedAudio) -> PlaybackItem {
        PlaybackItem(
            id: audio.youtubeID,
            title: audio.title,
            channelTitle: audio.channelTitle,
            duration: audio.duration,
            fileURL: environment.library.audioURL(for: audio),
            artworkURL: environment.library.thumbnailURL(for: audio),
            resumePosition: audio.lastPlaybackPosition
        )
    }

    private func delete(_ audio: SavedAudio) {
        do {
            try deleteFromLibrary(audio)
        } catch {
            errorMessage = error.localizedDescription
        }
        deletionTarget = nil
    }

    private func beginMultipleSelection() {
        selectedAudioIDs.removeAll()
        withAnimation { editMode = .active }
        onSelectionModeChange(true)
    }

    private func endMultipleSelection() {
        selectedAudioIDs.removeAll()
        withAnimation { editMode = .inactive }
        onSelectionModeChange(false)
    }

    private func deleteSelectedAudios() {
        let targets = audios.filter { selectedAudioIDs.contains($0.youtubeID) }
        var failureMessages: [String] = []
        for audio in targets {
            do {
                try deleteFromLibrary(audio)
            } catch {
                failureMessages.append("\(audio.title): \(error.localizedDescription)")
            }
        }
        endMultipleSelection()
        if !failureMessages.isEmpty {
            errorMessage = failureMessages.joined(separator: "\n")
        }
    }

    private func deleteFromLibrary(_ audio: SavedAudio) throws {
        // Stop immediately before touching the file. AVPlayer can keep an open
        // file descriptor alive briefly even after the library file is removed.
        environment.player.removeFromQueue(videoID: audio.youtubeID)
        try environment.library.delete(audio)
        environment.downloads.discardTerminalPhase(videoID: audio.youtubeID)
        if let record = watchTransferRecord(for: audio.youtubeID),
           (record.state == .failed || record.state == .reconciliationRequired),
           !record.isWatchDeletionFailure {
            try environment.watchTransfers.discardRetry(videoID: audio.youtubeID)
        }
    }

    @MainActor
    private func refreshStatistics() async {
        do {
            let counts = try await environment.catalog.refreshStatistics(videoIDs: audios.map(\.youtubeID))
            try environment.library.updateStatistics(counts)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct LibraryAudioRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let audio: SavedAudio
    let thumbnailURL: URL?
    let isCurrentItem: Bool
    let isPlaying: Bool
    let isSelectionMode: Bool
    let watchTransferRecord: WatchTransferRecord?
    let watchTransferProgress: Double?
    let optimizationProgress: LibraryAudioOptimizationProgress?
    let watchCanTransfer: Bool
    let onPlay: () -> Void
    let onWatchAction: (WatchTransferAction) -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 14))
        VStack(alignment: .leading, spacing: 10) {
            if isSelectionMode {
                summary(layout: layout, showsPlayIndicator: false)
            } else {
                Button(action: onPlay) {
                    summary(layout: layout, showsPlayIndicator: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playbackAccessibilityLabel)
                .accessibilityHint("ダブルタップして再生")
            }

            LibraryPlaybackFooter(
                audio: audio,
                isCurrentItem: isCurrentItem,
                isPlaying: isPlaying,
                watchTransferRecord: watchTransferRecord,
                watchTransferProgress: watchTransferProgress,
                optimizationProgress: optimizationProgress,
                watchCanTransfer: watchCanTransfer,
                onWatchAction: onWatchAction
            )
            .allowsHitTesting(!isSelectionMode)
        }
        .padding(11)
        .podCard()
    }

    private func summary(layout: AnyLayout, showsPlayIndicator: Bool) -> some View {
        layout {
            ZStack {
                PodArtworkImage(url: thumbnailURL)
                if showsPlayIndicator {
                    Image(systemName: "play.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(.black.opacity(0.54), in: Circle())
                }
            }
            .frame(width: 92, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(audio.title)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .foregroundStyle(.primary)
                    if showsNewBadge {
                        Text("新着")
                            .font(.caption2.bold())
                            .foregroundStyle(PodPalette.violet)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(PodPalette.raspberry.opacity(0.16), in: Capsule())
                    }
                }
                Text(audio.channelTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(DisplayFormatter.views(audio.savedViewCount))
                    Text("•")
                    Text(DisplayFormatter.relativeDate(audio.publishedAt))
                    Text("•")
                    Text(DisplayFormatter.duration(audio.duration))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var playbackAccessibilityLabel: String {
        let playbackState = isCurrentItem ? (isPlaying ? "再生中、" : "一時停止中、") : ""
        let base = "\(playbackState)\(showsNewBadge ? "新着、" : "")\(audio.title)、\(audio.channelTitle)、\(DisplayFormatter.duration(audio.duration))"
        guard audio.hasBeenPlayed else { return base }
        return "\(base)、前回の再生位置 \(DisplayFormatter.duration(audio.lastPlaybackPosition))、\(Int((audio.playbackProgress * 100).rounded()))パーセント"
    }

    private var showsNewBadge: Bool {
        !audio.hasBeenPlayed && watchTransferRecord?.state != .availableOnWatch
    }
}

private struct LibraryPlaybackFooter: View {
    let audio: SavedAudio
    let isCurrentItem: Bool
    let isPlaying: Bool
    let watchTransferRecord: WatchTransferRecord?
    let watchTransferProgress: Double?
    let optimizationProgress: LibraryAudioOptimizationProgress?
    let watchCanTransfer: Bool
    let onWatchAction: (WatchTransferAction) -> Void

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 8) {
                if audio.hasBeenPlayed {
                    Label {
                        Text("前回 \(DisplayFormatter.duration(audio.lastPlaybackPosition))")
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                Spacer(minLength: 8)
                HStack(alignment: .center, spacing: 7) {
                    WatchTransferActionButton(
                        record: watchTransferRecord,
                        liveProgress: watchTransferProgress,
                        canTransfer: watchCanTransfer,
                        onAction: onWatchAction
                    )

                    if isCurrentItem {
                        Label(
                            isPlaying ? "再生中" : "一時停止",
                            systemImage: isPlaying ? "waveform" : "pause.fill"
                        )
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(PodPalette.brandGradient, in: Capsule())
                    }

                    if audio.hasBeenPlayed {
                        Text("\(percentage)%")
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            if let state = watchTransferRecord?.state, state.isPendingTransfer {
                watchTransferProgressView(for: state)
            } else if let optimizationProgress {
                // Background optimization of a saved item (no Watch transfer
                // involved). Keep it quiet: one line, secondary color.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label("音声を最適化中", systemImage: "waveform.badge.magnifyingglass")
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if !optimizationProgress.isIndeterminate {
                            Text("\(Int((optimizationProgress.overallFraction * 100).rounded(.down)))%")
                                .monospacedDigit()
                        }
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    optimizationProgressBar(optimizationProgress, tint: .secondary)
                }
            }

            if audio.hasBeenPlayed {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(PodPalette.brandGradient)
                                .frame(width: proxy.size.width * audio.playbackProgress)
                        }
                }
                .frame(height: 5)
            }
        }
    }

    private var percentage: Int {
        Int((audio.playbackProgress * 100).rounded())
    }

    @ViewBuilder
    private func watchTransferProgressView(for state: WatchTransferState) -> some View {
        let preparation = state == .preparing
            ? optimizationProgress.map(WatchTransferPreparationProgress.init(stage:))
            : nil
        let statusText = preparation?.statusText ?? state.statusText
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(statusText, systemImage: "applewatch.and.arrow.forward")
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let preparation {
                    if let fraction = preparation.fraction {
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                            .monospacedDigit()
                    }
                } else if !state.showsIndeterminateProgress {
                    Text("\(WatchTransferProgressPresentation.percentage(watchTransferRawProgress))%")
                        .monospacedDigit()
                }
            }
            .font(.caption2.bold())
            .foregroundStyle(PodPalette.violet)

            if let preparation {
                optimizationProgressBar(preparation.stage, tint: PodPalette.violet)
                    .accessibilityLabel("Watch用の音声最適化の進捗")
                    .accessibilityValue(
                        preparation.fraction.map { "\(Int(($0 * 100).rounded(.down)))パーセント" } ?? "準備中"
                    )
            } else if state.showsIndeterminateProgress {
                // No WCSession progress exists before transferFile is called.
                ProgressView()
                    .tint(PodPalette.violet)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(statusText)
            } else {
                ProgressView(value: WatchTransferProgressPresentation.displayed(watchTransferRawProgress))
                    .tint(PodPalette.violet)
                    .accessibilityLabel("Apple Watchへの転送進捗")
                    .accessibilityValue(
                        "\(WatchTransferProgressPresentation.percentage(watchTransferRawProgress))パーセント、\(statusText)"
                    )
            }
        }
    }

    @ViewBuilder
    private func optimizationProgressBar(
        _ stage: LibraryAudioOptimizationProgress,
        tint: Color
    ) -> some View {
        if stage.isIndeterminate {
            ProgressView()
                .tint(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProgressView(value: stage.overallFraction)
                .tint(tint)
        }
    }

    private var watchTransferRawProgress: Double? {
        watchTransferProgress ?? watchTransferRecord?.lastKnownProgress
    }
}
