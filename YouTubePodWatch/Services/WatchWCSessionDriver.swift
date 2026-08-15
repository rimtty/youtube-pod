import Foundation
@preconcurrency import WatchConnectivity

/// The small, actor-confined surface used by the Watch peer service.
///
/// `WCSession`, `WCSessionFile`, and `WCSessionFileTransfer` cannot be
/// constructed by unit tests. Keeping those Apple-owned objects behind this
/// driver lets the peer service exercise activation and outbound delivery with
/// ordinary deterministic values while its delegate callback core remains
/// responsible for synchronously preserving incoming files.
@MainActor
protocol WatchWCSessionDriving: AnyObject {
    var isSupported: Bool { get }
    var isActivated: Bool { get }
    var hasContentPending: Bool { get }

    func installDelegate(_ delegate: (any WCSessionDelegate)?)
    func activate()
    func transferUserInfo(_ userInfo: [String: Any])
    func updateApplicationContext(_ applicationContext: [String: Any]) throws
}

@MainActor
final class AppleWatchWCSessionDriver: WatchWCSessionDriving {
    private let session: WCSession?

    init(session: WCSession? = WCSession.isSupported() ? .default : nil) {
        self.session = session
    }

    var isSupported: Bool {
        session != nil
    }

    var isActivated: Bool {
        session?.activationState == .activated
    }

    var hasContentPending: Bool {
        session?.hasContentPending ?? false
    }

    func installDelegate(_ delegate: (any WCSessionDelegate)?) {
        session?.delegate = delegate
    }

    func activate() {
        session?.activate()
    }

    func transferUserInfo(_ userInfo: [String: Any]) {
        session?.transferUserInfo(userInfo)
    }

    func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        guard let session else { throw WatchPeerSyncError.sessionUnavailable }
        try session.updateApplicationContext(applicationContext)
    }
}
