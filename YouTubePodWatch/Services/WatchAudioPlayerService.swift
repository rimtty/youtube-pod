import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// An immutable playback snapshot. Keeping SwiftData models out of the player
/// prevents a remotely deleted model from remaining referenced by AVPlayer/UI.
struct WatchPlaybackItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let channelTitle: String
    let duration: TimeInterval
    let fileURL: URL
    let artworkURL: URL?
    let resumePosition: TimeInterval
    let hasBeenPlayed: Bool

    init(
        id: String,
        title: String,
        channelTitle: String,
        duration: TimeInterval,
        fileURL: URL,
        artworkURL: URL? = nil,
        resumePosition: TimeInterval = 0,
        hasBeenPlayed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.channelTitle = channelTitle
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.fileURL = fileURL
        self.artworkURL = artworkURL
        self.resumePosition = resumePosition.isFinite ? max(0, resumePosition) : 0
        self.hasBeenPlayed = hasBeenPlayed
    }
}

enum WatchAudioPlayerError: Error, Equatable, Sendable {
    case audioSessionConfigurationFailed
    case audioRouteUnavailable
    case fileUnavailable
    case playbackFailed
    case persistenceFailed
}

@MainActor
protocol WatchAudioSessionActivating: AnyObject {
    func activate(
        completion: @escaping @MainActor @Sendable (WatchAudioPlayerError?) -> Void
    )
}

@MainActor
private final class WatchAVAudioSessionActivator: WatchAudioSessionActivating {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func activate(
        completion: @escaping @MainActor @Sendable (WatchAudioPlayerError?) -> Void
    ) {
        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio,
                options: []
            )
        } catch {
            completion(.audioSessionConfigurationFailed)
            return
        }

        // Long-form playback on watchOS must use asynchronous activation. It
        // gives the system an opportunity to present an eligible-route picker.
        session.activate(options: []) { activated, error in
            Task { @MainActor in
                completion(activated && error == nil ? nil : .audioRouteUnavailable)
            }
        }
    }
}

@MainActor
@Observable
final class WatchAudioPlayerService {
    private(set) var currentItem: WatchPlaybackItem?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var playbackError: WatchAudioPlayerError?

    private let player: AVPlayer
    private let audioSession: any WatchAudioSessionActivating
    private let persistPlaybackPosition: @MainActor (String, TimeInterval, Bool) throws -> Void
    private let now: @MainActor () -> Date
    private var queue: [WatchPlaybackItem] = []
    private var index = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedToEndObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var resumptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var itemStatusTask: Task<Void, Never>?
    private var lastPersistedTime: TimeInterval = 0
    private var hasStartedCurrentItem = false
    private var activationRequestID = 0
    private var seekRequestID = 0
    private var pendingSkipTask: Task<Void, Never>?
    private var protectedSeekTarget: TimeInterval?
    private var protectedSeekDeadline = Date.distantPast
    private var shouldResumeAfterInterruption = false

    init(
        persistPlaybackPosition: @escaping @MainActor (String, TimeInterval, Bool) throws -> Void = {
            _, _, _ in
        }
    ) {
        self.player = AVPlayer()
        self.audioSession = WatchAVAudioSessionActivator()
        self.persistPlaybackPosition = persistPlaybackPosition
        self.now = Date.init
        installPeriodicTimeObserver()
        installAudioSessionObservers()
        installRemoteCommands()
    }

    init(
        player: AVPlayer,
        audioSession: any WatchAudioSessionActivating,
        now: @escaping @MainActor () -> Date = Date.init,
        persistPlaybackPosition: @escaping @MainActor (String, TimeInterval, Bool) throws -> Void = {
            _, _, _ in
        }
    ) {
        self.player = player
        self.audioSession = audioSession
        self.persistPlaybackPosition = persistPlaybackPosition
        self.now = now
        installPeriodicTimeObserver()
        installAudioSessionObservers()
        installRemoteCommands()
    }

