import Foundation
@preconcurrency import WatchConnectivity

/// Invalidates a progress subscription without exposing
/// `NSKeyValueObservation` to the adapter or its tests.
@MainActor
protocol PhoneWCSessionProgressObserving: AnyObject {
    func invalidate()
}

/// The testable surface of one Apple-owned file transfer.
///
/// `WCSessionFileTransfer` cannot be constructed by unit tests. The concrete
/// Apple wrapper below is the only production type that retains it.
@MainActor
protocol PhoneWCSessionFileTransferDriving: AnyObject {
    var fileURL: URL { get }
    var metadata: [String: Any] { get }
    var fractionCompleted: Double { get }

    func cancel()
    func observeProgress(
        _ handler: @escaping @MainActor @Sendable (Double) -> Void
    ) -> any PhoneWCSessionProgressObserving
}

/// Actor-confined facade around the outbound and state-querying WCSession API.
/// Delegate callbacks remain on `WCSessionAdapter`, where Apple values are
/// synchronously normalized into Sendable app-domain values.
@MainActor
protocol PhoneWCSessionDriving: AnyObject {
    var isSupported: Bool { get }
    var activationState: WCSessionActivationState { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var receivedApplicationContext: [String: Any] { get }
    var outstandingFileTransfers: [any PhoneWCSessionFileTransferDriving] { get }

    func installDelegate(_ delegate: (any WCSessionDelegate)?)
    func activate()
    func transferFile(
        _ fileURL: URL,
        metadata: [String: Any]
    ) throws -> any PhoneWCSessionFileTransferDriving
    func transferUserInfo(_ userInfo: [String: Any]) throws
    func updateApplicationContext(_ applicationContext: [String: Any]) throws
}

@MainActor
final class ApplePhoneWCSessionDriver: PhoneWCSessionDriving {
    private let session: WCSession?

    init(session: WCSession? = WCSession.isSupported() ? .default : nil) {
        self.session = session
    }

    var isSupported: Bool { session != nil }
    var activationState: WCSessionActivationState {
        session?.activationState ?? .notActivated
    }
    var isPaired: Bool { session?.isPaired ?? false }
    var isWatchAppInstalled: Bool { session?.isWatchAppInstalled ?? false }
    var receivedApplicationContext: [String: Any] {
        session?.receivedApplicationContext ?? [:]
    }
    var outstandingFileTransfers: [any PhoneWCSessionFileTransferDriving] {
        session?.outstandingFileTransfers.map(ApplePhoneWCSessionFileTransferDriver.init) ?? []
    }

    func installDelegate(_ delegate: (any WCSessionDelegate)?) {
        session?.delegate = delegate
    }

    func activate() {
        session?.activate()
    }

    func transferFile(
        _ fileURL: URL,
        metadata: [String: Any]
    ) throws -> any PhoneWCSessionFileTransferDriving {
        guard let session else { throw WatchConnectivityAdapterError.unsupported }
        return ApplePhoneWCSessionFileTransferDriver(
            session.transferFile(fileURL, metadata: metadata)
        )
    }

    func transferUserInfo(_ userInfo: [String: Any]) throws {
        guard let session else { throw WatchConnectivityAdapterError.unsupported }
        session.transferUserInfo(userInfo)
    }

    func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        guard let session else { throw WatchConnectivityAdapterError.unsupported }
        try session.updateApplicationContext(applicationContext)
    }
}

@MainActor
private final class ApplePhoneWCSessionFileTransferDriver: PhoneWCSessionFileTransferDriving {
    private let transfer: WCSessionFileTransfer

    init(_ transfer: WCSessionFileTransfer) {
        self.transfer = transfer
    }

    var fileURL: URL { transfer.file.fileURL }
    var metadata: [String: Any] { transfer.file.metadata ?? [:] }
    var fractionCompleted: Double { transfer.progress.fractionCompleted }

    func cancel() {
        transfer.cancel()
    }

    func observeProgress(
        _ handler: @escaping @MainActor @Sendable (Double) -> Void
    ) -> any PhoneWCSessionProgressObserving {
        let observation = transfer.progress.observe(
            \.fractionCompleted,
            options: [.initial, .new]
        ) { progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in
                handler(value)
            }
        }
        return ApplePhoneWCSessionProgressObservation(observation)
    }
}

@MainActor
private final class ApplePhoneWCSessionProgressObservation: PhoneWCSessionProgressObserving {
    private var observation: NSKeyValueObservation?

    init(_ observation: NSKeyValueObservation) {
        self.observation = observation
    }

    func invalidate() {
        observation?.invalidate()
        observation = nil
    }

    deinit {
        observation?.invalidate()
    }
}
