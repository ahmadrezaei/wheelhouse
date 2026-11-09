import AppKit
import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

@main
struct WheelhouseMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var env: MacAppEnvironment

    init() {
        // The gate is evaluated first, inside `live()`, before any store, client or watcher exists.
        let env = MacAppEnvironment.live()
        _env = State(initialValue: env)
        MacAppDelegate.environment = env
        NSWindow.allowsAutomaticWindowTabbing = false
        #if WH_TEST_HOOKS
        WHTestHooks.installIfRequested()
        #endif
    }

    var body: some Scene {
        // One window per `WorkspaceWindowID`, with its state in `WorkspaceStore` (M4a). The workspace restores its own windows
        // after launch (`WorkspaceController.restoreRemainingWindows`), so SwiftUI/AppKit restoration is switched off; URLs and
        // files are handled by the app delegate, so a link never opens a window by itself.
        WindowGroup("Wheelhouse", id: "workspace", for: WorkspaceWindowID.self) { $id in
            MacShell(windowID: id)
                .environment(env)
                .environment(\.gitOpsOwnership, GitOpsOwnershipDetector())   // M9: fills the ownership badge slots
                .task { _ = EnergyMonitor.shared }   // follow Low Power Mode and the thermal state
        } defaultValue: {
            env.workspace.store.launchWindowID()
        }
        .defaultSize(width: 1_280, height: 780)
        .restorationBehavior(.disabled)
        .commands { MacCommands(env: env) }
        // A pane torn off into its own window.
        WindowGroup("Pane", id: "pane", for: PaneID.self) { $id in
            if let id {
                DetachedPaneWindow(paneID: id)
                    .environment(env)
                    .environment(\.gitOpsOwnership, GitOpsOwnershipDetector())
            }
        }
        .defaultSize(width: 720, height: 520)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])
        Window("Activity", id: "activity") {
            LockableActivity(env: env)
        }
        .restorationBehavior(.disabled)
        Settings {
            LockableSettings(env: env)
        }
    }
}

/// The Activity window: covered by the lock screen like every other window.
private struct LockableActivity: View {
    let env: MacAppEnvironment

    var body: some View {
        let locked = env.lock.isLocked
        ZStack {
            ActivityView()
                .environment(env)
                .environment(env.registry)
                .disabled(locked)
                .accessibilityHidden(locked)
            if locked { LockScreenView().environment(env.lock.controller).transition(.identity) }
        }
    }
}

/// The Settings window's content. While App Lock is on it is disabled, hidden from accessibility and covered by the lock screen,
/// like the workspace window, so ⌘, cannot reach cluster settings or Test Connection.
private struct LockableSettings: View {
    let env: MacAppEnvironment

    var body: some View {
        let locked = env.lock.isLocked
        ZStack {
            MacSettingsView()
                .environment(\.clusterClientFactory, env.clientFactory)
                .environment(\.clusterChangeAllowing, env.moorings.service)
                .disabled(locked)
                .accessibilityHidden(locked)
            if locked {
                LockScreenView().transition(.identity)
            }
        }
        .environment(env)
        .environment(env.registry)
        .environment(env.preferences)
        .environment(env.lock.controller)
    }
}

/// Activation policy, reopen, file opening and termination (ARCHITECTURE-MAC section 12.1). Gangway, Beacon and PTY teardown join
/// in later milestones.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var environment: MacAppEnvironment?

    @MainActor func applicationWillFinishLaunching(_ notification: Notification) {
        if let scenario = PerfScenario.requested() { PerfScenarioRunner.prepare(scenario) }
    }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        MacUpdater.shared.start()   // starts Sparkle only when the feed is set and the safety gate is off
        // Performance scenarios (`-WHPerfScenario <name>`) are honoured only while the safety gate is active.
        let env = Self.environment
        env?.start()
        if let scenario = PerfScenario.requested() {
            if let env { env.whenReady { PerfScenarioRunner.start(scenario, environment: env) } } else { PerfScenarioRunner.start(scenario, environment: nil) }
        }
    }

    /// Finder "Open With" and double-click on a kubeconfig, and `wheelhouse://` links (the only path for both: no scene handles them).
    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        guard let env = Self.environment else { return }
        for url in urls {
            if url.isFileURL {
                if MacImportCoordinator.isImportable(url) { env.importer.import(url: url, whileLocked: env.lock.isLocked); break }
            } else if DeepLink.isImport(url) {
                env.importer.presentOpenPanel(whileLocked: env.lock.isLocked)
            } else if env.lock.isLocked {
                env.workspace.pendingURL = url      // replayed after unlock
            } else {
                env.workspace.handle(url: url)
            }
        }
    }

    /// Quit: the windows closing during termination must not delete their state, and the workspace is written before the process ends.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let env = Self.environment {
            env.workspace.syncSidebarState()
            env.workspace.store.isTerminating = true
            env.workspace.store.flush()
            env.activity.flush()
        }
        return .terminateNow
    }

    @MainActor func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !PerfScenarioRunner.keepsRunningWithoutWindows
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A copied secret must not outlive the app.
        Pasteboard.clearSensitiveIfUnchanged()
        // The shutdown audits of Gangway, Landfall and the scanner run in `willTerminate` observers, after `applicationShouldTerminate`:
        // flush once more so none of them is lost.
        MainActor.assumeIsolated { MacAppDelegate.environment?.activity.flush() }
    }
}