    isolated deinit {
        pendingSkipTask?.cancel()
        itemStatusTask?.cancel()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let resumptionObserver {
            NotificationCenter.default.removeObserver(resumptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
    }

    func play(_ item: WatchPlaybackItem, queue: [WatchPlaybackItem]) {
        guard item.fileURL.isFileURL,
              FileManager.default.fileExists(atPath: item.fileURL.path) else {
            stopAndClearCurrentItem()
            playbackError = .fileUnavailable
            return
        }
        let previousQueue = self.queue
        let previousIndex = index
        let playableQueue = queue.filter { $0.duration > 0 }
        if let requestedIndex = playableQueue.firstIndex(where: { $0.id == item.id }) {
            self.queue = playableQueue
            index = requestedIndex
        } else {
            self.queue = [item] + playableQueue.filter { $0.id != item.id }
            index = 0
        }
        if !load(item, autoplay: true) {
            self.queue = previousQueue
            index = previousIndex
        }
    }

    func togglePlayback() {
        guard currentItem != nil else { return }
        if isPlaying {
            activationRequestID += 1
            player.pause()
            isPlaying = false
            persistCurrentPosition(force: true)
            updateNowPlaying(elapsedOnly: false)
        } else {
            if duration > 0, currentTime >= max(0, duration - 0.5) {
                seek(to: 0)
            }
            requestPlayback()
        }
    }

    func seek(to seconds: TimeInterval) {
        pendingSkipTask?.cancel()
        pendingSkipTask = nil
        applySeekRequest(to: seconds)
    }

    func skip(by seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let value = prepareSeek(to: currentTime + seconds)
        pendingSkipTask?.cancel()
        pendingSkipTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.performSeek(to: value, requestID: self.seekRequestID)
            self.pendingSkipTask = nil
        }
    }

    func previous() {
        if currentTime > 5 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty, index > 0 else {
            seek(to: 0)
            return
        }
        let previousIndex = index - 1
        if load(queue[previousIndex], autoplay: true) {
            index = previousIndex
        }
    }

    func next() {
        guard !queue.isEmpty else { return }
        guard index + 1 < queue.count else {
            player.pause()
            isPlaying = false
            persistCurrentPosition(force: true)
            updateNowPlaying(elapsedOnly: false)
            return
        }
        let nextIndex = index + 1
        if load(queue[nextIndex], autoplay: true) {
            index = nextIndex
        }
    }

    func persistPosition() {
        persistCurrentPosition(force: true)
    }

    /// Must be called before deleting the current item's file/model, whether
    /// deletion originated locally or from a WatchConnectivity command.
    func stopAndClearCurrentItem() {
        persistCurrentPosition(force: true)
        activationRequestID += 1
        seekRequestID += 1
        pendingSkipTask?.cancel()
        pendingSkipTask = nil
        protectedSeekTarget = nil
        protectedSeekDeadline = .distantPast
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeEndObserver()
        currentItem = nil
        queue.removeAll()
        index = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        lastPersistedTime = 0
        hasStartedCurrentItem = false
        playbackError = nil
        shouldResumeAfterInterruption = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func stopAndClearCurrentItem(ifMatching youtubeID: String) {
        guard currentItem?.id == youtubeID else { return }
        stopAndClearCurrentItem()
    }

    func removeFromQueue(youtubeID: String) {
        let removesCurrent = currentItem?.id == youtubeID
        if let removedIndex = queue.firstIndex(where: { $0.id == youtubeID }) {
            queue.remove(at: removedIndex)
            if removedIndex < index {
                index -= 1
            } else if index >= queue.count {
                index = max(0, queue.count - 1)
            }
        }
        if removesCurrent {
            stopAndClearCurrentItem()
        }
    }

    /// Exposed for deterministic notification-path testing. Production calls
    /// this only from the current AVPlayerItem's end notification.
    func handlePlaybackCompletion() {
        guard currentItem != nil else { return }
        pendingSkipTask?.cancel()
        pendingSkipTask = nil
        activationRequestID += 1
        currentTime = duration
        hasStartedCurrentItem = true
        if index + 1 < queue.count {
            let nextIndex = index + 1
            if load(queue[nextIndex], autoplay: true) {
                index = nextIndex
            } else {
                player.pause()
                isPlaying = false
                updateNowPlaying(elapsedOnly: false)
            }
        } else {
            guard persistCurrentPosition(force: true) else {
                player.pause()
                isPlaying = false
                updateNowPlaying(elapsedOnly: false)
                return
            }
            player.pause()
            isPlaying = false
            protectedSeekTarget = nil
            protectedSeekDeadline = .distantPast
            updateNowPlaying(elapsedOnly: false)
        }
    }

    func handleAudioSessionInterruptionBegan() {
        guard currentItem != nil else { return }
        shouldResumeAfterInterruption = isPlaying
        activationRequestID += 1
        player.pause()
        isPlaying = false
        persistCurrentPosition(force: true)
        updateNowPlaying(elapsedOnly: false)
    }

    func handleAudioSessionInterruptionEnded(shouldResume: Bool) {
        let resume = shouldResumeAfterInterruption && shouldResume
        shouldResumeAfterInterruption = false
        if resume {
            requestPlayback()
        }
    }

    func handleAudioRouteLost() {
        guard currentItem != nil else { return }
        shouldResumeAfterInterruption = false
        activationRequestID += 1
        player.pause()
        isPlaying = false
        playbackError = .audioRouteUnavailable
        persistCurrentPosition(force: true)
        updateNowPlaying(elapsedOnly: false)
    }

    func handlePlaybackFailure() {
        guard currentItem != nil else { return }
        shouldResumeAfterInterruption = false
        activationRequestID += 1
        player.pause()
        isPlaying = false
        playbackError = .playbackFailed
        persistCurrentPosition(force: true)
        updateNowPlaying(elapsedOnly: false)
    }

    /// Periodic callbacks can arrive after a seek. Ignore stale samples until
    /// AVPlayer reaches the newest target or a short safety deadline expires.
    func receivePeriodicTime(_ seconds: TimeInterval) {
        guard currentItem != nil else { return }
        let observed = seconds.isFinite ? min(max(0, seconds), duration) : 0
        if let target = protectedSeekTarget {
            let reachedTarget = abs(observed - target) < 0.8
            let protectionExpired = now() >= protectedSeekDeadline
            guard reachedTarget || protectionExpired else { return }
            protectedSeekTarget = nil
        }
        currentTime = observed
        persistCurrentPosition()
        updateNowPlaying(elapsedOnly: true)
    }

    @discardableResult
    private func load(_ item: WatchPlaybackItem, autoplay: Bool) -> Bool {
        guard item.fileURL.isFileURL,
              FileManager.default.fileExists(atPath: item.fileURL.path) else {
            playbackError = .fileUnavailable
            return false
        }
        guard persistCurrentPosition(force: true) else { return false }
        activationRequestID += 1
        seekRequestID += 1
        pendingSkipTask?.cancel()
        pendingSkipTask = nil
        protectedSeekTarget = nil
        playbackError = nil
        shouldResumeAfterInterruption = false
        currentItem = item
        duration = max(0, item.duration)
        currentTime = min(item.resumePosition, duration)
        lastPersistedTime = currentTime
        hasStartedCurrentItem = item.hasBeenPlayed

        let playerItem = AVPlayerItem(url: item.fileURL)
        player.replaceCurrentItem(with: playerItem)
        observePlayerItem(playerItem)
        applySeekRequest(to: currentTime, persist: false)
        updateNowPlaying(elapsedOnly: false)
        if autoplay {
            requestPlayback()
        }
        return true
    }

    private func requestPlayback() {
        activationRequestID += 1
        let requestID = activationRequestID
        let expectedItemID = currentItem?.id
        playbackError = nil
        audioSession.activate { [weak self] error in
            guard let self,
                  requestID == self.activationRequestID,
                  expectedItemID == self.currentItem?.id else { return }
            guard error == nil else {
                self.player.pause()
                self.isPlaying = false
                self.playbackError = error
                self.updateNowPlaying(elapsedOnly: false)
                return
            }
            self.player.play()
            self.isPlaying = true
            self.hasStartedCurrentItem = true
            self.persistCurrentPosition(force: true)
            self.updateNowPlaying(elapsedOnly: false)
        }
    }

    private func applySeekRequest(to seconds: TimeInterval, persist: Bool = true) {
        let value = prepareSeek(to: seconds, persist: persist)
        performSeek(to: value, requestID: seekRequestID)
    }

    @discardableResult
    private func prepareSeek(to seconds: TimeInterval, persist: Bool = true) -> TimeInterval {
        seekRequestID += 1
        let finiteSeconds = seconds.isFinite ? seconds : 0
        let value = min(max(0, finiteSeconds), duration)
        protectedSeekTarget = value
        protectedSeekDeadline = now().addingTimeInterval(2)
        currentTime = value
        if persist {
            persistCurrentPosition(force: true)
        }
        updateNowPlaying(elapsedOnly: true)
        return value
    }

    private func performSeek(to value: TimeInterval, requestID: Int) {
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: value, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished, requestID == self.seekRequestID else { return }
                self.currentTime = value
                self.protectedSeekTarget = value
                self.protectedSeekDeadline = self.now().addingTimeInterval(1)
                if self.isPlaying {
                    self.player.play()
                }
                self.updateNowPlaying(elapsedOnly: true)
            }
        }
    }

