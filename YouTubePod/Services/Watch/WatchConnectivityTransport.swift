import Foundation

struct WatchTransferKey: Hashable, Sendable {
    let transferID: UUID
    let fileKind: WatchTransferFileKind
}

enum WatchSessionActivation: Sendable, Equatable {
    case unsupported
    case inactive
    case activating
    case activated
}

struct WatchConnectionStatus: Sendable, Equatable {
    let activation: WatchSessionActivation
    let isPaired: Bool?
    let isWatchAppInstalled: Bool?

    var canTransfer: Bool {
        activation == .activated && isPaired == true && isWatchAppInstalled == true
    }

    static let unsupported = WatchConnectionStatus(
        activation: .unsupported,
        isPaired: nil,
        isWatchAppInstalled: nil
    )
}

struct WatchTransportFailure: Error, Equatable, Sendable {
    let code: String
    let message: String
    let isRetryable: Bool
}

struct OutstandingWatchFile: Equatable, Sendable {
    let key: WatchTransferKey
    let fileURL: URL
    let progress: Double
}

enum WatchConnectivityEvent: Sendable {
    case statusChanged(WatchConnectionStatus)
    case progress(WatchTransferKey, Double)
    case fileFinished(WatchTransferKey, WatchTransportFailure?)
    case acknowledgement(WatchTransferAcknowledgement)
    case inventory(WatchInventorySnapshot)
}

@MainActor
protocol WatchConnectivityTransport: AnyObject {
    var status: WatchConnectionStatus { get }
    var eventHandler: (@MainActor @Sendable (WatchConnectivityEvent) -> Void)? { get set }

    func activate()
    func outstandingFiles() -> [OutstandingWatchFile]
    func enqueueFile(at url: URL, envelope: WatchTransferEnvelope) throws
    func sendDeletionCommand(_ command: WatchLibraryCommand) throws
    func cancelFiles(transferID: UUID)
}
