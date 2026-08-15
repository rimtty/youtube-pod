import SwiftUI

struct SubscriptionsView: View {
    @Environment(AppEnvironment.self) private var environment

    let phaseForVideo: (String) -> DownloadPhase?
    let onDownload: (VideoSummary) -> Void
    let onCancel: (String) -> Void

    @State private var videos: [VideoSummary] = []
    @State private var nextPageToken: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var loadMoreError: String?
    @State private var selectedChannel: ChannelDestination?
    @State private var visitedPageTokens = Set<String>()

    var body: some View {
        NavigationStack {
            ZStack {
                PodScreenBackground()
                Group {
                    if isLoading && videos.isEmpty {
                        ProgressView("登録チャンネルを更新中…")
                            .tint(PodPalette.raspberry)
                    } else if let errorMessage, videos.isEmpty {
                        PodErrorState(message: errorMessage) {
                            Task { await load(forceRefresh: true) }
                        }
                    } else if videos.isEmpty {
                        PodEmptyState(
                        icon: "rectangle.stack.badge.person.crop",
                        title: "新着はありません",
                            message: "登録チャンネルに新しい公開動画が追加されると、ここに表示されます。",
                            actionTitle: "更新",
                            action: { Task { await load(forceRefresh: true) } }
                        )
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                SectionHeading(
                                    "新しい順",
                                    subtitle: "\(videos.count)本の公開動画",
                                    systemImage: "arrow.down.to.line.compact"
                                )
                                if let errorMessage {
                                    VStack(spacing: 8) {
                                        Label(errorMessage, systemImage: "arrow.clockwise.circle")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                        Button("もう一度試す") {
                                            Task { await load(forceRefresh: true) }
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                ForEach(videos) { video in
                                    VideoRowView(
                                        video: video,
                                        phase: phaseForVideo(video.id),
                                        onOpenChannel: video.channelID.isEmpty ? nil : {
                                            selectedChannel = ChannelDestination(
                                                channelID: video.channelID,
                                                title: video.channelTitle
                                            )
                                        },
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
                }
            }
            .navigationDestination(item: $selectedChannel) { destination in
                ChannelVideosView(
                    destination: destination,
                    phaseForVideo: phaseForVideo,
                    onDownload: onDownload,
                    onCancel: onCancel
                )
            }
            .navigationTitle("登録チャンネル")
            .refreshable { await load(forceRefresh: true) }
            .task(id: environment.auth.sessionID) {
                guard videos.isEmpty else { return }
                await load(forceRefresh: false)
            }
        }
    }

    @MainActor
    private func load(forceRefresh: Bool = false) async {
        guard !isLoading, !isLoadingMore else { return }
        if !forceRefresh, !videos.isEmpty { return }
        isLoading = true
        errorMessage = nil
        loadMoreError = nil
        defer { isLoading = false }

        do {
            let page = try await environment.catalog.subscriptionUploadsPage(
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

    @ViewBuilder
    private var loadMoreFooter: some View {
        if isLoadingMore {
            HStack { Spacer(); ProgressView("さらに読み込み中…"); Spacer() }
                .padding(.vertical, 16)
        } else if let loadMoreError {
            VStack(spacing: 8) {
                Label(loadMoreError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("もう一度試す") { Task { await loadMore() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if nextPageToken != nil {
            Button {
                Task { await loadMore() }
            } label: {
                Label("さらに登録チャンネルを読み込む", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PodPalette.violet)
            .padding(.vertical, 12)
        }
    }

    @MainActor
    private func loadMore() async {
        guard let token = nextPageToken, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            let page = try await environment.catalog.subscriptionUploadsPage(
                pageToken: token,
                forceRefresh: false
            )
            videos = YouTubeDataClient.mergeUnique([videos, page.videos])
            nextPageToken = validatedNextToken(page.nextPageToken, after: token)
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
