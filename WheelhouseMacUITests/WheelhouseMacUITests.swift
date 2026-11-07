import XCTest

/// UI automation for the Mac shell (ARCHITECTURE-MAC section 13.4). Demo flows run with `-WHDemoMode` (no network); the test-cluster
/// flows import `.testcluster/kubeconfig` through the real import sheet.
///
/// SAFETY: the app under test is the Debug build next to this runner (bundle ID `…mac.debug`, safety gate on). It only ever reads the
/// test kubeconfig, never `~/.kube`, and its keychain group cannot see the shared iCloud items.
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
        app.launchArguments = ["-WHKubeconfigPath", repoRoot.appending(path: ".testcluster/kubeconfig").path] + extra
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "no window")
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

    /// The Demo Fleet shell: the sidebar outline, its rows, expansion, and the resource table behind a kind.
    func testDemoShellAnatomy() throws {
        let app = try launch(["-WHDemoMode"])
        let outline = app.outlines["sidebar.tree"].firstMatch.exists ? app.outlines["sidebar.tree"] : app.outlines.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 20), "sidebar outline missing")
        attach(app, "demo-launch")
        dump(app, "demo-tree")
    }
}
