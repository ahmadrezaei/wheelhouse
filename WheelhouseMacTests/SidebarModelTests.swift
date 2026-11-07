import Testing
import Foundation
import WheelhouseKit
@testable import WheelhouseMac

/// A session provider that counts everything the model asks for. It has no way to create a store, a list or a watch, which is the
/// point: `SidebarSessionProviding` only offers lookups of stores that already run (ARCHITECTURE-MAC section 12.5).
@MainActor
final class FakeSidebarProvider: SidebarSessionProviding {
    var clusters: [ClusterConfig]
    var isDemoMode = false
    var namespaces: [ClusterID: String] = [:]
    var discoveryByCluster: [ClusterID: DiscoveryInfo?] = [:]
    var reviewByCluster: [ClusterID: JSONValue?] = [:]
    var running: [String: [Unstructured]] = [:]       // "<cluster>|<kind id>"
    var healthByCluster: [ClusterID: ClusterHealth] = [:]
    private(set) var discoveryReads = 0
    private(set) var reviewPosts: [String] = []
    private(set) var runningLookups = 0

    init(clusters: [ClusterConfig]) { self.clusters = clusters }

    func namespace(for id: ClusterID) -> String? { namespaces[id] }
    func loadDiscovery(for id: ClusterID) async -> DiscoveryInfo? { discoveryReads += 1; return discoveryByCluster[id] ?? nil }
    func rulesReview(for id: ClusterID, namespace: String?) async -> JSONValue? { reviewPosts.append("\(id)|\(namespace ?? "*")"); return reviewByCluster[id] ?? nil }
    func runningItems(for id: ClusterID, kind: ResourceKind, namespace: String?) -> (items: [Unstructured], updated: Date?)? {
        runningLookups += 1
        return running["\(id)|\(kind.id)"].map { ($0, nil) }
    }
    func health(for id: ClusterID) -> ClusterHealth? { healthByCluster[id] }
}

private func cfg(_ name: String, id: String? = nil) -> ClusterConfig {
    ClusterConfig(id: id ?? name, name: name, server: URL(string: "https://\(name).example")!, environment: .development)
}

private func resource(_ name: String, kind: String, group: String = "", version: String = "v1", namespaced: Bool = true, verbs: [String] = ["list", "get", "watch"], short: [String]? = nil) -> APIResource {
    var o: [String: JSONValue] = ["name": .string(name), "namespaced": .bool(namespaced), "kind": .string(kind), "verbs": .array(verbs.map(JSONValue.string)),
                                  "group": .string(group), "version": .string(version)]
    if let short { o["shortNames"] = .array(short.map(JSONValue.string)) }
    return try! JSONValue.object(o).decode(APIResource.self)
}

private func discovery(_ resources: [APIResource]) -> DiscoveryInfo { DiscoveryInfo(resources: resources) }

private let coreServed: [APIResource] = [
    resource("pods", kind: "Pod"), resource("services", kind: "Service"), resource("configmaps", kind: "ConfigMap"), resource("secrets", kind: "Secret"),
    resource("namespaces", kind: "Namespace", namespaced: false), resource("events", kind: "Event"),
    resource("deployments", kind: "Deployment", group: "apps"), resource("statefulsets", kind: "StatefulSet", group: "apps"),
    resource("customresourcedefinitions", kind: "CustomResourceDefinition", group: "apiextensions.k8s.io", namespaced: false),
]

private func reviewJSON(_ rules: [[String: [String]]], incomplete: Bool = false) -> JSONValue {
    let r: [JSONValue] = rules.map { rule in
        .object(rule.mapValues { .array($0.map(JSONValue.string)) })
    }
    return ["status": ["resourceRules": .array(r), "nonResourceRules": [], "incomplete": .bool(incomplete)]]
}

@MainActor
private func model(_ provider: FakeSidebarProvider) -> SidebarModel { SidebarModel(provider: provider, features: { [] }) }

private func titles(_ rows: [SidebarRow]) -> [String] { rows.map(\.title) }

@MainActor
private func cluster(_ m: SidebarModel, _ id: String) -> SidebarRow { m.rows.first { $0.id == "cluster.\(id)" }! }

private func group(_ c: SidebarRow, _ g: SidebarGroupID) -> SidebarRow? { c.children.first { $0.role == .group(g) } }

/// Waits until the model's in-flight discovery and review tasks have finished (they are main-actor tasks).
@MainActor
private func settle(_ m: SidebarModel, until condition: () -> Bool = { true }) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("Sidebar model")
@MainActor
struct SidebarModelTests {
    // MARK: Collapsed clusters cost nothing

