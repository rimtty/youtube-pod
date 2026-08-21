import SwiftData
import SwiftUI

@main
struct YouTubePodWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    private let runsProductionServices: Bool
    private let playableAudioURL: (WatchSavedAudio) -> URL?
    private let libraryFileURL: (String) -> URL?
    @State private var receiver: WatchSessionReceiver
    @State private var player: WatchAudioPlayerService

    init() {
#if DEBUG
        if WatchUITestFixture.isRequested {
            do {
                let fixture = try WatchUITestFixture.makeComposition()
                self.container = fixture.container
                self.runsProductionServices = false
                self.playableAudioURL = fixture.playableAudioURL
                self.libraryFileURL = fixture.libraryFileURL
                _receiver = State(initialValue: fixture.receiver)
                _player = State(initialValue: fixture.player)
                return
            } catch {
                fatalError("Watch UI test fixture initialization failed: \(error)")
            }
        }
        if WatchSimulatorSyncFixture.isRequested {
            do {
                let fixture = try WatchSimulatorSyncFixture.makeComposition()
                self.container = fixture.container
                self.runsProductionServices = false
                self.playableAudioURL = fixture.playableAudioURL
                self.libraryFileURL = fixture.libraryFileURL
                _receiver = State(initialValue: fixture.receiver)
                _player = State(initialValue: fixture.player)
                return
            } catch {
                fatalError("Watch Simulator sync fixture initialization failed: \(error)")
            }
        }
#endif
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
            self.runsProductionServices = true
            self.playableAudioURL = watchPlayableAudioURL
            self.libraryFileURL = watchLibraryFileURL
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
                playableAudioURL: playableAudioURL,
                libraryFileURL: libraryFileURL,
                reduceMotionOverride: watchUITestReduceMotionOverride,
                onDelete: { saved in
                    Task { @MainActor in
                        _ = await receiver.deleteFromWatch(saved)
                    }
                }
            )
                .applyingWatchUITestEnvironment()
                .task {
#if DEBUG
                    if WatchUITestFixture.isRequested {
                        await WatchUITestFixture.driveProgress(player: player)
                        return
                    }
#endif
                    receiver.start()
                }
                .onChange(of: scenePhase) {
                    guard scenePhase != .active else { return }
                    player.persistPosition()
                }
        }
        .modelContainer(container)
        .backgroundTask(.watchConnectivity) { [receiver] in
            guard runsProductionServices else { return }
            await receiver.handleConnectivityBackgroundTask()
        }
    }
}

private extension View {
    @ViewBuilder
    func applyingWatchUITestEnvironment() -> some View {
#if DEBUG
        if WatchUITestFixture.isRequested {
            self
                .environment(
                    \.dynamicTypeSize,
                    WatchUITestFixture.usesAccessibilitySize ? .accessibility5 : .large
                )
        } else {
            self
        }
#else
        self
#endif
    }
}

@MainActor
private var watchUITestReduceMotionOverride: Bool? {
#if DEBUG
    WatchUITestFixture.isRequested && WatchUITestFixture.reducesMotion ? true : nil
#else
    nil
#endif
}
