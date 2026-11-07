import Foundation

// Views over `JSONValue` for Flux and Argo CD objects (ARCHITECTURE-MAC section 7). Nothing here decodes into a rigid struct:
// a new CRD version with extra or moved fields still shows what it can.

// MARK: - Shared vocabulary

public enum GitOpsSyncStatus: String, Sendable, Hashable, CaseIterable {
    case synced = "Synced", outOfSync = "OutOfSync", unknown = "Unknown"
}

public enum GitOpsHealth: String, Sendable, Hashable, CaseIterable {
    case healthy = "Healthy", progressing = "Progressing", degraded = "Degraded", suspended = "Suspended", missing = "Missing", unknown = "Unknown"
}

/// A `status.conditions` entry.
public struct GitOpsCondition: Hashable, Sendable, Identifiable {
    public var type: String
    public var status: String
    public var reason: String?
    public var message: String?
    public var lastTransition: Date?
    public var id: String { type }
    public var isTrue: Bool { status == "True" }

    init?(_ v: JSONValue) {
        guard let type = v["type"]?.stringValue else { return nil }
        self.type = type
        status = v["status"]?.stringValue ?? "Unknown"
        reason = v["reason"]?.stringValue
        message = v["message"]?.stringValue
        lastTransition = (v["lastTransitionTime"]?.stringValue).flatMap(GitOpsDates.parse)
    }

    public static func list(_ raw: JSONValue, at path: String = "status.conditions") -> [GitOpsCondition] {
        (raw.value(at: path)?.arrayValue ?? []).compactMap(GitOpsCondition.init)
    }
}

enum GitOpsDates {
    static func parse(_ s: String) -> Date? {
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        return try? Date.ISO8601FormatStyle().parse(s)
    }
}

public enum GitOpsRevision {
    /// `main@sha1:3f2a9c1d…` becomes `main@3f2a9c1`; a 40-hex Git SHA becomes 7 characters; chart versions are kept.
    public static func short(_ revision: String?) -> String? {
        guard var r = revision, !r.isEmpty else { return nil }
        if let at = r.firstIndex(of: "@"), let colon = r[at...].firstIndex(of: ":") {
            let digest = r[r.index(after: colon)...]
            r = "\(r[..<at])@\(digest.prefix(7))"
            return r
        }
        if r.count >= 40, r.allSatisfy(\.isHexDigit) { return String(r.prefix(7)) }
        if r.hasPrefix("sha256:") { return "sha256:" + r.dropFirst(7).prefix(7) }
        return r
    }
}

// MARK: - The row shown in the Overview

/// One Flux or Argo CD object as an Overview row. Sources are rows too (sync = fetched, health = ready).
public struct GitOpsApp: Identifiable, Hashable, Sendable {
    public enum Flavor: String, Sendable, Hashable, CaseIterable {
        case fluxKustomization, fluxHelmRelease, fluxGitRepository, fluxOCIRepository, fluxHelmRepository, fluxHelmChart, fluxBucket
        case argoApplication

        public var tool: GitOpsOwner.Tool { self == .argoApplication ? .argoCD : .flux }
        public var isSource: Bool {
            switch self {
            case .fluxGitRepository, .fluxOCIRepository, .fluxHelmRepository, .fluxHelmChart, .fluxBucket: true
            default: false
            }
        }
        public var title: String {
            switch self {
            case .fluxKustomization: "Kustomization"
            case .fluxHelmRelease: "HelmRelease"
            case .fluxGitRepository: "GitRepository"
            case .fluxOCIRepository: "OCIRepository"
            case .fluxHelmRepository: "HelmRepository"
            case .fluxHelmChart: "HelmChart"
            case .fluxBucket: "Bucket"
            case .argoApplication: "Application"
            }
        }
        static func of(_ kind: ResourceKind) -> Flavor? {
            switch (kind.group, kind.kind) {
            case ("kustomize.toolkit.fluxcd.io", "Kustomization"): .fluxKustomization
            case ("helm.toolkit.fluxcd.io", "HelmRelease"): .fluxHelmRelease
            case ("source.toolkit.fluxcd.io", "GitRepository"): .fluxGitRepository
            case ("source.toolkit.fluxcd.io", "OCIRepository"): .fluxOCIRepository
            case ("source.toolkit.fluxcd.io", "HelmRepository"): .fluxHelmRepository
            case ("source.toolkit.fluxcd.io", "HelmChart"): .fluxHelmChart
            case ("source.toolkit.fluxcd.io", "Bucket"): .fluxBucket
            case ("argoproj.io", "Application"): .argoApplication
            default: nil
            }
        }
    }

