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
    let player: AudioPlayerService

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
        self.player = AudioPlayerService(
            persistPlaybackPosition: { videoID, position in
                library.updatePlaybackPosition(videoID: videoID, position: position)
            },
            markPlaybackStarted: { videoID in
                library.markPlayed(videoID: videoID)
            }
        )
        self.downloads = DownloadManager(extractor: PythonAudioExtractor(), library: library)
    }

    func start() async {
        await auth.restore()
        player.configureAudioSession()
    }
}
