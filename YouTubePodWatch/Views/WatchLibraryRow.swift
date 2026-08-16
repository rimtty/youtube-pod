import SwiftUI
import UIKit

struct WatchLibraryRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let audio: WatchSavedAudio
    let isCurrent: Bool
    let isPlaying: Bool
    let currentTime: TimeInterval
    let play: () -> Void

    var body: some View {
        Group {
            if isPlayable {
                Button(action: play) {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(
                    "ダブルタップして再生画面を開く。左にスワイプすると削除できます"
                )
            } else {
                rowContent
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityHint("左にスワイプすると削除できます")
            }
        }
    }

    private var progress: Double {
        WatchUIPresentation.playbackProgress(
            duration: audio.duration,
            persistedProgress: audio.playbackProgress,
            isCurrent: isCurrent,
            currentTime: currentTime
        )
    }

    private var showsPlaybackProgress: Bool {
        WatchUIPresentation.showsPlaybackProgress(
            hasBeenPlayed: audio.hasBeenPlayed,
            isCurrent: isCurrent
        )
    }

    private var playbackPercentage: Int {
        WatchUIPresentation.playbackPercentage(progress: progress)
    }

    private var accessibilityLabel: String {
        var parts = [audio.title, audio.channelTitle, durationText(audio.duration)]
        if !isPlayable {
            parts.append("利用できません")
        } else if isCurrent {
            parts.append(isPlaying ? "再生中" : "一時停止中")
            parts.append("\(playbackPercentage)パーセント再生済み")
        } else if audio.hasBeenPlayed {
            parts.append("\(playbackPercentage)パーセント再生済み")
        } else {
            parts.append("新着")
        }
        return parts.joined(separator: "、")
    }

    private var isPlayable: Bool {
        watchPlayableAudioURL(for: audio) != nil
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                WatchArtwork(audio: audio)
                    .frame(width: 52, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(audio.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)

                    Text(audio.channelTitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if !isPlayable {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .accessibilityHidden(true)
                            Text("利用できません")
                        } else if isCurrent {
                            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                                .foregroundStyle(WatchPodPalette.lilac)
                                .symbolEffect(
                                    .variableColor.iterative,
                                    isActive: WatchUIPresentation.shouldAnimatePlaybackSymbol(
                                        isPlaying: isPlaying,
                                        reduceMotion: reduceMotion
                                    )
                                )
                                .accessibilityHidden(true)
                        }
                        Text(durationText(audio.duration))
                        if showsPlaybackProgress {
                            Text("·")
                            Text("\(playbackPercentage)%")
                        } else {
                            Text("新着")
                                .foregroundStyle(WatchPodPalette.lilac)
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.62))
                }
            }

            if showsPlaybackProgress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule()
                            .fill(WatchPodPalette.brandGradient)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .padding(8)
        .background(
            reduceTransparency
                ? AnyShapeStyle(WatchPodPalette.deepTurquoise)
                : AnyShapeStyle(.thinMaterial),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isCurrent ? WatchPodPalette.lilac.opacity(0.72) : .white.opacity(0.08),
                    lineWidth: isCurrent ? 1.25 : 0.75
                )
        }
    }
}

struct WatchArtwork: View {
    let imageURL: URL?

    init(audio: WatchSavedAudio) {
        imageURL = audio.safeThumbnailRelativePath.flatMap {
            watchLibraryFileURL(relativePath: $0)
        }
    }

    init(url: URL?) {
        imageURL = url
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                WatchPodPalette.brandGradient
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.headline.bold())
                            .foregroundStyle(.white)
                    }
            }
        }
        .background(.black.opacity(0.32))
        .accessibilityHidden(true)
    }

    private var image: UIImage? {
        guard let imageURL else { return nil }
        return UIImage(contentsOfFile: imageURL.path)
    }
}

func watchLibraryFileURL(relativePath: String) -> URL? {
    guard let supportURL = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    ) else { return nil }
    return supportURL
        .appending(path: "WatchLibrary", directoryHint: .isDirectory)
        .appending(path: relativePath)
}

func watchPlayableAudioURL(for audio: WatchSavedAudio) -> URL? {
    guard audio.storageState == .ready || audio.storageState == .readyWithoutArtwork,
          let relativePath = audio.safeAudioRelativePath,
          let url = watchLibraryFileURL(relativePath: relativePath),
          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          values.isRegularFile == true,
          let fileSize = values.fileSize,
          Int64(fileSize) == audio.fileSize
    else { return nil }
    return url
}

func durationText(_ duration: TimeInterval) -> String {
    guard duration.isFinite, duration >= 0 else { return "0:00" }
    let seconds = Int(duration.rounded(.down))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainder = seconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%d:%02d", minutes, remainder)
}