    public var flavor: Flavor
    public var kind: ResourceKind
    public var name: String
    public var namespace: String?
    /// Argo CD project, when this is an Application.
    public var project: String?
    /// `repo + path`, chart, or URL.
    public var source: String
    public var targetRevision: String?
    public var liveRevision: String?
    public var sync: GitOpsSyncStatus
    public var health: GitOpsHealth
    public var suspended: Bool
    public var lastActivity: Date?
    public var message: String?
    public var raw: JSONValue

    public var id: String { Self.identifier(kind: kind, namespace: namespace, name: name) }
    public static func identifier(kind: ResourceKind, namespace: String?, name: String) -> String { "\(kind.id)/\(namespace ?? "-")/\(name)" }
    public var tool: GitOpsOwner.Tool { flavor.tool }

    /// Out of sync, degraded or failing: sorted first.
    public var isProblem: Bool { sync == .outOfSync || health == .degraded || health == .missing }
    public var isFailedReconcile: Bool { health == .degraded }
    public var revisionDiffers: Bool { targetRevision != nil && liveRevision != nil && targetRevision != liveRevision }

    /// Problems first, then by namespace and name.
    public static func problemsFirst(_ a: GitOpsApp, _ b: GitOpsApp) -> Bool {
        if a.isProblem != b.isProblem { return a.isProblem }
        return (a.namespace ?? "", a.name, a.kind.kind) < (b.namespace ?? "", b.name, b.kind.kind)
    }

    public init?(raw: JSONValue, kind: ResourceKind) {
        guard let flavor = Flavor.of(kind), let name = raw.value(at: "metadata.name")?.stringValue else { return nil }
        self.flavor = flavor
        self.kind = kind
        self.name = name
        self.namespace = raw.value(at: "metadata.namespace")?.stringValue
        self.raw = raw
        self.project = nil
        self.source = ""
        self.targetRevision = nil
        self.liveRevision = nil
        self.sync = .unknown
        self.health = .unknown
        self.suspended = false
        self.lastActivity = nil
        self.message = nil
        if flavor == .argoApplication { fillArgo() } else { fillFlux() }
    }

    private mutating func fillFlux() {
        let f = FluxView(raw: raw, flavor: flavor)
        suspended = f.suspended
        source = f.sourceDescription
        message = f.readyCondition?.message
        lastActivity = f.readyCondition?.lastTransition ?? f.artifactUpdatedAt
        switch flavor {
        case .fluxKustomization, .fluxHelmRelease:
            liveRevision = f.lastAppliedRevision
            targetRevision = f.lastAttemptedRevision ?? f.lastAppliedRevision
        default:
            liveRevision = f.artifactRevision
            targetRevision = f.artifactRevision
        }
        let ready = f.readyCondition
        if f.suspended {
            health = .suspended
        } else if f.stalled || ready?.status == "False" {
            health = .degraded
        } else if f.reconciling || ready == nil || ready?.status == "Unknown" {
            health = ready == nil && !f.reconciling ? .unknown : .progressing
        } else {
            health = .healthy
        }
        switch ready?.status {
        case "True": sync = (f.lastAttemptedRevision != nil && f.lastAppliedRevision != nil && f.lastAttemptedRevision != f.lastAppliedRevision) ? .outOfSync : .synced
        case "False": sync = .outOfSync
        default: sync = .unknown
        }
    }

    private mutating func fillArgo() {
        let a = ArgoView(raw: raw)
        project = a.project
        source = a.sourceDescription
        sync = a.syncStatus
        health = a.health
        liveRevision = a.syncRevision
        targetRevision = a.targetRevision
        lastActivity = a.operationState?.finishedAt ?? a.reconciledAt
        message = a.operationState?.message ?? a.conditions.first?.message ?? a.healthMessage
    }
}

