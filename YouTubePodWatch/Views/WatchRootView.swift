import SwiftData
import SwiftUI

struct WatchRootView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Query(sort: \WatchSavedAudio.receivedAt, order: .reverse)
    private var audios: [WatchSavedAudio]

    let player: WatchAudioPlayerService
    let receiver: WatchSessionReceiver
    let onDelete: (WatchSavedAudio) -> Void

    @State private var deletionTarget: WatchSavedAudio?
    @State private var showsPlayer = false

    var body: some View {
        NavigationStack {
            ZStack {
                WatchPodBackground()

                VStack(spacing: 4) {
                    receiverStatus

                    if audios.isEmpty {
                        emptyState
                    } else {
                        library
                    }
                }
            }
            .navigationTitle("ライブラリ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if player.currentItem != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsPlayer = true
                        } label: {
                            Image(systemName: player.isPlaying ? "waveform.circle.fill" : "play.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, WatchPodPalette.violet)
                        }
                        .accessibilityLabel("再生中の画面を開く")
                    }
                }
            }
        }
        .sheet(isPresented: $showsPlayer) {
            if player.currentItem != nil {
                WatchNowPlayingView(player: player)
            }
        }
        .alert("この音声を削除しますか？", isPresented: deletionPresented) {
            Button("削除", role: .destructive) {
                guard let deletionTarget else { return }
                if player.currentItem?.id == deletionTarget.youtubeID {
                    player.stopAndClearCurrentItem()
                } else {
                    player.removeFromQueue(youtubeID: deletionTarget.youtubeID)
                }
                onDelete(deletionTarget)
                self.deletionTarget = nil
            }
            Button("キャンセル", role: .cancel) {
                deletionTarget = nil
            }
        } message: {
            Text("音声とサムネイルをApple Watchから削除します。")
        }
        .onChange(of: player.currentItem?.id) {
            if player.currentItem == nil {
                showsPlayer = false
            }
        }
    }

    private var library: some View {
        List {
            Section {
                ForEach(audios) { audio in
                    WatchLibraryRow(
                        audio: audio,
                        isCurrent: player.currentItem?.id == audio.youtubeID,
                        isPlaying: player.isPlaying,
                        currentTime: player.currentTime
                    ) {
                        guard let item = playbackItem(audio) else { return }
                        player.play(item, queue: audios.compactMap(playbackItem))
                        showsPlayer = true
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 4, bottom: 5, trailing: 4))
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        Button("削除", systemImage: "trash", role: .destructive) {
                            deletionTarget = audio
                        }
                    }
                }
            } header: {
                Text("\(audios.count)件・iPhoneから転送済み")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                    .textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(WatchPodPalette.brandGradient)
                    .accessibilityHidden(true)

                Text("まだ静かです")
                    .font(.headline)

                Text("iPhoneのライブラリから\n音声を転送してください。")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.top, 28)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var receiverStatus: some View {
        if receiver.isReceiving {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .tint(WatchPodPalette.lilac)
                Text("iPhoneから受信中")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                reduceTransparency
                    ? AnyShapeStyle(WatchPodPalette.deepTurquoise)
                    : AnyShapeStyle(.thinMaterial),
                in: Capsule()
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("iPhoneから音声を受信中")
        } else if let message = receiver.lastErrorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await receiver.synchronizeNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("再同期")
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 5)
            .background(
                reduceTransparency
                    ? AnyShapeStyle(WatchPodPalette.deepTurquoise)
                    : AnyShapeStyle(.thinMaterial),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .padding(.horizontal, 4)
            .accessibilityElement(children: .contain)
        }
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { deletionTarget != nil },
            set: { if !$0 { deletionTarget = nil } }
        )
    }

    private func playbackItem(_ audio: WatchSavedAudio) -> WatchPlaybackItem? {
        guard let audioURL = watchPlayableAudioURL(for: audio) else { return nil }
        let artworkURL = audio.safeThumbnailRelativePath.flatMap {
            watchLibraryFileURL(relativePath: $0)
        }
        return WatchPlaybackItem(
            id: audio.youtubeID,
            title: audio.title,
            channelTitle: audio.channelTitle,
            duration: audio.duration,
            fileURL: audioURL,
            artworkURL: artworkURL,
            resumePosition: audio.normalizedPlaybackPosition,
            hasBeenPlayed: audio.hasBeenPlayed
        )
    }
}

enum WatchPodPalette {
    static let turquoise = Color(red: 0.02, green: 0.69, blue: 0.66)
    static let deepTurquoise = Color(red: 0.02, green: 0.20, blue: 0.23)
    static let violet = Color(red: 0.55, green: 0.30, blue: 0.72)
    static let lilac = Color(red: 0.79, green: 0.49, blue: 0.79)

    static let brandGradient = LinearGradient(
        colors: [lilac, violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct WatchPodBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                WatchPodPalette.turquoise.opacity(0.48),
                WatchPodPalette.deepTurquoise,
                .black
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
