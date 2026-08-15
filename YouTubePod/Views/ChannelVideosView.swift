import SwiftUI

struct ChannelDestination: Identifiable, Hashable {
    let channelID: String
    let title: String

    var id: String { channelID }
}

struct ChannelVideosView: View {
    @Environment(AppEnvironment.self) private var environment

    let destination: ChannelDestination
    let phaseForVideo: (String) -> DownloadPhase?
    let onDownload: (VideoSummary) -> Void
    let onCancel: (String) -> Void

    @State private var videos: [VideoSummary] = []
    @State private var nextPageToken: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var loadMoreError: String?
    @State private var visitedPageTokens = Set<String>()

    var body: some View {
        ZStack {
            PodScreenBackground()
            Group {
                if isLoading && videos.isEmpty {
                    ProgressView("チャンネルの動画を読み込み中…")
                        .tint(PodPalette.raspberry)
                } else if let errorMessage, videos.isEmpty {
                    PodErrorState(message: errorMessage) {
                        Task { await load(forceRefresh: true) }
                    }
                } else if videos.isEmpty {
                    PodEmptyState(
                        icon: "rectangle.stack",
                        title: "公開動画はありません",
                        message: "このチャンネルには現在表示できる公開動画がありません。",
                        actionTitle: "更新",
                        action: { Task { await load(forceRefresh: true) } }
                    )
                } else {
                    content
                }
            }
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(forceRefresh: true) }
        .task(id: destination.channelID) { await load(forceRefresh: false) }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                SectionHeading(
                    "新しい順",
                    subtitle: "\(videos.count)本の公開動画",
                    systemImage: "play.rectangle.on.rectangle"
                )

                if let errorMessage {
                    inlineError(errorMessage) {
                        Task { await load(forceRefresh: true) }
                    }
                }

                ForEach(videos) { video in
                    VideoRowView(
                        video: video,
                        phase: phaseForVideo(video.id),
                        onSave: { onDownload(video) },
                        onCancel: { onCancel(video.id) }
                    )
                }

                if nextPageToken != nil || isLoadingMore || loadMoreError != nil {
                    loadMoreFooter
                }
            }
            .padding()
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if isLoadingMore {
            HStack { Spacer(); ProgressView("さらに読み込み中…"); Spacer() }
                .padding(.vertical, 16)
        } else if let loadMoreError {
            inlineError(loadMoreError) {
                Task { await loadMore() }
            }
        } else if nextPageToken != nil {
            Button {
                Task { await loadMore() }
            } label: {
                Label("さらに動画を読み込む", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PodPalette.violet)
            .padding(.vertical, 12)
        }
    }

    private func inlineError(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("もう一度試す", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @MainActor
    private func load(forceRefresh: Bool) async {
        guard !isLoading, !isLoadingMore else { return }
        if !forceRefresh, !videos.isEmpty { return }
        isLoading = true
        errorMessage = nil
        loadMoreError = nil
        defer { isLoading = false }

        do {
            let page = try await environment.catalog.channelVideosPage(
                channelID: destination.channelID,
                pageToken: nil,
                forceRefresh: forceRefresh
            )
            videos = page.videos
            visitedPageTokens.removeAll()
            nextPageToken = validatedNextToken(page.nextPageToken, after: nil)
        } catch {
            if error is CancellationError { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore() async {
        guard let nextPageToken, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }

        do {
            let page = try await environment.catalog.channelVideosPage(
                channelID: destination.channelID,
                pageToken: nextPageToken,
                forceRefresh: false
            )
            videos = YouTubeDataClient.mergeUnique([videos, page.videos])
            self.nextPageToken = validatedNextToken(page.nextPageToken, after: nextPageToken)
        } catch {
            if error is CancellationError { return }
            loadMoreError = error.localizedDescription
        }
    }

    private func validatedNextToken(_ candidate: String?, after current: String?) -> String? {
        guard let candidate, !candidate.isEmpty, candidate != current,
              visitedPageTokens.insert(candidate).inserted else { return nil }
        return candidate
    }
}
