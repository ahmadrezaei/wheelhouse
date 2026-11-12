import AppKit
import Foundation
import notify
import WheelhouseDesktop
import WheelhouseKit

/// A performance scenario fixture (`perf/scenarios/<name>.json`, ARCHITECTURE-MAC §12.3.1), loaded with `-WHPerfScenario <name>`.
/// Honoured ONLY while the safety gate is active (`DevSafetyPolicy.perfScenario`); Distribution builds ignore it.
///
/// M1a applies `hideWindowsAfterSeconds` and `windowAction` (the `hidden` scenarios) and records the rest. The layout fields
/// (`clusters`, `windows`, `tabs`, `panes`) take effect as the workspace arrives (M3 clusters, M4a windows and tabs).
struct PerfScenario: Codable, Equatable {
    var name: String
    var description: String?
    /// Number of cluster contexts the scenario uses (`wh-perf-01` …).
    var clusters: Int
    var windows: Int
    var tabs: Int
    /// Free-form pane layout notes for the workspace loader (M4a).
    var panes: [String]?
    /// Seconds after launch at which every window is closed or miniaturised (menu-bar mode); nil = stay visible.
    var hideWindowsAfterSeconds: Double?
    /// `close` (default) or `minimise`.
    var windowAction: String?
    /// Soak runs: seconds between navigation cycles (default 300). `scripts/perf-sample.sh` reads the same field to measure growth
    /// over whole cycles.
    var cycleSeconds: Double?
    /// `-WHPerfKeepVisible YES`: the workspace window floats on every Space, so a visible scenario measures a window that is really on
    /// screen even while another app is full screen or in front (the sampler checks it). Not part of the fixture file.
    var keepsWindowVisible = false

    private enum CodingKeys: String, CodingKey {
        case name, description, clusters, windows, tabs, panes, hideWindowsAfterSeconds, windowAction, cycleSeconds
    }

    var minimises: Bool { windowAction == "minimise" }

    /// Reads `<directory>/<name>.json`.
    static func load(named name: String, directory: URL) throws -> PerfScenario {
        guard name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        let data = try Data(contentsOf: directory.appending(path: "\(name).json"))
        return try JSONDecoder().decode(PerfScenario.self, from: data)
    }

    /// The scenario requested on the command line and permitted by the gate, with `-WHPerfHideAfter <s>` overriding the hide delay.
    static func requested(arguments: [String] = ProcessInfo.processInfo.arguments, gate: DevSafetyPolicy = .current,
                          info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> PerfScenario? {
        guard let name = gate.perfScenario(arguments: arguments),
              let dir = (info["WHPerfScenarioDirectory"] as? String).flatMap({ $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }),
              var scenario = try? load(named: name, directory: dir) else { return nil }
        if let i = arguments.firstIndex(of: "-WHPerfHideAfter"), arguments.indices.contains(i + 1), let s = Double(arguments[i + 1]) {
            scenario.hideWindowsAfterSeconds = s
        }
        // A pair, like every launch default: AppKit's argument domain would read the next argument as the value of a bare flag.
        let keep = arguments.firstIndex(of: "-WHPerfKeepVisible").map { arguments.indices.contains($0 + 1) && arguments[$0 + 1] == "YES" } ?? false
        scenario.keepsWindowVisible = keep && scenario.hideWindowsAfterSeconds == nil
        return scenario
    }
}

/// Runs the parts of a scenario the app applies itself.
///
/// M1b applies the cluster set (imported from the performance kubeconfig THROUGH `MacImportPolicy`: the same checks as a user
/// import, read-only, environment Development, never `~/.kube`), the sidebar disclosure, the selected screen (the last pane of the
/// scenario that M1b can show), a log follow for scenarios that name one, a 5-minute navigation cycle for soak runs, and hiding.
/// M4a adds windows and tabs (`PerfLayout`); the Deck Terminal arrives with M5b (its pane descriptions are skipped until then).
@MainActor
enum PerfScenarioRunner {
    private(set) static var keepsRunningWithoutWindows = false
    private static var cycle: PeriodicTask?

