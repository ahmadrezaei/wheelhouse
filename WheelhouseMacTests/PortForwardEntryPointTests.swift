import Foundation
import Testing
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// The port-forward entry points beyond a resource's own action: Resource ▸ Port Forward… (⌥⌘P), Sessions ▸ Recent and the picker.
/// Each one hands a target to the pane's launcher, which keeps every safety check (see PortForwardLauncherTests).
@MainActor
@Suite("Port-forward entry points")
struct PortForwardEntryPointTests {
    private struct Fixture {
        let registry: ClusterRegistry
        let window: WorkspaceWindowModel
        let staging: ClusterConfig
        let production: ClusterConfig
        let readOnly: ClusterConfig
        let demo: ClusterConfig
    }

    private func fixture() -> Fixture {
        var staging = ClusterConfig(name: "staging", server: URL(string: "https://s.invalid:6443")!, environment: .staging)
        staging.defaultNamespace = "shop"
        let production = ClusterConfig(name: "prod", server: URL(string: "https://p.invalid:6443")!, environment: .production)
        var readOnly = ClusterConfig(name: "frozen", server: URL(string: "https://r.invalid:6443")!, environment: .staging)
        readOnly.readOnly = true
        var demo = ClusterConfig(name: "demo", server: URL(string: "https://d.invalid:6443")!, environment: .development)
        demo.isDemo = true
        let client = FixtureGitOpsClient(items: [:], groups: [])
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore([staging, production, readOnly, demo]),
                                       defaults: UserDefaults(suiteName: "wh.pfentry.\(UUID().uuidString)")!, clientFactory: { _, _ in client })
        let controller = WorkspaceController(store: WorkspaceStore(file: nil), registry: registry, sidebarFactory: { SidebarModel(provider: RegistrySidebarProvider(registry: registry)) })
        let window = controller.model(for: controller.store.createWindow())
        window.activate(cluster: staging.id, placement: .here)
        return Fixture(registry: registry, window: window, staging: staging, production: production, readOnly: readOnly, demo: demo)
    }

    private func pod(_ cluster: ClusterID, _ name: String = "api-0") -> ResourceRef { ResourceRef(clusterID: cluster, kind: .pod, namespace: "shop", name: name) }

    // MARK: Resource menu

    @Test func theCommandTargetsOnlyAServiceOrPodWithANamespace() {
        let ref = pod("c")
        for route in [Route.resourceDetail(ref), .yaml(ref), .logs(ref, container: nil, previous: false), .shell(ref, container: nil), .portForward(ref)] {
            #expect(WorkspaceWindowModel.portForwardTarget(of: .route(route)) == ref)
        }
        let service = ResourceRef(clusterID: "c", kind: .service, namespace: "shop", name: "api")
        #expect(WorkspaceWindowModel.portForwardTarget(of: .route(.resourceDetail(service))) == service)
        #expect(WorkspaceWindowModel.portForwardTarget(of: .route(.resourceDetail(ResourceRef(clusterID: "c", kind: .deployment, namespace: "shop", name: "api")))) == nil)
        #expect(WorkspaceWindowModel.portForwardTarget(of: .route(.resourceDetail(ResourceRef(clusterID: "c", kind: .pod, namespace: nil, name: "api")))) == nil)
        #expect(WorkspaceWindowModel.portForwardTarget(of: .route(.resourceList("c", .pod, namespace: "shop"))) == nil)
        #expect(WorkspaceWindowModel.portForwardTarget(of: .landfall) == nil)
        #expect(WorkspaceWindowModel.portForwardTarget(of: nil) == nil)
    }

    @Test func theCommandIsOffWhenThePaneShowsNothingToForward() {
        let f = fixture()
        #expect(f.window.portForwardCommandTarget(registry: f.registry) == nil)
        f.window.show(.route(.resourceList(f.staging.id, .pod, namespace: "shop")), placement: .here)
        #expect(f.window.portForwardCommandTarget(registry: f.registry) == nil)
        f.window.show(.route(.resourceDetail(pod(f.staging.id))), placement: .here)
        #expect(f.window.portForwardCommandTarget(registry: f.registry) == pod(f.staging.id))
    }

    @Test func theCommandFollowsTheGateOfTheShownCluster() {
        let f = fixture()
        // Production is allowed: the launcher asks for a button confirmation when the form submits.
        f.window.show(.route(.resourceDetail(pod(f.production.id))), placement: .here)
        #expect(f.window.portForwardCommandTarget(registry: f.registry) == pod(f.production.id))
        f.window.show(.route(.resourceDetail(pod(f.readOnly.id))), placement: .here)
        #expect(f.window.portForwardCommandTarget(registry: f.registry) == nil)
        f.window.show(.route(.resourceDetail(pod(f.demo.id))), placement: .here)
        #expect(f.window.portForwardCommandTarget(registry: f.registry) == nil)
        f.window.show(.route(.resourceDetail(pod("removed"))), placement: .here)
        #expect(f.window.portForwardCommandTarget(registry: f.registry) == nil)
    }

    @Test func performingTheCommandOpensTheAdvancedFormThroughThePaneLauncher() {
        let f = fixture()
        var calls: [(ResourceRef, Int?, Bool)] = []
        f.window.focusedRouter.portForwardStarter = { ref, port, configure in calls.append((ref, port, configure)) }
        f.window.performPortForwardCommand(registry: f.registry)
        #expect(calls.isEmpty)   // nothing to forward
        f.window.show(.route(.resourceDetail(pod(f.staging.id))), placement: .here)
        f.window.focusedRouter.portForwardStarter = { ref, port, configure in calls.append((ref, port, configure)) }
        f.window.performPortForwardCommand(registry: f.registry)
        #expect(calls.count == 1)
        #expect(calls[0].0 == pod(f.staging.id) && calls[0].1 == nil && calls[0].2 == true)
        // A refused cluster never reaches the launcher.
        f.window.show(.route(.resourceDetail(pod(f.readOnly.id))), placement: .here)
        f.window.focusedRouter.portForwardStarter = { ref, port, configure in calls.append((ref, port, configure)) }
        f.window.performPortForwardCommand(registry: f.registry)
        #expect(calls.count == 1)
    }

    // MARK: Sessions

    @Test func aRecentForwardKnowsItsTargetAndOtherRecentsDoNot() {
        let ref = pod("c")
        let forward = RecentSession(kind: .forward, title: "t", subtitle: "s", endedAt: Date(), route: .portForward(ref))
        #expect(SessionsForward.target(of: forward) == ref)
        #expect(SessionsForward.target(of: RecentSession(kind: .forward, title: "t", subtitle: "s", endedAt: Date(), route: nil)) == nil)
        #expect(SessionsForward.target(of: RecentSession(kind: .shell, title: "t", subtitle: "s", endedAt: Date(), route: .shell(ref, container: nil))) == nil)
        #expect(SessionsForward.target(of: RecentSession(kind: .logs, title: "t", subtitle: "s", endedAt: Date(), route: .portForward(ref))) == nil)
    }

    @Test func aChoiceStartsThroughTheRouterWithOneClickOrTheAdvancedForm() {
        let router = AppRouter()
        var calls: [(ResourceRef, Int?, Bool)] = []
        router.portForwardStarter = { ref, port, configure in calls.append((ref, port, configure)) }
        let ref = pod("c")
        SessionsForward.start(.init(ref: ref, configure: false), router: router)
        SessionsForward.start(.init(ref: ref, configure: true), router: router)
        SessionsForward.start(.init(ref: ref, configure: false, port: 3306), router: router)
        #expect(calls.map { $0.2 } == [false, true, false])
        #expect(calls.allSatisfy { $0.0 == ref })
        #expect(calls.map { $0.1 } == [nil, nil, 3306])
    }

    @Test func aRecentKeepsItsRemotePort() {
        let recent = RecentSession(kind: .forward, title: "t", subtitle: "s", endedAt: Date(), route: .portForward(pod("c")), remotePort: 8080)
        #expect(recent.remotePort == 8080)
    }

    @Test func theStoresRunWhileTheTaskLivesAndReleaseAfterwards() async throws {
        let f = fixture()
        let session = try #require(f.registry.session(for: f.staging.id))
        let group = NamespaceTypedStores<Service>(session: session, selection: NamespaceSelection(names: ["a", "b"]))
        let task = Task { await group.run() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(group.stores.allSatisfy { $0.consumerCount == 1 })
        task.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(group.stores.allSatisfy { $0.consumerCount == 0 })
    }

    @Test func thePickerListsTheNamespacesOfTheSelection() throws {
        let f = fixture()
        let session = try #require(f.registry.session(for: f.staging.id))
        func names(_ selection: NamespaceSelection) -> [String?] { NamespaceTypedStores<Service>(session: session, selection: selection).stores.map(\.namespace) }
        #expect(names(.all) == [nil])
        #expect(names(NamespaceSelection("shop")) == ["shop"])
        #expect(names(NamespaceSelection(names: ["web", "shop"])) == ["shop", "web"])
        // The members are the session's shared stores, so a namespace that stays selected keeps its watch.
        #expect(NamespaceTypedStores<Service>(session: session, selection: NamespaceSelection("shop")).stores[0] === session.store(for: Service.self, namespace: "shop"))
    }
}
