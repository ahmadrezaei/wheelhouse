import Foundation
import WheelhouseKit

/// The two hooks the app-wide coordinators call (ARCHITECTURE-MAC §12.3.4 item 9, and the lock):
///
/// - `trim()` on a memory-pressure warning or critical event: empties the decoded-release cache and drops each open release's
///   rebuildable state (drift report, finished comparison).
/// - `scrub()` when the app locks: also empties the cache and drops every decoded release from the open detail panes and hides
///   revealed values, because a decoded release holds user values and Secret objects in clear.
enum ChartRoomMemory {
    static let didTrim = Notification.Name("wheelhouse.chartroom.didTrim")
    static let didScrub = Notification.Name("wheelhouse.chartroom.didScrub")

    static func trim() {
        DecodedReleaseCache.shared.removeAll()
        NotificationCenter.default.post(name: didTrim, object: nil)
    }

    static func scrub() {
        DecodedReleaseCache.shared.removeAll()
        NotificationCenter.default.post(name: didScrub, object: nil)
    }
}
