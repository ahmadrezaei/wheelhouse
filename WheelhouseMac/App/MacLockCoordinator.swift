import AppKit
import Foundation
import Observation
import WheelhouseKit

/// App lock for the Mac (ARCHITECTURE-MAC section 1.6 row 2). It reuses the shared `AppLockController` (state, Touch ID or password
/// through `LAPolicy.deviceOwnerAuthentication`, "reveal once per session" reset) and adds what only the Mac has:
///
/// - locking after the timeout when the app was deactivated (the iOS timeout options, 0 = as soon as the app is deactivated);
/// - locking on **sleep** (`NSWorkspace.willSleepNotification`) and when the **screen locks** (`com.apple.screenIsLocked`),
///   each switchable in Settings and on by default;
/// - **Lock Wheelhouse** (Wheelhouse menu, no default shortcut: ⌥⌘L is Previous Logs);
/// - coverage: `MacShell` draws `LockScreenView` over the workspace, disables the workspace and hides it from accessibility,
///   resigns the first responder of every window, closes the Settings window and dismisses sheets; the File, View and Go
///   commands are disabled (Lock and Quit stay). A file that arrives while locked is held until unlock.
///
/// The cold launch with App Lock on starts locked, so no content is ever drawn first.
@MainActor @Observable
final class MacLockCoordinator {
    /// The shared lock state; the lock screen view reads it from the environment.
    let controller: AppLockController
    var isLocked: Bool { controller.isLocked }

    @ObservationIgnored private var preferences: AppPreferences?
    @ObservationIgnored private var macPreferences: MacPreferences?
    @ObservationIgnored private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(locked: Bool = false) { controller = AppLockController(locked: locked) }

    /// Starts observing. Idempotent.
    func start(preferences: AppPreferences, macPreferences: MacPreferences) {
        guard tokens.isEmpty else { return }
        self.preferences = preferences
        self.macPreferences = macPreferences
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (MacLockCoordinator) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { handler(self) } }
            }
            tokens.append((center, token))
        }
        observe(.default, NSApplication.didResignActiveNotification) { me in
            if let p = me.preferences { me.controller.appDidEnterBackground(preferences: p) }
        }
        observe(.default, NSApplication.didBecomeActiveNotification) { me in
            if let p = me.preferences { me.controller.appDidBecomeActive(preferences: p) }
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { me in
            if me.macPreferences?.lockOnSleep == true { me.lockIfEnabled() }
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { me in
            if me.macPreferences?.lockOnScreenLock == true { me.lockIfEnabled() }
        }
    }

    func stop() {
        tokens.forEach { $0.center.removeObserver($0.token) }
        tokens = []
    }

    private func lockIfEnabled() {
        guard let preferences, preferences.appLockEnabled else { return }
        controller.lockNow()
    }

    /// Wheelhouse ▸ Lock Wheelhouse. A no-op until App Lock is turned on in Settings.
    func lockNow() { lockIfEnabled() }

    /// Whether the menu item can lock right now.
    var canLock: Bool { preferences?.appLockEnabled == true && !isLocked }
}