    /// Before the first window exists (`applicationWillFinishLaunching`): a run that keeps its window visible starts as an accessory
    /// app (only an accessory app's window may join another app's full-screen Space) and floats each workspace window as it appears.
    static func prepare(_ scenario: PerfScenario) {
        guard scenario.keepsWindowVisible else { return }
        NSApp.setActivationPolicy(.accessory)
        // Synchronously, while the window registers (`viewDidMoveToWindow`), before SwiftUI first orders it in: a window first ordered
        // in without the all-Spaces behaviour stays on the Space it was placed on, and a later change does not bring it here.
        WorkspaceWindows.observe(keepVisible)
    }

    static func start(_ scenario: PerfScenario, environment env: MacAppEnvironment?) {
        if let env { applyLayout(scenario, env: env) }
        guard let delay = scenario.hideWindowsAfterSeconds else { return }
        keepsRunningWithoutWindows = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            let windows = NSApp.windows.filter { $0.canBecomeMain && $0.isVisible }
            if scenario.minimises {
                windows.forEach { $0.miniaturize(nil) }
            } else {
                windows.forEach { $0.close() }
                // Menu-bar mode: no Dock icon and no windows (ARCHITECTURE-MAC section 12.1).
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Floats a workspace window above other apps on every Space (performance runs only, `-WHPerfKeepVisible`), without activating
    /// the app or taking the keyboard. Ordered out and in again, so the window server re-homes it with the new behaviour.
    static func keepVisible(_ window: NSWindow) {
        var behavior = window.collectionBehavior
        behavior.remove([.moveToActiveSpace, .fullScreenPrimary, .fullScreenNone])
        behavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.collectionBehavior = behavior
        window.level = .floating
        // A measuring run must not be ended by a stray ⌘M or a click on the yellow button (the verdict would turn to "hidden" and the
        // run would measure a hidden app): performance windows cannot be miniaturised.
        window.styleMask.remove(.miniaturizable)
        window.orderOut(nil)
        window.orderFrontRegardless()
    }

    // MARK: Layout

    /// Imports `scenario.clusters` contexts named `wh-perf-NN` from the explicit kubeconfig and shows the scenario's screen.
    static func applyLayout(_ scenario: PerfScenario, env: MacAppEnvironment) {
        guard let file = KubeconfigDiscoveryPolicy.explicitTestKubeconfig() else { return }
        // The file may sit in a folder macOS protects with a prompt: read and parse it off the main thread, then apply.
        let policy = env.importer.policy
        DispatchQueue.global(qos: .utility).async {
            guard FileManager.default.fileExists(atPath: file.path), let loaded = try? policy.loadFile(file), let kc = try? policy.parse(loaded.text) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { applyLayout(scenario, env: env, kubeconfig: kc, policy: policy) } }
        }
    }

    private static func applyLayout(_ scenario: PerfScenario, env: MacAppEnvironment, kubeconfig kc: Kubeconfig, policy: MacImportPolicy) {
        let registry = env.registry
        // A real (non-Demo) fleet: the scenario measures real sessions, stores and watches.
        if registry.isDemoMode { registry.exitDemoMode() }
        let wanted = kc.contexts.filter { $0.name.hasPrefix("wh-perf-") }.sorted { $0.name < $1.name }.prefix(scenario.clusters)
        var ids: [String: ClusterID] = [:]
        for ctx in wanted where policy.blockedReason(for: ctx) == nil {
            guard var made = ctx.makeClusterConfig() else { continue }
            // Reuse a cluster of the same name. A Moorings cluster (read from the same explicit file) follows the file by itself. A Keychain
            // cluster saved by an earlier run is first brought in line with the file: a test cluster restarted on a new port, CA or user
            // would otherwise leave every run measuring dead connections.
            if let existing = registry.clusters.first(where: { $0.name == ctx.name }) {
                ids[ctx.name] = existing.id
                if existing.origin == nil, let refresh = refreshed(existing, secrets: registry.secrets(for: existing.id), from: made) {
                    try? registry.update(refresh.config, secrets: refresh.secrets)
                }
                continue
            }
            made.config.environment = .development
            made.config.readOnly = true
            made.config.iCloudSync = false
            try? registry.add(made.config, secrets: made.secrets)
            ids[ctx.name] = made.config.id
        }
        guard let first = wanted.first.flatMap({ ids[$0.name] }) else { return }
        registry.select(first)
        let ordered = wanted.compactMap { ctx in ids[ctx.name].map { (name: ctx.name, id: $0) } }
        PerfLayout.apply(scenario, clusters: ordered, workspace: env.workspace)
        if scenario.name.hasPrefix("soak") { startCycle(ids: ids, env: env, cycleSeconds: scenario.cycleSeconds ?? 300) }
        // M11b: `-WHPerfFirstMate YES` replays a 50-turn First Mate conversation over each soak cycle (no network; gate-only).
        if scenario.name.hasPrefix("soak") { FirstMatePerfReplay.startIfRequested(env: env, cycleSeconds: scenario.cycleSeconds ?? 300) }
    }

    /// The saved cluster updated to the context's server, TLS settings and credentials, or nil when it already matches them.
    static func refreshed(_ existing: ClusterConfig, secrets: ClusterSecrets, from made: (config: ClusterConfig, secrets: ClusterSecrets))
        -> (config: ClusterConfig, secrets: ClusterSecrets)? {
        var config = existing
        config.server = made.config.server
        config.authKind = made.config.authKind
        config.skipTLSVerify = made.config.skipTLSVerify
        config.tlsServerName = made.config.tlsServerName
        // The credential fields come from the context; anything else saved with them (keys a newer build wrote) is kept.
        var refreshedSecrets = secrets
        refreshedSecrets.token = made.secrets.token
        refreshedSecrets.clientCertificatePEM = made.secrets.clientCertificatePEM
        refreshedSecrets.clientKeyPEM = made.secrets.clientKeyPEM
        refreshedSecrets.caPEM = made.secrets.caPEM
        guard config != existing || refreshedSecrets != secrets else { return nil }
        return (config, refreshedSecrets)
    }

    /// Soak runs: every cycle the active window opens four tabs (the ConfigMaps list with 2,000 rows, Deployments, Pods and the Fleet),
    /// splits a pane, then closes the tabs and the split again, so stores are released and re-acquired and the tables, panes and
    /// routers are built and torn down, exactly the churn the soak budgets are about. (Compass joins the cycle in M4b.)
    private static func startCycle(ids: [String: ClusterID], env: MacAppEnvironment, cycleSeconds: TimeInterval) {
        guard cycle == nil, let id = ids.sorted(by: { $0.key < $1.key }).first?.value else { return }
        let t = PeriodicTask(name: "perf.cycle", interval: cycleSeconds, hiddenInterval: nil, tolerance: 1) {
            await MainActor.run {
                guard let model = env.workspace.activeModel ?? env.workspace.models.values.first else { return }
                Task { @MainActor in await runCycle(model: model, cluster: id) }
            }
        }
        cycle = t
        t.start()
    }

    static func runCycle(model: WorkspaceWindowModel, cluster id: ClusterID, pause: Duration = .seconds(8)) async {
        let original = model.selectedTab.id
        var opened: [TabID] = []
        for (step, kind) in [ResourceKind.configMap, .deployment, .pod].enumerated() {
            model.openInNewTab(.route(.resourceList(id, kind, namespace: nil)))
            opened.append(model.selectedTab.id)
            CyclePhaseReport.publish(step + 1)
            try? await Task.sleep(for: pause)
        }
        model.openInNewTab(.route(.fleet))
        opened.append(model.selectedTab.id)
        CyclePhaseReport.publish(4)
        if !PerfSwitches.noSplit {
            model.split(.horizontal)
            CyclePhaseReport.publish(5)
            try? await Task.sleep(for: pause / 2)
            if let split = model.selectedTab.panes.last?.id { model.closePane(split) }
        }
        for tab in opened { model.closeTab(tab) }
        model.select(tab: original)
        CyclePhaseReport.publish(0)
    }
}

/// The soak cycle's step as the state of a Darwin notification, so a sampler can align its samples with the cycle (`notifyutil -g`):
/// 1 ConfigMaps opened, 2 Deployments, 3 Pods, 4 Fleet, 5 split, 0 every cycle tab closed again (and before the first cycle). Only
/// scenario runs publish it, and scenarios run only while the safety gate is active.
@MainActor
enum CyclePhaseReport {
    static let name = "com.ahmadrezaei.wheelhouse.perf.cycle-phase"
    private static var token: Int32 = -1

