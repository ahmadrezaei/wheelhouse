import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// The Survey state of one cluster. The RBAC and workload stores run **only while a Survey view of this cluster is visible**
/// (`retain()` when it appears, `release()` when it goes; ARCHITECTURE-MAC §6.2 and §15.1 M8a). While they run, every change
/// reruns the rules off the main actor, debounced.
@MainActor @Observable
final class SurveyModel {
    let clusterID: ClusterID
    let clusterName: String

    private(set) var report: SurveyReport?
    private(set) var isComputing = false
    /// True from the first `retain()` until the last `release()`.
    private(set) var isWatching = false

    @ObservationIgnored private let session: ClusterSession
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var signal: CheckedContinuation<Void, Never>?

    // RBAC and the namespaces (typed).
    @ObservationIgnored private let roles: ResourceStore<Role>
    @ObservationIgnored private let clusterRoles: ResourceStore<ClusterRole>
    @ObservationIgnored private let roleBindings: ResourceStore<RoleBinding>
    @ObservationIgnored private let clusterRoleBindings: ResourceStore<ClusterRoleBinding>
    @ObservationIgnored private let serviceAccounts: ResourceStore<ServiceAccount>
    @ObservationIgnored private let namespaces: ResourceStore<Namespace>
    // Workloads (raw: the rules read security fields the display models do not carry).
    @ObservationIgnored private let controllerStores: [(kind: String, store: ResourceStore<Unstructured>)]
    @ObservationIgnored private let pods: ResourceStore<Unstructured>

    init(session: ClusterSession) {
        self.session = session
        clusterID = session.config.id
        clusterName = session.config.name
        roles = session.store(for: Role.self)
        clusterRoles = session.store(for: ClusterRole.self)
        roleBindings = session.store(for: RoleBinding.self)
        clusterRoleBindings = session.store(for: ClusterRoleBinding.self)
        serviceAccounts = session.store(for: ServiceAccount.self)
        namespaces = session.store(for: Namespace.self)
        let controllerKinds: [(ResourceKind, String)] = [(.deployment, "Deployment"), (.statefulSet, "StatefulSet"), (.daemonSet, "DaemonSet"),
                                                         (.job, "Job"), (.cronJob, "CronJob")]
        controllerStores = controllerKinds.map { (kind: $0.1, store: session.unstructuredStore(kind: $0.0)) }
        pods = session.unstructuredStore(kind: .pod)
    }

    // MARK: Visibility

    /// The number of RBAC stores this model keeps running while watched (for tests and the status line).
    var runningStoreCount: Int { allStoreConsumers.filter { $0 > 0 }.count }
    private var allStoreConsumers: [Int] {
        [roles.consumerCount, clusterRoles.consumerCount, roleBindings.consumerCount, clusterRoleBindings.consumerCount, serviceAccounts.consumerCount,
         namespaces.consumerCount, pods.consumerCount] + controllerStores.map(\.store.consumerCount)
    }

    func retain() {
        viewers += 1
        guard viewers == 1 else { return }
        isWatching = true
        roles.start(); clusterRoles.start(); roleBindings.start(); clusterRoleBindings.start(); serviceAccounts.start(); namespaces.start()
        for c in controllerStores { c.store.start() }
        pods.start()
        loop = Task { [weak self] in await self?.run() }
    }

    func release() {
        guard viewers > 0 else { return }
        viewers -= 1
        guard viewers == 0 else { return }
        isWatching = false
        loop?.cancel()
        loop = nil
        fire()
        roles.stop(); clusterRoles.stop(); roleBindings.stop(); clusterRoleBindings.stop(); serviceAccounts.stop(); namespaces.stop()
        for c in controllerStores { c.store.stop() }
        pods.stop()
    }

