import Foundation
import UserNotifications

/// `UNUserNotificationCenterDelegate`: opens the deep link in a tapped notification's `userInfo["url"]`.
/// Hook-up (one line in `WheelhouseApp.init`, after the router/registry exist):
/// `NotificationCoordinator.shared.install { url in router.open(url: url, registry: registry) }`
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()
    private var onOpen: (@MainActor (URL) -> Void)?
    private var pending: URL?

    func install(onOpen: @escaping @MainActor (URL) -> Void) {
        self.onOpen = onOpen
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        AlertNotifier.registerCategories()
        if let url = pending { pending = nil; onOpen(url) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == AlertNotifierIDs.open,
              let string = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: string) else { return }
        await MainActor.run {
            if let onOpen { onOpen(url) } else { pending = url }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

private enum AlertNotifierIDs { static let open = "app.wheelhouse.alert.open" }
