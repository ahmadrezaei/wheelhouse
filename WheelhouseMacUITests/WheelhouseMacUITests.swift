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

    /// Screenshots are deliberately not taken: UI checks read the accessibility tree instead (no screen capture of the desktop).
    private func attach(_ app: XCUIApplication, _ name: String) { dump(app, name) }

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

    /// Imports `.testcluster/kubeconfig` through the real import sheet: read-only by default, the environment must be chosen.
    func testImportTestClusterThroughTheSheet() throws {
        let app = try launch(["-WHImportFile", repoRoot.appending(path: ".testcluster/kubeconfig").path, "-WHResetState"])
        sleep(6)
        attach(app, "import-sheet")
        dump(app, "import-sheet-tree")
        XCTAssertTrue(app.buttons["Add Cluster"].waitForExistence(timeout: 5), "the import sheet did not open")
        app.sheets.firstMatch.buttons["Add Cluster"].click()
        let row = cell(app, "wheelhouse-test")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the imported cluster is missing from the sidebar")
        attach(app, "after-import")
        sleep(15)
        attach(app, "after-import-15s")
        expand(app, "Workloads")
        cell(app, "Namespaces").click()
        let table = app.tables["Resources"]
        XCTAssertTrue(table.waitForExistence(timeout: 20))
        XCTAssertTrue(table.tableRows.firstMatch.waitForExistence(timeout: 30), "namespaces did not load from the test cluster")
        XCTAssertGreaterThanOrEqual(table.tableRows.count, 6)
        attach(app, "test-cluster-namespaces")
        cell(app, "Pods").click()
        sleep(3)
        attach(app, "test-cluster-pods")
    }

    // MARK: Workspace (M4a)

    private func tempWorkspaceFile() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appending(path: "workspace.json")
    }

    private func panes(_ app: XCUIApplication) -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "pane") }
    private func tabs(_ app: XCUIApplication) -> XCUIElementQuery { app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")) }

    private func windowMenu(_ app: XCUIApplication, _ item: String) {
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems[item].click()
    }

    /// Split a pane with the menu, then move it into a window of its own with pane ⋯ ▸ Move ▸ New Window (the menu path of R19).
    func testSplitAndMoveAPaneToANewWindow() throws {
        let app = try launch(["-WHDemoMode", "-WHWorkspaceFile", tempWorkspaceFile().path])
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 20), "no pane")
        XCTAssertEqual(panes(app).count, 1)
        windowMenu(app, "Split Right")
        XCTAssertTrue(waitForCount(panes(app), 2), "the split did not produce a second pane")
        // Move the focused (new) pane to a new window from the Window menu.
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Move Pane"].click()
        app.menuBars.menuItems["Move Pane"].menuItems["New Window"].click()
        XCTAssertTrue(waitForCount(app.windows.matching(NSPredicate(format: "title != ''")), 2), "the pane did not open in its own window")
        XCTAssertTrue(waitForCount(panes(app), 2) , "both panes should still exist (one per window)")
        dump(app, "after-detach")
    }

    /// Open a tab and a split, quit, launch again on the same workspace file: the layout is the same.
    func testRestorationAfterARelaunchIsExact() throws {
        let file = tempWorkspaceFile()
        var app = try launch(["-WHDemoMode", "-WHWorkspaceFile", file.path])
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 20))
        windowMenu(app, "Split Down")
        XCTAssertTrue(waitForCount(panes(app), 2))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForCount(tabs(app), 2), "the new tab is missing")
        app.terminate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "quitting must write the workspace")
        app = try launch(["-WHDemoMode", "-WHWorkspaceFile", file.path])
        XCTAssertTrue(waitForCount(tabs(app), 2), "the tabs were not restored")
        // The selected tab is the new one (the Fleet): switch to the first, which holds the split.
        tabs(app).element(boundBy: 0).click()
        XCTAssertTrue(waitForCount(panes(app), 2), "the split was not restored")
    }

    /// A pane saved in a form this build cannot read shows the placeholder, and its JSON survives a quit until the pane is closed.
    func testAnUnreadablePaneRestoresAsAPlaceholderAndKeepsItsJSON() throws {
        let file = tempWorkspaceFile()
        let json = #"{"version":1,"windows":[{"id":"w1","state":{"tabs":[{"id":"t1","focusedPane":"p-bad","root":{"split":{"axis":"horizontal","fraction":0.5,"first":{"leaf":{"id":"p-bad","stack":[{"case":"holodeck","payload":{"x":1}}]}},"second":{"leaf":{"id":"p-ok","stack":[{"case":"moorings"}]}}}}}],"selectedTab":"t1"}}]}"#
        try json.write(to: file, atomically: true, encoding: .utf8)
        let app = try launch(["-WHDemoMode", "-WHWorkspaceFile", file.path])
        let placeholder = app.descendants(matching: .any).matching(identifier: "pane.placeholder").firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 20), "no placeholder for the unreadable pane")
        XCTAssertTrue(waitForCount(panes(app), 2), "the readable pane must restore next to it")
        app.terminate()
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("holodeck"), "the unreadable pane's JSON must be written back")
        // Closing the placeholder discards it.
        let again = try launch(["-WHDemoMode", "-WHWorkspaceFile", file.path])
        again.descendants(matching: .any).matching(identifier: "pane.placeholder.close").firstMatch.click()
        XCTAssertTrue(waitForCount(panes(again), 1))
        again.terminate()
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("holodeck"))
    }

    private func waitForCount(_ query: XCUIElementQuery, _ count: Int, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if query.count == count { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return query.count == count
    }
}
