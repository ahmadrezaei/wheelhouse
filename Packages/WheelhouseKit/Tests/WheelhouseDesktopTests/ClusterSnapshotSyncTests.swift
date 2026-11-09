#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// `ClusterRegistry.reloadFromStore` (Moorings found, changed or lost a context) posts its event BEFORE it assigns the new list, and
/// posts nothing for a change that needs no new client. Gangway's snapshot must still end up current.
@MainActor
@Suite("Gangway cluster snapshot", .serialized)
struct ClusterSnapshotSyncTests {
    private func cluster(_ id: String, readOnly: Bool = false, server: String = "https://a.test:6443") -> ClusterConfig {
        ClusterConfig(id: id, name: id, server: URL(string: server)!, readOnly: readOnly)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func rig(_ clusters: [ClusterConfig]) throws -> (ClusterRegistry, InMemoryMetadataStore, SnapshotClusterProvider, GangwayService, Scratch) {
        let store = InMemoryMetadataStore(clusters)
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: store, defaults: UserDefaults(suiteName: "wh.m5a.sync.\(UUID().uuidString)") ?? .standard,
                                       clientFactory: { _, _ in DemoFleet.client(for: ClusterConfig(name: "x", server: URL(string: "https://x.test")!, isDemo: true)) })
        let provider = SnapshotClusterProvider { c in GangwayUpstream(config: c, secrets: ClusterSecrets()) }
        let scratch = try Scratch()
        let paths = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: scratch.root, temporaryDirectory: scratch.root.appending(path: "tmp"))
        let service = GangwayService(paths: paths, clusters: provider, gate: { DevSafetyPolicy(isActive: false) }, observesClusterEvents: false)
        return (registry, store, provider, service, scratch)
    }

    @Test("a read-only change and a removal found by a reload reach the snapshot and the sessions")
    func reloadFromStore() async throws {
        let (registry, store, provider, service, scratch) = try rig([cluster("kc-a"), cluster("kc-b")])
        defer { scratch.cleanup(); service.stop() }
        let sync = ClusterSnapshotSync(registry: registry, provider: provider, service: { service })
        sync.start()
        defer { sync.stop() }
        #expect(provider.config(for: "kc-a")?.readOnly == false)
        let session = try await service.openSession(clusterID: "kc-a", origin: .harness("t"))
        let other = try await service.openSession(clusterID: "kc-b", origin: .harness("t"))

        // 1. read-only toggled by the store: the registry posts NOTHING for this (no new client is needed).
        try store.save([cluster("kc-a", readOnly: true), cluster("kc-b")])
        registry.reloadFromStore()
        #expect(try await eventually { provider.config(for: "kc-a")?.readOnly == true })
        #expect(!session.session.isRevoked)

        // 2. the server of kc-a changes: the session of kc-a ends, kc-b's does not.
        try store.save([cluster("kc-a", readOnly: true, server: "https://moved.test:6443"), cluster("kc-b")])
        registry.reloadFromStore()
        #expect(try await eventually { session.session.isRevoked })
        #expect(!other.session.isRevoked)

        // 3. kc-b leaves its kubeconfig: the event arrives before the registry's new list, and the snapshot still drops it.
        try store.save([cluster("kc-a", readOnly: true, server: "https://moved.test:6443")])
        registry.reloadFromStore()
        #expect(try await eventually { provider.config(for: "kc-b") == nil })
        #expect(try await eventually { other.session.isRevoked })
    }
}
#endif
