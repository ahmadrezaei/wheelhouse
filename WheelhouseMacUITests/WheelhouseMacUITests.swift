import XCTest

/// UI automation for the Mac shell (ARCHITECTURE-MAC section 13.4). Demo flows run with `-WHDemoMode` (no network); the test-cluster
/// flows import `.testcluster/kubeconfig` through the real import sheet.
///
/// SAFETY: the app under test is the Debug build next to this runner (bundle ID `…mac.debug`, safety gate on). It only ever reads the
/// test kubeconfig, never `~/.kube`, and its keychain group cannot see the shared iCloud items.
@MainActor
final class WheelhouseMacUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func appURL() throws -> URL {
        var dir = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let candidate = dir.appending(path: "Wheelhouse.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("Wheelhouse.app was not found next to the test bundle")
    }

    private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication(url: try appURL())
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO", "-WHKubeconfigPath", repoRoot.appending(path: ".testcluster/kubeconfig").path] + extra
        app.launch()
        addTeardownBlock { app.terminate() }
        let found = app.windows.firstMatch.waitForExistence(timeout: 30)
        if !found { dump(app, "no-window-tree"); print("APP STATE", app.state.rawValue, app.debugDescription) }
        XCTAssertTrue(found, "no window")
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func dump(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testBundleLoads() { XCTAssertTrue(true) }

    private func cell(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.outlines["sidebar.tree"].cells.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func expand(_ app: XCUIApplication, _ prefix: String) {
        let c = cell(app, prefix)
        XCTAssertTrue(c.waitForExistence(timeout: 15), "\(prefix) row missing")
        let t = c.disclosureTriangles.firstMatch
        if t.exists, (t.value as? Int) == 0 || (t.value as? String) == "0" { t.click() }
    }

    /// The Demo Fleet shell: the sidebar outline, expansion, and the resource table behind a kind.
    func testDemoShellAnatomy() throws {
        let app = try launch(["-WHDemoMode"])
        let outline = app.outlines["sidebar.tree"]
        XCTAssertTrue(outline.waitForExistence(timeout: 20), "sidebar outline missing")
        for top in ["Search", "Fleet", "Alerts", "Sessions"] { XCTAssertTrue(cell(app, top).exists, top) }
        expand(app, "Workloads")
        let pods = cell(app, "Pods")
        XCTAssertTrue(pods.waitForExistence(timeout: 10), "Pods row missing")
        pods.click()
        let table = app.tables["Resources"]
        XCTAssertTrue(table.waitForExistence(timeout: 20), "resource table missing")
        XCTAssertTrue(table.tableRows.firstMatch.waitForExistence(timeout: 20), "no rows")
        XCTAssertGreaterThan(table.tableRows.count, 0)
        attach(app, "demo-pods-table")
        dump(app, "demo-pods-tree")
        // Keyboard: Return on a row opens its detail on the right.
        table.tableRows.firstMatch.click()
        app.typeKey(.return, modifierFlags: [])
        sleep(2)
        attach(app, "demo-pod-detail-return")
        table.tableRows.element(boundBy: 2).doubleClick()
        sleep(2)
        attach(app, "demo-pod-detail")
        dump(app, "demo-after-detail-tree")
        // Filter finds a kind by its short name.
        let filter = app.textFields["sidebar.filter"]
        filter.click(); filter.typeText("deploy")
        XCTAssertTrue(cell(app, "Deployments").waitForExistence(timeout: 5))
        attach(app, "demo-filter")
    }

    func testSettingsOpens() throws {
        let app = try launch(["-WHDemoMode"])
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title CONTAINS 'General' OR title CONTAINS 'Settings'")).firstMatch.waitForExistence(timeout: 10))
        attach(app, "settings")
    }
}
