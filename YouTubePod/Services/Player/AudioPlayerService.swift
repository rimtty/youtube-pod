import AVFoundation
import Foundation
import MediaPlayer
import Observation

@MainActor
@Observable
final class AudioPlayerService: AudioPlaying {
    private(set) var currentItem: PlaybackItem?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private let player = AVPlayer()
    private var queue: [PlaybackItem] = []
    private var index = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastPersistedTime: TimeInterval = 0
    private var activationRequestID = 0
    private var seekRequestID = 0
    private var pendingSkipTask: Task<Void, Never>?
    private var protectedSeekTarget: TimeInterval?
    private var protectedSeekDeadline = Date.distantPast
    private var preservedPositionAfterQueueEnd: TimeInterval?
    private let persistPlaybackPosition: @MainActor (String, TimeInterval) -> Void
    private let markPlaybackStarted: @MainActor (String) -> Void

    init(
        persistPlaybackPosition: @escaping @MainActor (String, TimeInterval) -> Void = { _, _ in },
        markPlaybackStarted: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.persistPlaybackPosition = persistPlaybackPosition
        self.markPlaybackStarted = markPlaybackStarted
        installRemoteCommands()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let observedTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                if let target = self.protectedSeekTarget {
                    let reachedTarget = abs(observedTime - target) < 0.8
                    let protectionExpired = Date() >= self.protectedSeekDeadline
                    guard reachedTarget || protectionExpired else { return }
                    self.protectedSeekTarget = nil
                }
                self.currentTime = observedTime
                self.persistCurrentPosition()
                self.updateNowPlaying(elapsedOnly: true)
            }
        }
    }

    isolated deinit {
        pendingSkipTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        } catch {
            assertionFailure("Audio session configuration failed: \(error)")
        }
    }

    func play(_ item: PlaybackItem, queue: [PlaybackItem]) {
        self.queue = queue
        index = queue.firstIndex(where: { $0.id == item.id }) ?? 0
        load(item, autoplay: true)
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
        preservedPositionAfterQueueEnd = nil
        pendingSkipTask?.cancel()
        applySeekRequest(to: seconds)
    }

    func skip(by seconds: TimeInterval) {
        preservedPositionAfterQueueEnd = nil
        // Update the visible position for every tap, but coalesce a burst of
        // skip commands into one AVPlayer seek. Issuing many exact seeks at
        // once can leave AVPlayer waiting on superseded requests.
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

    func persistPosition() {
        persistCurrentPosition(force: true)
    }

    func removeFromQueue(videoID: String) {
        let removesCurrentItem = currentItem?.id == videoID

        if let removedIndex = queue.firstIndex(where: { $0.id == videoID }) {
            queue.remove(at: removedIndex)
            if removedIndex < index {
                index -= 1
            } else if index >= queue.count {
                index = max(0, queue.count - 1)
            }
        }

        guard removesCurrentItem else { return }
        stopAndClearCurrentItem()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            index += 1
            load(queue[index], autoplay: true)
        } else {
            // Preserve the final visible position before rewinding AVPlayer.
            // The zero seek is only an idle UI state, not new playback history.
            persistCurrentPosition(force: true)
            if preservedPositionAfterQueueEnd == nil {
                preservedPositionAfterQueueEnd = currentTime
            }
            activationRequestID += 1
            seekRequestID += 1
            pendingSkipTask?.cancel()
            pendingSkipTask = nil
            protectedSeekTarget = 0
            protectedSeekDeadline = Date().addingTimeInterval(2)
            player.pause()
            player.seek(to: .zero)
            isPlaying = false
            currentTime = 0
            updateNowPlaying(elapsedOnly: false)
        }
    }

    func previous() {
        if currentTime > 5 { seek(to: 0); return }
        guard !queue.isEmpty, index > 0 else { seek(to: 0); return }
        index -= 1
        load(queue[index], autoplay: true)
    }

    private func load(_ item: PlaybackItem, autoplay: Bool) {
        persistCurrentPosition(force: true)
        preservedPositionAfterQueueEnd = nil
        currentItem = item
        markPlaybackStarted(item.id)
        duration = max(0, item.duration)
        currentTime = min(max(0, item.resumePosition), duration)
        lastPersistedTime = currentTime
        let playerItem = AVPlayerItem(url: item.fileURL)
        player.replaceCurrentItem(with: playerItem)
        observePlaybackEnd(for: playerItem)
        seek(to: currentTime)
        if autoplay {
            requestPlayback()
        }
        // Do not carry metadata or artwork from the previously queued item.
        // Artwork is loaded asynchronously and is guarded by the item ID below.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateNowPlaying(elapsedOnly: false)
        loadArtwork(item.artworkURL, for: item.id)
    }

    private func requestPlayback() {
        activationRequestID += 1
        let requestID = activationRequestID
        let expectedItemID = currentItem?.id

        AVAudioSession.sharedInstance().activate(options: []) { [weak self] activated, error in
            Task { @MainActor [weak self] in
                guard let self,
                      requestID == self.activationRequestID,
                      expectedItemID == self.currentItem?.id else { return }
                guard activated, error == nil else {
                    self.isPlaying = false
                    self.updateNowPlaying(elapsedOnly: false)
                    return
                }
                self.preservedPositionAfterQueueEnd = nil
                self.player.play()
                self.isPlaying = true
                self.updateNowPlaying(elapsedOnly: false)
            }
        }
    }

    /// Keeps a completed item at 100% in the library. Starting it again seeks
    /// to the beginning in `togglePlayback()`.
    func handlePlaybackCompletion() {
        guard currentItem != nil else { return }
        preservedPositionAfterQueueEnd = nil
        activationRequestID += 1
        pendingSkipTask?.cancel()
        pendingSkipTask = nil
        currentTime = duration
        persistCurrentPosition(force: true)
        if index + 1 < queue.count {
            index += 1
            load(queue[index], autoplay: true)
        } else {
            player.pause()
            player.seek(to: .zero)
            isPlaying = false
            protectedSeekTarget = nil
            protectedSeekDeadline = .distantPast
            updateNowPlaying(elapsedOnly: false)
        }
    }

    private func stopAndClearCurrentItem() {
        persistCurrentPosition(force: true)
        activationRequestID += 1
        seekRequestID += 1
        pendingSkipTask?.cancel()
        pendingSkipTask = nil
        protectedSeekTarget = nil
        protectedSeekDeadline = .distantPast
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        currentItem = nil
        preservedPositionAfterQueueEnd = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        lastPersistedTime = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func applySeekRequest(to seconds: TimeInterval) {
        let value = prepareSeek(to: seconds)
        performSeek(to: value, requestID: seekRequestID)
    }

    @discardableResult
    private func prepareSeek(to seconds: TimeInterval) -> TimeInterval {
        seekRequestID += 1
        let value = min(max(0, seconds), max(duration, 0))
        // AVPlayer can emit stale periodic-time callbacks while a seek is in
        // flight. Keep the latest requested position visible until it arrives.
        protectedSeekTarget = value
        protectedSeekDeadline = Date().addingTimeInterval(2)
        currentTime = value
        persistCurrentPosition(force: true)
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
                self.protectedSeekDeadline = Date().addingTimeInterval(1)
                if self.isPlaying {
                    self.player.play()
                }
                self.updateNowPlaying(elapsedOnly: true)
            }
        }
    }

    private func persistCurrentPosition(force: Bool = false) {
        guard let item = currentItem else { return }
        let position = preservedPositionAfterQueueEnd ?? currentTime
        guard force || abs(position - lastPersistedTime) >= 5 else { return }
        lastPersistedTime = position
        persistPlaybackPosition(item.id, position)
    }

    private func installRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayback() } }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayback() } }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(by: 15) }; return .success }
        commands.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(by: -15) }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func observePlaybackEnd(for playerItem: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePlaybackCompletion()
            }
        }
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

    private func loadArtwork(_ url: URL?, for itemID: String) {
        guard let url else { return }
        Task.detached {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
            // MediaPlayer invokes this request handler on its private access queue.
            // Build it outside the MainActor so Swift 6 does not attach main-actor
            // isolation to a callback that must be callable from any queue.
            let artwork = Self.makeArtwork(from: image)
            await MainActor.run {
                guard self.currentItem?.id == itemID else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    private nonisolated static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
