import SwiftData
import SwiftUI

@main
struct YouTubePodWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    @State private var receiver: WatchSessionReceiver
    @State private var player: WatchAudioPlayerService

    init() {
        do {
            let container = try ModelContainer(
                for: WatchSavedAudio.self,
                WatchDeletionTombstone.self,
                WatchPendingAcknowledgement.self,
                WatchLibraryMetadata.self
            )
            let stager = WatchIncomingFileStager()
            let library = WatchAudioLibraryService(
                modelContext: container.mainContext,
                validator: AVFoundationWatchAudioValidator(),
                capacityChecker: FileSystemWatchCapacityChecker()
            )
            let player = WatchAudioPlayerService { videoID, position, hasBeenPlayed in
                try library.persistPlaybackPosition(
                    videoID: videoID,
                    position: position,
                    hasBeenPlayed: hasBeenPlayed
                )
            }
            let receiver = WatchSessionReceiver(
                stager: stager,
                library: library,
                peer: WatchWCSessionPeerSyncService(stager: stager),
                invalidatePlaybackItem: { videoID in
                    player.removeFromQueue(youtubeID: videoID)
                }
            )
            self.container = container
            _receiver = State(initialValue: receiver)
            _player = State(initialValue: player)
        } catch {
            // Never erase or recreate an unknown SwiftData store. Preserving
            // the user's transferred audio is safer than a destructive
            // fallback when migration cannot be proven.
            fatalError("Watch SwiftData initialization failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(
                player: player,
                receiver: receiver,
                onDelete: { saved in
                    Task { @MainActor in
                        _ = await receiver.deleteFromWatch(saved)
                    }
                }
            )
                .task { receiver.start() }
                .onChange(of: scenePhase) {
                    guard scenePhase != .active else { return }
                    player.persistPosition()
                }
        }
        .modelContainer(container)
    }
}
