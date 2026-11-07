import Foundation
import Synchronization
import Testing
@testable import WheelhouseKit

@Suite("Helm manifest and drift")
struct HelmManifestTests {
    static let manifest = """
    ---
    # Source: wh-fixture/templates/configmap.yaml
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: web-config
    data:
      replicas: "2"
      image: registry.k8s.io/pause:3.10
    ---
    # Source: wh-fixture/templates/deployment.yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: web
      namespace: shop
      creationTimestamp: null
    spec:
      replicas: 2
      template:
        spec:
          containers:
            - name: app
              image: pause:3.10
              ports:
                - containerPort: 80
    ---
    # Source: wh-fixture/templates/secret.yaml
    apiVersion: v1
    kind: Secret
    metadata:
      name: creds
    stringData:
      password: hunter2
    """

    @Test func splitsDocumentsWithSources() {
        let objects = HelmManifest.objects(in: Self.manifest)
        #expect(objects.map(\.id) == ["ConfigMap/-/web-config", "Deployment/shop/web", "Secret/-/creds"])
        #expect(objects[0].source == "wh-fixture/templates/configmap.yaml")
        #expect(HelmManifest.objects(in: "").isEmpty)
        #expect(HelmManifest.objects(in: "---\n---\n# only a comment\n").isEmpty)
    }

    @Test func flattensLists() {
        let list = "apiVersion: v1\nkind: List\nitems:\n- {apiVersion: v1, kind: ConfigMap, metadata: {name: a}}\n- {apiVersion: v1, kind: ConfigMap, metadata: {name: b}}\n"
        #expect(HelmManifest.objects(in: list).map(\.name) == ["a", "b"])
    }

    @Test func kindResolutionUsesBuiltInsThenDiscoveryThenAGuess() {
        func obj(_ apiVersion: String, _ kind: String) -> HelmManifestObject {
            HelmManifestObject(apiVersion: apiVersion, kind: kind, name: "x", namespace: nil, source: nil, yaml: "", value: .null)
        }
        #expect(HelmManifest.resourceKind(for: obj("apps/v1", "Deployment"), discovery: nil).plural == "deployments")
        let discovery = DiscoveryInfo(resources: [APIResource(name: "widgets", singularName: nil, namespaced: false, kind: "Widget", verbs: ["list"],
                                                              shortNames: nil, group: "acme.io", version: "v1")])
        let custom = HelmManifest.resourceKind(for: obj("acme.io/v1", "Widget"), discovery: discovery)
        #expect(custom.plural == "widgets" && !custom.namespaced)
        #expect(HelmManifest.resourceKind(for: obj("acme.io/v1", "Gadget"), discovery: nil).plural == "gadgets")
        #expect(HelmManifest.pluralGuess("NetworkPolicy") == "networkpolicies" && HelmManifest.pluralGuess("Ingress") == "ingresses")
    }

    // MARK: Comparison

    @Test func serverDefaultsAreNotDrift() {
        let desired = HelmDrift.normalise(HelmManifest.objects(in: Self.manifest)[1].value, kind: "Deployment")
        let live: JSONValue = [
            "apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": ["name": "web", "namespace": "shop", "uid": "u", "resourceVersion": "9", "managedFields": [[:]],
                         "creationTimestamp": "2026-01-01T00:00:00Z"],
            "spec": ["replicas": 2, "revisionHistoryLimit": 10, "progressDeadlineSeconds": 600,
                     "template": ["metadata": ["creationTimestamp": nil],
                                  "spec": ["containers": [["name": "app", "image": "pause:3.10", "imagePullPolicy": "IfNotPresent",
                                                           "ports": [["containerPort": 80, "protocol": "TCP"]]]],
                                           "restartPolicy": "Always"]]],
            "status": ["readyReplicas": 2],
        ]
        #expect(HelmDrift.differences(desired: desired, live: live).isEmpty)
    }

