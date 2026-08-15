import SwiftData
import SwiftUI

@main
struct YouTubePodWatchApp: App {
    private let container: ModelContainer
    @State private var receiver: WatchSessionReceiver

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
            let receiver = WatchSessionReceiver(
                stager: stager,
                library: library,
                peer: WatchWCSessionPeerSyncService(stager: stager)
            )
            self.container = container
            _receiver = State(initialValue: receiver)
        } catch {
            // Never erase or recreate an unknown SwiftData store. Preserving
            // the user's transferred audio is safer than a destructive
            // fallback when migration cannot be proven.
            fatalError("Watch SwiftData initialization failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .task { receiver.start() }
        }
        .modelContainer(container)
    }
}
