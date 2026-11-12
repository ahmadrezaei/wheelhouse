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
        // M4b: Crow's Nest. The item is inserted while the preference is on; dragging it out of the menu bar (⌘-drag) switches the
        // preference off, which would leave a menu-bar-only app with nothing to click, so the app then shows a window.
        MenuBarExtra(isInserted: Binding(get: { env.macPreferences.showsCrowsNest }, set: { inserted in
            guard !inserted, env.macPreferences.showsCrowsNest else { return }
            env.macPreferences.showsCrowsNest = false
            Task { @MainActor in env.showWorkspace() }
        })) {
            CrowsNestPanel(env: env)
        } label: {
            CrowsNestLabel(env: env)
        }
        .menuBarExtraStyle(.window)
        // end M4b
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
                if env.workspace.activeModel == nil { env.showWorkspace() }   // menu-bar mode: a window with the lock screen
            } else {
                env.workspace.handle(url: url)
            }
        }
    }

    /// Quit: the windows closing during termination must not delete their state, and the workspace is written before the process ends.
    /// A pane with an unapplied editor draft asks first, outside this call (`terminateLater`), so logout and restart wait for the answer.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let env = Self.environment else { return .terminateNow }
        let dirty = env.workspace.panesWithUnsavedEdits
        guard dirty > 0 else { Self.prepareForTermination(env); return .terminateNow }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let quit = env.workspace.confirmsDiscardingEdits(dirty, .quit)
                if quit { Self.prepareForTermination(env) }
                NSApp.reply(toApplicationShouldTerminate: quit)
            }
        }
        return .terminateLater
    }

    @MainActor static func prepareForTermination(_ env: MacAppEnvironment) {
        env.workspace.syncSidebarState()
        env.workspace.store.isTerminating = true
        env.activationPolicy.isTerminating = true
        env.frecency.flush()
        env.workspace.store.flush()
        // From here on every activity record is written before `record` returns: the `willTerminate` observers (Gangway's revoked
        // sessions, Landfall, the scanner) may record after the delegate's own last flush.
        env.activity.beginTermination()
    }

    @MainActor func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // M4b: with Crow's Nest on and "keep running" chosen, closing the last window leaves the menu bar item running.
        let keeps = Self.environment.map { $0.macPreferences.showsCrowsNest && $0.macPreferences.keepsRunningInMenuBar } ?? false
        return !PerfScenarioRunner.keepsRunningWithoutWindows && !keeps
    }

    /// M4b: a click on the Dock icon, or the app opened again from Finder, with no window: open one (the last one's state comes back).
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let env = Self.environment else { return true }
        env.showWorkspace()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A copied secret must not outlive the app.
        Pasteboard.clearSensitiveIfUnchanged()
        // The shutdown audits of Gangway, Landfall and the scanner run in `willTerminate` observers, in no fixed order relative to
        // this method: `beginTermination` (already called by `applicationShouldTerminate` on a normal quit) makes their records
        // synchronous, so each is written before its observer returns, whichever runs first.
        MainActor.assumeIsolated { MacAppDelegate.environment?.activity.beginTermination() }
    }
}
