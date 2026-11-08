import XCTest

/// The performance harness (ARCHITECTURE-MAC section 12.3.5), run through the `WheelhouseMacPerf` scheme in the **Profile**
/// configuration (optimised, Debug identity, safety gate on, no test hooks). `scripts/perf-check.sh --xcresult <path>` compares
/// the result with `perf/budgets.json` and the previous baseline.
///
/// SAFETY: the app under test is the Profile build next to this runner, never an installed copy. It starts with the Demo Fleet
/// (M1a) or with `.testcluster/perf-kubeconfig` (the test cluster only); it cannot reach `~/.kube` or the shared keychain group.
final class WheelhouseMacPerfTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The Wheelhouse.app that was built next to this bundle (walks up from the test bundle until it finds it).
    private func appURL() throws -> URL {
        var dir = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let candidate = dir.appending(path: "Wheelhouse.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("Wheelhouse.app was not found next to the test bundle")
    }

    private var repoRoot: URL {
        // #filePath is <repo>/WheelhouseMacPerfTests/WheelhouseMacPerfTests.swift
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func makeApp(scenario: String) throws -> XCUIApplication {
        let app = XCUIApplication(url: try appURL())
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WHPerfScenario", scenario, "-WHKubeconfigPath", repoRoot.appending(path: ".testcluster/perf-kubeconfig").path]
        return app
    }

    private var options: XCTMeasureOptions {
        let o = XCTMeasureOptions()
        o.iterationCount = 5
        return o
    }

    /// Cold launch to a responsive window, 5 iterations. Budget: p90 <= 1.0 s (`perf/budgets.json`, `testLaunch`).
    ///
    /// `XCTApplicationLaunchMetric` records no measurements for a macOS app in the result bundle, so each launch is also timed by hand:
    /// from `launch()` (which returns when the app is running and idle) until its window exists. That includes about a second of
    /// XCUITest accessibility and automation setup, so it is informational (a `WHLAUNCH_XCUI_RUNS [...]` line); the budgeted number is
    /// `scripts/perf-launch.swift` (launch to on-screen window, no automation).
    @MainActor
    func testLaunch() throws {
        let app = try makeApp(scenario: "idle-1")
        var runs: [Double] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
            runs.append(ProcessInfo.processInfo.systemUptime - start)
            app.terminate()
        }
        let data = try JSONSerialization.data(withJSONObject: runs.map { ($0 * 1000).rounded() / 1000 })
        print("WHLAUNCH_XCUI_RUNS \(String(decoding: data, as: UTF8.self))")
        // XCTest terminates the app between iterations itself; terminating inside the block would void the measurement.
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
        }
        app.terminate()
    }

    /// `idle-1`: launch, wait 60 s, then measure CPU and memory over a 60 s idle block.
    func testIdleOneWindow() throws {
        let app = try makeApp(scenario: "idle-1")
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 60)
        let o = XCTMeasureOptions(); o.iterationCount = 1
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: o) {
            Thread.sleep(forTimeInterval: 60)
        }
    }

    // The tests below arrive with the features they measure. Their signposts and scenarios are declared in
    // perf/scenarios and DESIGN-MAC section 14; until then they skip, so the harness runs end to end.

    func testBusyTen() throws { throw XCTSkip("busy-10 needs the multi-window workspace (M4a)") }
    func testCompassOpen() throws { throw XCTSkip("Compass arrives in M4b") }
    func testTableLoad2000() throws { throw XCTSkip("KubeTable arrives in M1b") }
    func testSidebarFilter() throws { throw XCTSkip("the sidebar tree arrives in M1b") }
}