    @Test func changedValuesAreReportedWithPaths() {
        let desired = HelmDrift.normalise(HelmManifest.objects(in: Self.manifest)[1].value, kind: "Deployment")
        let live: JSONValue = [
            "spec": ["replicas": 5, "template": ["spec": ["containers": [["name": "app", "image": "pause:3.11", "ports": [["containerPort": 80]]]]]]],
        ]
        let paths = HelmDrift.differences(desired: desired, live: live)
        #expect(paths.contains("spec.replicas"))
        #expect(paths.contains("spec.template.spec.containers[app].image"))
        #expect(!paths.contains { $0.contains("ports") })
    }

    @Test func namedListsMatchByNameNotPosition() {
        let desired: JSONValue = ["spec": ["containers": [["name": "b", "image": "1"], ["name": "a", "image": "2"]]]]
        let live: JSONValue = ["spec": ["containers": [["name": "a", "image": "2"], ["name": "sidecar", "image": "x"], ["name": "b", "image": "1"]]]]
        #expect(HelmDrift.differences(desired: desired, live: live).isEmpty)
        let gone: JSONValue = ["spec": ["containers": [["name": "a", "image": "2"]]]]
        #expect(HelmDrift.differences(desired: desired, live: gone) == ["spec.containers[b]"])
    }

    @Test func secretStringDataFoldsIntoDataAndIsHidden() {
        let secret = HelmManifest.objects(in: Self.manifest)[2].value
        let desired = HelmDrift.normalise(secret, kind: "Secret")
        #expect(desired["stringData"] == nil)
        #expect(desired.value(at: "data.password")?.stringValue == Data("hunter2".utf8).base64EncodedString())
        let live: JSONValue = ["apiVersion": "v1", "kind": "Secret", "metadata": ["name": "creds"],
                               "data": ["password": .string(Data("hunter2".utf8).base64EncodedString())]]
        #expect(HelmDrift.differences(desired: desired, live: live).isEmpty)
    }

    @Test func lastAppliedAnnotationAndBookkeepingAreDropped() {
        let value: JSONValue = ["metadata": ["name": "x", "annotations": ["kubectl.kubernetes.io/last-applied-configuration": "{}"],
                                             "creationTimestamp": "t", "uid": "u"], "status": ["a": 1]]
        let normal = HelmDrift.normalise(value, kind: "ConfigMap")
        #expect(normal.value(at: "metadata.annotations") == nil && normal["status"] == nil && normal.value(at: "metadata.uid") == nil)
    }

    // MARK: Checking against a (fake) cluster

    @Test func checkReportsInSyncDriftedAndMissingWithBoundedConcurrency() async throws {
        let gate = Mutex<(active: Int, peak: Int)>((0, 0))
        let (client, _) = FakeAPI.client { req in
            gate.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
            defer { gate.withLock { $0.active -= 1 } }
            Thread.sleep(forTimeInterval: 0.01)
            if req.path.hasSuffix("/configmaps/web-config") {
                return .json(["apiVersion": "v1", "kind": "ConfigMap", "metadata": ["name": "web-config", "namespace": "shop"],
                              "data": ["replicas": "2", "image": "registry.k8s.io/pause:3.10", "extra": "server added"]])
            }
            if req.path.hasSuffix("/deployments/web") {
                return .json(["apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "web", "namespace": "shop"],
                              "spec": ["replicas": 9, "template": ["spec": ["containers": [["name": "app", "image": "pause:3.10", "ports": [["containerPort": 80]]]]]]],
                              "status": ["readyReplicas": 3]])
            }
            return .notFound()
        }
        let report = await HelmDrift.check(manifest: Self.manifest, releaseNamespace: "shop", client: client, discovery: nil)
        #expect(report.objects.map(\.state.isDrift) == [false, true, true])
        #expect(report.objects[0].state == .inSync)
        #expect(report.objects[1].state == .drifted(paths: ["spec.replicas"]))
        #expect(report.objects[1].liveSummary == "3/9 ready")
        #expect(report.objects[2].state == .missing)
        #expect(report.driftCount == 2 && report.hasDrift)
        #expect(gate.withLock { $0.peak } <= HelmDrift.maxInFlight)
        // The diff texts differ on the replicas line only, and a Secret's value never appears.
        let diff = LineDiff.diff(old: report.objects[1].desiredYAML, new: report.objects[1].liveYAML)
        #expect(diff.filter { $0.kind != .context }.count == 2)
        #expect(!report.objects[2].desiredYAML.contains("hunter2") && !report.objects[2].desiredYAML.contains(Data("hunter2".utf8).base64EncodedString()))
    }