    @discardableResult
    private func persistCurrentPosition(force: Bool = false) -> Bool {
        guard let item = currentItem else { return true }
        guard force || abs(currentTime - lastPersistedTime) >= 5 else { return true }
        do {
            try persistPlaybackPosition(item.id, currentTime, hasStartedCurrentItem)
            lastPersistedTime = currentTime
            if playbackError == .persistenceFailed {
                playbackError = nil
            }
            return true
        } catch {
            // Keep lastPersistedTime unchanged so the next periodic tick or
            // lifecycle force-save retries instead of silently losing progress.
            playbackError = .persistenceFailed
            return false
        }
    }

    private func installPeriodicTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.receivePeriodicTime(time.seconds)
            }
        }
    }

    private func observePlayerItem(_ playerItem: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePlaybackCompletion()
            }
        }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePlaybackFailure()
            }
        }
        itemStatusTask?.cancel()
        itemStatusTask = Task { @MainActor [weak self, weak playerItem] in
            for _ in 0..<100 {
                guard let self, let playerItem, !Task.isCancelled,
                      self.player.currentItem === playerItem else { return }
                switch playerItem.status {
                case .failed:
                    self.handlePlaybackFailure()
                    return
                case .readyToPlay:
                    return
                case .unknown:
                    break
                @unknown default:
                    break
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    private func removeEndObserver() {
        itemStatusTask?.cancel()
        itemStatusTask = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }
    }

    private func installAudioSessionObservers() {
        let center = NotificationCenter.default
        if #available(watchOS 27.0, *) {
            installModernAudioSessionObservers(center: center)
        } else {
            installLegacyAudioSessionObserver(center: center)
        }
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let routeWasLost = rawValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                == .oldDeviceUnavailable
            MainActor.assumeIsolated {
                guard routeWasLost else { return }
                self?.handleAudioRouteLost()
            }
        }
    }

    @available(watchOS 27.0, *)
    private func installModernAudioSessionObservers(center: NotificationCenter) {
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAudioSessionInterruptionBegan()
            }
        }
        resumptionObserver = center.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let shouldResume = (
                notification.userInfo?[AVAudioSession.resumptionContextKey]
                    as? AVAudioSession.ResumptionContext
            )?.recommendation == .shouldResume
            MainActor.assumeIsolated {
                self?.handleAudioSessionInterruptionEnded(shouldResume: shouldResume)
            }
        }
    }

    private func installLegacyAudioSessionObserver(center: NotificationCenter) {
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeRawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = typeRawValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let optionsRawValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let shouldResume = optionsRawValue.map {
                AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume)
            } ?? false
            MainActor.assumeIsolated {
                switch type {
                case .began:
                    self?.handleAudioSessionInterruptionBegan()
                case .ended:
                    self?.handleAudioSessionInterruptionEnded(shouldResume: shouldResume)
                case nil:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func installRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        remoteCommandTargets = [
            (commands.playCommand, commands.playCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    if self?.isPlaying == false { self?.togglePlayback() }
                }
                return .success
            }),
            (commands.pauseCommand, commands.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    if self?.isPlaying == true { self?.togglePlayback() }
                }
                return .success
            }),
            (commands.skipForwardCommand, commands.skipForwardCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.skip(by: 15) }
                return .success
            }),
            (commands.skipBackwardCommand, commands.skipBackwardCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.skip(by: -15) }
                return .success
            })
        ]
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
    }

    private func updateNowPlaying(elapsedOnly: Bool) {
        guard let item = currentItem else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if !elapsedOnly {
            info[MPMediaItemPropertyTitle] = item.title
            info[MPMediaItemPropertyArtist] = item.channelTitle
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
