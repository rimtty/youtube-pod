import Foundation
import OSLog
import WatchKit

@MainActor
enum WatchBackgroundSyncScheduler {
    static let identifier = "com.rimtty.YouTubePod.watch-sync-recovery"

    static func schedule(after delay: TimeInterval = 60) {
        let identifier = identifier as NSString
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: max(1, delay)),
            userInfo: identifier
        ) { error in
            if let error {
                WatchSyncLog.watchReceiver.error(
                    "recovery_schedule_failed code=\(WatchSyncLog.errorCode(error), privacy: .public)"
                )
            } else {
                WatchSyncLog.watchReceiver.notice("recovery_scheduled")
            }
        }
    }
}