    @Test func objectsWithoutANamespaceUseTheReleaseNamespace() async throws {
        let (client, host) = FakeAPI.client { _ in .notFound() }
        _ = await HelmDrift.check(manifest: Self.manifest, releaseNamespace: "shop", client: client, discovery: nil)
        let paths = Set(FakeAPI.requests(host: host).map(\.path))
        #expect(paths.contains("/api/v1/namespaces/shop/configmaps/web-config"))
        #expect(paths.contains("/apis/apps/v1/namespaces/shop/deployments/web"))
    }

    @Test func forbiddenReadsAreUnreadableNotDrift() async throws {
        let (client, _) = FakeAPI.client { _ in .forbidden(resource: "configmaps", namespace: "shop") }
        let report = await HelmDrift.check(manifest: Self.manifest, releaseNamespace: "shop", client: client, discovery: nil)
        #expect(!report.hasDrift)
        if case .unreadable = report.objects[0].state {} else { Issue.record("expected unreadable") }
    }
}

@Suite("Helm repositories, indexes, charts")
struct HelmRepositoryTests {
    @Test func pathsFollowHelmsResolutionOrder() {
        let home = URL(fileURLWithPath: "/Users/u")
        let defaults = HelmPaths.resolve(environment: [:], home: home)
        #expect(defaults.repositoryConfig.path == "/Users/u/Library/Preferences/helm/repositories.yaml")
        #expect(defaults.repositoryCache.path == "/Users/u/Library/Caches/helm/repository")
        let xdg = HelmPaths.resolve(environment: ["XDG_CONFIG_HOME": "/x/c", "XDG_CACHE_HOME": "/x/k"], home: home)
        #expect(xdg.repositoryConfig.path == "/x/c/helm/repositories.yaml" && xdg.repositoryCache.path == "/x/k/helm/repository")
        let homes = HelmPaths.resolve(environment: ["HELM_CONFIG_HOME": "/h/c", "HELM_CACHE_HOME": "/h/k", "XDG_CONFIG_HOME": "/x"], home: home)
        #expect(homes.repositoryConfig.path == "/h/c/repositories.yaml" && homes.repositoryCache.path == "/h/k/repository")
        let explicit = HelmPaths.resolve(environment: ["HELM_REPOSITORY_CONFIG": "/e/r.yaml", "HELM_REPOSITORY_CACHE": "/e/cache", "HELM_CONFIG_HOME": "/h"], home: home)
        #expect(explicit.repositoryConfig.path == "/e/r.yaml" && explicit.repositoryCache.path == "/e/cache")
    }

    @Test func repositoriesParseWithoutReadingPasswords() throws {
        let yaml = """
        apiVersion: ""
        generated: "0001-01-01T00:00:00Z"
        repositories:
        - name: bitnami
          url: https://charts.bitnami.com/bitnami
        - name: private
          url: https://charts.example.com
          username: bot
          password: s3cret
        - name: oci
          url: oci://ghcr.io/org/charts
        """
        let repos = try HelmRepositories.parse(yaml)
        #expect(repos.map(\.name) == ["bitnami", "private", "oci"])
        #expect(repos.map(\.hasCredentials) == [false, true, false])
        #expect(repos[2].isOCI && !repos[0].isOCI)
        #expect(!String(describing: repos).contains("s3cret"))
        #expect(try HelmRepositories.load(config: URL(fileURLWithPath: "/nonexistent/repositories.yaml")).isEmpty)
    }

    static let index = """
    apiVersion: v1
    entries:
      nginx:
        - name: nginx
          version: 18.2.0
          appVersion: 1.27.1
          description: NGINX web server
          icon: https://example.com/nginx.png
          created: "2026-10-01T00:00:00Z"
          keywords: [http, web]
          maintainers:
            - name: Broadcom
        - name: nginx
          version: 18.1.0
          appVersion: 1.27.0
          deprecated: true
      redis:
        - name: redis
          version: 20.0.0
          appVersion: 7.4.0
          description: In-memory key-value store
    generated: "2026-11-01T00:00:00Z"
    """

