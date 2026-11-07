import Foundation
import Observation
import WheelhouseKit

/// At most four release records are fetched and decoded at once: the table decodes only the rows on screen, on demand.
actor DecodeLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int = 4) { self.limit = limit }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        if running >= limit { await withCheckedContinuation { waiters.append($0) } }
        running += 1
        defer {
            running -= 1
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await work()
    }
}

/// The chart and app version columns need the release payload, which a metadata-only listing does not carry. They fill in as rows
/// appear (and stay in the 32 MB decode cache), so the list itself never reads a payload.
struct ReleaseChartInfo: Hashable, Sendable {
    var chart: String
    var appVersion: String
    var updated: Date?
    var description: String = ""
}

enum DriftState: Equatable, Sendable {
    case checking
    case checked(drifted: Int, total: Int)
    case unavailable(String)
}

@MainActor @Observable
final class ReleasesModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    let session: ClusterSession
    let services: ChartRoomServices
    let limiter = DecodeLimiter()

    private(set) var phase: Phase = .loading
    private(set) var listing: HelmReleaseListing?
    private(set) var owners: [String: GitOpsOwner] = [:]
    private(set) var chartInfo: [String: ReleaseChartInfo] = [:]
    private(set) var drift: [String: DriftState] = [:]
    private(set) var knownNamespaces: [String] = []
    private(set) var loadedAt: Date?

    /// nil = All namespaces (the default).
    var scope: String?
    /// Client-side filter on the namespace column when the list covers every namespace.
    var namespaceFilter: String?
    var search = ""
    var selection: String?

    @ObservationIgnored private var decoding: Set<String> = []
    @ObservationIgnored private var loadGeneration = 0

    init(session: ClusterSession, services: ChartRoomServices, scope: String? = nil) {
        self.session = session
        self.services = services
        self.scope = scope
    }

    var clusterID: ClusterID { session.config.id }

    var visibleReleases: [HelmReleaseSummary] {
        let all = listing?.releases ?? []
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { r in
            if let ns = namespaceFilter, r.namespace != ns { return false }
            guard !query.isEmpty else { return true }
            return r.name.lowercased().contains(query) || r.namespace.lowercased().contains(query)
                || (chartInfo[r.id]?.chart.lowercased().contains(query) ?? false)
        }
    }

    var failure: HelmListFailure? { listing?.failure }

    // MARK: Load (metadata only)

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if listing == nil { phase = .loading }
        do {
            let result = try await HelmReleaseCatalog.load(client: session.client, namespace: scope)
            guard generation == loadGeneration else { return }
            listing = result
            phase = .loaded
            loadedAt = Date()
            if scope == nil { knownNamespaces = Array(Set(result.releases.map(\.namespace))).sorted() }
            if let ns = namespaceFilter, !knownNamespaces.contains(ns) { namespaceFilter = nil }
            await resolveOwners(result.releases)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            phase = .failed((error as? KubeError)?.summary ?? error.localizedDescription)
        }
    }

    /// The ownership badge: the detector (M9) answers from a record's labels and annotations. `NoOwnership` answers nil.
    private func resolveOwners(_ releases: [HelmReleaseSummary]) async {
        var found: [String: GitOpsOwner] = [:]
        for release in releases {
            let metadata: JSONValue = ["metadata": ["name": .string(release.current.objectName), "namespace": .string(release.namespace),
                                                    "labels": .object(release.current.labels.mapValues { .string($0) }),
                                                    "annotations": .object(release.current.annotations.mapValues { .string($0) })]]
            if let owner = await services.ownership.owner(of: metadata, cluster: clusterID) { found[release.id] = owner }
        }
        owners = found
    }

    // MARK: On-demand decode for the visible rows

    func ensureChartInfo(for release: HelmReleaseSummary) async {
        let id = release.id
        guard chartInfo[id] == nil, !decoding.contains(id) else { return }
        decoding.insert(id)
        defer { decoding.remove(id) }
        let reader = HelmReleaseReader(client: session.client, cluster: clusterID, cache: services.releaseCache)
        let revision = release.current
        guard let decoded = try? await limiter.run({ try await reader.read(revision) }) else { return }
        chartInfo[id] = ReleaseChartInfo(chart: "\(decoded.chart.metadata.name)-\(decoded.chart.metadata.version)",
                                         appVersion: decoded.chart.metadata.appVersion ?? "",
                                         updated: decoded.info.lastDeployed)
    }

    func recordDrift(id: String, state: DriftState) { drift[id] = state }
}

// MARK: - One release

@MainActor @Observable
final class ReleaseDetailModel {
    enum Phase: Equatable { case loading, loaded, notFound, failed(String) }

    let session: ClusterSession
    let services: ChartRoomServices
    let namespace: String
    let name: String
    let limiter = DecodeLimiter()

