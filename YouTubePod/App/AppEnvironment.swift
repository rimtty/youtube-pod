import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppEnvironment {
    let auth: GoogleAuthService
    let catalog: YouTubeDataClient
    let library: AudioLibraryService
    let downloads: DownloadManager
    let optimizer: LibraryAudioOptimizer
    let player: AudioPlayerService
    let watchTransfers: PhoneWatchTransferService

    init(modelContext: ModelContext) {
        // A force quit or process termination can happen after yt-dlp created
        // its working directory but before the normal defer cleanup runs.
        // No extraction is active while the environment is being assembled,
        // so directories from the previous process are safe to remove here.
        PythonAudioExtractor.removeStaleWorkingDirectories()

        let auth = GoogleAuthService()
        let library = AudioLibraryService(modelContext: modelContext)
        self.auth = auth
        self.library = library
        self.catalog = YouTubeDataClient(
            credentialProvider: { await auth.validCredential() },
            authenticationFailureHandler: { await auth.invalidateSession() }
        )
        let player = AudioPlayerService(
            persistPlaybackPosition: { videoID, position in
                library.updatePlaybackPosition(videoID: videoID, position: position)
            },
            markPlaybackStarted: { videoID in
                library.markPlayed(videoID: videoID)
            }
        )
        self.player = player
        // Deferral closures read `downloads`, which is created after the
        // optimizer; a weak box breaks the initialization cycle.
        let downloadsBox = WeakBox<DownloadManager>()
        let optimizer = LibraryAudioOptimizer(
            library: library,
            shouldDeferBackfill: { downloadsBox.value?.isExtracting == true },
            isCurrentlyPlaying: { videoID in player.currentItem?.id == videoID }
        )
        self.optimizer = optimizer
        let downloads = DownloadManager(
            extractor: PythonAudioExtractor(),
            library: library,
            optimizer: optimizer
        )
        downloadsBox.value = downloads
        self.downloads = downloads
        self.watchTransfers = PhoneWatchTransferService(
            modelContext: modelContext,
            transport: WCSessionAdapter(),
            snapshots: WatchTransferSnapshotStore(),
            optimizer: optimizer
        )
    }

    func start() async {
        watchTransfers.start()
        optimizer.resumeBackfill()
        // Do not wait for the first foreground transition callback to learn
        // the Watch's state. SwiftUI can create this environment while the
        // scene is already active, in which case no initial phase change is
        // guaranteed.
        watchTransfers.refreshState()
        await auth.restore()
        player.configureAudioSession()
    }
}

@MainActor
private final class WeakBox<Value: AnyObject> {
    weak var value: Value?
}