// MARK: - Flux

public struct FluxInventoryEntry: Hashable, Sendable, Identifiable {
    public var namespace: String?
    public var name: String
    public var group: String
    public var kind: String
    public var version: String?
    public var id: String { "\(namespace ?? "")/\(group)/\(kind)/\(name)" }

    /// Parses Flux's object id `<namespace>_<name>_<group>_<kind>`. The name is everything between the namespace and the last two
    /// parts, and Flux encodes a `:` in names as `__`. The namespace is empty for cluster-scoped objects and the group is empty
    /// for the core group.
    public static func parse(id: String, version: String?) -> FluxInventoryEntry? {
        let parts = id.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        let name = parts[1..<(parts.count - 2)].joined(separator: "_").replacingOccurrences(of: "__", with: ":")
        guard !name.isEmpty else { return nil }
        return FluxInventoryEntry(namespace: parts[0].isEmpty ? nil : parts[0], name: name, group: parts[parts.count - 2],
                                  kind: parts[parts.count - 1], version: version)
    }
}

public struct FluxObjectRef: Hashable, Sendable {
    public var kind: String?
    public var name: String
    public var namespace: String?
    init?(_ v: JSONValue?, defaultNamespace: String?) {
        guard let v, let name = v["name"]?.stringValue else { return nil }
        self.kind = v["kind"]?.stringValue
        self.name = name
        self.namespace = v["namespace"]?.stringValue ?? defaultNamespace
    }
}

public struct FluxHelmHistoryEntry: Hashable, Sendable, Identifiable {
    public var version: Int?
    public var chartName: String?
    public var chartVersion: String?
    public var appVersion: String?
    public var status: String?
    public var deployed: Date?
    public var id: String { "\(version ?? 0)-\(chartVersion ?? "")-\(status ?? "")" }
}

public struct FluxView: Sendable {
    public var raw: JSONValue
    public var flavor: GitOpsApp.Flavor

    public init(raw: JSONValue, flavor: GitOpsApp.Flavor) {
        self.raw = raw
        self.flavor = flavor
    }

    public var namespace: String? { raw.value(at: "metadata.namespace")?.stringValue }
    public var conditions: [GitOpsCondition] { GitOpsCondition.list(raw) }
    public var readyCondition: GitOpsCondition? { conditions.first { $0.type == "Ready" } }
    public var reconciling: Bool { conditions.first { $0.type == "Reconciling" }?.isTrue ?? false }
    public var stalled: Bool { conditions.first { $0.type == "Stalled" }?.isTrue ?? false }
    public var suspended: Bool { raw.value(at: "spec.suspend")?.boolValue ?? false }
    public var interval: String? { raw.value(at: "spec.interval")?.stringValue }
    public var lastAppliedRevision: String? { raw.value(at: "status.lastAppliedRevision")?.stringValue }
    public var lastAttemptedRevision: String? { raw.value(at: "status.lastAttemptedRevision")?.stringValue }
    public var artifactRevision: String? { raw.value(at: "status.artifact.revision")?.stringValue }
    public var artifactUpdatedAt: Date? { (raw.value(at: "status.artifact.lastUpdateTime")?.stringValue).flatMap(GitOpsDates.parse) }
    public var url: String? { raw.value(at: "spec.url")?.stringValue }
    public var path: String? { raw.value(at: "spec.path")?.stringValue }
    /// The token Flux sets after it handled a reconcile request; equals the last `requestedAt` once handled.
    public var lastHandledReconcileAt: String? { raw.value(at: "status.lastHandledReconcileAt")?.stringValue }

    public var sourceRef: FluxObjectRef? {
        FluxObjectRef(raw.value(at: "spec.sourceRef") ?? raw.value(at: "spec.chart.spec.sourceRef") ?? raw.value(at: "spec.chartRef"),
                      defaultNamespace: namespace)
    }

    public var dependsOn: [FluxObjectRef] {
        (raw.value(at: "spec.dependsOn")?.arrayValue ?? []).compactMap { FluxObjectRef($0, defaultNamespace: namespace) }
    }

