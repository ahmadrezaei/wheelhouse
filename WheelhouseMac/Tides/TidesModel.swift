import Foundation
import Observation
import WheelhouseKit

/// What Tides knows about one cluster: which GitOps kinds it serves (CRD discovery) and the shared stores over them.
///
/// The model never starts a watch by itself. Views call ``run(includeSources:)`` from `.task`, so the stores run exactly as long
/// as a Tides view is visible (ARCHITECTURE-MAC §12.3: GitOps stores run only while their views are visible).
@MainActor @Observable
final class TidesClusterModel: Identifiable {
    let session: ClusterSession
    private(set) var detection = GitOpsDetection()
    private(set) var discoveryDone = false

    nonisolated var id: ClusterID { session.id }
    var name: String { session.config.name }
    var config: ClusterConfig { session.config }

    init(session: ClusterSession) { self.session = session }

    /// Reads discovery (cached per cluster) and detects Flux and Argo CD.
    func loadDiscovery() async {
        if session.discovery == nil { await session.loadDiscovery() }
        detection = GitOpsDetection.detect(session.discovery)
        discoveryDone = true
    }

    /// The kinds a view needs: the app kinds always, the Flux sources when asked.
    func kinds(includeSources: Bool) -> [ResourceKind] {
        detection.appKinds + (includeSources ? detection.fluxSources : [])
    }

    func store(for kind: ResourceKind) -> ResourceStore<Unstructured> { session.unstructuredStore(kind: kind) }

    /// Starts the stores of this cluster's GitOps kinds (discovery must be loaded). Pair with ``release(_:)``.
    func acquire(includeSources: Bool) -> [ResourceStore<Unstructured>] {
        let stores = kinds(includeSources: includeSources).map(store(for:))
        stores.forEach { $0.start() }
        return stores
    }

    func release(_ stores: [ResourceStore<Unstructured>]) { stores.forEach { $0.stop() } }

    /// Keeps the stores of this cluster's GitOps kinds alive until the calling task is cancelled.
    func run(includeSources: Bool) async {
        await loadDiscovery()
        guard !Task.isCancelled else { return }
        let stores = acquire(includeSources: includeSources)
        // Hold the watches until this task is cancelled (the view went away, or its window was hidden), then release them.
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        release(stores)
    }

    /// Every object of the given kinds as Overview rows.
    func rows(of kinds: [ResourceKind]) -> [GitOpsApp] {
        kinds.flatMap { kind in store(for: kind).items.compactMap { GitOpsApp(raw: $0.raw, kind: kind) } }
    }

    var apps: [GitOpsApp] { rows(of: detection.appKinds) }
    var sources: [GitOpsApp] { rows(of: detection.fluxSources) }

    /// The first failure among the running stores (for the empty and error states).
    var storeError: KubeError? {
        detection.appKinds.lazy.compactMap { self.store(for: $0).error }.first
    }
    var isLoading: Bool { !discoveryDone || detection.appKinds.contains { store(for: $0).isLoading } }

    func app(id: String) -> GitOpsApp? { (apps + sources).first { $0.id == id } }
}

/// One Overview row: an app with the cluster it lives in.
struct TidesRow: Identifiable, Hashable {
    var cluster: ClusterID
    var clusterName: String
    var app: GitOpsApp
    var id: String { "\(cluster)/\(app.id)" }
}

/// The four tiles of the Overview.
struct TidesTally: Equatable {
    var outOfSync = 0
    var degraded = 0
    var suspended = 0
    var failedReconcile = 0

    init(_ apps: [GitOpsApp]) {
        for a in apps where !a.flavor.isSource {
            if a.sync == .outOfSync && !a.suspended { outOfSync += 1 }
            if a.health == .degraded || a.health == .missing { degraded += 1 }
            if a.suspended || a.health == .suspended { suspended += 1 }
            if a.tool == .flux && a.health == .degraded { failedReconcile += 1 }
        }
    }
}

/// Where the Argo CD API of a cluster is, and whether this Mac holds a token for it. The token lives in the Mac-private keychain
/// group (this device only, never synchronised); the location is a plain preference.
struct ArgoConnection: @unchecked Sendable {
    var readToken: @Sendable (ClusterID) -> String?
    var writeToken: @Sendable (String?, ClusterID) -> Bool
    var defaults: UserDefaults = .standard

    static let live = ArgoConnection(
        readToken: { id in (try? MacPrivateSecretStore(.argoToken).read(account: id)).flatMap { $0 } },
        writeToken: { token, id in
            let store = MacPrivateSecretStore(.argoToken)
            do {
                if let token, !token.isEmpty { try store.write(token, account: id) } else { try store.delete(account: id) }
                return true
            } catch { return false }
        })

    private func key(_ id: ClusterID) -> String { "tides.argoLocation.\(id)" }
    static let defaultLocationKey = "tides.argoDefaultLocation"

    func location(for id: ClusterID) -> ArgoServiceLocation {
        decode(defaults.data(forKey: key(id))) ?? decode(defaults.data(forKey: Self.defaultLocationKey)) ?? ArgoServiceLocation()
    }
    func setLocation(_ l: ArgoServiceLocation, for id: ClusterID) { defaults.set(try? JSONEncoder().encode(l), forKey: key(id)) }
    func defaultLocation() -> ArgoServiceLocation { decode(defaults.data(forKey: Self.defaultLocationKey)) ?? ArgoServiceLocation() }
    func setDefaultLocation(_ l: ArgoServiceLocation) { defaults.set(try? JSONEncoder().encode(l), forKey: Self.defaultLocationKey) }
    func hasToken(_ id: ClusterID) -> Bool { readToken(id) != nil }

    /// The API client for a cluster, or nil without a token.
    @MainActor func api(for session: ClusterSession) -> ArgoAPI? {
        guard let token = readToken(session.id), !token.isEmpty else { return nil }
        return ArgoAPI(client: session.client, location: location(for: session.id), token: token)
    }

    private func decode(_ d: Data?) -> ArgoServiceLocation? { d.flatMap { try? JSONDecoder().decode(ArgoServiceLocation.self, from: $0) } }
}
