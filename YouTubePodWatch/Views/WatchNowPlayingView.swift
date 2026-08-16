import SwiftUI

struct WatchNowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let player: WatchAudioPlayerService

    @State private var scrubTime: TimeInterval = 0
    @State private var isScrubbing = false

    var body: some View {
        NavigationStack {
            ZStack {
                WatchPodBackground()
                if let item = player.currentItem {
                    ScrollView {
                        VStack(spacing: 10) {
                            WatchArtwork(url: item.artworkURL)
                                .frame(width: artworkWidth, height: artworkWidth * 9 / 16)
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .strokeBorder(.white.opacity(0.12))
                                }

                            metadata(for: item)
                            timeline
                            if let playbackError = player.playbackError {
                                playbackErrorView(playbackError)
                            }
                            controls
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 12)
                    }
                }
            }
            .navigationTitle("再生中")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる", systemImage: "chevron.down") {
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .onAppear {
            scrubTime = normalized(player.currentTime)
        }
        .onChange(of: player.currentTime) {
            guard !isScrubbing else { return }
            scrubTime = normalized(player.currentTime)
        }
        .onChange(of: player.currentItem?.id) {
            guard player.currentItem != nil else {
                dismiss()
                return
            }
            scrubTime = normalized(player.currentTime)
        }
    }

    private var artworkWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 92 : 116
    }

    private func metadata(for item: WatchPlaybackItem) -> some View {
        VStack(spacing: 2) {
            Text(item.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                .multilineTextAlignment(.center)
            Text(item.channelTitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var timeline: some View {
        VStack(spacing: 2) {
            Slider(
                value: $scrubTime,
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        player.seek(to: normalized(scrubTime))
                    }
                }
            )
            .tint(WatchPodPalette.lilac)
            .accessibilityLabel("再生位置")
            .accessibilityValue(
                "\(durationText(scrubTime))、全体\(durationText(player.duration))"
            )

            HStack {
                Text(durationText(scrubTime))
                Spacer()
                Text("−\(durationText(max(0, player.duration - scrubTime)))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.62))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            reduceTransparency
                ? AnyShapeStyle(WatchPodPalette.deepTurquoise)
                : AnyShapeStyle(.thinMaterial),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                control("gobackward.15", label: "15秒戻す", size: 44) {
                    player.skip(by: -15)
                }
                control(
                    player.isPlaying ? "pause.fill" : "play.fill",
                    label: player.isPlaying ? "一時停止" : "再生",
                    size: 50,
                    prominent: true,
                    action: player.togglePlayback
                )
                control("goforward.15", label: "15秒進める", size: 44) {
                    player.skip(by: 15)
                }
            }
            HStack(spacing: 28) {
                control("backward.end.fill", label: "前の項目", size: 44, action: player.previous)
                control("forward.end.fill", label: "次の項目", size: 44, action: player.next)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func playbackErrorView(_ error: WatchAudioPlayerError) -> some View {
        let presentation = WatchUIPresentation.playbackError(error)
        return Label {
            Text(presentation.message)
        } icon: {
            Image(systemName: presentation.symbolName)
        }
        .font(.caption2)
        .foregroundStyle(.yellow)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.message)
    }

    private func control(
        _ symbol: String,
        label: String,
        size: CGFloat,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 17 : 13, weight: .bold))
                .frame(width: size, height: size)
                .background(
                    prominent ? AnyShapeStyle(WatchPodPalette.brandGradient) : AnyShapeStyle(.white.opacity(0.10)),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func normalized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), max(player.duration, 0))
    }
}