    public var inventory: [FluxInventoryEntry] {
        (raw.value(at: "status.inventory.entries")?.arrayValue ?? []).compactMap {
            guard let id = $0["id"]?.stringValue else { return nil }
            return FluxInventoryEntry.parse(id: id, version: $0["v"]?.stringValue)
        }
    }

    public var helmHistory: [FluxHelmHistoryEntry] {
        (raw.value(at: "status.history")?.arrayValue ?? []).map {
            FluxHelmHistoryEntry(version: $0["version"]?.intValue, chartName: $0["chartName"]?.stringValue,
                                 chartVersion: $0["chartVersion"]?.stringValue, appVersion: $0["appVersion"]?.stringValue,
                                 status: $0["status"]?.stringValue,
                                 deployed: ($0["lastDeployed"]?.stringValue ?? $0["firstDeployed"]?.stringValue).flatMap(GitOpsDates.parse))
        }
    }

    /// `repo path`, chart, or URL, whichever fits the kind.
    public var sourceDescription: String {
        switch flavor {
        case .fluxKustomization:
            return [sourceRef.map { "\($0.kind ?? "Source")/\($0.name)" }, path].compactMap { $0 }.joined(separator: " ")
        case .fluxHelmRelease:
            let chart = raw.value(at: "spec.chart.spec.chart")?.stringValue ?? raw.value(at: "spec.chartRef.name")?.stringValue
            let version = raw.value(at: "spec.chart.spec.version")?.stringValue
            return [chart, version].compactMap { $0 }.joined(separator: " ")
        default:
            return url ?? raw.value(at: "spec.bucketName")?.stringValue ?? ""
        }
    }
}

// MARK: - Argo CD

public struct ArgoResourceStatus: Hashable, Sendable, Identifiable {
    public var group: String
    public var version: String?
    public var kind: String
    public var namespace: String?
    public var name: String
    public var sync: GitOpsSyncStatus
    public var health: GitOpsHealth?
    public var healthMessage: String?
    public var hook: Bool
    public var requiresPruning: Bool
    public var id: String { "\(group)/\(kind)/\(namespace ?? "")/\(name)" }
    /// `Deployment/ns/name`
    public var display: String { [kind, namespace, name].compactMap { $0 }.joined(separator: "/") }

    init?(_ v: JSONValue) {
        guard let kind = v["kind"]?.stringValue, let name = v["name"]?.stringValue else { return nil }
        group = v["group"]?.stringValue ?? ""
        version = v["version"]?.stringValue
        self.kind = kind
        self.name = name
        namespace = v["namespace"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        sync = GitOpsSyncStatus(rawValue: v["status"]?.stringValue ?? "") ?? .unknown
        health = (v.value(at: "health.status")?.stringValue).flatMap { GitOpsHealth(rawValue: $0) }
        healthMessage = v.value(at: "health.message")?.stringValue
        hook = v["hook"]?.boolValue ?? false
        requiresPruning = v["requiresPruning"]?.boolValue ?? false
    }
}

public struct ArgoHistoryEntry: Hashable, Sendable, Identifiable {
    public var id: Int
    public var revision: String?
    public var revisions: [String]
    public var deployedAt: Date?
    public var source: JSONValue?
    public var sources: [JSONValue]
    public var initiatedBy: String?

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.intValue else { return nil }
        self.id = id
        revision = v["revision"]?.stringValue
        revisions = (v["revisions"]?.arrayValue ?? []).compactMap(\.stringValue)
        deployedAt = (v["deployedAt"]?.stringValue).flatMap(GitOpsDates.parse)
        source = v["source"]
        sources = v["sources"]?.arrayValue ?? []
        initiatedBy = v.value(at: "initiatedBy.username")?.stringValue
    }
}

public struct ArgoOperationState: Hashable, Sendable {
    public var phase: String
    public var message: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var revision: String?
    public var isRunning: Bool { phase == "Running" || phase == "Terminating" }

    init?(_ v: JSONValue?) {
        guard let v, let phase = v["phase"]?.stringValue else { return nil }
        self.phase = phase
        message = v["message"]?.stringValue
        startedAt = (v["startedAt"]?.stringValue).flatMap(GitOpsDates.parse)
        finishedAt = (v["finishedAt"]?.stringValue).flatMap(GitOpsDates.parse)
        revision = v.value(at: "syncResult.revision")?.stringValue
    }
}