    static func publish(_ step: Int) {
        if token < 0, notify_register_check(name, &token) != 0 { token = -1; return }
        notify_set_state(token, UInt64(step))
        notify_post(name)
    }
}

/// Measurement-only switch for A/B soak runs (`-WHPerfNoSplit YES`: the cycle skips its split), read only by the soak cycle. Honoured only
/// while the safety gate is active, like the scenarios themselves.
enum PerfSwitches {
    static func isOn(_ name: String, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard DevSafety.isActive, let i = arguments.firstIndex(of: name) else { return false }
        return arguments.indices.contains(i + 1) && arguments[i + 1] == "YES"
    }
    static var noSplit: Bool { isOn("-WHPerfNoSplit") }
    /// `-WHPerfCascade YES`: the scenario's windows cascade over each other even where they could sit side by side (the layout
    /// before M4a's close-out, kept to reproduce the overlap A/B recorded in perf/baselines/M4a.json).
    static var cascade: Bool { isOn("-WHPerfCascade") }
}

/// How a scenario's pane list becomes windows and tabs. The single-window, single-tab scenarios (`idle-1`) keep the M1b behaviour: the
/// last pane the app can show wins. Larger scenarios (`busy-10`, `soak-5`) get `windows x tabs` tabs, one pane description each in
/// order (cluster `n` for the n-th tab), padded with cluster overviews when the list is short. Deck Terminal descriptions are
/// skipped until M5b.
@MainActor
enum PerfLayout {
    /// Windows, each a list of the destinations of its tabs.
    static func plan(_ scenario: PerfScenario, clusters: [(name: String, id: ClusterID)]) -> [[WorkspaceDestination]] {
        guard !clusters.isEmpty else { return [] }
        var cursor = 0
        func nextCluster() -> (name: String, id: ClusterID) { defer { cursor += 1 }; return clusters[cursor % clusters.count] }
        let parsed: [WorkspaceDestination] = (scenario.panes ?? []).compactMap { spec in destination(for: spec, clusters: clusters, nextCluster: nextCluster) }
        if scenario.windows <= 1 && scenario.tabs <= 1 { return [[parsed.last ?? .route(.fleet)]] }
        let total = max(1, scenario.windows) * max(1, scenario.tabs)
        var all = Array(parsed.prefix(total))
        while all.count < total { all.append(.route(.cluster(nextCluster().id))) }
        let perWindow = max(1, scenario.tabs)
        return stride(from: 0, to: all.count, by: perWindow).map { Array(all[$0..<min($0 + perWindow, all.count)]) }
    }

