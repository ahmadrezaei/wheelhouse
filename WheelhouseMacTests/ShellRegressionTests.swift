import Testing
import AppKit
import SwiftUI
import WheelhouseKit
@testable import WheelhouseMac

/// Regression tests for two crashes of the Debug app.
///
/// 1. SIGABRT, `swift_beginAccess` in `SidebarScrollView.outlineView(_:child:ofItem:)`: the outline view calls back into the data
///    source while it applies an insertion, and the reconcile function held an `inout` on the same array.
/// 2. SIGTRAP in `EnvironmentValues.subscript.getter` from `MacContent.contentStack`: a view value was created outside the view
///    hierarchy (in a split-view builder), so its `@Environment` reads had no environment.
@Suite("Shell regressions")
@MainActor
struct ShellRegressionTests {
    private func cluster(_ name: String) -> ClusterConfig { ClusterConfig(id: name, name: name, server: URL(string: "https://\(name).example")!, environment: .development) }

    private func resource(_ name: String, kind: String, group: String = "", namespaced: Bool = true) -> APIResource {
        let o: [String: JSONValue] = ["name": .string(name), "namespaced": .bool(namespaced), "kind": .string(kind), "verbs": ["list", "get", "watch"],
                                      "group": .string(group), "version": "v1"]
        return try! JSONValue.object(o).decode(APIResource.self)
    }

    @Test func theOutlineAppliesInsertionsAndRemovalsWhileItCallsBackIntoItsDataSource() async throws {
        let provider = FakeSidebarProvider(clusters: [cluster("alpha"), cluster("beta")])
        let served = [resource("pods", kind: "Pod"), resource("services", kind: "Service"), resource("deployments", kind: "Deployment", group: "apps"),
                      resource("configmaps", kind: "ConfigMap")]
        provider.discoveryByCluster["alpha"] = DiscoveryInfo(resources: served)
        provider.discoveryByCluster["beta"] = DiscoveryInfo(resources: served)
        let model = SidebarModel(provider: provider, features: { [] })
        let view = SidebarScrollView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 700)

        view.update(rows: model.rows, selected: nil)
        // Expanding a cluster inserts a "Loading…" child, then the real groups arrive: two insertions into an expanded parent.
        model.expand(cluster: "alpha")
        view.update(rows: model.rows, selected: nil)
        for _ in 0..<100 where model.discovery["alpha"] == nil { try await Task.sleep(for: .milliseconds(10)) }
        view.update(rows: model.rows, selected: nil)
        // Opening a group inserts its kinds; a second cluster inserts more; collapsing removes them again.
        if let workloads = model.rows.first(where: { $0.role == .cluster })?.children.first(where: { $0.role == .group(.workloads) }) {
            model.setExpanded(true, rowID: workloads.id)
        }
        view.update(rows: model.rows, selected: nil)
        model.expand(cluster: "beta")
        for _ in 0..<100 where model.discovery["beta"] == nil { try await Task.sleep(for: .milliseconds(10)) }
        view.update(rows: model.rows, selected: nil)
        model.collapse(cluster: "alpha")
        view.update(rows: model.rows, selected: nil)
        model.filter = "pod"
        view.update(rows: model.rows, selected: nil)
        model.filter = ""
        view.update(rows: model.rows, selected: model.rowID(for: .fleet))
        #expect(!model.rows.isEmpty)       // reaching here means no exclusivity violation was reported
    }

    /// A pane's hosting view starts with an EMPTY environment (nothing crosses an NSHostingView boundary): the pane host must inject
    /// everything its screens read, or a screen that reads `ClusterRegistry` or `AppRouter` would crash when it builds.
    @Test func aPaneHostResolvesItsEnvironmentInsideAHostingView() throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        let window = env.workspace.store.createWindow()
        let model = env.workspace.model(for: window)
        let pane = model.focusedPaneID
        let h = NSHostingView(rootView: PaneHost(env: env, model: model, paneID: pane))
        h.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        h.layoutSubtreeIfNeeded()
        env.registry.exitDemoMode()
    }

    @Test func theWholeShellBuildsInAHostingView() throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        let window = env.workspace.store.createWindow()
        let h = NSHostingView(rootView: MacShell(windowID: window).environment(env))
        h.frame = NSRect(x: 0, y: 0, width: 1_280, height: 780)
        h.layoutSubtreeIfNeeded()
        env.registry.exitDemoMode()
    }
}