    @Test func indexParsesIntoCompactSummaries() throws {
        let parsed = try HelmRepositories.parseIndex(Data(Self.index.utf8), repository: "bitnami")
        #expect(parsed.charts.map(\.name) == ["nginx", "redis"])
        let nginx = parsed.charts[0]
        #expect(nginx.repository == "bitnami" && nginx.id == "bitnami/nginx")
        #expect(nginx.latest.version == "18.2.0" && nginx.latest.appVersion == "1.27.1")
        #expect(nginx.versions.map(\.version) == ["18.2.0", "18.1.0"] && nginx.versions[1].deprecated)
        #expect(nginx.keywords == ["http", "web"] && nginx.maintainers == ["Broadcom"] && nginx.icon == "https://example.com/nginx.png")
        #expect(throws: HelmRepositoryError.notAnIndex) { try HelmRepositories.parseIndex(Data("just: text".utf8), repository: "x") }
    }

    @Test func indexInGoYAMLLayoutParsesChartByChart() throws {
        // Go's YAML writer puts list items at the indentation of their key, and `generated` comes last.
        let go = """
        apiVersion: v1
        entries:
          alpha:
          - apiVersion: v2
            appVersion: 1.0.0
            description: first
            name: alpha
            version: 2.0.0
          - apiVersion: v2
            name: alpha
            version: 1.0.0
          beta:
          - description: second
            keywords:
            - x
            name: beta
            version: 0.1.0
        generated: "2026-11-01T10:00:00.123456789Z"
        """
        let parsed = try HelmRepositories.parseIndex(Data(go.utf8), repository: "go")
        #expect(parsed.charts.map(\.name) == ["alpha", "beta"])
        #expect(parsed.charts[0].versions.map(\.version) == ["2.0.0", "1.0.0"] && parsed.charts[0].description == "first")
        #expect(parsed.charts[1].keywords == ["x"] && parsed.generated?.hasPrefix("2026-11-01") == true)
        #expect(try HelmRepositories.parseIndex(Data("apiVersion: v1\nentries: {}\n".utf8), repository: "e").charts.isEmpty)
    }

    @Test func searchRanksNameMatchesFirst() throws {
        let charts = try HelmRepositories.parseIndex(Data(Self.index.utf8), repository: "r").charts
        #expect(HelmRepositories.search("redis", in: charts).map(\.name) == ["redis"])
        #expect(HelmRepositories.search("web", in: charts).map(\.name) == ["nginx"])          // keyword
        #expect(HelmRepositories.search("key-value", in: charts).map(\.name) == ["redis"])     // description
        #expect(HelmRepositories.search("", in: charts).count == 2 && HelmRepositories.search("zzz", in: charts).isEmpty)
    }

