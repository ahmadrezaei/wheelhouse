import Testing
import AppKit
import Foundation
import WheelhouseKit
@testable import WheelhouseMac

/// App lock on the Mac: the triggers only lock when App Lock is on, and each Mac trigger can be switched off.
@Suite("Lock coordinator")
@MainActor
struct LockCoordinatorTests {
    private func make(lockEnabled: Bool, sleepOn: Bool = true, screenOn: Bool = true, timeout: LockTimeout = .immediately) -> MacLockCoordinator {
        let suite = "wh.lock.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prefs = AppPreferences(defaults: defaults)
        prefs.appLockEnabled = lockEnabled
        prefs.lockTimeout = timeout
        let mac = MacPreferences(defaults: defaults)
        mac.lockOnSleep = sleepOn
        mac.lockOnScreenLock = screenOn
        let c = MacLockCoordinator(locked: false)
        c.start(preferences: prefs, macPreferences: mac)
        Self.keep.append((prefs, mac))
        return c
    }

    private static var keep: [(AppPreferences, MacPreferences)] = []

    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

    private func sleepNow() { NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil) }

    private func screenLock() {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.apple.screenIsLocked"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    @Test func coldLaunchWithLockOnStartsLocked() {
        #expect(MacLockCoordinator(locked: true).isLocked)
        #expect(!MacLockCoordinator(locked: false).isLocked)
    }

    @Test func sleepLocksWhenEnabled() async {
        let c = make(lockEnabled: true)
        sleepNow()
        await settle()
        #expect(c.isLocked)
        c.stop()
    }

    @Test func screenLockLocksWhenEnabled() async {
        let c = make(lockEnabled: true)
        screenLock()
        await settle()
        #expect(c.isLocked)
        c.stop()
    }

    @Test func nothingLocksWithoutAppLock() async {
        let c = make(lockEnabled: false)
        sleepNow(); screenLock(); c.lockNow()
        await settle()
        #expect(!c.isLocked && !c.canLock)
        c.stop()
    }

    @Test func eachMacTriggerCanBeSwitchedOff() async {
        let c = make(lockEnabled: true, sleepOn: false, screenOn: false)
        sleepNow(); screenLock()
        await settle()
        #expect(!c.isLocked)
        c.lockNow()                                    // Lock Wheelhouse always works while App Lock is on
        #expect(c.isLocked)
        c.stop()
    }

    @Test func deactivationLocksImmediatelyOrAfterTheTimeout() async {
        let now = make(lockEnabled: true, timeout: .immediately)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        await settle()
        #expect(now.isLocked)
        now.stop()
        let later = make(lockEnabled: true, timeout: .fiveMinutes)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        #expect(!later.isLocked)                       // back inside the 5 minute grace
        later.stop()
    }
}
