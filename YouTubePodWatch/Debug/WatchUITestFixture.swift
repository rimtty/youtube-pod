#if DEBUG
import Foundation
import SwiftData
import SwiftUI

/// A single composite, deterministic fixture selected exclusively by the
/// `--watch-ui-test-fixture` launch argument.
@MainActor
enum WatchUITestFixture {
    // CI scans the Release executable to prove this DEBUG-only composition was
    // removed by conditional compilation.
    static let releaseIsolationSentinel = "YOUTUBEPOD_WATCH_UI_FIXTURE_SENTINEL"

    struct Composition {
        let container: ModelContainer
        let receiver: WatchSessionReceiver
        let player: WatchAudioPlayerService
        let playableAudioURL: (WatchSavedAudio) -> URL?
        let libraryFileURL: (String) -> URL?
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--watch-ui-test-fixture")
    }

    static var usesAccessibilitySize: Bool {
        ProcessInfo.processInfo.arguments.contains("--watch-ui-test-accessibility-size")
    }

    static var reducesMotion: Bool {
        ProcessInfo.processInfo.arguments.contains("--watch-ui-test-reduce-motion")
    }

    static func makeComposition() throws -> Composition {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: WatchSavedAudio.self,
            WatchDeletionTombstone.self,
            WatchPendingAcknowledgement.self,
            WatchLibraryMetadata.self,
            configurations: configuration
        )

        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: releaseIsolationSentinel, directoryHint: .isDirectory)
        // UI tests relaunch the app several times. Reuse one deterministic
        // sandbox root and remove the previous run so fixture files never
        // accumulate or influence the next assertion.
        try? FileManager.default.removeItem(at: rootURL)
        let audioDirectory = rootURL.appending(path: "Audio", directoryHint: .isDirectory)
        let stagingDirectory = rootURL.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )

        let playableURL = audioDirectory.appending(path: "uitest00001.m4a")
        let playableBytes = Data("watch-ui-test-audio".utf8)
        try playableBytes.write(to: playableURL, options: .atomic)

        let playable = WatchSavedAudio(
            youtubeID: "uitest00001",
            transferID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            title: "朝のテクノロジーポッドキャスト",
            channelTitle: "YouTube Pod テスト",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            savedViewCount: 12_345,
            duration: 120,
            audioRelativePath: "Audio/uitest00001.m4a",
            fileSize: Int64(playableBytes.count),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_100),
            revision: 1,
            lastPlaybackPosition: 30,
            hasBeenPlayed: true
        )
        let missing = WatchSavedAudio(
            youtubeID: "uitest00002",
            transferID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            title: "転送待ちの長いタイトルを持つ音声エピソード",
            channelTitle: "オフラインテストチャンネル",
            publishedAt: Date(timeIntervalSince1970: 1_699_999_000),
            savedViewCount: 98_765,
            duration: 300,
            audioRelativePath: "Audio/uitest00002.m4a",
            fileSize: 42,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            revision: 1
        )
        container.mainContext.insert(playable)
        container.mainContext.insert(missing)
        try container.mainContext.save()

        let stager = WatchIncomingFileStager(rootDirectoryURL: stagingDirectory)
        let library = WatchAudioLibraryService(
            modelContext: container.mainContext,
            validator: AVFoundationWatchAudioValidator(),
            capacityChecker: FileSystemWatchCapacityChecker(),
            rootURL: rootURL
        )
        let player = WatchAudioPlayerService()
        let playbackItem = WatchPlaybackItem(
            id: playable.youtubeID,
            title: playable.title,
            channelTitle: playable.channelTitle,
            duration: playable.duration,
            fileURL: playableURL,
            resumePosition: 30,
            hasBeenPlayed: true
        )
        player.installUITestFixture(
            item: playbackItem,
            currentTime: 30,
            isPlaying: true
        )

        let receiver = WatchSessionReceiver(
            stager: stager,
            library: library,
            peer: WatchUITestPeerSyncService(),
            invalidatePlaybackItem: { videoID in
                player.removeFromQueue(youtubeID: videoID)
            }
        )
        receiver.installUITestFixture(
            errorMessage: "iPhoneとの同期を確認できませんでした。再同期してください。"
        )

        let playableURLs = [playable.youtubeID: playableURL]
        return Composition(
            container: container,
            receiver: receiver,
            player: player,
            playableAudioURL: { audio in
                guard let url = playableURLs[audio.youtubeID],
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return url
            },
            libraryFileURL: { relativePath in
                rootURL.appending(path: relativePath)
            }
        )
    }

    static func driveProgress(player: WatchAudioPlayerService) async {
        // Keep the initial 25% value stable long enough for the Watch app's
        // accessibility hierarchy to become queryable on slower CI hosts,
        // then perform one deterministic live update to 30%.
        do {
            try await Task.sleep(for: .seconds(5))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        player.updateUITestFixtureProgress(to: 36)
    }
}

@MainActor
private final class WatchUITestPeerSyncService: WatchPeerSyncing {
    var stagedFileHandler: (@MainActor @Sendable (StagedWatchTransferFile) -> Void)?
    var commandHandler: (@MainActor @Sendable (StagedWatchLibraryCommand) -> Void)?
    var inventoryRequestHandler: (@MainActor @Sendable (WatchInventoryRequest) -> Void)?
    var activationHandler: (@MainActor @Sendable () -> Void)?
    var hasContentPending: Bool { false }

    func activate() {}
    func waitForActivation() async throws {}
    func waitUntilContentDrained() async throws {}
    func enqueueAcknowledgement(_ acknowledgement: WatchTransferAcknowledgement) throws {}
    func publishInventory(_ inventory: WatchInventorySnapshot) throws {}
    func currentInventoryRequest() -> WatchInventoryRequest? { nil }
}
#endif
