import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment

    let phaseForVideo: (String) -> DownloadPhase?
    let onDownload: (VideoSummary) -> Void
    let onCancel: (String) -> Void
    let showAccount: () -> Void

    @State private var popular: [VideoSummary] = []
    @State private var recent: [VideoSummary] = []
    @State private var searchResults: [VideoSummary] = []
    @State private var searchText = ""
    @State private var submittedSearchText = ""
    @State private var isLoading = false
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchErrorMessage: String?
    @State private var selectedChannel: ChannelDestination?

    var body: some View {
        NavigationStack {
            ZStack {
                PodScreenBackground()
                Group {
                    if isLoading && popular.isEmpty && recent.isEmpty {
                        loadingView
                    } else if let errorMessage, popular.isEmpty && recent.isEmpty {
                        PodErrorState(message: errorMessage) {
                            Task { await reload(forceRefresh: true) }
                        }
                    } else {
                        feed
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
            .navigationTitle("ホーム")
            .searchable(text: $searchText, prompt: "動画を検索")
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PodToolbarBrandMark(size: 34)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: showAccount) {
                        PodAccountAvatar(
                            imageURL: environment.auth.profileImageURL,
                            displayName: environment.auth.displayName,
                            size: 34
                        )
                    }
                    .accessibilityLabel("Googleアカウント: \(environment.auth.displayName)")
                    .accessibilityHint("アカウントと設定を表示")
                }
            }
            .refreshable { await reload(forceRefresh: true) }
            .task { await reload(forceRefresh: false) }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 18) {
            PodBrandMark(size: 72)
            ProgressView("あなた向けの音声を探しています…")
                .tint(PodPalette.raspberry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                hero

                if isSearching {
                    HStack { Spacer(); ProgressView("検索中…"); Spacer() }
                } else if let searchErrorMessage {
                    SearchFeedbackCard(
                        icon: "wifi.exclamationmark",
                        title: "検索できませんでした",
                        message: searchErrorMessage,
                        actionTitle: "もう一度試す",
                        action: { Task { await search() } }
                    )
                } else if !searchResults.isEmpty {
                    videoSection(
                        title: "検索結果",
                        subtitle: "「\(submittedSearchText)」に一致する動画",
                        icon: "magnifyingglass",
                        videos: searchResults
                    )
                } else if !submittedSearchText.isEmpty {
                    SearchFeedbackCard(
                        icon: "magnifyingglass",
                        title: "動画が見つかりませんでした",
                        message: "「\(submittedSearchText)」に一致する公開動画はありません。",
                        actionTitle: nil,
                        action: nil
                    )
                }

                if !recent.isEmpty {
                    videoSection(
                        title: "登録チャンネルの新着",
                        subtitle: "いつものチャンネルから、できたてを",
                        icon: "sparkles.tv",
                        videos: Array(recent.prefix(20))
                    )
                }

                if !popular.isEmpty {
                    videoSection(
                        title: "日本で人気",
                        subtitle: "いま聴かれている動画",
                        icon: "flame.fill",
                        videos: Array(popular.prefix(20))
                    )
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private var hero: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("見つけて、保存して、\n好きなときに聴こう。")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("公開動画の音声を、この端末だけのライブラリへ。")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
            }
            Spacer(minLength: 6)
            Image(systemName: "headphones.circle.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .nonRepeating)
                .accessibilityHidden(true)
        }
        .padding(20)
        .background(PodPalette.playerGradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: PodPalette.violet.opacity(0.2), radius: 18, y: 9)
        .accessibilityElement(children: .combine)
    }

    private func videoSection(
        title: String,
        subtitle: String,
        icon: String,
        videos: [VideoSummary]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title, subtitle: subtitle, systemImage: icon)
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
        }
    }

    @MainActor
    private func reload(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if forceRefresh {
            await environment.catalog.clearCache()
        }

        // Start both requests together. The subscription feed can require several
        // YouTube API calls, so running it after the popular feed made the refresh
        // indicator appear to remain stuck for much longer than necessary.
        async let popularRequest = environment.catalog.popularVideos(regionCode: "JP")
        async let recentRequest = environment.catalog.subscriptionUploads()

        do {
            popular = try await popularRequest
        } catch {
            errorMessage = error.localizedDescription
        }

        do {
            recent = try await recentRequest
        } catch {
            if popular.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            submittedSearchText = ""
            searchErrorMessage = nil
            return
        }
        submittedSearchText = query
        searchErrorMessage = nil
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await environment.catalog.searchVideos(query: query)
        } catch {
            searchResults = []
            searchErrorMessage = error.localizedDescription
        }
    }
}

private struct SearchFeedbackCard: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3.bold())
                .foregroundStyle(PodPalette.violet)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.bold())
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                        .tint(PodPalette.violet)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .podCard()
    }
}
