import AppKit
import Foundation
import WheelhouseDesktop

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
        return scenario
    }
}

/// Runs the parts of a scenario the app applies itself.
@MainActor
enum PerfScenarioRunner {
    private(set) static var keepsRunningWithoutWindows = false

    static func start(_ scenario: PerfScenario) {
        guard let delay = scenario.hideWindowsAfterSeconds else { return }
        keepsRunningWithoutWindows = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            let windows = NSApp.windows.filter { $0.canBecomeMain && $0.isVisible }
            if scenario.minimises {
                windows.forEach { $0.miniaturize(nil) }
            } else {
                windows.forEach { $0.close() }
                // Menu-bar mode: no Dock icon and no windows (ARCHITECTURE-MAC §12.1).
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
