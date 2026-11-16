import AppKit
import SwiftUI
import Testing
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

/// The window title follows the focused pane (it followed the first pane's screen), a Tides app opens as a screen of the pane's own
/// stack, and a shell's Back is the pane's Back. Each hosts a whole workspace window, with the toolbar and title bridged from SwiftUI
/// the way a `WindowGroup` window's are (the same fixture as `PaneNavigationTests`).
@MainActor
@Suite("WindowTitleTests", .serialized)
struct WindowTitleTests {
    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(50)) }
    }

    @MainActor private struct Fixture {
        let env: MacAppEnvironment
        let model: WorkspaceWindowModel
        let cluster: ClusterID
        let window: NSWindow
        var ref: ResourceRef { ResourceRef(clusterID: cluster, kind: .deployment, namespace: "payments", name: "payments-api") }
        var focusedTitle: String { model.focusedPane?.title(registry: env.registry) ?? "" }
    }

    private func workspaceWindow(root: (ClusterID) -> WorkspaceDestination = { .route(.resourceList($0, .deployment, namespace: nil)) }) throws -> Fixture {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        let cluster = try #require(env.registry.clusters.first?.id)
        let id = env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: root(cluster))]))
        let model = env.workspace.model(for: id)
        let controller = NSHostingController(rootView: AnyView(WorkspaceWindowContent(model: model).environment(env)))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.setFrame(NSRect(x: 40, y: 40, width: 1_300, height: 820), display: true)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return Fixture(env: env, model: model, cluster: cluster, window: window)
    }

    private func close(_ f: Fixture) {
        for sheet in f.window.sheets { f.window.endSheet(sheet) }
        f.window.orderOut(nil)
        f.env.registry.exitDemoMode()
    }

    @Test func theWindowTitleFollowsTheFocusedPane() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        let first = f.model.focusedPaneID
        try await waitUntil { f.window.title == f.focusedTitle }
        #expect(f.window.title == "Deployments")

        // A second pane takes focus: the window is named for it, not for the first pane's screen.
        f.model.split(.vertical)
        let second = f.model.focusedPaneID
        #expect(second != first)
        f.model.mutate { $0.setRoot(.route(.resourceList(f.cluster, .configMap, namespace: nil)), in: second) }
        try await waitUntil { f.window.title == "ConfigMaps" }
        #expect(f.window.title == "ConfigMaps")

        // A pushed detail names the window, although the screens set their own navigation titles.
        f.model.push(.resourceDetail(f.ref), from: second)
        try await waitUntil { f.window.title == "payments-api" }
        #expect(f.window.title == "payments-api")

        // Focus moves back to the first pane; Back in the unfocused second pane leaves the title alone.
        f.model.focus(pane: first)
        try await waitUntil { f.window.title == "Deployments" }
        #expect(f.window.title == "Deployments")
        #expect(f.model.goBack(in: second))
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.window.title == "Deployments")
        f.model.focus(pane: second)
        try await waitUntil { f.window.title == "ConfigMaps" }
        #expect(f.window.title == "ConfigMaps")
    }

    @Test func aTitleWrittenByAScreenDoesNotStick() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        try await waitUntil { f.window.title == "Deployments" }
        f.window.title = "Something a screen set"
        // The observer answers synchronously: no re-render is needed to put the title back.
        #expect(f.window.title == "Deployments")
    }

    @Test func aDetachedPaneWindowIsNamedForItsPane() async throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        defer { env.registry.exitDemoMode() }
        let cluster = try #require(env.registry.clusters.first?.id)
        let pane = PaneState(showing: .route(.resourceList(cluster, .secret, namespace: nil)))
        env.workspace.store.detach(pane)
        let controller = NSHostingController(rootView: AnyView(DetachedPaneWindow(paneID: pane.id).environment(env)))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setFrame(NSRect(x: 40, y: 40, width: 900, height: 600), display: true)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await waitUntil { window.title == "Secrets" }
        #expect(window.title == "Secrets")
        let model = env.workspace.detachedModel(for: pane.id)
        model.push(.route(.resourceDetail(ResourceRef(clusterID: cluster, kind: .secret, namespace: "payments", name: "db-credentials"))), from: pane.id)
        try await waitUntil { window.title == "db-credentials" }
        #expect(window.title == "db-credentials")
    }

    /// A Tides app opens as a screen of the pane's stack, and the pane stays live: its sheets still present and Back returns.
    @Test func aTidesAppOpensOnThePaneStackAndBackReturns() async throws {
        let f = try workspaceWindow(root: { .tides(TidesScope(clusterID: $0, tool: nil)) })
        defer { close(f) }
        let pane = f.model.focusedPaneID
        try await waitUntil { f.window.title == "Tides: \(f.env.registry.config(for: f.cluster)?.name ?? "")" }
        let rootTitle = f.window.title
        #expect(rootTitle.hasPrefix("Tides"))
        let ref = ResourceRef(clusterID: f.cluster, kind: .deployment, namespace: "payments", name: "payments-api")
        // The destination a row opens: the app as a `ResourceRef` of its cluster.
        let kustomization = try #require(Self.app(named: "apps", in: "flux-system"))
        #expect(TidesRootView.destination(for: TidesRow(cluster: f.cluster, clusterName: "demo", app: kustomization))
                == .gitopsApp(ResourceRef(clusterID: f.cluster, kind: kustomization.kind, namespace: "flux-system", name: "apps")))

        f.model.push(.gitopsApp(ref), from: pane)
        try await waitUntil { f.window.title == "payments-api" }
        #expect(f.model.pane(pane)?.stack.count == 2)
        #expect(f.window.title == "payments-api")

        // The pane still takes its sheets and sidebar changes over the pushed app (the nested stack's failure).
        f.model.router(for: pane).sheet = PresentedRoute(route: .portForward(ref))
        try await waitUntil { f.window.attachedSheet != nil }
        #expect(f.window.attachedSheet != nil)
        f.model.router(for: pane).sheet = nil
        try await waitUntil { f.window.attachedSheet == nil }

        #expect(f.model.goBack(in: pane))
        try await waitUntil { f.window.title == rootTitle }
        #expect(f.window.title == rootTitle)
        #expect(f.model.pane(pane)?.stack.count == 1)
    }

    /// The shell's Close Session on the Mac is the pane's Back (the router's own paths are empty there).
    @Test func aPaneRouterGoesBackThroughThePane() throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        defer { env.registry.exitDemoMode() }
        let cluster = try #require(env.registry.clusters.first?.id)
        let id = env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.resourceList(cluster, .pod, namespace: nil)))]))
        let model = env.workspace.model(for: id)
        let pane = model.focusedPaneID
        let router = model.router(for: pane)
        let paneBack = try #require(router.paneBack)
        paneBack()
        #expect(model.pane(pane)?.stack.count == 1)
        model.push(.shell(ResourceRef(clusterID: cluster, kind: .pod, namespace: "payments", name: "api-0"), container: nil), from: pane)
        #expect(model.pane(pane)?.stack.count == 2)
        paneBack()
        #expect(model.pane(pane)?.stack.count == 1)
    }

    private static func app(named name: String, in namespace: String) -> GitOpsApp? {
        let kind: ResourceKind = .custom(group: "kustomize.toolkit.fluxcd.io", version: "v1", kind: "Kustomization", plural: "kustomizations", namespaced: true)
        return GitOpsApp(raw: .object(["metadata": .object(["name": .string(name), "namespace": .string(namespace)])]), kind: kind)
    }
}
