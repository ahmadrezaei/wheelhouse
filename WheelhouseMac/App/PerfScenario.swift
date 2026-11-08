import AppKit
import Foundation
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
    /// `-WHPerfKeepVisible`: the workspace window floats on every Space, so a visible scenario measures a window that is really on
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
        scenario.keepsWindowVisible = arguments.contains("-WHPerfKeepVisible") && scenario.hideWindowsAfterSeconds == nil
        return scenario
    }
}

/// Runs the parts of a scenario the app applies itself.
///
/// M1b applies the cluster set (imported from the performance kubeconfig THROUGH `MacImportPolicy`: the same checks as a user
/// import, read-only, environment Development, never `~/.kube`), the sidebar disclosure, the selected screen (the last pane of the
/// scenario that M1b can show), a log follow for scenarios that name one, a 5-minute navigation cycle for soak runs, and hiding.
/// Tabs, splits, windows and the Deck Terminal arrive with M4a and M5b.
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
        env.sidebar.focus(cluster: first)
        for pane in scenario.panes ?? [] { apply(pane: pane, ids: ids, env: env) }
        if scenario.name.hasPrefix("soak") { startCycle(ids: ids, env: env, cycleSeconds: scenario.cycleSeconds ?? 300) }
    }

    /// The saved cluster updated to the context's server, TLS settings and credentials, or nil when it already matches them.
    static func refreshed(_ existing: ClusterConfig, secrets: ClusterSecrets, from made: (config: ClusterConfig, secrets: ClusterSecrets))
        -> (config: ClusterConfig, secrets: ClusterSecrets)? {
        var config = existing
        config.server = made.config.server
        config.authKind = made.config.authKind
        config.skipTLSVerify = made.config.skipTLSVerify
        config.tlsServerName = made.config.tlsServerName
        // Compare the credential fields only (unknown keys a newer build wrote are not part of the context).
        let current = ClusterSecrets(token: secrets.token, clientCertificatePEM: secrets.clientCertificatePEM,
                                     clientKeyPEM: secrets.clientKeyPEM, caPEM: secrets.caPEM)
        guard config != existing || current != made.secrets else { return nil }
        return (config, made.secrets)
    }

    /// One pane description of a scenario, as far as M1b can show it. Later panes replace earlier ones (one window, one screen).
    private static func apply(pane: String, ids: [String: ClusterID], env: MacAppEnvironment) {
        let parts = pane.split(separator: ":", maxSplits: 1).map(String.init)
        let key = parts[0], arg = parts.count > 1 ? parts[1] : ""
        switch key {
        case "fleet": env.navigation.selection = .fleet
        case "cluster-overview":
            if let id = ids[arg] { env.navigation.selection = .clusterOverview(id) }
        case "pods":
            let ctx = arg.split(separator: "/").first.map(String.init) ?? arg
            if let id = ids[ctx] { env.navigation.selection = .kind(id, .pod) }
        case "logs":
            if let id = ids.sorted(by: { $0.key < $1.key }).first?.value {
                env.launchRoutes.append(.logs(ResourceRef(clusterID: id, kind: .pod, namespace: "wh-perf", name: arg), container: nil, previous: false))
                env.navigation.selection = .kind(id, .pod)
            }
        default: break
        }
    }

    /// Soak runs: every 5 minutes the content column visits the ConfigMaps (2,000 rows), Deployments and Pods lists and returns,
    /// so stores are released and re-acquired and the tables rebuilt, exactly the churn the soak budgets are about.
    private static func startCycle(ids: [String: ClusterID], env: MacAppEnvironment, cycleSeconds: TimeInterval) {
        guard cycle == nil, let id = ids.sorted(by: { $0.key < $1.key }).first?.value else { return }
        let t = PeriodicTask(name: "perf.cycle", interval: cycleSeconds, hiddenInterval: nil, tolerance: 1) {
            await MainActor.run {
                let start = env.navigation.selection
                Task { @MainActor in
                    for kind in [ResourceKind.configMap, .deployment, .pod] {
                        env.navigation.selection = .kind(id, kind)
                        try? await Task.sleep(for: .seconds(8))
                    }
                    env.navigation.selection = start
                }
            }
        }
        cycle = t
        t.start()
    }
}