    @Test func aCollapsedClusterTriggersNoRequestAndShowsNoChildren() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        let m = model(p)
        m.refreshBadges()
        await settle(m)
        #expect(p.discoveryReads == 0 && p.reviewPosts.isEmpty)
        #expect(cluster(m, "alpha").children.isEmpty)
        #expect(cluster(m, "alpha").isExpandable)
        #expect(p.runningLookups == 0)          // a collapsed cluster is not even asked about its stores
    }

    @Test func expandingReadsDiscoveryOnceAndPostsOneReview() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        p.reviewByCluster["alpha"] = reviewJSON([["verbs": ["*"], "apiGroups": ["*"], "resources": ["*"]]])
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { p.reviewPosts.count == 1 && m.rules["alpha"] != nil }
        #expect(p.discoveryReads == 1)
        #expect(p.reviewPosts == ["alpha|*"])
        // Expanding again (or a namespace change within the TTL) reuses the cached discovery and the cached review.
        m.namespaceChanged(cluster: "alpha")
        await settle(m)
        #expect(p.discoveryReads == 1 && p.reviewPosts.count == 1)
        // A 403 invalidates the review: the next load posts a new one.
        m.forbiddenSeen(cluster: "alpha")
        m.namespaceChanged(cluster: "alpha")
        await settle(m) { p.reviewPosts.count == 2 }
        #expect(p.reviewPosts.count == 2)
    }

    @Test func aNamespaceChangeIsADifferentScopeAndPostsItsOwnReview() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        p.reviewByCluster["alpha"] = reviewJSON([["verbs": ["*"], "apiGroups": ["*"], "resources": ["*"]]])
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { p.reviewPosts.count == 1 }
        p.namespaces["alpha"] = "shop"
        m.namespaceChanged(cluster: "alpha")
        await settle(m) { p.reviewPosts.count == 2 }
        #expect(p.reviewPosts == ["alpha|*", "alpha|shop"])
    }

    @Test func collapsingStopsLoading() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        let m = model(p)
        m.expand(cluster: "alpha")
        m.collapse(cluster: "alpha")
        #expect(cluster(m, "alpha").children.isEmpty)
    }

    // MARK: Discovery-driven kinds

    @Test func onlyServedKindsAppearAndEmptyGroupsAreHidden() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { m.discovery["alpha"] != nil }
        let c = cluster(m, "alpha")
        let workloads = group(c, .workloads)!
        #expect(titles(workloads.children) == ["Overview", "Pods", "Deployments", "StatefulSets"])
        #expect(titles(group(c, .config)!.children) == ["ConfigMaps", "Secrets"])
        #expect(titles(group(c, .network)!.children) == ["Services", "Port Forwards"])
        #expect(group(c, .storage) == nil)                       // nothing served in Storage: the group is hidden
        #expect(group(c, .accessControl) == nil)
        #expect(group(c, .namespaces)?.destination == .kind("alpha", .namespace))
        #expect(group(c, .events) != nil)
        #expect(group(c, .overview)?.destination == .clusterOverview("alpha"))
    }

    @Test func replicationControllersAppearOnlyWhenOneExists() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed + [resource("replicationcontrollers", kind: "ReplicationController")])
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { m.discovery["alpha"] != nil }
        #expect(!titles(group(cluster(m, "alpha"), .workloads)!.children).contains("ReplicationControllers"))
        let rc = Unstructured(raw: ["apiVersion": "v1", "kind": "ReplicationController", "metadata": ["name": "legacy", "namespace": "default"]])
        p.running["alpha|\(SidebarCatalog.replicationController.id)"] = [rc]
        m.rebuild()
        #expect(titles(group(cluster(m, "alpha"), .workloads)!.children).contains("ReplicationControllers"))
    }

    @Test func gatewayKindsAppearOnlyWhenTheirAPIIsServed() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha"), cfg("beta")])
        let ingress = resource("ingresses", kind: "Ingress", group: "networking.k8s.io")
        p.discoveryByCluster["alpha"] = discovery(coreServed + [ingress])
        p.discoveryByCluster["beta"] = discovery(coreServed + [ingress, resource("httproutes", kind: "HTTPRoute", group: "gateway.networking.k8s.io")])
        let m = model(p)
        m.expand(cluster: "alpha"); m.expand(cluster: "beta")
        await settle(m) { m.discovery["alpha"] != nil && m.discovery["beta"] != nil }
        #expect(!titles(group(cluster(m, "alpha"), .network)!.children).contains("HTTPRoutes"))
        #expect(titles(group(cluster(m, "beta"), .network)!.children).contains("HTTPRoutes"))
    }

    @Test func customResourcesListOneSubGroupPerUncoveredAPIGroup() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed + [
            resource("issuers", kind: "Issuer", group: "cert-manager.io", version: "v1"),
            resource("certificates", kind: "Certificate", group: "cert-manager.io", version: "v1"),
            resource("servicemonitors", kind: "ServiceMonitor", group: "monitoring.coreos.com", version: "v1"),
            resource("applications", kind: "Application", group: "argoproj.io", version: "v1alpha1"),          // covered by Tides
            resource("kustomizations", kind: "Kustomization", group: "kustomize.toolkit.fluxcd.io", version: "v1"),
            resource("vulnerabilityreports", kind: "VulnerabilityReport", group: "aquasecurity.github.io", version: "v1alpha1"),
            resource("httproutes", kind: "HTTPRoute", group: "gateway.networking.k8s.io", version: "v1"),
            resource("noverbs", kind: "NoVerbs", group: "weird.io", version: "v1", verbs: ["get"]),            // not listable
        ])
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { m.discovery["alpha"] != nil }
        let cr = group(cluster(m, "alpha"), .customResources)!
        #expect(cr.children.first?.title == "Definitions")
        let subs = cr.children.filter { $0.role == .apiGroup }
        #expect(titles(subs) == ["cert-manager.io", "monitoring.coreos.com"])
        #expect(titles(subs[0].children) == ["Certificate", "Issuer"])
        #expect(subs[0].children.allSatisfy { $0.level == 4 } && subs[0].level == 3)
    }

    @Test func featureGroupsComeFromTheirFeatureAndTidesNeedItsCRDs() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha"), cfg("beta")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        p.discoveryByCluster["beta"] = discovery(coreServed + [resource("applications", kind: "Application", group: "argoproj.io", version: "v1alpha1")])
        let m = SidebarModel(provider: p, features: { FeatureRegistry.enabled })
        m.expand(cluster: "alpha"); m.expand(cluster: "beta")
        await settle(m) { m.discovery["alpha"] != nil && m.discovery["beta"] != nil }
        #expect(titles(group(cluster(m, "alpha"), .chartRoom)!.children) == ["Releases", "Charts", "Repositories"])
        #expect(group(cluster(m, "alpha"), .tides) == nil)                         // neither Argo CD nor Flux: the group disappears
        #expect(titles(group(cluster(m, "beta"), .tides)!.children) == ["Argo CD"])
    }

    // MARK: RBAC hiding

    @Test func kindsTheUserCannotListAreHiddenAndShownDimmedOnRequest() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        p.reviewByCluster["alpha"] = reviewJSON([
            ["verbs": ["list", "get"], "apiGroups": [""], "resources": ["pods", "services", "namespaces", "events"]],
            ["verbs": ["list"], "apiGroups": ["apps"], "resources": ["deployments"]],
        ])
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { m.rules["alpha"] != nil }
        var c = cluster(m, "alpha")
        #expect(titles(group(c, .workloads)!.children) == ["Overview", "Pods", "Deployments"])      // StatefulSets: not allowed
        #expect(group(c, .config) == nil)                                                             // every kind forbidden: the group is hidden
        m.showsForbiddenKinds = true
        c = cluster(m, "alpha")
        let sts = group(c, .workloads)!.children.first { $0.title == "StatefulSets" }
        #expect(sts?.isForbidden == true)
        #expect(group(c, .config)?.children.allSatisfy(\.isForbidden) == true)
    }

    @Test func anIncompleteReviewHidesNothing() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        p.reviewByCluster["alpha"] = reviewJSON([["verbs": ["list"], "apiGroups": [""], "resources": ["pods"]]], incomplete: true)
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { m.rules["alpha"] != nil }
        #expect(titles(group(cluster(m, "alpha"), .workloads)!.children).contains("StatefulSets"))
    }

    @Test func aFailedReviewHidesNothing() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        p.reviewByCluster["alpha"] = .some(nil)                 // the review itself was forbidden or failed
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { p.reviewPosts.count == 1 }
        #expect(m.rules["alpha"] == nil)
        #expect(titles(group(cluster(m, "alpha"), .workloads)!.children).contains("StatefulSets"))
    }

    @Test func aRuleLimitedToNamedObjectsDoesNotGrantListing() {
        let rules = SidebarRuleSet(rules: [.init(verbs: ["list"], apiGroups: [""], resources: ["pods"], resourceNames: ["one"])], incomplete: false)
        #expect(!rules.allowsList(.pod))
        let star = SidebarRuleSet(rules: [.init(verbs: ["*"], apiGroups: ["*"], resources: ["*"], resourceNames: [])], incomplete: false)
        #expect(star.allowsList(.pod) && star.allowsList(.deployment))
    }

    // MARK: Filtering

    @Test func filterMatchesShortNamesAndSingularFormsAndOpensAncestors() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed + [
            resource("ingresses", kind: "Ingress", group: "networking.k8s.io"), resource("ingressclasses", kind: "IngressClass", group: "networking.k8s.io", namespaced: false),
        ])
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { m.discovery["alpha"] != nil }
        m.filter = "ingress"
        var c = cluster(m, "alpha")
        let net = group(c, .network)!
        #expect(titles(net.children) == ["Ingresses", "IngressClasses"])
        #expect(m.forcedOpen.contains(net.id) && m.forcedOpen.contains(c.id))
        #expect(group(c, .workloads) == nil)
        m.filter = "deploy"
        c = cluster(m, "alpha")
        #expect(titles(group(c, .workloads)!.children) == ["Deployments"])
        m.filter = "sts"
        #expect(titles(group(cluster(m, "alpha"), .workloads)!.children) == ["StatefulSets"])
        m.filter = "pod"                                   // singular form of Pods
        #expect(titles(group(cluster(m, "alpha"), .workloads)!.children) == ["Pods"])
        m.filter = ""
        #expect(m.forcedOpen.isEmpty)                      // clearing the filter restores the disclosure state
        #expect(titles(group(cluster(m, "alpha"), .workloads)!.children).count == 4)
    }

    @Test func filterMatchesClusterNamesAndHidesTheTopRows() async {
        let p = FakeSidebarProvider(clusters: [cfg("prod-eu"), cfg("staging-eu")])
        let m = model(p)
        m.filter = "stag"
        #expect(m.rows.compactMap { $0.role == .cluster ? $0.title : nil } == ["staging-eu"])
        #expect(!m.rows.contains { $0.role == .top })
    }

    @Test func filterOver2000RowsIsFast() {
        let p = FakeSidebarProvider(clusters: (0..<40).map { cfg("c\($0)") })
        var resources = coreServed
        for i in 0..<50 { resources.append(resource("things\(i)", kind: "Thing\(i)", group: "g\(i % 10).example.io")) }
        for c in p.clusters { p.discoveryByCluster[c.id] = discovery(resources) }
        let m = model(p)
        for c in p.clusters { m.expandedClusters.insert(c.id); m.expand(cluster: c.id) }
        // Feed discovery without the async path: the builder is pure.
        var input = SidebarBuildInput(clusters: p.clusters, expandedClusters: m.expandedClusters, expandedGroups: [], filter: "thing", showsForbiddenKinds: false,
                                      discovery: p.discoveryByCluster.compactMapValues { $0 }, rules: [:])
        input.features = []
        let start = ContinuousClock.now
        let out = SidebarTreeBuilder.build(input)
        let elapsed = ContinuousClock.now - start
        let rows = out.rows.reduce(0) { $0 + $1.subtreeIDs.count }
        #expect(rows >= 2_000)
        #expect(elapsed < .milliseconds(160), "filtering \(rows) rows took \(elapsed)")      // budget 16 ms; the debug build gets 10x
    }

    // MARK: Badges and counts

    private func crashingPod(_ name: String) -> Unstructured {
        Unstructured(raw: [
            "apiVersion": "v1", "kind": "Pod", "metadata": ["name": .string(name), "namespace": "shop", "uid": .string(name), "resourceVersion": "1"],
            "spec": ["containers": [["name": "c", "image": "x"]]],
            "status": ["phase": "Running", "containerStatuses": [["name": "c", "ready": false, "restartCount": 9, "image": "x", "imageID": "",
                                                                  "state": ["waiting": ["reason": "CrashLoopBackOff"]]]]],
        ])
    }

    @Test func badgesComeOnlyFromRunningStoresAndAggregateWhenCollapsed() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { m.discovery["alpha"] != nil }
        // Nothing is running: no badges, no counts.
        m.refreshBadges(now: Date(timeIntervalSince1970: 1_000))
        #expect(m.badges.isEmpty && m.counts.isEmpty)
        // A running Pods store with two crashing pods.
        p.running["alpha|\(ResourceKind.pod.id)"] = [crashingPod("a"), crashingPod("b")]
        m.refreshBadges(now: Date(timeIntervalSince1970: 1_005))
        let podsRow = group(cluster(m, "alpha"), .workloads)!.children.first { $0.title == "Pods" }!
        #expect(m.badges[podsRow.id] == SidebarBadge(count: 2, severity: .critical))
        #expect(m.counts[podsRow.id] == 2)
        #expect(m.badges["agg.group.alpha.workloads"]?.count == 2)             // shown on the group while it is collapsed
        #expect(m.badges["agg.cluster.alpha"]?.severity == .critical)
        // Kinds without a store show nothing.
        let deployments = group(cluster(m, "alpha"), .workloads)!.children.first { $0.title == "Deployments" }!
        #expect(m.badges[deployments.id] == nil && m.counts[deployments.id] == nil)
    }

    @Test func podsFallBackToTheLatestHealthSnapshot() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        var counts = ClusterCounts(); counts.podsFailing = 3
        p.healthByCluster["alpha"] = ClusterHealth(clusterID: "alpha", status: .critical, isReachable: true, items: [], counts: counts, updatedAt: Date())
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { m.discovery["alpha"] != nil }
        m.refreshBadges()
        let podsRow = group(cluster(m, "alpha"), .workloads)!.children.first { $0.title == "Pods" }!
        #expect(m.badges[podsRow.id] == SidebarBadge(count: 3, severity: .critical))
        #expect(m.counts[podsRow.id] == nil)                                     // a snapshot gives no item count
    }

    @Test func badgeRefreshesAreCoalescedToOncePerSecond() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { m.discovery["alpha"] != nil }
        let t = Date(timeIntervalSince1970: 5_000)
        m.refreshBadges(now: t)
        m.refreshBadges(now: t.addingTimeInterval(0.2))
        m.refreshBadges(now: t.addingTimeInterval(0.9))
        #expect(m.badgeRefreshes == 1)
        m.refreshBadges(now: t.addingTimeInterval(1.1))
        #expect(m.badgeRefreshes == 2)
    }

    // MARK: Disclosure state survives rebuilds

    @Test func groupDisclosureIsRememberedPerCluster() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha"), cfg("beta")])
        p.discoveryByCluster["alpha"] = discovery(coreServed); p.discoveryByCluster["beta"] = discovery(coreServed)
        let m = model(p)
        m.expand(cluster: "alpha"); m.expand(cluster: "beta")
        await settle(m) { m.discovery["alpha"] != nil && m.discovery["beta"] != nil }
        let workloadsAlpha = group(cluster(m, "alpha"), .workloads)!
        m.setExpanded(true, rowID: workloadsAlpha.id)
        #expect(m.isExpanded(rowID: workloadsAlpha.id))
        #expect(!m.isExpanded(rowID: group(cluster(m, "beta"), .workloads)!.id))
        m.rebuild()
        #expect(m.isExpanded(rowID: workloadsAlpha.id))
        let saved = m.persisted
        let m2 = model(p)
        m2.restore(saved)
        #expect(m2.expandedGroups == m.expandedGroups && m2.expandedClusters == m.expandedClusters)
    }

    @Test func onlyTheFocusedClusterAutoExpandsUnlessKept() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha"), cfg("beta"), cfg("gamma")])
        let m = model(p)
        m.focus(cluster: "alpha")
        m.toggleKeepExpanded("alpha")
        m.focus(cluster: "beta")
        #expect(m.expandedClusters == ["alpha", "beta"])
        m.focus(cluster: "gamma")
        #expect(m.expandedClusters == ["alpha", "gamma"])
    }

    @Test func rowsRevealTheirDestination() async {
        let p = FakeSidebarProvider(clusters: [cfg("alpha")])
        p.discoveryByCluster["alpha"] = discovery(coreServed)
        let m = model(p)
        m.expand(cluster: "alpha")
        await settle(m) { m.discovery["alpha"] != nil }
        #expect(m.rowID(for: .kind("alpha", .pod)) == "kind.alpha.\(ResourceKind.pod.id)")
        #expect(m.rowID(for: .fleet) == "top.fleet")
    }
}
