import Foundation
import UserNotifications
import WheelhouseKit

/// Posts local notifications for `AlertPlanner` results. No mutating actions: the only category action is "Open".
/// Preference keys read (App Group defaults, see `AlertKeys`): alertsEnabled, hideAlertDetailsOnLockScreen, alertRuleCrashLoop,
/// alertRuleNodeNotReady, alertRuleJobFailed, alertRuleUnreachable, alertQuietHoursEnabled, alertQuietStartMinutes,
/// alertQuietEndMinutes, alertDisabledClusterIDs.
@MainActor
struct AlertNotifier {
    static let categoryIdentifier = "app.wheelhouse.alert"
    static let openActionIdentifier = "app.wheelhouse.alert.open"

    /// Registers the notification category. Called by `NotificationCoordinator.install`.
    static func registerCategories() {
        let open = UNNotificationAction(identifier: openActionIdentifier, title: "Open", options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryIdentifier, actions: [open], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Call from the Settings "Alerts" toggle when it turns on. Prompts only if permission was never asked. Returns whether alerts can be delivered.
    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Evaluates the rules against fresh health, posts new alerts, clears recovered ones and persists de-dupe state.
    static func process(health: [ClusterHealth], clusters: [ClusterConfig], now: Date = Date()) async {
        let defaults = AppGroup.defaults
        let settings = AlertSettings.load(from: defaults)
        let state = AlertState.load(from: defaults)
        let plan = AlertPlanner.plan(health: health,
                                     clusterNames: Dictionary(clusters.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
                                     environments: Dictionary(clusters.map { ($0.id, $0.environment) }, uniquingKeysWith: { a, _ in a }),
                                     settings: settings, state: state, now: now)
        let center = UNUserNotificationCenter.current()
        if !plan.resolved.isEmpty { center.removeDeliveredNotifications(withIdentifiers: Array(plan.resolved)) }
        var newState = plan.newState
        // Summary notifications have unique identifiers, so they are never "resolved" by fingerprint: replace them with the
        // new summary, or clear them once nothing is left to notify about.
        if plan.isSummary || newState.notified.isEmpty {
            let stale = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix("summary|") }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
        if !plan.toPost.isEmpty {
            let authorised = await authorizationStatus()
            if authorised == .authorized || authorised == .provisional || authorised == .ephemeral {
                for c in plan.toPost { await post(c) }
            } else {
                // Can't deliver: don't mark as notified so they fire once permission is granted.
                for c in plan.toPost { newState.notified[c.fingerprint] = nil }
            }
        }
        newState.save(to: defaults)
    }

    static func post(_ c: AlertCandidate) async {
        let content = UNMutableNotificationContent()
        content.title = c.title
        content.body = c.body
        content.threadIdentifier = c.isSummaryLike ? "fleet" : c.clusterID
        content.categoryIdentifier = categoryIdentifier
        content.interruptionLevel = switch c.level { case .timeSensitive: .timeSensitive; case .active: .active; case .passive: .passive }
        content.sound = c.level == .passive ? nil : .default
        if let url = c.url { content.userInfo = ["url": url.absoluteString] }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: c.fingerprint, content: content, trigger: nil))
    }
}

private extension AlertCandidate {
    var isSummaryLike: Bool { fingerprint.hasPrefix("summary|") || rule == .unreachable }
}
