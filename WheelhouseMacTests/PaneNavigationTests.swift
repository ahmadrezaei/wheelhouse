import AppKit
import SwiftUI
import Testing
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

/// The owner's report after the first install: on a pushed detail screen, sidebar clicks, the YAML and Port Forward actions did nothing
/// until Back, and Back then showed the port-forward form. Inside the workspace's `NavigationSplitView` the split view took a pane's
/// `NavigationStack` over after its first push. These tests host a whole workspace window, where the pane sits in the split view.
@MainActor
@Suite("PaneNavigationTests", .serialized)
struct PaneNavigationTests {
    private func classNames(_ view: NSView, into out: inout Set<String>) {
        out.insert(String(describing: type(of: view)))
        for sub in view.subviews { classNames(sub, into: &out) }
    }

    /// True when a view whose class name contains `fragment` is in the window and not hidden by an `opacity(0)` layer (SwiftUI keeps
    /// hidden layers' AppKit views, so this looks at the visible part only: a view of a hidden layer has no hit area).
    private func shows(_ window: NSWindow, _ fragment: String) -> Bool {
        guard let content = window.contentView else { return false }
        var found = false
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).contains(fragment), !view.isHiddenOrHasHiddenAncestor, view.window != nil {
                let r = view.convert(view.bounds, to: nil)
                let centre = NSPoint(x: r.midX, y: r.midY)
                if let hit = content.hitTest(content.superview?.convert(centre, from: nil) ?? centre), hit === view || hit.isDescendant(of: view) { found = true }
            }
            for sub in view.subviews where !found { walk(sub) }
        }
        walk(content)
        return found
    }

    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(50)) }
    }

    @MainActor private struct Fixture {
        let env: MacAppEnvironment
        let model: WorkspaceWindowModel
        let pane: PaneID
        let cluster: ClusterID
        let window: NSWindow
        var router: AppRouter { model.router(for: pane) }
        var ref: ResourceRef { ResourceRef(clusterID: cluster, kind: .deployment, namespace: "payments", name: "payments-api") }
    }

    /// A workspace window whose toolbar and title are bridged from SwiftUI the way a `WindowGroup` window's are, on the demo fleet.
    private func workspaceWindow() throws -> Fixture {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        let cluster = try #require(env.registry.clusters.first?.id)
        let id = env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.resourceList(cluster, .deployment, namespace: nil)))]))
        let model = env.workspace.model(for: id)
        let controller = NSHostingController(rootView: AnyView(WorkspaceWindowContent(model: model).environment(env)))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.setFrame(NSRect(x: 40, y: 40, width: 1_300, height: 820), display: true)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return Fixture(env: env, model: model, pane: model.focusedPaneID, cluster: cluster, window: window)
    }

    private func close(_ f: Fixture) {
        for sheet in f.window.sheets { f.window.endSheet(sheet) }
        f.window.orderOut(nil)
        f.env.registry.exitDemoMode()
    }

    @Test func aPushedDetailStillTakesSheetsPushesAndSidebarClicks() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        try await waitUntil { shows(f.window, "KubeNSTable") }
        #expect(shows(f.window, "KubeNSTable"))

        f.router.push(.resourceDetail(f.ref))
        try await waitUntil { !shows(f.window, "KubeNSTable") }
        #expect(!shows(f.window, "KubeNSTable"))

        // Port Forward… on the detail: the form is a sheet of the pane.
        f.router.sheet = PresentedRoute(route: .portForward(f.ref))
        try await waitUntil { f.window.attachedSheet != nil }
        #expect(f.window.attachedSheet != nil)
        f.router.sheet = nil
        try await waitUntil { f.window.attachedSheet == nil }

        // YAML on the detail: the editor shows.
        f.router.push(.yaml(f.ref))
        try await waitUntil { shows(f.window, "YAMLCodeEditor") }
        #expect(shows(f.window, "YAMLCodeEditor"))

        // A sidebar click replaces the pane's stack: the new list shows, nothing of the old stack does.
        f.model.selectSidebar(.kind(f.cluster, .configMap))
        try await waitUntil { shows(f.window, "KubeNSTable") && !shows(f.window, "YAMLCodeEditor") }
        #expect(f.model.pane(f.pane)?.stack.count == 1)
        #expect(shows(f.window, "KubeNSTable"))
        #expect(!shows(f.window, "YAMLCodeEditor"))
    }

    @Test func backLeavesTheTopScreenAndTheListUnderItComesBack() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        try await waitUntil { shows(f.window, "KubeNSTable") }
        #expect(!f.model.canGoBack(in: f.pane))
        #expect(!f.model.goBack(in: f.pane))

        f.router.push(.resourceDetail(f.ref))
        f.router.push(.yaml(f.ref))
        try await waitUntil { shows(f.window, "YAMLCodeEditor") }
        #expect(f.model.canGoBack(in: f.pane))
        #expect(f.model.goBack(in: f.pane))
        try await waitUntil { !shows(f.window, "YAMLCodeEditor") }
        #expect(!shows(f.window, "YAMLCodeEditor"))
        #expect(f.model.goBack(in: f.pane))
        #expect(f.model.pane(f.pane)?.stack.count == 1)
        try await waitUntil { shows(f.window, "KubeNSTable") }
        #expect(shows(f.window, "KubeNSTable"))
    }

    @Test func backAsksBeforeLeavingAnEditorWithADraft() throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        defer { env.registry.exitDemoMode() }
        let cluster = try #require(env.registry.clusters.first?.id)
        let ref = ResourceRef(clusterID: cluster, kind: .configMap, namespace: "payments", name: "settings")
        let id = env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.resourceList(cluster, .configMap, namespace: nil)))]))
        let model = env.workspace.model(for: id)
        let pane = model.focusedPaneID
        model.push(.resourceDetail(ref), from: pane)
        model.push(.yaml(ref), from: pane)
        let editor = NSObject()
        model.editorReported(editor, dirty: true, in: pane)
        var asked = 0
        env.workspace.confirmsDiscardingEdits = { _, _ in asked += 1; return false }
        #expect(!model.goBack(in: pane))
        #expect(asked == 1)
        #expect(model.pane(pane)?.stack.count == 3)
        env.workspace.confirmsDiscardingEdits = { _, _ in asked += 1; return true }
        #expect(model.goBack(in: pane))
        #expect(asked == 2)
        #expect(model.pane(pane)?.stack.count == 2)
        // Leaving a screen that is not an editor never asks, even with a draft further down.
        model.push(.logs(ResourceRef(clusterID: cluster, kind: .pod, namespace: "payments", name: "p"), container: nil, previous: false), from: pane)
        #expect(model.goBack(in: pane))
        #expect(asked == 2)
        withExtendedLifetime(editor) {}
    }
}