    private(set) var phase: Phase = .loading
    private(set) var summary: HelmReleaseSummary?
    /// The revision on screen. Held only while it is shown: dropped on lock and rebuilt on demand from the reader and its cache.
    private(set) var release: HelmRelease? {
        didSet { manifestObjects = HelmManifest.objects(in: release?.manifest ?? "") }
    }
    /// The manifest split once per decoded release, never in a view body.
    private(set) var manifestObjects: [HelmManifestObject] = []
    private(set) var decodeError: String?
    /// What the history table shows per revision, filled in as rows appear. Facts only: the decoded releases stay in the 32 MB cache.
    private(set) var revisions: [Int: ReleaseChartInfo] = [:]
    private(set) var driftReport: HelmDrift.Report?
    private(set) var driftState: DriftState?
    private(set) var comparison: HelmComparison?
    private(set) var comparisonError: String?
    var selectedRevision: Int?

    @ObservationIgnored private var driftRevisionKey: String?
    @ObservationIgnored var onDrift: ((DriftState) -> Void)?

    init(session: ClusterSession, services: ChartRoomServices, namespace: String, name: String, summary: HelmReleaseSummary? = nil, revision: Int? = nil) {
        self.session = session
        self.services = services
        self.namespace = namespace
        self.name = name
        self.summary = summary
        self.selectedRevision = revision
        if summary != nil { phase = .loaded }
    }

    var clusterID: ClusterID { session.config.id }
    var reader: HelmReleaseReader { HelmReleaseReader(client: session.client, cluster: clusterID, cache: services.releaseCache) }

    /// The revision the detail shows: the one asked for, else the current.
    var shownRevision: HelmRevisionSummary? {
        guard let summary else { return nil }
        return summary.history.first { $0.revision == selectedRevision } ?? summary.current
    }

    func load() async {
        do {
            guard let found = try await HelmReleaseCatalog.release(named: name, namespace: namespace, client: session.client) else {
                phase = .notFound
                return
            }
            summary = found
            phase = .loaded
            await decodeShown()
        } catch is CancellationError {
            return
        } catch {
            phase = .failed((error as? KubeError)?.summary ?? error.localizedDescription)
        }
    }

    func decodeShown() async {
        guard let revision = shownRevision else { return }
        do {
            release = try await reader.read(revision)
            decodeError = nil
        } catch is CancellationError {
            return
        } catch {
            release = nil
            decodeError = (error as? LocalizedError)?.errorDescription ?? (error as? KubeError)?.summary ?? error.localizedDescription
        }
    }

    /// App lock: nothing decoded stays in this model. The view reloads from the reader when the app unlocks.
    func scrub() {
        release = nil
        comparison = nil
        comparisonError = nil
        driftReport = nil
        driftState = nil
        driftRevisionKey = nil
    }

    /// Memory pressure: drop what can be rebuilt (the drift report, a finished comparison); the revision on screen stays.
    func trimTransient() {
        comparison = nil
        driftReport = nil
        driftRevisionKey = nil
        if driftState != .checking { driftState = nil }
    }

    func show(revision: Int) async {
        selectedRevision = revision
        driftReport = nil
        driftState = nil
        await decodeShown()
    }

    // MARK: History

    func ensureRevision(_ revision: HelmRevisionSummary) async {
        guard revisions[revision.revision] == nil else { return }
        let reader = reader
        if let decoded = try? await limiter.run({ try await reader.read(revision) }) {
            revisions[revision.revision] = ReleaseChartInfo(chart: "\(decoded.chart.metadata.name)-\(decoded.chart.metadata.version)",
                                                            appVersion: decoded.chart.metadata.appVersion ?? "", updated: decoded.info.lastDeployed,
                                                            description: decoded.info.description)
        }
    }

    func compare(_ a: Int, _ b: Int) async {
        comparison = nil
        comparisonError = nil
        guard let summary else { return }
        let (older, newer) = (min(a, b), max(a, b))
        let reader = reader
        do {
            guard let oldRevision = summary.history.first(where: { $0.revision == older }),
                  let newRevision = summary.history.first(where: { $0.revision == newer }) else { return }
            async let o = reader.read(oldRevision)
            async let n = reader.read(newRevision)
            let (oldRelease, newRelease) = try await (o, n)
            comparison = HelmComparison.compare(old: oldRelease, new: newRelease)
        } catch {
            comparisonError = (error as? LocalizedError)?.errorDescription ?? (error as? KubeError)?.summary ?? error.localizedDescription
        }
    }

    // MARK: Drift (lazy: one GET per object, four in flight; cached until the revision changes)

    func checkDrift(force: Bool = false) async {
        guard let release, let revision = shownRevision else { return }
        let key = "\(revision.revision)|\(revision.resourceVersion ?? "-")"
        if !force, driftRevisionKey == key, driftReport != nil { return }
        driftState = .checking
        let discovery = try? await session.client.discovery()
        let report = await HelmDrift.check(manifest: release.manifest, releaseNamespace: namespace, client: session.client, discovery: discovery)
        guard !Task.isCancelled else { driftState = nil; return }
        driftReport = report
        driftRevisionKey = key
        let state: DriftState
        if !report.objects.isEmpty, report.objects.allSatisfy({ if case .unreadable = $0.state { true } else { false } }) {
            state = .unavailable("Not permitted to read the live objects")
        } else {
            state = .checked(drifted: report.driftCount, total: report.objects.count)
        }
        driftState = state
        if revision.revision == summary?.current.revision { onDrift?(state) }
    }
}
