import SwiftUI
import UIKit
import Observation
import WheelhouseKit
import WheelhouseUI

/// Puts the app-lock screen and the app-switcher privacy cover in a dedicated overlay `UIWindow` per `UIWindowScene`,
/// at `windowLevel = .alert + 1`. A SwiftUI overlay inside the content cannot cover sheets (they are separate UIKit modals);
/// a window above everything does, in every scene (including iPad multi-window).
///
/// - Visible while `AppLockController.isLocked`.
/// - Visible while a scene is inactive (`sceneWillResignActive`) when "Hide in App Switcher" or App Lock is on,
///   so the switcher snapshot never shows content.
@MainActor
final class LockWindowManager {
    static let shared = LockWindowManager()

    private final class Entry {
        let window: UIWindow
        var covered = false
        init(window: UIWindow) { self.window = window }
    }

    private var lock: AppLockController?
    private var preferences: AppPreferences?
    private var registry: ClusterRegistry?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var observers: [NSObjectProtocol] = []
    private(set) var isConfigured = false

    /// Call once from `WheelhouseApp.init`.
    func configure(lock: AppLockController, preferences: AppPreferences, registry: ClusterRegistry) {
        self.lock = lock
        self.preferences = preferences
        self.registry = registry
        guard !isConfigured else { return }
        isConfigured = true
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (LockWindowManager, UIWindowScene?) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                let scene = note.object as? UIWindowScene
                MainActor.assumeIsolated { handler(LockWindowManager.shared, scene) }
            }
            observers.append(token)
        }
        observe(UIScene.willConnectNotification) { m, scene in if let s = scene { m.attach(s) } }
        observe(UIScene.didDisconnectNotification) { m, scene in if let s = scene { m.detach(s) } }
        observe(UIScene.willDeactivateNotification) { m, scene in if let s = scene { m.setCovered(true, for: s) } }
        observe(UIScene.didActivateNotification) { m, scene in
            // Evaluate the lock BEFORE the cover comes off so there is no frame of unlocked content.
            if let p = m.preferences { m.lock?.appDidBecomeActive(preferences: p) }
            if let s = scene { m.setCovered(false, for: s) }
        }
        observe(UIApplication.didEnterBackgroundNotification) { m, _ in
            if let p = m.preferences { m.lock?.appDidEnterBackground(preferences: p) }
            m.syncAll()
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes { attach(scene) }
        trackLock()
    }

    // MARK: Scenes

    private func attach(_ scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard entries[key] == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level.alert + 1
        window.backgroundColor = .clear
        window.isHidden = true
        let entry = Entry(window: window)
        entries[key] = entry
        // A scene that connects while inactive (cold launch, state restoration) starts covered.
        entry.covered = scene.activationState != .foregroundActive && coverEnabled
        sync(entry, scene: scene)
    }

    private func detach(_ scene: UIWindowScene) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(scene)) else { return }
        entry.window.isHidden = true
        entry.window.rootViewController = nil
    }

    private var coverEnabled: Bool { (preferences?.hideInAppSwitcher ?? true) || (preferences?.appLockEnabled ?? false) }

    private func setCovered(_ covered: Bool, for scene: UIWindowScene) {
        guard let entry = entries[ObjectIdentifier(scene)] else { attach(scene); return }
        entry.covered = covered && coverEnabled
        sync(entry, scene: scene)
    }

    private func syncAll() {
        for (_, entry) in entries { if let scene = entry.window.windowScene { sync(entry, scene: scene) } }
    }

    private func trackLock() {
        guard let lock else { return }
        withObservationTracking { _ = lock.isLocked } onChange: { [weak self] in
            Task { @MainActor in self?.syncAll(); self?.trackLock() }
        }
    }

    // MARK: Visibility

    private func sync(_ entry: Entry, scene: UIWindowScene) {
        let locked = lock?.isLocked ?? false
        let shouldShow = locked || entry.covered
        let window = entry.window
        if shouldShow {
            if window.isHidden || window.rootViewController == nil {
                guard let lock, let preferences, let registry else { return }
                let host = UIHostingController(rootView: LockOverlayContent()
                    .environment(lock).environment(preferences).environment(registry))
                host.view.backgroundColor = .clear
                host.view.accessibilityViewIsModal = true
                window.rootViewController = host
                window.isHidden = false
                window.makeKey()
                window.layoutIfNeeded()
            }
        } else if !window.isHidden {
            window.isHidden = true
            window.rootViewController = nil
            // Give key status back to the app's window.
            scene.windows.first { $0 !== window && !$0.isHidden && $0.windowLevel < window.windowLevel }?.makeKey()
        }
    }

    /// For tests/diagnostics.
    func isShowingOverlay(in scene: UIWindowScene) -> Bool { entries[ObjectIdentifier(scene)].map { !$0.window.isHidden } ?? false }
}

/// What the overlay window shows: the lock screen while locked, otherwise the opaque privacy cover.
private struct LockOverlayContent: View {
    @Environment(AppLockController.self) private var lock

    var body: some View {
        if lock.isLocked { LockScreenView() } else { PrivacyCover() }
    }
}

/// Hides content in the App Switcher. Opaque on purpose: a blur still leaks layout and colours.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Palette.navy
            Image("wheelhouse.helm").resizable().scaledToFit().frame(width: 72, height: 72).foregroundStyle(Palette.seafoam)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
