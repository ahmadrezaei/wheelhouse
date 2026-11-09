#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseKit

/// Live checks against the TEST cluster only. Seed first: `scripts/testcluster-fixtures.sh --section m7-schema` (and `m9-gitops` for the
/// Flux and Argo CD CRDs).
///
///   WH_LIVE_TESTS=1 WH_TEST_KUBECONFIG=<repo>/.testcluster/kubeconfig swift test --filter SchemaLiveTests
///
/// It uses the same harness as `HelmLiveTests` (refuses any cluster but `wheelhouse-test`; never reads `~/.kube` or `.secrets/`).
@Suite("Schema live (test cluster only)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["WH_LIVE_TESTS"] == "1"))
struct SchemaLiveTests {
    func store() async throws -> (OpenAPIStore, HelmLiveTests.Harness, URL) {
        let h = try HelmLiveTests.harness()
        let version = try await h.client.version().gitVersion
        let dir = tempDirectory()
        return (OpenAPIStore(cluster: h.config.id, serverVersion: version, cacheRoot: dir, client: h.client), h, dir)
    }

    @Test func coreKindsComeFromTheClusterAndAreCachedOnDisk() async throws {
        let (store, h, dir) = try await store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deployment = try #require(await store.kindSchema(for: GroupVersionKind(group: "apps", version: "v1", kind: "Deployment")))
        #expect(deployment.source == .cluster)
        #expect(await store.downloads == 1)
        // Completions inside a pod template.
        let text = "apiVersion: apps/v1\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: web\n          image: nginx\n          resou\n"
        let result = await ManifestAssist.completions(text: text, offset: (text as NSString).length - 1, schemas: store)
        #expect(result.items.map(\.label) == ["resources", "resizePolicy"] || result.items.map(\.label).contains("resources"), "\(result.items.map(\.label))")
        // A second store (a new launch) reads the disk copy.
        let version = try await h.client.version().gitVersion
        let again = OpenAPIStore(cluster: h.config.id, serverVersion: version, cacheRoot: dir, client: h.client)
        #expect(await again.kindSchema(for: GroupVersionKind(group: "apps", version: "v1", kind: "Deployment")) != nil)
        #expect(await again.downloads == 0)
    }

    @Test func theFullCoreDocumentFitsTheBudget() async throws {
        let (store, _, dir) = try await store()
        defer { try? FileManager.default.removeItem(at: dir) }
        for gvk in [GroupVersionKind(group: "", version: "v1", kind: "Pod"), GroupVersionKind(group: "apps", version: "v1", kind: "Deployment"),
                    GroupVersionKind(group: "batch", version: "v1", kind: "Job")] {
            #expect(await store.kindSchema(for: gvk) != nil)
        }
        let cost = await store.memoryCost
        print("SCHEMA live: core + apps + batch documents estimate \(cost / 1024) KB of \(await store.memoryLimit / 1024) KB")
        #expect(cost > 0 && cost <= 32 * 1024 * 1024)
    }

    @Test func theCrdOfTheFixtureCompletesAndValidates() async throws {
        let (store, _, dir) = try await store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gvk = GroupVersionKind(group: "m7.wheelhouse.test", version: "v1", kind: "Widget")
        let widget = try #require(await store.kindSchema(for: gvk), "seed first: scripts/testcluster-fixtures.sh --section m7-schema")
        #expect(widget.source == .cluster)

        let keys = "apiVersion: m7.wheelhouse.test/v1\nkind: Widget\nspec:\n  \n"
        let fields = await ManifestAssist.completions(text: keys, offset: (keys as NSString).length - 1, schemas: store)
        #expect(Set(fields.items.map(\.label)) == ["replicas", "size", "tags"])
        #expect(fields.items.first?.detail == "string · required")

        let values = "apiVersion: m7.wheelhouse.test/v1\nkind: Widget\nspec:\n  size: \n"
        let sizes = await ManifestAssist.completions(text: values, offset: (values as NSString).length - 1, schemas: store)
        #expect(sizes.items.map(\.label) == ["small", "medium", "large"])

        let bad = "apiVersion: m7.wheelhouse.test/v1\nkind: Widget\nmetadata:\n  name: w\nspec:\n  size: huge\n  replicas: -1\n  colour: red\n"
        let analysis = await ManifestAnalyzer(schemas: store).analyze(bad)
        let messages = analysis.diagnostics.map(\.message)
        #expect(messages.contains { $0.hasPrefix("Must be one of: small, medium, large") })
        #expect(messages.contains { $0.hasPrefix("Must be at least 0") })
        #expect(messages.contains { $0.hasPrefix("Unknown field “colour”") })
        #expect(analysis.schemaNote == nil)
        let good = "apiVersion: m7.wheelhouse.test/v1\nkind: Widget\nmetadata:\n  name: w\nspec:\n  size: small\nstatus:\n  anything: [1]\n"
        #expect(await ManifestAnalyzer(schemas: store).analyze(good).diagnostics.isEmpty)
    }

    @Test func theGitOpsCrdsOfTheFixturesAreFoundAndStayOpen() async throws {
        let (store, _, dir) = try await store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kustomization = GroupVersionKind(group: "kustomize.toolkit.fluxcd.io", version: "v1", kind: "Kustomization")
        let found = try #require(await store.kindSchema(for: kustomization), "seed first: scripts/testcluster-fixtures.sh --section m9-gitops")
        #expect(found.source == .cluster)
        // preserve-unknown-fields: any spec validates, the envelope still completes.
        let text = "apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\nmetadata:\n  name: apps\nspec:\n  path: ./apps\n  anything: [1, 2]\n"
        #expect(await ManifestAnalyzer(schemas: store).analyze(text).diagnostics.isEmpty)
        let top = "apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\n\n"
        let items = await ManifestAssist.completions(text: top, offset: (top as NSString).length - 1, schemas: store).items.map(\.label)
        #expect(items.contains("metadata"))       // the CRD declares nothing else: spec is free-form
    }

    @Test func referencesAreCompletedFromTheClusterByNameOnly() async throws {
        let (_, h, dir) = try await store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let refs = ClusterReferences(client: h.client)
        let accounts = await refs.names(.serviceAccount, "wh-m7")
        #expect(accounts.contains("m7-sa") && accounts.contains("default"))
        #expect(await refs.names(.configMap, "wh-m7").contains("m7-config"))
        // Secrets: names only (the metadata list carries no data).
        let secrets = await refs.names(.secret, "kube-system")
        #expect(secrets.allSatisfy { !$0.isEmpty })
    }

    @Test func theIndexIsServedAndOtherPathsAreRefused() async throws {
        let h = try HelmLiveTests.harness()
        let index = try JSONValue.parse(try await h.client.openAPIDocument(path: "/openapi/v3"))
        #expect(index.value(at: "paths")?.objectValue?["apis/apps/v1"] != nil)
        await #expect(throws: KubeError.self) { _ = try await h.client.openAPIDocument(path: "/api/v1/secrets") }
    }
}
#endif