    /// Reloads the stores now (the toolbar's Refresh).
    func refresh() async {
        var tasks: [Task<Void, Never>] = [
            Task { await self.roles.refresh() }, Task { await self.clusterRoles.refresh() }, Task { await self.roleBindings.refresh() },
            Task { await self.clusterRoleBindings.refresh() }, Task { await self.serviceAccounts.refresh() }, Task { await self.namespaces.refresh() },
            Task { await self.pods.refresh() },
        ]
        for c in controllerStores { let store = c.store; tasks.append(Task { await store.refresh() }) }
        for t in tasks { await t.value }
        await recompute()
    }

    // MARK: Loop

    private func run() async {
        // Wait for the first lists, then recompute on every change (at most about twice a second).
        while !Task.isCancelled {
            if settled { await recompute() }
            await nextChange()
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Every store has finished its first list (loaded or failed).
    private var settled: Bool {
        func done<T: KubeObject>(_ s: ResourceStore<T>) -> Bool { s.phase == .loaded || s.phase == .failed }
        let typed = done(roles) && done(clusterRoles) && done(roleBindings) && done(clusterRoleBindings) && done(serviceAccounts) && done(namespaces)
        return typed && done(pods) && controllerStores.allSatisfy { done($0.store) }
    }

    private func nextChange() async {
        guard !Task.isCancelled, viewers > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            signal = continuation
            withObservationTracking {
                _ = roles.items; _ = clusterRoles.items; _ = roleBindings.items; _ = clusterRoleBindings.items; _ = serviceAccounts.items
                _ = namespaces.items; _ = pods.items
                for c in controllerStores { _ = c.store.items }
                _ = roles.phase; _ = clusterRoles.phase; _ = roleBindings.phase; _ = clusterRoleBindings.phase; _ = serviceAccounts.phase
                _ = namespaces.phase; _ = pods.phase
                for c in controllerStores { _ = c.store.phase }
            } onChange: { [weak self] in
                Task { @MainActor in self?.fire() }
            }
        }
    }

    private func fire() {
        let c = signal
        signal = nil
        c?.resume()
    }

    // MARK: Snapshot

    func makeSnapshot() -> SurveySnapshot {
        var limitations: [SurveyLimitation] = []
        func note<T: KubeObject>(_ store: ResourceStore<T>, _ name: String) {
            if store.phase == .failed, let e = store.error { limitations.append(SurveyLoader.limitation(name, e)) }
        }
        note(roles, "Roles"); note(clusterRoles, "ClusterRoles"); note(roleBindings, "RoleBindings"); note(clusterRoleBindings, "ClusterRoleBindings")
        note(serviceAccounts, "ServiceAccounts"); note(namespaces, "Namespaces")
        var controllers: [String: [JSONValue]] = [:]
        for c in controllerStores {
            if c.store.phase == .failed { note(c.store, c.kind + "s") } else { controllers[c.kind] = c.store.items.map(\.raw) }
        }
        var podList: [JSONValue]?
        if pods.phase == .failed { note(pods, "Pods") } else { podList = pods.items.map(\.raw) }
        return SurveySnapshot(clusterID: clusterID, roles: roles.items, clusterRoles: clusterRoles.items, roleBindings: roleBindings.items,
                              clusterRoleBindings: clusterRoleBindings.items, serviceAccounts: serviceAccounts.items, namespaces: namespaces.items,
                              workloads: SurveySnapshot.workloads(controllers: controllers, pods: podList), limitations: limitations.sorted { $0.kind < $1.kind })
    }

    /// Runs the rules over the current store contents, off the main actor.
    func recompute() async {
        guard !isComputing else { return }
        isComputing = true
        defer { isComputing = false }
        let snapshot = makeSnapshot()
        report = await SurveyEngine.run(snapshot)
    }
}

/// One cluster's one-shot result for the fleet overview (no watches: loaded when the fleet Survey opens or is refreshed).
struct FleetSurveyEntry: Identifiable {
    enum State { case loading, done(SurveyReport), failed(String) }
    var id: ClusterID
    var name: String
    var environment: ClusterEnvironment
    var state: State
    var report: SurveyReport? { if case .done(let r) = state { r } else { nil } }
}

/// App-wide Survey state: the per-cluster models, the fleet results and the accepted risks.
@MainActor @Observable
final class SurveyHub {
    static let shared = SurveyHub(riskFile: AppPaths.current.root.appending(path: "survey-accepted-risks.json"))

