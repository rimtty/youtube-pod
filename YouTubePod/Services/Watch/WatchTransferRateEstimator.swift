import Foundation

/// Remaining-time estimate for one in-flight WatchConnectivity file transfer.
struct WatchTransferEstimate: Equatable, Sendable {
    /// `nil` while the transfer is stalled (no progress for a while).
    let remainingSeconds: TimeInterval?
    let bytesPerSecond: Double
    let computedAt: Date

    var isStalled: Bool { remainingSeconds == nil }
}

/// Derives throughput from WCSession progress callbacks.
///
/// WatchConnectivity does not populate `Progress.estimatedTimeRemaining`, and
/// Bluetooth throughput swings widely, so the rate is measured over a sliding
/// window of recent samples and only reported once enough time has passed
/// for the number to be meaningful.
struct WatchTransferRateEstimator: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        let fraction: Double
        let time: Date
    }

    static let windowDuration: TimeInterval = 60
    static let minimumSpan: TimeInterval = 10
    static let stallThreshold: TimeInterval = 30

    private(set) var samples: [Sample] = []

    init() {}

    /// Records a progress callback. Non-increasing fractions are ignored so a
    /// repeated KVO notification does not shorten the measured span.
    mutating func record(fraction: Double, at time: Date) {
        guard fraction.isFinite else { return }
        let clamped = min(max(fraction, 0), 1)
        if let last = samples.last {
            guard clamped > last.fraction, time > last.time else { return }
        }
        samples.append(Sample(fraction: clamped, time: time))
        let cutoff = time.addingTimeInterval(-Self.windowDuration)
        // Keep one sample older than the window so the span stays wide
        // enough right after trimming.
        while samples.count > 2, samples[1].time < cutoff {
            samples.removeFirst()
        }
    }

    func estimate(fileSize: Int64, at now: Date) -> WatchTransferEstimate? {
        guard fileSize > 0,
              let first = samples.first,
              let last = samples.last,
              samples.count >= 2 else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        guard span >= Self.minimumSpan else { return nil }
        let transferredBytes = (last.fraction - first.fraction) * Double(fileSize)
        guard transferredBytes > 0 else { return nil }
        let bytesPerSecond = transferredBytes / span
        if now.timeIntervalSince(last.time) > Self.stallThreshold {
            return WatchTransferEstimate(remainingSeconds: nil, bytesPerSecond: bytesPerSecond, computedAt: now)
        }
        let remainingBytes = (1 - last.fraction) * Double(fileSize)
        let projected = remainingBytes / bytesPerSecond - now.timeIntervalSince(last.time)
        return WatchTransferEstimate(
            remainingSeconds: max(0, projected),
            bytesPerSecond: bytesPerSecond,
            computedAt: now
        )
    }
}
