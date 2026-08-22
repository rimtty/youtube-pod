import AVFoundation
import Foundation
import MediaPlayer
import Observation
import OSLog

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
    private let logger = Logger(
        subsystem: "com.rimtty.YouTubePod",
        category: "WatchAudioSession"
    )
    private var isConfigured = false

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func activate(
        completion: @escaping @MainActor @Sendable (WatchAudioPlayerError?) -> Void
    ) {
        if !isConfigured {
            do {
                try session.setCategory(
                    .playback,
                    mode: .spokenAudio,
                    policy: .longFormAudio,
                    options: []
                )
                isConfigured = true
                logger.info("audio_session_configured")
                debugTrace("audio_session_configured")
            } catch {
                let nsError = error as NSError
                logger.error(
                    "audio_session_configuration_failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
                )
                debugTrace(
                    "audio_session_configuration_failed domain=\(nsError.domain) code=\(nsError.code)"
                )
                completion(.audioSessionConfigurationFailed)
                return
            }
        }

        // Long-form playback on watchOS must use asynchronous activation. It
        // gives the system an opportunity to present an eligible-route picker.
        logger.info(
            "audio_session_activation_requested routes=\(self.routeSummary, privacy: .public)"
        )
        debugTrace("audio_session_activation_requested routes=\(routeSummary)")
        session.activate(options: []) { activated, error in
            let nsError = error as NSError?
            let errorDomain = nsError?.domain ?? "none"
            let errorCode = nsError?.code ?? 0
            let succeeded = activated && error == nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.info(
                    "audio_session_activation_completed activated=\(activated, privacy: .public) domain=\(errorDomain, privacy: .public) code=\(errorCode, privacy: .public) routes=\(self.routeSummary, privacy: .public)"
                )
                self.debugTrace(
                    "audio_session_activation_completed activated=\(activated) domain=\(errorDomain) code=\(errorCode) routes=\(self.routeSummary)"
                )
                completion(succeeded ? nil : .audioRouteUnavailable)
            }
        }
    }

    private var routeSummary: String {
        let routes = session.currentRoute.outputs.map(\.portType.rawValue)
        return routes.isEmpty ? "none" : routes.joined(separator: ",")
    }

    private func debugTrace(_ message: String) {
#if DEBUG
        print("[WatchAudioSession] \(message)")
#endif
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
    private let logger = Logger(subsystem: "com.rimtty.YouTubePod", category: "WatchPlayback")
    private var queue: [WatchPlaybackItem] = []
    private var index = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedToEndObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
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
        let player = AVPlayer()
        self.player = player
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
        if let stalledObserver {
            NotificationCenter.default.removeObserver(stalledObserver)
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
        if currentItem?.id == item.id {
            let playableQueue = queue.filter { $0.duration > 0 }
            self.queue = playableQueue.contains(where: { $0.id == item.id })
                ? playableQueue
                : [item] + playableQueue.filter { $0.id != item.id }
            index = self.queue.firstIndex(where: { $0.id == item.id }) ?? 0

            // Selecting the highlighted row must remain seamless while it is
            // actively playing. Once playback has stopped at the end, though,
            // the same action means "play again" rather than reopening an
            // AVPlayerItem whose end notification would immediately advance.
            if !isPlaying, isAtEnd {
                isPlaying = true
                applySeekRequest(to: 0, resumePlayback: true)
            }
            return
        }
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
                // Keep the resume intent true until the rewind has completed,
                // so activation cannot race ahead of the seek.
                isPlaying = true
                applySeekRequest(to: 0, resumePlayback: true)
                return
            }
            requestPlayback(reason: "user_resume")
        }
    }

    func seek(to seconds: TimeInterval) {
        pendingSkipTask?.cancel()
        pendingSkipTask = nil
        logger.info(
            "seek_requested kind=direct from=\(self.currentTime, privacy: .public) target=\(seconds, privacy: .public) playing=\(self.isPlaying)"
        )
        debugTrace("seek_requested kind=direct from=\(currentTime) target=\(seconds) playing=\(isPlaying)")
        applySeekRequest(to: seconds)
    }

    func skip(by seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let value = prepareSeek(to: currentTime + seconds)
        logger.info(
            "seek_requested kind=skip delta=\(seconds, privacy: .public) target=\(value, privacy: .public) playing=\(self.isPlaying)"
        )
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

#if DEBUG
    /// Seeds the observable playback snapshot used by Watch UI tests without
    /// touching AVPlayer, AVAudioSession, or remote-command playback state.
    func installUITestFixture(
        item: WatchPlaybackItem,
        currentTime: TimeInterval,
        isPlaying: Bool
    ) {
        activationRequestID += 1
        seekRequestID += 1
        pendingSkipTask?.cancel()
        pendingSkipTask = nil
        currentItem = item
        queue = [item]
        index = 0
        duration = item.duration
        self.currentTime = min(max(currentTime, 0), item.duration)
        lastPersistedTime = self.currentTime
        hasStartedCurrentItem = true
        self.isPlaying = isPlaying
        playbackError = nil
    }

    /// Moves only the observable fixture clock. The real periodic AVPlayer
    /// observer remains authoritative in every non-fixture composition.
    func updateUITestFixtureProgress(to currentTime: TimeInterval) {
        guard currentItem != nil else { return }
        self.currentTime = min(max(currentTime, 0), duration)
    }
#endif

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
            requestPlayback(reason: "interruption_resume")
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
        logger.error(
            "playback_failed rate=\(self.player.rate, privacy: .public) timeControl=\(self.player.timeControlStatus.rawValue, privacy: .public) itemStatus=\(self.player.currentItem?.status.rawValue ?? -1, privacy: .public) error=\(self.player.currentItem?.error?.localizedDescription ?? "none", privacy: .public)"
        )
        shouldResumeAfterInterruption = false
        activationRequestID += 1
        player.pause()
        isPlaying = false
        playbackError = .playbackFailed
        persistCurrentPosition(force: true)
        updateNowPlaying(elapsedOnly: false)
    }

    func handlePlaybackStalled() {
        guard currentItem != nil else { return }
        logger.error(
            "playback_stalled position=\(self.currentTime, privacy: .public) rate=\(self.player.rate, privacy: .public) timeControl=\(self.player.timeControlStatus.rawValue, privacy: .public)"
        )
        debugTrace(
            "playback_stalled position=\(currentTime) rate=\(player.rate) timeControl=\(player.timeControlStatus.rawValue)"
        )
        guard isPlaying else { return }
        player.play()
        logger.info("playback_stall_recovery_requested")
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
        let storedPosition = min(item.resumePosition, duration)
        // A persisted end position is a completed state, not a useful resume
        // point. Starting an AVPlayerItem there emits didPlayToEnd almost
        // immediately and skips to the next queue entry.
        currentTime = isAtEnd(storedPosition, duration: duration) ? 0 : storedPosition
        lastPersistedTime = currentTime
        hasStartedCurrentItem = item.hasBeenPlayed

        let playerItem = AVPlayerItem(url: item.fileURL)
        player.replaceCurrentItem(with: playerItem)
        observePlayerItem(playerItem)
        applySeekRequest(to: currentTime, persist: false, resumePlayback: false)
        updateNowPlaying(elapsedOnly: false)
        if autoplay {
            requestPlayback(reason: "autoplay")
        }
        return true
    }

    private var isAtEnd: Bool {
        isAtEnd(currentTime, duration: duration)
    }

    private func isAtEnd(_ position: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && position >= max(0, duration - 0.5)
    }

    private func requestPlayback(reason: String) {
        activationRequestID += 1
        let requestID = activationRequestID
        let expectedItemID = currentItem?.id
        playbackError = nil
        logger.info(
            "playback_activation_requested request=\(requestID) reason=\(reason, privacy: .public) \(self.playbackDiagnostics, privacy: .public)"
        )
        debugTrace(
            "playback_activation_requested request=\(requestID) reason=\(reason) \(playbackDiagnostics)"
        )
        audioSession.activate { [weak self] error in
            guard let self,
                  requestID == self.activationRequestID,
                  expectedItemID == self.currentItem?.id else {
                self?.logger.info(
                    "playback_activation_ignored request=\(requestID) reason=superseded"
                )
                self?.debugTrace(
                    "playback_activation_ignored request=\(requestID) reason=superseded"
                )
                return
            }
            guard error == nil else {
                self.player.pause()
                self.isPlaying = false
                self.playbackError = error
                self.logger.error(
                    "playback_activation_failed request=\(requestID) reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public) \(self.playbackDiagnostics, privacy: .public)"
                )
                self.debugTrace(
                    "playback_activation_failed request=\(requestID) reason=\(reason) error=\(String(describing: error)) \(self.playbackDiagnostics)"
                )
                self.updateNowPlaying(elapsedOnly: false)
                return
            }
            self.player.play()
            self.isPlaying = true
            self.hasStartedCurrentItem = true
            self.persistCurrentPosition(force: true)
            self.updateNowPlaying(elapsedOnly: false)
            self.logger.info(
                "playback_resumed request=\(requestID) reason=\(reason, privacy: .public) \(self.playbackDiagnostics, privacy: .public)"
            )
            self.debugTrace(
                "playback_resumed request=\(requestID) reason=\(reason) \(self.playbackDiagnostics)"
            )
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self,
                      requestID == self.activationRequestID,
                      expectedItemID == self.currentItem?.id else { return }
                self.debugTrace(
                    "playback_post_resume request=\(requestID) reason=\(reason) \(self.playbackDiagnostics)"
                )
            }
        }
    }

    private func applySeekRequest(
        to seconds: TimeInterval,
        persist: Bool = true,
        resumePlayback: Bool? = nil
    ) {
        let value = prepareSeek(to: seconds, persist: persist)
        performSeek(
            to: value,
            requestID: seekRequestID,
            resumePlayback: resumePlayback
        )
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

    private func performSeek(
        to value: TimeInterval,
        requestID: Int,
        attempt: Int = 0,
        resumePlayback: Bool? = nil
    ) {
        let tolerance = attempt == 0
            ? CMTime(seconds: 0.1, preferredTimescale: 600)
            : .zero
        let shouldResume = resumePlayback ?? isPlaying
        if attempt == 0, shouldResume {
            // Stop the renderer before moving the local M4A timebase. Playing
            // through a large seek can leave watchOS advancing time while its
            // audio output pipeline remains silent.
            activationRequestID += 1
            player.pause()
        }
        logger.info(
            "seek_performing request=\(requestID) attempt=\(attempt) target=\(value, privacy: .public) resume=\(shouldResume) \(self.playbackDiagnostics, privacy: .public)"
        )
        debugTrace(
            "seek_performing request=\(requestID) attempt=\(attempt) target=\(value) resume=\(shouldResume) \(playbackDiagnostics)"
        )
        player.seek(
            to: CMTime(seconds: value, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard requestID == self.seekRequestID else {
                    self.logger.info("seek_ignored request=\(requestID) reason=superseded")
                    return
                }
                self.logger.info(
                    "seek_completed request=\(requestID) attempt=\(attempt) target=\(value, privacy: .public) finished=\(finished) playing=\(self.isPlaying) \(self.playbackDiagnostics, privacy: .public)"
                )
                self.debugTrace(
                    "seek_completed request=\(requestID) attempt=\(attempt) target=\(value) finished=\(finished) playing=\(self.isPlaying) \(self.playbackDiagnostics)"
                )
                if !finished, attempt == 0 {
                    self.logger.error("seek_retrying request=\(requestID) target=\(value, privacy: .public)")
                    self.performSeek(
                        to: value,
                        requestID: requestID,
                        attempt: 1,
                        resumePlayback: shouldResume
                    )
                    return
                }
                self.currentTime = value
                self.protectedSeekTarget = value
                self.protectedSeekDeadline = self.now().addingTimeInterval(1)
                if shouldResume, self.isPlaying {
                    self.requestPlayback(reason: "seek_completed")
                }
                self.updateNowPlaying(elapsedOnly: true)
            }
        }
    }

    private var playbackDiagnostics: String {
        let item = player.currentItem
        let waitingReason = player.reasonForWaitingToPlay?.rawValue ?? "none"
        let itemError = item?.error?.localizedDescription ?? "none"
        return "rate=\(player.rate) timeControl=\(player.timeControlStatus.rawValue) waiting=\(waitingReason) itemStatus=\(item?.status.rawValue ?? -1) current=\(item?.currentTime().seconds ?? -1) likelyToKeepUp=\(item?.isPlaybackLikelyToKeepUp ?? false) bufferEmpty=\(item?.isPlaybackBufferEmpty ?? false) bufferFull=\(item?.isPlaybackBufferFull ?? false) error=\(itemError)"
    }

    private func debugTrace(_ message: String) {
#if DEBUG
        print("[WatchPlayback] \(message)")
#endif
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
        stalledObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePlaybackStalled()
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
        if let stalledObserver {
            NotificationCenter.default.removeObserver(stalledObserver)
            self.stalledObserver = nil
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
