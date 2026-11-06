import Foundation
import Testing
@testable import WheelhouseKit

@Suite struct HealthTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func pod(_ name: String, json extra: String) throws -> Pod {
        let json = #"{"metadata":{"name":"\#(name)","namespace":"prod","uid":"\#(name)","creationTimestamp":"2027-01-15T07:00:00Z"},"spec":{"containers":[{"name":"app","image":"x","resources":{"limits":{"memory":"256Mi"}}}]},\#(extra)}"#
        return try KubeJSON.decoder.decode(Pod.self, from: Data(json.utf8))
    }

    static func iso(_ ago: TimeInterval) -> String { now.addingTimeInterval(-ago).formatted(.iso8601) }

    static func crashPod() throws -> Pod {
        try pod("api-1", json: #"""
        "status":{"phase":"Running","containerStatuses":[{"name":"app","ready":false,"restartCount":14,
          "state":{"waiting":{"reason":"CrashLoopBackOff"}},
          "lastState":{"terminated":{"exitCode":137,"reason":"OOMKilled","startedAt":"\#(iso(150))","finishedAt":"\#(iso(70))"}}}]}
        """#)
    }

    static func runningPod(_ name: String = "ok-1") throws -> Pod {
        try pod(name, json: #""status":{"phase":"Running","containerStatuses":[{"name":"app","ready":true,"restartCount":0,"state":{"running":{}}}]}"#)
    }

    static func node(_ name: String, ready: Bool, extra: String = "") throws -> Node {
        let json = #"{"metadata":{"name":"\#(name)"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"\#(ready ? "True" : "Unknown")","reason":"\#(ready ? "KubeletReady" : "NodeStatusUnknown")"}\#(extra)]}}"#
        return try KubeJSON.decoder.decode(Node.self, from: Data(json.utf8))
    }

    @Test func podStates() throws {
        let crash = try Self.crashPod().stateSummary()
        #expect(crash.reason == "CrashLoopBackOff")
        #expect(crash.severity == .critical)
        #expect(crash.lastTerminationReason == "OOMKilled")
        #expect(crash.lastExitCode == 137)
        let ok = try Self.runningPod().stateSummary()
        #expect(ok.severity == .healthy)
        #expect(ok.isReady)
        let pull = try Self.pod("p", json: #""status":{"phase":"Pending","containerStatuses":[{"name":"app","ready":false,"restartCount":0,"state":{"waiting":{"reason":"ImagePullBackOff"}}}]}"#).stateSummary()
        #expect(pull.reason == "ImagePullBackOff")
        #expect(pull.severity == .warning)
        let initializing = try Self.pod("i", json: #""status":{"phase":"Pending","initContainerStatuses":[{"name":"init","ready":false,"restartCount":0,"state":{"running":{}}}]}"#).stateSummary()
        #expect(initializing.reason == "Init:0/1")
    }

    @Test func attentionItemsAndClusterStatus() throws {
        var input = ClusterHealthInput(clusterID: "c1", environment: .production)
        input.pods = [try Self.crashPod(), try Self.runningPod("a"), try Self.runningPod("b")]
        input.nodes = [try Self.node("n1", ready: true), try Self.node("n2", ready: false)]
        let health = HealthEvaluator.evaluate(input, now: Self.now)
        #expect(health.status == .critical)
        #expect(health.counts.nodesNotReady == 1)
        #expect(health.counts.podsRunning == 2)
        #expect(health.counts.podsFailing == 1)
        #expect(health.items.contains { $0.kind == .oomKilled })
        #expect(health.items.contains { $0.kind == .nodeNotReady })
        #expect(health.items.first?.severity == .critical)
    }

    @Test func healthyClusterAndDegradedCluster() throws {
        var input = ClusterHealthInput(clusterID: "c", environment: .staging)
        input.pods = [try Self.runningPod()]
        input.nodes = [try Self.node("n1", ready: true)]
        #expect(HealthEvaluator.evaluate(input, now: Self.now).status == .healthy)
        input.pods.append(try Self.crashPod())
        #expect(HealthEvaluator.evaluate(input, now: Self.now).status == .warning) // crash loops alone degrade, not critical
    }

    @Test func pendingThresholdAndHighRestarts() throws {
        let pending = try Self.pod("pend", json: #""status":{"phase":"Pending","conditions":[{"type":"PodScheduled","status":"False","reason":"Unschedulable","message":"0/3 nodes"}]}"#)
        var input = ClusterHealthInput(clusterID: "c", environment: .development)
        input.pods = [pending]
        let late = Date(timeIntervalSince1970: 1_800_000_000 + 10 * 86_400)
        #expect(HealthEvaluator.evaluate(input, now: late).items.contains { $0.kind == .podPending })
        let early = try #require(pending.metadata.creationTimestamp).addingTimeInterval(60)
        #expect(HealthEvaluator.evaluate(input, now: early).items.isEmpty)

        let restarty = try Self.pod("r", json: #""status":{"phase":"Running","containerStatuses":[{"name":"app","ready":true,"restartCount":9,"state":{"running":{}}}]}"#)
        input.pods = [restarty]
        #expect(HealthEvaluator.evaluate(input, now: early).items.first?.kind == .highRestarts)
    }

    @Test func failedJobsDeploymentsAndPressure() throws {
        var input = ClusterHealthInput(clusterID: "c", environment: .development)
        let job = try KubeJSON.decoder.decode(Job.self, from: Data(#"{"metadata":{"name":"j","namespace":"x"},"spec":{"template":{"spec":{}}},"status":{"conditions":[{"type":"Failed","status":"True","reason":"BackoffLimitExceeded"}]}}"#.utf8))
        let dep = try KubeJSON.decoder.decode(Deployment.self, from: Data(#"{"metadata":{"name":"d","namespace":"x"},"spec":{"replicas":3,"template":{"spec":{}}},"status":{"replicas":3,"availableReplicas":0}}"#.utf8))
        input.jobs = [job]
        input.deployments = [dep]
        input.nodes = [try Self.node("n", ready: true, extra: #",{"type":"MemoryPressure","status":"True"}"#)]
        let h = HealthEvaluator.evaluate(input, now: Self.now)
        #expect(h.items.contains { $0.kind == .jobFailed })
        #expect(h.items.contains { $0.kind == .deploymentUnavailable })
        #expect(h.items.contains { $0.kind == .nodePressure })
        #expect(h.status == .critical)
        #expect(h.counts.deploymentsAvailable == 0)
    }

    @Test func unreachable() {
        let h = ClusterHealth.unreachable(clusterID: "c", environment: .production, cause: "timeout")
        #expect(h.status == .unknown)
        #expect(!h.isReachable)
        #expect(h.items.first?.severity == .critical)
        #expect(ClusterHealth.unreachable(clusterID: "c", environment: .staging).items.first?.severity == .warning)
    }

    @Test func diagnosisBanner() throws {
        let d = try #require(PodDiagnoser.diagnose(try Self.crashPod(), memoryPeakBytes: 255 * 1_048_576, now: Self.now))
        #expect(d.title == "OOMKilled")
        #expect(d.suggestsPreviousLogs)
        #expect(d.bannerText.contains("exit 137"))
        #expect(d.bannerText.contains("memory peaked at 255Mi of 256Mi limit"))
        #expect(d.bannerText.contains("next restart in"))
        #expect(PodDiagnoser.diagnose(try Self.runningPod(), now: Self.now) == nil)
        #expect(PodDiagnoser.backoffDelay(restarts: 1) == 10)
        #expect(PodDiagnoser.backoffDelay(restarts: 20) == 300)
    }

    @Test func pendingDiagnosis() throws {
        let pod = try Self.pod("p", json: #""status":{"phase":"Pending","conditions":[{"type":"PodScheduled","status":"False","reason":"Unschedulable","message":"0/8 nodes are available: 6 Insufficient memory."}]}"#)
        let d = try #require(PodDiagnoser.diagnose(pod, now: Self.now.addingTimeInterval(3600)))
        #expect(d.title == "Pending")
        #expect(d.explanation.contains("Insufficient memory"))
    }
}

@Suite struct DemoTests {
    @Test func prodFleetHealthMatchesDesign() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[0])
        var input = ClusterHealthInput(clusterID: DemoFleet.prodID, environment: .production)
        input.pods = try await client.list(Pod.self).items
        input.nodes = try await client.list(Node.self).items
        input.deployments = try await client.list(Deployment.self).items
        input.jobs = try await client.list(Job.self).items
        input.pvcs = try await client.list(PersistentVolumeClaim.self).items
        let h = HealthEvaluator.evaluate(input)
        #expect(h.status == .critical)
        let kinds = Set(h.items.map(\.kind))
        #expect(kinds.isSuperset(of: [.oomKilled, .podPending, .nodeNotReady, .jobFailed]))
    }

    @Test func offlineClusterThrowsUnreachable() async {
        let client = DemoKubeClient(config: DemoFleet.configs[3])
        await #expect(throws: KubeError.self) { _ = try await client.version() }
    }

    @Test func mutationsChangeState() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[1])
        _ = try await client.scale(.deployment, name: "checkout-web", namespace: "checkout", replicas: 4)
        let pods = try await client.list(Pod.self, namespace: "checkout", options: ListOptions(labelSelector: "app=checkout-web")).items
        #expect(pods.count == 4)
        try await client.delete(.pod, name: try #require(pods.first).metadata.name, namespace: "checkout", options: DeleteOptions())
        let after = try await client.list(Pod.self, namespace: "checkout", options: ListOptions(labelSelector: "app=checkout-web")).items
        #expect(after.count == 4) // the Deployment replaced it
    }

    @Test func readOnlyDemoRefusesMutations() async {
        var cfg = DemoFleet.configs[1]
        cfg.readOnly = true
        let client = DemoKubeClient(config: cfg)
        await #expect(throws: KubeError.readOnly) { try await client.delete(.pod, name: "x", namespace: "payments", options: DeleteOptions()) }
    }

    @Test func prometheusDiscoveryAndQuery() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[0])
        let service = MetricsService(client: client)
        let (availability, endpoint) = await service.availability()
        #expect(availability == .both)
        let series = try await service.prometheus(try #require(endpoint)).queryRange(PromQL.clusterCPUUsage, name: "cpu", range: .hour)
        #expect(series.first?.points.count ?? 0 > 50)
        let homelab = DemoKubeClient(config: DemoFleet.configs[2])
        #expect(await MetricsService(client: homelab).availability().0 == .metricsServer)
    }

    @Test func logsStreamAndPreviousForCrashPod() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[0])
        let crash = try await client.list(Pod.self, namespace: "payments", options: ListOptions(labelSelector: "app=payments-api")).items.first { $0.stateSummary().reason == "CrashLoopBackOff" }
        let name = try #require(crash).metadata.name
        var last = ""
        for try await line in client.logs(namespace: "payments", pod: name, options: LogOptions(previous: true, tailLines: 20)) { last = line }
        #expect(last.contains("OutOfMemoryError"))
    }

    @Test func storeReflectsWatchUpdates() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[1])
        let store = await ResourceStore<Pod>(client: client, namespace: "payments", labelSelector: "app=payments-api")
        await store.start()
        try await Task.sleep(for: .milliseconds(600))
        let count = await store.items.count
        #expect(count == 2)
        await store.stop()
    }
}

@Suite struct MetadataStoreTests {
    @Test func mergePrefersNewer() {
        let url = URL(string: "https://a")!
        let old = ClusterConfig(id: "1", name: "old", server: url, modifiedAt: Date(timeIntervalSince1970: 100))
        let new = ClusterConfig(id: "1", name: "new", server: url, modifiedAt: Date(timeIntervalSince1970: 200))
        let other = ClusterConfig(id: "2", name: "other", server: url)
        let merged = ClusterMetadataStore.merge(local: [old], mirrored: [new, other])
        #expect(merged.map(\.name) == ["new", "other"])
    }

    @Test func jsonFileRoundTrip() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ClusterMetadataStore(directory: dir, useKeychainMirror: false)
        let c = ClusterConfig(name: "x", server: URL(string: "https://x:6443")!, environment: .production, readOnly: true)
        try store.save([c, ClusterConfig(name: "demo", server: URL(string: "https://d")!, isDemo: true)])
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.readOnly == true)
        #expect(loaded.first?.environment == .production)
    }
}
