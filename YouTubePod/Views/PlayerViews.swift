import SwiftUI

struct MiniPlayerView: View {
    let item: PlaybackItem
    let isPlaying: Bool
    let progress: Double
    let togglePlayback: () -> Void
    let seek: (TimeInterval) -> Void
    let showPlayer: () -> Void

    @State private var scrubProgress: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Button(action: showPlayer) {
                    HStack(spacing: 10) {
                        artwork
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Text(item.channelTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isPlaying ? "再生中" : "一時停止中")、\(item.title)、\(item.channelTitle)")
                .accessibilityHint("ダブルタップしてプレイヤーを開く")

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "一時停止" : "再生")
            }

            MiniPlaybackScrubber(
                value: scrubProgress ?? normalizedProgress,
                duration: item.duration,
                onChange: { scrubProgress = $0 },
                onCommit: { value in
                    seek(item.duration * value)
                    scrubProgress = nil
                }
            )
            .padding(.horizontal, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color(.secondarySystemBackground))
                : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        .onChange(of: item.id) {
            scrubProgress = nil
        }
    }

    private var artwork: some View {
        ZStack {
            Color.black.opacity(0.16)
            PodArtworkImage(url: item.artworkURL, contentMode: .fit)
        }
        .frame(width: 50, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var normalizedProgress: Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }
}

private struct MiniPlaybackScrubber: View {
    let value: Double
    let duration: TimeInterval
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.2))
                    .frame(height: 3)
                Capsule()
                    .fill(PodPalette.brandGradient)
                    .frame(width: width * normalizedValue, height: 3)
                Circle()
                    .fill(.white)
                    .frame(width: 8, height: 8)
                    .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
                    .offset(x: max(0, (width - 8) * normalizedValue))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onChange(value(at: gesture.location.x, width: width))
                    }
                    .onEnded { gesture in
                        onCommit(value(at: gesture.location.x, width: width))
                    }
            )
        }
        // Keep the track visually compact while providing a generous drag target.
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("ミニプレイヤーの再生位置")
        .accessibilityValue(
            "\(DisplayFormatter.duration(duration * normalizedValue))、全体 \(DisplayFormatter.duration(duration))"
        )
        .accessibilityAdjustableAction { direction in
            let adjustment = direction == .increment ? 0.05 : -0.05
            onCommit(min(max(normalizedValue + adjustment, 0), 1))
        }
    }

    private var normalizedValue: Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private func value(at location: CGFloat, width: CGFloat) -> Double {
        Double(min(max(location / max(width, 1), 0), 1))
    }
}

struct FullPlayerView: View {
    let item: PlaybackItem
    let isPlaying: Bool
    let currentTime: TimeInterval
    let togglePlayback: () -> Void
    let seek: (TimeInterval) -> Void
    let skip: (TimeInterval) -> Void
    let previous: () -> Void
    let next: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrubTime: TimeInterval?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    PodPalette.playerGradient
                        .opacity(0.14)
                        .ignoresSafeArea()
                    ScrollView {
                        VStack(spacing: 0) {
                            Spacer(minLength: 24)
                            artwork(width: min(geometry.size.width * 0.78, 320))
                            metadata
                                .padding(.top, 18)
                            playbackPanel
                                .padding(.top, 30)
                            Spacer(minLength: 24)
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: max(0, geometry.size.height - 42),
                            alignment: .top
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                        .padding(.bottom, 28)
                    }
                }
            }
            .navigationTitle("再生中")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる", systemImage: "chevron.down") { dismiss() }
                }
            }
        }
        .presentationDetents([.fraction(0.70)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
    }

    private func artwork(width: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.2)
            PodArtworkImage(url: item.artworkURL, contentMode: .fit)
        }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: PodPalette.violet.opacity(0.2), radius: 18, y: 10)
            .accessibilityLabel("\(item.title)のアートワーク")
    }

    private var metadata: some View {
        VStack(spacing: 6) {
            Text(item.title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(item.channelTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: 340, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private var playbackPanel: some View {
        VStack(spacing: 18) {
            timeline
            controls
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: 350)
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color(.secondarySystemBackground))
                : AnyShapeStyle(.thinMaterial),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var timeline: some View {
        VStack(spacing: 6) {
            CompactPlaybackSlider(
                value: scrubTime ?? currentTime,
                range: 0...max(item.duration, 1),
                onChange: { scrubTime = $0 },
                onCommit: { value in
                    seek(value)
                    scrubTime = nil
                }
            )
            HStack {
                Text(DisplayFormatter.duration(scrubTime ?? currentTime))
                Spacer()
                Text("−\(DisplayFormatter.duration(max(0, item.duration - (scrubTime ?? currentTime))))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    primaryPlaybackButton
                    HStack(spacing: 18) {
                        secondaryPlaybackButtons
                    }
                }
            } else {
                HStack(spacing: 14) {
                    playerButton("backward.end.fill", label: "前の項目", action: previous)
                    playerButton("gobackward.15", label: "15秒戻す") { skip(-15) }
                    primaryPlaybackButton
                    playerButton("goforward.15", label: "15秒進める") { skip(15) }
                    playerButton("forward.end.fill", label: "次の項目", action: next)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var secondaryPlaybackButtons: some View {
        playerButton("backward.end.fill", label: "前の項目", action: previous)
        playerButton("gobackward.15", label: "15秒戻す") { skip(-15) }
        playerButton("goforward.15", label: "15秒進める") { skip(15) }
        playerButton("forward.end.fill", label: "次の項目", action: next)
    }

    private var primaryPlaybackButton: some View {
        Button(action: togglePlayback) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(PodPalette.brandGradient, in: Circle())
                .shadow(color: PodPalette.raspberry.opacity(0.26), radius: 12, y: 6)
        }
        .accessibilityLabel(isPlaying ? "一時停止" : "再生")
    }

    private func playerButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }
}

/// A compact playback scrubber with a predictable circular thumb.
/// The system Slider uses a wide capsule thumb in iOS 27, which reads more like
/// a handle than a precise playback position at this size.
private struct CompactPlaybackSlider: View {
    let value: TimeInterval
    let range: ClosedRange<TimeInterval>
    let onChange: (TimeInterval) -> Void
    let onCommit: (TimeInterval) -> Void

    private let thumbDiameter: CGFloat = 14
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, thumbDiameter)
            let progress = normalizedProgress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.24))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(PodPalette.raspberry)
                    .frame(width: max(trackHeight, width * progress), height: trackHeight)

                Circle()
                    .fill(.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .offset(x: (width - thumbDiameter) * progress)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onChange(value(at: gesture.location.x, width: width))
                    }
                    .onEnded { gesture in
                        onCommit(value(at: gesture.location.x, width: width))
                    }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("再生位置")
        .accessibilityValue(DisplayFormatter.duration(value))
        .accessibilityAdjustableAction { direction in
            let adjustment: TimeInterval = direction == .increment ? 15 : -15
            onCommit(min(max(value + adjustment, range.lowerBound), range.upperBound))
        }
    }

    private var normalizedProgress: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    private func value(at location: CGFloat, width: CGFloat) -> TimeInterval {
        let usableWidth = max(width - thumbDiameter, 1)
        let progress = min(max((location - thumbDiameter / 2) / usableWidth, 0), 1)
        return range.lowerBound + TimeInterval(progress) * (range.upperBound - range.lowerBound)
    }
}
