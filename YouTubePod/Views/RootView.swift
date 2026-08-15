import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Query private var savedAudios: [SavedAudio]

    @State private var selectedTab = AppTab.home
    @State private var showsAccount = false
    @State private var showsPlayer = false

    var body: some View {
        rootContent
            .animation(.smooth, value: environment.auth.phase)
            .onChange(of: environment.auth.sessionID) { _, _ in
                Task { await environment.catalog.clearCache() }
            }
            .onChange(of: environment.auth.isSignedIn) { _, isSignedIn in
                guard !isSignedIn else { return }
                showsAccount = false
                Task { await environment.downloads.cancelAll() }
            }
            .onChange(of: environment.player.currentItem?.id) { _, itemID in
                if itemID == nil {
                    showsPlayer = false
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .background else { return }
                environment.player.persistPosition()
                Task { await environment.downloads.cancelAll() }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch environment.auth.phase {
        case .restoring:
            AuthenticationRestoringView()
                .transition(.opacity)
        case .signedIn:
            authenticatedApp
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .signedOut, .signingIn, .failed:
            AuthenticationView()
                .transition(.opacity)
        }
    }

    private var authenticatedApp: some View {
        tabViewWithOptionalMiniPlayer
            .sheet(isPresented: $showsAccount) {
                AccountSettingsView(
                    displayName: environment.auth.displayName,
                    email: environment.auth.email,
                    profileImageURL: environment.auth.profileImageURL,
                    librarySize: librarySize,
                    signOut: environment.auth.signOut
                )
            }
            .sheet(isPresented: $showsPlayer) {
                if let item = environment.player.currentItem {
                    FullPlayerView(
                        item: item,
                        isPlaying: environment.player.isPlaying,
                        currentTime: environment.player.currentTime,
                        togglePlayback: environment.player.togglePlayback,
                        seek: environment.player.seek,
                        skip: environment.player.skip,
                        previous: environment.player.previous,
                        next: environment.player.next
                    )
                } else {
                    PodEmptyState(
                        icon: "speaker.slash",
                        title: "再生が終了しました",
                        message: "ライブラリから音声を選んでください。"
                    )
                }
            }
    }

    @ViewBuilder
    private var tabViewWithOptionalMiniPlayer: some View {
        if let item = environment.player.currentItem {
            tabs
                .tabViewBottomAccessory {
                    MiniPlayerView(
                        item: item,
                        isPlaying: environment.player.isPlaying,
                        progress: playbackProgress,
                        togglePlayback: environment.player.togglePlayback,
                        seek: environment.player.seek,
                        showPlayer: { showsPlayer = true }
                    )
                }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            tabs
                .tabBarMinimizeBehavior(.onScrollDown)
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("ホーム", systemImage: "sparkles", value: .home) {
                HomeView(
                    phaseForVideo: phase,
                    onDownload: startDownload,
                    onCancel: cancelDownload,
                    showAccount: { showsAccount = true }
                )
            }

            Tab("登録チャンネル", systemImage: "rectangle.stack.badge.person.crop", value: .subscriptions) {
                SubscriptionsView(
                    phaseForVideo: phase,
                    onDownload: startDownload,
                    onCancel: cancelDownload
                )
            }

            Tab("ライブラリ", systemImage: "headphones", value: .library) {
                LibraryView()
            }
            .badge(unplayedAudioCount)
        }
        .tint(PodPalette.raspberry)
    }

    private var playbackProgress: Double {
        let duration = environment.player.duration
        guard duration > 0 else { return 0 }
        return min(max(environment.player.currentTime / duration, 0), 1)
    }

    private var librarySize: String {
        let size = savedAudios.reduce(Int64(0)) { $0 + $1.fileSize }
        return "\(savedAudios.count)件 · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    private var unplayedAudioCount: Int {
        savedAudios.lazy.filter { !$0.hasBeenPlayed }.count
    }

    private func phase(for videoID: String) -> DownloadPhase? {
        environment.downloads.phases[videoID]
            ?? (savedAudios.contains { $0.youtubeID == videoID } ? .completed : nil)
    }

    private func startDownload(_ video: VideoSummary) {
        environment.downloads.enqueue(video)
    }

    private func cancelDownload(_ videoID: String) {
        Task { await environment.downloads.cancel(videoID: videoID) }
    }
}

private enum AppTab: Hashable {
    case home
    case subscriptions
    case library
}