    @Test func indexStoreParsesOncePerFileModification() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wh-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        let helmCache = root.appending(path: "helm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: helmCache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = HelmRepository(name: "bitnami", url: "https://x", hasCredentials: false)
        #expect(try HelmIndexStore(cacheDirectory: root.appending(path: "compact")).index(for: repo, helmCache: helmCache) == nil)   // never updated

        try Data(Self.index.utf8).write(to: helmCache.appending(path: "bitnami-index.yaml"))
        let store = HelmIndexStore(cacheDirectory: root.appending(path: "compact", directoryHint: .isDirectory))
        let first = try #require(try store.index(for: repo, helmCache: helmCache))
        #expect(first.charts.count == 2)
        let compact = root.appending(path: "compact/bitnami.json")
        #expect(FileManager.default.fileExists(atPath: compact.path))

        // Unchanged source: the compact file is used (proved by replacing its content with a recognisable marker).
        var marked = first
        marked.generated = "from-compact-cache"
        try JSONEncoder().encode(marked).write(to: compact)
        #expect(try store.index(for: repo, helmCache: helmCache)?.generated == "from-compact-cache")
        // `helm repo update` rewrites the source: parsed again.
        try Data(Self.index.replacingOccurrences(of: "redis", with: "valkey").utf8).write(to: helmCache.appending(path: "bitnami-index.yaml"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: helmCache.appending(path: "bitnami-index.yaml").path)
        #expect(try store.index(for: repo, helmCache: helmCache)?.charts.map(\.name) == ["nginx", "valkey"])
    }

    @Test func snapshotReadsConfigAndIndexesAndReportsBrokenOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wh-snap-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cache = root.appending(path: "cache/repository", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HelmPaths(repositoryConfig: root.appending(path: "repositories.yaml"), repositoryCache: cache)
        let empty = await HelmRepositorySnapshot.load(paths: paths, indexCache: root.appending(path: "compact"))
        #expect(!empty.configExists && empty.repositories.isEmpty && empty.charts.isEmpty)

        try Data("repositories:\n- name: good\n  url: https://g\n- name: broken\n  url: https://b\n- name: fresh\n  url: https://f\n- name: oci\n  url: oci://x\n".utf8).write(to: paths.repositoryConfig)
        try Data(Self.index.utf8).write(to: cache.appending(path: "good-index.yaml"))
        try Data("not: an index".utf8).write(to: cache.appending(path: "broken-index.yaml"))
        let snapshot = await HelmRepositorySnapshot.load(paths: paths, indexCache: root.appending(path: "compact"))
        #expect(snapshot.configExists && snapshot.repositories.map(\.name) == ["good", "broken", "fresh", "oci"])
        #expect(snapshot.indexes.keys.sorted() == ["good"] && snapshot.charts.map(\.name) == ["nginx", "redis"])
        #expect(snapshot.errors.keys.sorted() == ["broken"])
        #expect(snapshot.lastUpdated["good"] != nil && snapshot.lastUpdated["fresh"] == nil)      // never updated: no index, no error
    }

    @Test func aLargeIndexParsesCompactlyOnAUtilityQueue() async throws {
        var text = "apiVersion: v1\nentries:\n"
        for c in 0..<100 {
            text += "  chart-\(c):\n"
            for v in 0..<25 {
                text += "    - name: chart-\(c)\n      version: 1.\(25 - v).0\n      appVersion: \"2.\(v)\"\n      description: A fairly long description for chart \(c) so the file grows like a real index does\n      digest: \(String(repeating: "ab", count: 32))\n      urls:\n        - https://charts.example.com/chart-\(c)-1.\(25 - v).0.tgz\n"
            }
        }
        let size = text.utf8.count
        let parsed = try await Task.detached(priority: .utility) { try HelmRepositories.parseIndex(Data(text.utf8), repository: "big") }.value
        #expect(parsed.charts.count == 100 && parsed.charts[0].versions.count == 25)
        #expect(size > 400_000)
    }

    @Test func tarReaderAndChartArchive() throws {
        let tgz = TestTar.tgz([
            ("wh-fixture/Chart.yaml", "apiVersion: v2\nname: wh-fixture\nversion: 0.1.0\n"),
            ("wh-fixture/values.yaml", "replicas: 1\n"),
            ("wh-fixture/README.md", "# Fixture\n"),
            ("wh-fixture/values.schema.json", "{}"),
            ("wh-fixture/templates/configmap.yaml", "kind: ConfigMap\n"),
            ("wh-fixture/charts/sub/values.yaml", "nested: true\n"),
        ])
        let entries = try TarReader.entries(inGzip: tgz)
        #expect(entries.count == 6)
        let archive = try HelmChartArchive.read(tgz: tgz)
        #expect(archive.chartYAML?.contains("wh-fixture") == true)
        #expect(archive.values == "replicas: 1\n")                       // the chart's own values, not the subchart's
        #expect(archive.readme == "# Fixture\n" && archive.schema == "{}")
    }

    @Test func tarReaderRejectsDamage() throws {
        let tar = TestTar.archive([("a/file.txt", String(repeating: "x", count: 1000))])
        #expect(throws: TarReader.TarError.truncated) { try TarReader.entries(in: tar.prefix(700)) }
        #expect(throws: TarReader.TarError.badHeader) { try TarReader.entries(in: tar, maxEntrySize: 10) }
        #expect(try TarReader.entries(in: tar, filter: { _ in false }).isEmpty)
    }
}
