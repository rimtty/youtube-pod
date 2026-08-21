import Foundation
import OSLog

/// Stable unified-log categories for correlating one Watch transfer across
/// the iPhone and Watch processes. User-facing titles and file paths must not
/// be logged here.
enum WatchSyncLog {
    static let subsystem = "com.rimtty.YouTubePod.watch-sync"

    static let phoneTransport = Logger(subsystem: subsystem, category: "PhoneTransport")
    static let phoneService = Logger(subsystem: subsystem, category: "PhoneService")
    static let watchPeer = Logger(subsystem: subsystem, category: "WatchPeer")
    static let watchReceiver = Logger(subsystem: subsystem, category: "WatchReceiver")

    static func errorCode(_ error: any Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain).\(nsError.code)"
    }
}