    private static func destination(for spec: String, clusters: [(name: String, id: ClusterID)], nextCluster: () -> (name: String, id: ClusterID)) -> WorkspaceDestination? {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let key = parts[0], arg = parts.count > 1 ? parts[1] : ""
        func cluster(named name: String) -> ClusterID? { clusters.first { $0.name == name }?.id }
        switch key {
        case "fleet": return .route(.fleet)
        case "cluster-overview", "overview": return .route(.cluster(cluster(named: arg) ?? nextCluster().id))
        case "pods":
            let ctx = arg.split(separator: "/").first.map(String.init) ?? arg
            return .route(.resourceList(cluster(named: ctx) ?? nextCluster().id, .pod, namespace: nil))
        case "deployments": return .route(.resourceList(cluster(named: arg) ?? nextCluster().id, .deployment, namespace: nil))
        case "configmaps", "configmaps-2000": return .route(.resourceList(cluster(named: arg) ?? nextCluster().id, .configMap, namespace: nil))
        case "logs":
            let id = clusters.sorted { $0.name < $1.name }.first?.id ?? nextCluster().id
            return .route(.logs(ResourceRef(clusterID: id, kind: .pod, namespace: "wh-perf", name: arg), container: nil, previous: false))
        default: return nil          // deck-terminal: M5b
        }
    }

