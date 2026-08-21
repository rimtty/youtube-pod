import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var savedAudios: [SavedAudio]
    @Query private var watchTransferRecords: [WatchTransferRecord]

    @State private var selectedTab = AppTab.home
    @State private var offlineSelectedTab = AppTab.library
    @State private var showsAccount = false
    @State private var showsPlayer = false
    @State private var isBrowsingOfflineLibrary = false

    var body: some View {
        rootContent
            .animation(reduceMotion ? nil : .smooth, value: environment.auth.phase)
            .sheet(isPresented: $showsPlayer) {
                playerSheet
            }
            .onChange(of: environment.auth.isSignedIn) { _, isSignedIn in
                if isSignedIn {
                    isBrowsingOfflineLibrary = false
                } else {
                    showsAccount = false
                    Task {
                        await environment.downloads.cancelAll()
                        await environment.catalog.clearCache()
                    }
                    if environment.player.currentItem != nil, !savedAudios.isEmpty {
                        isBrowsingOfflineLibrary = true
                    }
                }
            }
            .onChange(of: savedAudios.count) { _, count in
                if count == 0, watchAudioCount == 0 {
                    isBrowsingOfflineLibrary = false
                }
            }
            .onChange(of: watchAudioCount) { _, count in
                if count == 0, savedAudios.isEmpty {
                    isBrowsingOfflineLibrary = false
                }
            }
            .onChange(of: environment.player.currentItem?.id) { _, itemID in
                if itemID == nil {
                    showsPlayer = false
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    // Reattach to WCSession.outstandingFileTransfers and refresh
                    // persisted progress as soon as the foreground UI returns.
                    environment.watchTransfers.refreshState()
                case .background:
                    environment.player.persistPosition()
                    Task { await environment.downloads.cancelAll() }
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if isBrowsingOfflineLibrary, !environment.auth.isSignedIn {
            offlineLibrary
                .transition(.opacity)
        } else {
            switch environment.auth.phase {
            case .restoring:
                AuthenticationRestoringView()
                    .transition(.opacity)
            case .signedIn:
                authenticatedApp
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .signedOut, .signingIn, .authorizationRequired, .failed:
                AuthenticationView(
                    savedAudioCount: savedAudios.count,
                    watchAudioCount: watchAudioCount,
                    openOfflineLibrary: {
                        offlineSelectedTab = savedAudios.isEmpty && watchAudioCount > 0 ? .watch : .library
                        isBrowsingOfflineLibrary = true
                    }
                )
                .transition(.opacity)
            }
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
    }

    private var offlineLibrary: some View {
        TabView(selection: $offlineSelectedTab) {
            Tab("ライブラリ", systemImage: "headphones", value: .library) {
                tabContent {
                    LibraryView(
                        allowsOnlineActions: false,
                        closeOfflineLibrary: {
                            isBrowsingOfflineLibrary = false
                        },
                        signIn: {
                            Task { try? await environment.auth.signIn() }
                        }
                    )
                }
            }
            .badge(unplayedAudioCount)

            Tab("Watch", systemImage: "applewatch", value: .watch) {
                tabContent {
                    WatchTransfersView()
                }
            }
            .badge(pendingWatchTransferCount)
        }
        .tint(PodPalette.raspberry)
    }

    @ViewBuilder
    private var playerSheet: some View {
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

    private var tabViewWithOptionalMiniPlayer: some View {
        tabs
            .tabBarMinimizeBehavior(.onScrollDown)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("ホーム", systemImage: "sparkles", value: .home) {
                tabContent {
                    HomeView(
                        phaseForVideo: phase,
                        onDownload: startDownload,
                        onCancel: cancelDownload,
                        showAccount: { showsAccount = true }
                    )
                }
            }

            Tab("登録チャンネル", systemImage: "rectangle.stack.badge.person.crop", value: .subscriptions) {
                tabContent {
                    SubscriptionsView(
                        phaseForVideo: phase,
                        onDownload: startDownload,
                        onCancel: cancelDownload
                    )
                }
            }

            Tab("ライブラリ", systemImage: "headphones", value: .library) {
                tabContent {
                    LibraryView()
                }
            }
            .badge(unplayedAudioCount)

            Tab("Watch", systemImage: "applewatch", value: .watch) {
                tabContent {
                    WatchTransfersView()
                }
            }
            .badge(pendingWatchTransferCount)
        }
        .tint(PodPalette.raspberry)
    }

    private func tabContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 8) {
                miniPlayer
            }
            .animation(reduceMotion ? nil : .smooth, value: environment.player.currentItem?.id)
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if let item = environment.player.currentItem {
            MiniPlayerView(
                item: item,
                isPlaying: environment.player.isPlaying,
                progress: playbackProgress,
                togglePlayback: environment.player.togglePlayback,
                seek: environment.player.seek,
                showPlayer: { showsPlayer = true }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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

    private var watchAudioCount: Int {
        watchTransferRecords.lazy.filter { $0.state != .removedFromWatch }.count
    }

    private var pendingWatchTransferCount: Int {
        watchTransferRecords.lazy.filter { $0.state.isPendingTransfer }.count
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
    case watch
}