    private(set) var risks: AcceptedRiskBook
    private(set) var fleet: [FleetSurveyEntry] = []
    private(set) var isLoadingFleet = false
    @ObservationIgnored private var models: [ClusterID: SurveyModel] = [:]
    @ObservationIgnored private let riskFile: URL?

    init(riskFile: URL?) {
        self.riskFile = riskFile
        risks = riskFile.map(AcceptedRiskStorage.load(from:)) ?? AcceptedRiskBook()
    }

    func model(for session: ClusterSession) -> SurveyModel {
        if let m = models[session.config.id] { return m }
        let m = SurveyModel(session: session)
        models[session.config.id] = m
        return m
    }

    /// The most recent report of a cluster, from its live model or the fleet load.
    func report(for clusterID: ClusterID) -> SurveyReport? {
        models[clusterID]?.report ?? fleet.first { $0.id == clusterID }?.report
    }

    // MARK: Accepted risks

    func accept(_ finding: SecurityFinding, scope: AcceptanceScope, reason: String, days: Int) {
        risks.accept(finding, scope: scope, reason: reason, days: days)
        persist()
    }

    func removeRisk(_ id: UUID) {
        risks.remove(id)
        persist()
    }

    func removeExpiredRisks() {
        risks.removeExpired()
        persist()
    }

    private func persist() {
        guard let riskFile else { return }
        try? AcceptedRiskStorage.save(risks, to: riskFile)
    }

    // MARK: Fleet

    /// Loads every cluster once, two at a time. Clusters without usable credentials are listed with the reason.
    func loadFleet(registry: ClusterRegistry) async {
        guard !isLoadingFleet else { return }
        isLoadingFleet = true
        defer { isLoadingFleet = false }
        let clusters = registry.clusters
        fleet = clusters.map { FleetSurveyEntry(id: $0.id, name: $0.name, environment: $0.environment, state: .loading) }
        var jobs: [(ClusterID, any KubeClientProtocol)] = []
        for c in clusters {
            guard let session = registry.session(for: c.id) else { setFailed(c.id, "Not available"); continue }
            if session.credentialsMissing { setFailed(c.id, "Credentials are not on this device"); continue }
            jobs.append((c.id, session.client))
        }
        // Two clusters at a time.
        let results = await withTaskGroup(of: (ClusterID, SurveyReport?, String?).self, returning: [(ClusterID, SurveyReport?, String?)].self) { group in
            var out: [(ClusterID, SurveyReport?, String?)] = []
            var iterator = jobs.makeIterator()
            func add() {
                guard let (id, client) = iterator.next() else { return }
                group.addTask {
                    let snapshot = await SurveyLoader.load(client: client, clusterID: id)
                    if snapshot.limitations.count >= 6 && snapshot.bindingCount == 0 {
                        return (id, nil, snapshot.limitations.first?.message ?? "The cluster could not be read")
                    }
                    return (id, await SurveyEngine.run(snapshot), nil)
                }
            }
            add(); add()
            for await result in group { out.append(result); add() }
            return out
        }
        for (id, report, failure) in results {
            if let report { set(id, .done(report)) } else { setFailed(id, failure ?? "Failed") }
        }
    }

    private func set(_ id: ClusterID, _ state: FleetSurveyEntry.State) {
        if let i = fleet.firstIndex(where: { $0.id == id }) { fleet[i].state = state }
    }
    private func setFailed(_ id: ClusterID, _ message: String) { set(id, .failed(message)) }
}