    /// Builds the scenario's windows: the first window is the one that exists. Windows that fit side by side (`tiledFrames`) never
    /// overlap; the others open cascaded (never fully covering each other, so every window counts as visible).
    ///
    /// Why side by side: with two of the app's windows overlapping, the window server charges the app a ~97 MB graphics allocation
    /// ("Owned physical footprint (unmapped) (graphics)") for about a second whenever the front window's content changes, for
    /// example at every 30-second cluster-overview refresh. Opaque materials, the normal window level and the pre-Liquid Glass design
    /// all left it unchanged; non-overlapping windows removed it (perf/baselines/M4a.json, `soakEvidence`).
    static func apply(_ scenario: PerfScenario, clusters: [(name: String, id: ClusterID)], workspace: WorkspaceController) {
        let windows = plan(scenario, clusters: clusters)
        guard !windows.isEmpty else { return }
        let expanded = clusters.prefix(3).map(\.id)
        let firstID = workspace.models.keys.first
        let tiles = PerfSwitches.cascade ? nil : tiledFrames(count: windows.count)
        for (index, destinations) in windows.enumerated() {
            let tabs = destinations.map { TabState(showing: $0) }
            var state = WorkspaceWindowState(tabs: tabs)
            state.sidebar.expandedClusters = Array(expanded)
            if index == 0, let firstID {
                let previous = workspace.store.state(for: firstID)
                state.inspector = previous.inspector
                workspace.store.mutate(firstID) { $0 = state }
                workspace.models[firstID]?.sidebar.restore(state.sidebar.persisted)
                workspace.models[firstID]?.focusedPaneChanged()
                if let tile = tiles?[index] { workspace.models[firstID]?.window?.setFrame(NSRect(x: tile[0], y: tile[1], width: tile[2], height: tile[3]), display: true) }
            } else {
                state.frame = tiles?[index] ?? [Double(80 + index * 60), Double(80 + index * 40), 1_100, 720]
                workspace.newWindow(state)
            }
        }
    }

    /// Side-by-side frames at the top of the main screen, each as wide as the screen allows down to the workspace minimum width
    /// (960 pt), one gap apart; nil when the windows would not fit. On a screen narrower than two minimum-width windows (a 14-inch
    /// MacBook Pro shows 1,512 pt) the last window runs past the right edge, as long as `minimumOnScreen` of it stays on the screen
    /// (it then still counts as visible). Three windows (`busy-10`) do not fit and keep the cascade.
    static func tiledFrames(count: Int, screen: NSRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 88, width: 1_512, height: 861),
                            minimumOnScreen: Double = 400) -> [[Double]]? {
        guard count > 1 else { return nil }
        let gap = 8.0, minimum = 960.0
        let width = max(minimum, (Double(screen.width) - gap * Double(count - 1)) / Double(count))
        let lastX = Double(screen.minX) + Double(count - 1) * (width + gap)
        guard Double(screen.maxX) - lastX >= minimumOnScreen else { return nil }
        let height = min(720.0, Double(screen.height))
        let y = Double(screen.maxY) - height
        return (0..<count).map { [Double(screen.minX) + Double($0) * (width + gap), y, width, height] }
    }
}
