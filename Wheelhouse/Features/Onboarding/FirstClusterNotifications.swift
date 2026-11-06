import UserNotifications
import WheelhouseKit

/// Asks for notification permission at a meaningful moment: right after the first real cluster is added, when alerts are on
/// and the system has never been asked. (Settings → Alerts asks again when the user turns alerts on.)
@MainActor
enum FirstClusterNotifications {
    static func requestIfNeeded(preferences: AppPreferences) async {
        guard preferences.alertsEnabled else { return }
        guard await AlertNotifier.authorizationStatus() == .notDetermined else { return }
        await AlertNotifier.requestAuthorizationIfNeeded()
    }
}