public struct ArgoSource: Hashable, Sendable {
    public var repoURL: String?
    public var path: String?
    public var chart: String?
    public var targetRevision: String?
    init(_ v: JSONValue) {
        repoURL = v["repoURL"]?.stringValue
        path = v["path"]?.stringValue
        chart = v["chart"]?.stringValue
        targetRevision = v["targetRevision"]?.stringValue
    }
}

public struct ArgoView: Sendable {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }

    public var project: String? { raw.value(at: "spec.project")?.stringValue }
    public var syncStatus: GitOpsSyncStatus { GitOpsSyncStatus(rawValue: raw.value(at: "status.sync.status")?.stringValue ?? "") ?? .unknown }
    public var syncRevision: String? { raw.value(at: "status.sync.revision")?.stringValue ?? raw.value(at: "status.sync.revisions")?.arrayValue?.first?.stringValue }
    public var health: GitOpsHealth { GitOpsHealth(rawValue: raw.value(at: "status.health.status")?.stringValue ?? "") ?? .unknown }
    public var healthMessage: String? { raw.value(at: "status.health.message")?.stringValue }
    public var reconciledAt: Date? { (raw.value(at: "status.reconciledAt")?.stringValue).flatMap(GitOpsDates.parse) }
    public var conditions: [GitOpsCondition] { GitOpsCondition.list(raw) }
    public var operationState: ArgoOperationState? { ArgoOperationState(raw.value(at: "status.operationState")) }
    /// An `operation` is queued but the controller has not picked it up yet (or it is still running).
    public var operationPending: Bool { !(raw["operation"]?.isNull ?? true) }
    public var isSyncRunning: Bool { operationState?.isRunning == true }

    public var resources: [ArgoResourceStatus] { (raw.value(at: "status.resources")?.arrayValue ?? []).compactMap(ArgoResourceStatus.init) }
    public var history: [ArgoHistoryEntry] { (raw.value(at: "status.history")?.arrayValue ?? []).compactMap(ArgoHistoryEntry.init) }

    public var sources: [ArgoSource] {
        if let many = raw.value(at: "spec.sources")?.arrayValue, !many.isEmpty { return many.map(ArgoSource.init) }
        return raw.value(at: "spec.source").map { [ArgoSource($0)] } ?? []
    }
    public var targetRevision: String? { sources.first?.targetRevision ?? (sources.isEmpty ? nil : "HEAD") }
    public var sourceDescription: String {
        guard let s = sources.first else { return "" }
        let base = (s.repoURL ?? "").replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: ".git", with: "")
        let tail = s.path.map { $0 == "." || $0.isEmpty ? "" : " \($0)" } ?? (s.chart.map { " \($0)" } ?? "")
        return base + tail + (sources.count > 1 ? " (+\(sources.count - 1))" : "")
    }

    public var destinationServer: String? { raw.value(at: "spec.destination.server")?.stringValue ?? raw.value(at: "spec.destination.name")?.stringValue }
    public var destinationNamespace: String? { raw.value(at: "spec.destination.namespace")?.stringValue }

    public var autoSyncEnabled: Bool { raw.value(at: "spec.syncPolicy.automated").map { !$0.isNull } ?? false }
    public var autoPrune: Bool { raw.value(at: "spec.syncPolicy.automated.prune")?.boolValue ?? false }
    public var selfHeal: Bool { raw.value(at: "spec.syncPolicy.automated.selfHeal")?.boolValue ?? false }
    public var syncOptions: [String] { (raw.value(at: "spec.syncPolicy.syncOptions")?.arrayValue ?? []).compactMap(\.stringValue) }

    /// Resources in the cluster that Git no longer has: what a Sync with Prune would delete.
    public var pruneCandidates: [ArgoResourceStatus] { resources.filter { $0.requiresPruning && !$0.hook } }
    public var outOfSyncResources: [ArgoResourceStatus] { resources.filter { $0.sync == .outOfSync } }
}
