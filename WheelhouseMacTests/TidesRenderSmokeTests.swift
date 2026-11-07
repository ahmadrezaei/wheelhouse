import AppKit
import SwiftUI
import Testing
import WheelhouseKit
@testable import WheelhouseMac

/// Hosts the Tides views over fixture data in an off-screen window, so a crash or a runtime layout failure shows up in tests.
/// Set `WH_TIDES_SNAPSHOT_DIR` to also write PNGs of the Overview and an Argo detail.
@MainActor @Suite("Tides views (smoke)")
struct TidesRenderSmokeTests {
    private func registry() -> (ClusterRegistry, ClusterID) {
        let client = FixtureGitOpsClient(items: ["kustomizations": [kustomizationFixture, brokenFixture], "applications": [argoFixture]], groups: [
            ("kustomize.toolkit.fluxcd.io", "v1", "Kustomization", "kustomizations"), ("argoproj.io", "v1alpha1", "Application", "applications")])
        let cfg = ClusterConfig(name: "staging-1", server: URL(string: "https://example.invalid:6443")!, environment: .staging)
        let r = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore([cfg]),
                                defaults: UserDefaults(suiteName: "tides.smoke.\(UUID().uuidString)")!, clientFactory: { _, _ in client })
        return (r, cfg.id)
    }

    private func host<V: View>(_ view: V, size: CGSize = CGSize(width: 1100, height: 560)) -> (NSWindow, NSHostingView<AnyView>) {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        return (window, hosting)
    }

    private func snapshot(_ view: NSView, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["WH_TIDES_SNAPSHOT_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    @Test func overviewRendersFixtureApps() async throws {
        let (reg, id) = registry()
        let (window, hosting) = host(TidesRootView(scope: TidesScope(clusterID: id, tool: nil)).environment(reg))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(1200))
        snapshot(hosting, name: "tides-overview")
        #expect(hosting.fittingSize.width > 0)
    }

    @Test func argoDetailRenders() async throws {
        let (reg, id) = registry()
        let session = try #require(reg.session(for: id))
        let model = TidesClusterModel(session: session)
        let (window, hosting) = host(NavigationStack { TidesDetailView(model: model, appID: "argoproj.io/v1alpha1/applications/argocd/checkout") }.environment(reg))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(1200))
        snapshot(hosting, name: "tides-argo-detail")
        #expect(model.detection.hasArgo)
    }
}

private let kustomizationFixture: JSONValue = try! JSONValue.parse(Data(#"{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"Kustomization","metadata":{"name":"apps","namespace":"flux-system","uid":"k1"},"spec":{"interval":"10m","path":"./apps/prod","sourceRef":{"kind":"GitRepository","name":"fleet"}},"status":{"conditions":[{"type":"Ready","status":"True","message":"Applied revision: main@sha1:3f2a9c1d0e","lastTransitionTime":"2026-11-07T10:00:00Z"}],"lastAppliedRevision":"main@sha1:3f2a9c1d0e","lastAttemptedRevision":"main@sha1:3f2a9c1d0e"}}"#.utf8))
private let brokenFixture: JSONValue = try! JSONValue.parse(Data(#"{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"Kustomization","metadata":{"name":"broken","namespace":"flux-system","uid":"k2"},"spec":{"interval":"5m","path":"./broken","sourceRef":{"kind":"GitRepository","name":"fleet"}},"status":{"conditions":[{"type":"Ready","status":"False","message":"kustomize build failed: no such file ./broken","lastTransitionTime":"2026-11-07T08:00:00Z"},{"type":"Stalled","status":"True"}],"lastAppliedRevision":"main@sha1:1111111aaaaa","lastAttemptedRevision":"main@sha1:3f2a9c1d0e"}}"#.utf8))
private let argoFixture: JSONValue = try! JSONValue.parse(Data(#"{"apiVersion":"argoproj.io/v1alpha1","kind":"Application","metadata":{"name":"checkout","namespace":"argocd","uid":"a1"},"spec":{"project":"shop","source":{"repoURL":"https://github.com/acme/deploy.git","path":"checkout","targetRevision":"main"},"destination":{"server":"https://kubernetes.default.svc","namespace":"checkout"},"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}},"status":{"sync":{"status":"OutOfSync","revision":"0123456789abcdef0123456789abcdef01234567"},"health":{"status":"Degraded","message":"1 pod crashing"},"resources":[{"group":"apps","kind":"Deployment","namespace":"checkout","name":"web","status":"OutOfSync","health":{"status":"Degraded"}},{"group":"","kind":"ConfigMap","namespace":"checkout","name":"old-config","status":"OutOfSync","requiresPruning":true},{"group":"","kind":"Service","namespace":"checkout","name":"web","status":"Synced","health":{"status":"Healthy"}}]}}"#.utf8))
