import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \SavedAudio.downloadedAt, order: .reverse) private var audios: [SavedAudio]
    @Query private var watchTransferRecords: [WatchTransferRecord]

    @State private var deletionTarget: SavedAudio?
    @State private var watchDeletionTarget: WatchTransferRecord?
    @State private var errorMessage: String?

    var allowsOnlineActions = true
    var closeOfflineLibrary: (() -> Void)?
    var signIn: (() -> Void)?

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
                        List {
                            Section {
                                ForEach(audios) { audio in
                                    LibraryAudioRow(
                                        audio: audio,
                                        thumbnailURL: environment.library.thumbnailURL(for: audio),
                                        isCurrentItem: environment.player.currentItem?.id == audio.youtubeID,
                                        isPlaying: environment.player.isPlaying,
                                        watchTransferRecord: watchTransferRecord(for: audio.youtubeID),
                                        watchTransferProgress: environment.watchTransfers.liveProgress[audio.youtubeID],
                                        watchCanTransfer: environment.watchTransfers.connectionStatus.canTransfer,
                                        onPlay: { play(audio) },
                                        onWatchAction: { action in
                                            performWatchAction(action, for: audio)
                                        }
                                    )
                                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .swipeActions(edge: .trailing) {
                                        Button("削除", systemImage: "trash", role: .destructive) {
                                            deletionTarget = audio
                                        }
                                    }
                                    .contextMenu {
                                        Button("再生", systemImage: "play.fill") { play(audio) }
                                        Button("削除", systemImage: "trash", role: .destructive) {
                                            deletionTarget = audio
                                        }
                                    }
                                }
                            } header: {
                                Text("\(audios.count)件・\(totalSizeText)")
                            }
                        }
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
                if allowsOnlineActions {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
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
            }
            .alert("この音声を削除しますか？", isPresented: deletionPresented, presenting: deletionTarget) { audio in
                Button("削除", role: .destructive) { delete(audio) }
                Button("キャンセル", role: .cancel) { deletionTarget = nil }
            } message: { audio in
                Text("「\(audio.title)」の音声とサムネイルをこの端末から削除します。")
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
            if watchTransferRecord(for: audio.youtubeID)?.state == .reconciliationRequired {
                // Confirmed transfers no longer retain their staging snapshot.
                // Reconciliation therefore needs a fresh snapshot and revision
                // from the iPhone library instead of clone-based retry.
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
        // Stop immediately before touching the file. AVPlayer can keep an open
        // file descriptor alive briefly even after the library file is removed.
        environment.player.removeFromQueue(videoID: audio.youtubeID)
        do {
            try environment.library.delete(audio)
            environment.downloads.discardTerminalPhase(videoID: audio.youtubeID)
        } catch {
            errorMessage = error.localizedDescription
        }
        deletionTarget = nil
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
    let watchTransferRecord: WatchTransferRecord?
    let watchTransferProgress: Double?
    let watchCanTransfer: Bool
    let onPlay: () -> Void
    let onWatchAction: (WatchTransferAction) -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 14))
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onPlay) {
                layout {
                    ZStack {
                        PodArtworkImage(url: thumbnailURL)
                        Image(systemName: "play.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(.black.opacity(0.54), in: Circle())
                    }
                    .frame(width: 92, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(audio.title)
                                .font(.headline)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                .foregroundStyle(.primary)
                            if !audio.hasBeenPlayed {
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
            .buttonStyle(.plain)
            .accessibilityLabel(playbackAccessibilityLabel)
            .accessibilityHint("ダブルタップして再生")

            LibraryPlaybackFooter(
                audio: audio,
                isCurrentItem: isCurrentItem,
                isPlaying: isPlaying,
                watchTransferRecord: watchTransferRecord,
                watchTransferProgress: watchTransferProgress,
                watchCanTransfer: watchCanTransfer,
                onWatchAction: onWatchAction
            )
        }
        .padding(11)
        .podCard()
    }

    private var playbackAccessibilityLabel: String {
        let playbackState = isCurrentItem ? (isPlaying ? "再生中、" : "一時停止中、") : ""
        let base = "\(playbackState)\(audio.hasBeenPlayed ? "" : "新着、")\(audio.title)、\(audio.channelTitle)、\(DisplayFormatter.duration(audio.duration))"
        guard audio.hasBeenPlayed else { return base }
        return "\(base)、前回の再生位置 \(DisplayFormatter.duration(audio.lastPlaybackPosition))、\(Int((audio.playbackProgress * 100).rounded()))パーセント"
    }
}

private struct LibraryPlaybackFooter: View {
    let audio: SavedAudio
    let isCurrentItem: Bool
    let isPlaying: Bool
    let watchTransferRecord: WatchTransferRecord?
    let watchTransferProgress: Double?
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
}
