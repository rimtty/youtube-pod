import SwiftUI
import WatchKit

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
                    VStack(spacing: contentSpacing) {
                        artwork(for: item)
                        metadata(for: item)
                        WatchSystemVolumeControl()
                            .frame(height: 24)
                            .padding(.horizontal, 12)
                            .accessibilityIdentifier("watch.now-playing.system-volume-control")
                        timeline
                        if let playbackError = player.playbackError {
                            playbackErrorView(playbackError)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
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
                    .focusable(false)
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
        dynamicTypeSize.isAccessibilitySize ? 72 : 88
    }

    private var contentSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 3 : 6
    }

    private func artwork(for item: WatchPlaybackItem) -> some View {
        WatchArtwork(url: item.artworkURL)
            .frame(width: artworkWidth, height: artworkWidth * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            }
            .overlay {
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(WatchPodPalette.brandGradient, in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(.white.opacity(0.24))
                        }
                        .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityIdentifier("watch.now-playing.play-pause-overlay")
                .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")
            }
    }

    private func metadata(for item: WatchPlaybackItem) -> some View {
        VStack(spacing: 2) {
            Text(item.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .minimumScaleFactor(0.78)
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
            HStack(spacing: 6) {
                timelineStepControl(
                    "gobackward.15",
                    label: "15秒戻す",
                    identifier: "watch.now-playing.seek-backward"
                ) {
                    player.skip(by: -15)
                }
                scrubber
                timelineStepControl(
                    "goforward.15",
                    label: "15秒進める",
                    identifier: "watch.now-playing.seek-forward"
                ) {
                    player.skip(by: 15)
                }
            }

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

    private var scrubber: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = player.duration > 0 ? normalized(scrubTime) / player.duration : 0
            let knobSize: CGFloat = 12
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(height: 4)
                Capsule()
                    .fill(WatchPodPalette.brandGradient)
                    .frame(width: width * progress, height: 4)
                Circle()
                    .fill(WatchPodPalette.lilac)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: min(max(width * progress - knobSize / 2, 0), width - knobSize))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateScrub(locationX: value.location.x, width: width)
                    }
                    .onEnded { value in
                        finishScrub(locationX: value.location.x, width: width)
                    }
            )
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityIdentifier("watch.now-playing.scrubber")
        .accessibilityLabel("再生位置")
        .accessibilityValue("\(durationText(scrubTime))、全体\(durationText(player.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                player.skip(by: 15)
            case .decrement:
                player.skip(by: -15)
            @unknown default:
                break
            }
        }
    }

    private func timelineStepControl(
        _ symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
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

    private func normalized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), max(player.duration, 0))
    }

    private func updateScrub(locationX: CGFloat, width: CGFloat) {
        guard player.duration > 0, width > 0 else { return }
        isScrubbing = true
        scrubTime = normalized(player.duration * min(max(locationX / width, 0), 1))
    }

    private func finishScrub(locationX: CGFloat, width: CGFloat) {
        updateScrub(locationX: locationX, width: width)
        let target = normalized(scrubTime)
        isScrubbing = false
        player.seek(to: target)
    }
}

/// Uses the system output-volume presentation and lets watchOS own Digital
/// Crown direction, haptics, and route-aware volume changes.
private struct WatchSystemVolumeControl: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: .local)
        control.focus()
        return control
    }

    func updateWKInterfaceObject(
        _ control: WKInterfaceVolumeControl,
        context: Context
    ) {
        control.focus()
    }

    static func dismantleWKInterfaceObject(
        _ control: WKInterfaceVolumeControl,
        coordinator: Void
    ) {
        control.resignFocus()
    }
}
