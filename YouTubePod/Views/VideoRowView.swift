import SwiftUI

struct VideoRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let video: VideoSummary
    var phase: DownloadPhase?
    var onOpenChannel: (() -> Void)? = nil
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))

        layout {
            channelThumbnail
            VStack(alignment: .leading, spacing: 7) {
                channelMetadata
                downloadControl
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .podCard()
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var channelThumbnail: some View {
        if let onOpenChannel {
            Button(action: onOpenChannel) {
                thumbnail
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(video.channelTitle)の動画一覧を表示")
        } else {
            thumbnail
        }
    }

    @ViewBuilder
    private var channelMetadata: some View {
        if let onOpenChannel {
            Button(action: onOpenChannel) {
                metadataContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(video.title)、\(video.channelTitle)の動画一覧を表示")
        } else {
            metadataContent
        }
    }

    private var metadataContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(video.title)
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .foregroundStyle(.primary)

            HStack(spacing: 5) {
                Text(video.channelTitle)
                    .lineLimit(1)
                if onOpenChannel != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack(spacing: 5) {
                Text(DisplayFormatter.views(video.viewCount))
                Text("•")
                Text(DisplayFormatter.relativeDate(video.publishedAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: video.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        PodPalette.playerGradient.opacity(0.24)
                        Image(systemName: "waveform")
                            .font(.title2.bold())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 136, height: 77)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            Text(thumbnailBadge)
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(6)
        }
        .accessibilityLabel("動画のサムネイル、長さ \(DisplayFormatter.duration(video.duration))")
    }

    private var thumbnailBadge: String {
        switch video.broadcastStatus {
        case .live: "ライブ"
        case .upcoming: "公開予定"
        case .none where video.duration <= 0: "準備中"
        case .none: DisplayFormatter.duration(video.duration)
        }
    }

    @ViewBuilder
    private var downloadControl: some View {
        switch phase {
        case .queued:
            DownloadStatusLabel(icon: "clock", text: "待機中", tint: .secondary)
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .tint(PodPalette.raspberry)
                    .accessibilityLabel("保存進捗")
                    .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button("中止", systemImage: "xmark.circle.fill", action: onCancel)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("「\(video.title)」の保存を中止")
            }
            .accessibilityElement(children: .contain)
        case .retrying(let attempt, let maximumRetries):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(PodPalette.raspberry)
                Text("自動再試行 \(attempt)/\(maximumRetries)")
                    .font(.caption.bold())
                    .foregroundStyle(PodPalette.violet)
                Button("中止", systemImage: "xmark.circle.fill", action: onCancel)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("「\(video.title)」の保存を中止")
            }
        case .validating:
            DownloadStatusLabel(icon: "checkmark.shield", text: "音声を確認中", tint: PodPalette.violet)
        case .completed:
            DownloadStatusLabel(icon: "checkmark.circle.fill", text: "保存済み", tint: .green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Button(action: onSave) {
                    Label("再試行", systemImage: "arrow.clockwise")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .tint(PodPalette.raspberry)
                .accessibilityLabel("「\(video.title)」の音声保存を再試行")
            }
        case nil where !video.supportsAudioExtraction:
            DownloadStatusLabel(
                icon: "exclamationmark.circle",
                text: video.audioExtractionUnavailableMessage,
                tint: .secondary
            )
        case nil:
            Button(action: onSave) {
                Label("音声を保存", systemImage: "arrow.down.circle.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
            .tint(PodPalette.raspberry)
            .accessibilityLabel("「\(video.title)」の音声を保存")
        }
    }
}

private struct DownloadStatusLabel: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(tint)
    }
}
