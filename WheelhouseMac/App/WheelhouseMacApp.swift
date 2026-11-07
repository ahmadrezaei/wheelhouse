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
        // One workspace window in M1b. `Window` (not `WindowGroup`) keeps it single; M4a switches to a window group with state.
        Window("Wheelhouse", id: "workspace") {
            MacShell()
                .environment(env)
                .task { _ = EnergyMonitor.shared }   // follow Low Power Mode and the thermal state
        }
        .defaultSize(width: 1_280, height: 780)
        .commands { MacCommands(env: env) }
        Settings {
            MacSettingsView().environment(env).environment(env.registry).environment(env.preferences)
        }
    }
}

/// Activation policy, reopen, file opening and termination (ARCHITECTURE-MAC section 12.1). Gangway, Beacon and PTY teardown join
/// in later milestones.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var environment: MacAppEnvironment?

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // Performance scenarios (`-WHPerfScenario <name>`) are honoured only while the safety gate is active.
        if let scenario = PerfScenario.requested() { PerfScenarioRunner.start(scenario, environment: Self.environment) }
    }

    /// Finder "Open With" and double-click on a kubeconfig, and `wheelhouse://` links.
    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        guard let env = Self.environment else { return }
        for url in urls where url.isFileURL && MacImportCoordinator.isImportable(url) {
            env.importer.import(url: url, whileLocked: env.lock.isLocked)
            break
        }
    }

    @MainActor func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !PerfScenarioRunner.keepsRunningWithoutWindows
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A copied secret must not outlive the app.
        Pasteboard.clearSensitiveIfUnchanged()
    }
}
