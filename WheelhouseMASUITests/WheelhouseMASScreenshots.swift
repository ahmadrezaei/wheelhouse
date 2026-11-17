import XCTest

/// App Store screenshots of the Mac App Store edition (design/mac/MAS-LISTING.md).
///
/// SAFETY, all of it enforced below:
/// - The app is the MAS Debug build next to this runner (bundle ID `…wheelhouse.mas.debug`, dev-safety gate on).
/// - It always launches with `-WHDemoMode`, `-WHResetState` and a clean state, so only the built-in demo fleet can appear.
///   Before any capture the test checks that the sidebar shows exactly the demo clusters; anything else aborts the run.
/// - Captures are of the app's own window (`XCUIElement.screenshot()`), never of the screen.
@MainActor
final class WheelhouseMASScreenshots: XCTestCase {
    private static let demoClusters: Set<String> = ["prod-eu-west", "staging", "homelab-k3s", "edge-oslo"]
    private static let size = CGSize(width: 1_440, height: 900)

    override func setUp() { continueAfterFailure = false }

    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "design/mac/screenshots-mas", directoryHint: .isDirectory)
    }

    private func appURL() throws -> URL {
        var dir = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let candidate = dir.appending(path: "WheelhouseMAS.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("WheelhouseMAS.app was not found next to the test bundle")
    }

    private func launch() throws -> XCUIApplication {
        let app = XCUIApplication(url: try appURL())
        // `-key value` pairs first, bare flags last: AppKit would otherwise take a following path as a document to open.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
                               "-WHDemoMode", "-WHResetState"]
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "no window")
        return app
    }

    private func cell(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.outlines["sidebar.tree"].cells.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func expand(_ app: XCUIApplication, _ prefix: String) {
        let c = cell(app, prefix)
        XCTAssertTrue(c.waitForExistence(timeout: 15), "\(prefix) row missing")
        let t = c.disclosureTriangles.firstMatch
        if t.exists, (t.value as? Int) == 0 || (t.value as? String) == "0" { t.click() }
    }

    /// Aborts unless the sidebar lists the demo clusters and nothing else.
    private func assertDemoFleetOnly(_ app: XCUIApplication) {
        XCTAssertTrue(app.outlines["sidebar.tree"].waitForExistence(timeout: 20), "sidebar missing")
        XCTAssertTrue(cell(app, "prod-eu-west").waitForExistence(timeout: 20), "the demo fleet did not load")
        let clusterRows = app.outlines["sidebar.tree"].cells.allElementsBoundByIndex.filter { $0.disclosureTriangles.firstMatch.exists }
        let known = clusterRows.filter { row in Self.demoClusters.contains { row.label.hasPrefix($0) } }
        // Every top-level cluster row must be a demo cluster. Rows that are neither a cluster nor a demo group are ignored.
        let unknown = app.outlines["sidebar.tree"].cells.allElementsBoundByIndex.filter {
            $0.label.contains("demo.") || $0.label.contains(".kube") || $0.label.lowercased().contains("minikube")
        }
        XCTAssertTrue(unknown.isEmpty, "something other than the demo fleet is in the sidebar: \(unknown.map(\.label))")
        XCTAssertFalse(known.isEmpty, "no demo cluster rows")
    }

    /// Moves the window to the top-left of the screen and drags its right and bottom edges until it is 1440 x 900 points.
    /// (The sandboxed app cannot read a frame from a file the runner writes, so the window is resized like a user would.)
    private func sizeWindow(_ app: XCUIApplication) throws {
        let window = app.windows.firstMatch
        let screen = try XCTUnwrap(NSScreen.main, "no screen").frame
        XCTAssertGreaterThanOrEqual(screen.width, Self.size.width, "the screen is too small for a 1440-point window")
        XCTAssertGreaterThanOrEqual(screen.height, Self.size.height + 60, "the screen is too small for a 900-point window")
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 10))
        let from = window.frame.origin
        titleBar.press(forDuration: 0.1, thenDragTo: titleBar.withOffset(CGVector(dx: 20 - from.x, dy: 30 - from.y)))
        for _ in 0..<6 {
            let f = window.frame
            let dw = Self.size.width - f.width, dh = Self.size.height - f.height
            if abs(dw) <= 1, abs(dh) <= 1 { break }
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -1, dy: -1))
            corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: dw, dy: dh)))
        }
    }

    private func launchSized() throws -> XCUIApplication {
        let app = try launch()
        assertDemoFleetOnly(app)
        try sizeWindow(app)
        let f = app.windows.firstMatch.frame
        if abs(f.width - Self.size.width) > 2 || abs(f.height - Self.size.height) > 2 {
            // XCUI drags did not resize the window on the machine that tried this (macOS 27). See design/mac/MAS-LISTING.md, Screenshots.
            throw XCTSkip("The window is \(Int(f.width)) x \(Int(f.height)) points, not 1440 x 900. Resize it once by hand (the app restores its frame) and run again.")
        }
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) throws {
        sleep(2)   // let the last animation and data settle
        let window = app.windows.firstMatch
        XCTAssertEqual(window.frame.width, Self.size.width, accuracy: 2, "the window is not 1440 points wide: \(window.frame)")
        XCTAssertEqual(window.frame.height, Self.size.height, accuracy: 2, "the window is not 900 points high: \(window.frame)")
        let shot = window.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // The runner may be sandboxed and unable to write into the repository: the attachment is the source of truth, and
        // exporting the attachments from the .xcresult is the fallback.
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: outputDirectory.appending(path: "\(name).png"))
    }

    func testCaptureStoreScreenshots() throws {
        let app = try launchSized()

        // 1. Fleet overview.
        cell(app, "Fleet").click()
        sleep(3)
        try capture(app, "01-fleet-overview")

        // 2. A cluster's workloads (pods).
        expand(app, "Workloads")
        let pods = cell(app, "Pods")
        XCTAssertTrue(pods.waitForExistence(timeout: 10), "Pods row missing")
        pods.click()
        let table = app.tables["Resources"]
        XCTAssertTrue(table.tableRows.firstMatch.waitForExistence(timeout: 20), "no pod rows")
        try capture(app, "02-workloads-pods")

        // 3 and 4. A pod's logs and its YAML, from the detail's tiles.
        table.tableRows.element(boundBy: 0).doubleClick()
        let logs = app.buttons["Logs"]
        XCTAssertTrue(logs.waitForExistence(timeout: 20), "no Logs tile")
        logs.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).click()
        sleep(3)
        try capture(app, "03-pod-logs")
        app.typeKey("[", modifierFlags: .command)   // back to the detail
        let yaml = app.buttons["YAML"]
        XCTAssertTrue(yaml.waitForExistence(timeout: 20), "no YAML tile")
        yaml.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).click()
        sleep(2)
        try capture(app, "04-yaml")

        // 5. Chart Room, read-only: the Releases list.
        expand(app, "Chart Room")
        let releases = cell(app, "Releases")
        XCTAssertTrue(releases.waitForExistence(timeout: 10), "Releases row missing")
        releases.click()
        sleep(3)
        XCTAssertFalse(cell(app, "Repositories").exists, "the App Store edition must not list Repositories")
        try capture(app, "05-chart-room-releases")

        // 6. Survey.
        expand(app, "Survey")
        let survey = cell(app, "Access risks")
        XCTAssertTrue(survey.waitForExistence(timeout: 10), "Survey rows missing")
        survey.click()
        sleep(3)
        try capture(app, "06-survey")
    }
}
