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
        _env = State(initialValue: MacAppEnvironment.live())
        NSWindow.allowsAutomaticWindowTabbing = false
        #if WH_TEST_HOOKS
        WHTestHooks.installIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup("Wheelhouse", id: "workspace") {
            MacSceneRoot()
                .environment(env)
                .task { _ = EnergyMonitor.shared }   // follow Low Power Mode and the thermal state
        }
        .commands { MacCommands() }
        Settings {
            MacSettingsView().environment(env)
        }
    }
}

/// Activation policy, reopen and termination (ARCHITECTURE-MAC §12.1). Gangway, Beacon and PTY teardown join in later milestones.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // Performance scenarios (`-WHPerfScenario <name>`) are honoured only while the safety gate is active.
        if let scenario = PerfScenario.requested() { PerfScenarioRunner.start(scenario) }
    }

    @MainActor func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !PerfScenarioRunner.keepsRunningWithoutWindows
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A copied secret must not outlive the app.
        Pasteboard.clearSensitiveIfUnchanged()
    }
}
