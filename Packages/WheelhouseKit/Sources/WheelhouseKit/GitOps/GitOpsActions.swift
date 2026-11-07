import Foundation

// Tides actions (ARCHITECTURE-MAC section 7): patch builders, preconditions, and a plan that carries everything the confirmation
// sheet needs. Every action is one kube API patch (Flux annotations and `spec.suspend`; the Argo CD `operation` field and refresh
// annotation) and always has a server dry-run of the SAME patch first. Nothing here talks to the Flux or Argo CD controllers.

public enum GitOpsActionError: Error, LocalizedError, Equatable {
    case syncAlreadyRunning
    case operationPending
    case notRunning
    case autoSyncMustBeOff
    case noSuchHistoryEntry(Int)
    case missingSource
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .syncAlreadyRunning: "A sync is already running."
        case .operationPending: "A sync has already been requested for this application."
        case .notRunning: "No sync is running."
        case .autoSyncMustBeOff: "Auto-sync is on, so Argo CD would sync the application straight back. Disable auto-sync first."
        case .noSuchHistoryEntry(let id): "History entry \(id) was not found."
        case .missingSource: "The source this object points at is not available on this cluster."
        case .unsupported(let m): m
        }
    }
}

/// A resource named in an Argo CD sync's `resources` list.
public struct ArgoSyncResource: Hashable, Sendable {
    public var group: String
    public var kind: String
    public var name: String
    public var namespace: String?
    public init(group: String, kind: String, name: String, namespace: String? = nil) {
        self.group = group
        self.kind = kind
        self.name = name
        self.namespace = namespace
    }
    public init(_ r: ArgoResourceStatus) { self.init(group: r.group, kind: r.kind, name: r.name, namespace: r.namespace) }
}

public struct ArgoSyncRequest: Hashable, Sendable {
    public var revision: String?
    public var revisions: [String]
    /// `source` / `sources` copied from a history entry (rollback).
    public var source: JSONValue?
    public var sources: [JSONValue]
    public var prune = false
    public var dryRun = false
    public var applyOutOfSyncOnly = false
    public var syncOptions: [String] = []
    public var resources: [ArgoSyncResource] = []

    public init(revision: String? = nil, revisions: [String] = [], source: JSONValue? = nil, sources: [JSONValue] = [], prune: Bool = false,
                dryRun: Bool = false, applyOutOfSyncOnly: Bool = false, syncOptions: [String] = [], resources: [ArgoSyncResource] = []) {
        self.revision = revision
        self.revisions = revisions
        self.source = source
        self.sources = sources
        self.prune = prune
        self.dryRun = dryRun
        self.applyOutOfSyncOnly = applyOutOfSyncOnly
        self.syncOptions = syncOptions
        self.resources = resources
    }
}

/// The `spec.syncPolicy.automated` flags, kept so that Undo of Disable Auto-Sync restores what was there.
public struct GitOpsAutoSyncPolicy: Hashable, Sendable {
    public var prune: Bool
    public var selfHeal: Bool
    public init(prune: Bool, selfHeal: Bool) { self.prune = prune; self.selfHeal = selfHeal }
}

public enum GitOpsActions {
    public static let requestedAtKey = "reconcile.fluxcd.io/requestedAt"
    public static let forceAtKey = "reconcile.fluxcd.io/forceAt"
    public static let resetAtKey = "reconcile.fluxcd.io/resetAt"
    public static let argoRefreshKey = "argocd.argoproj.io/refresh"
    public static let argoUsername = "wheelhouse"

    /// RFC 3339 with nanoseconds, UTC: the value Flux compares with `status.lastHandledReconcileAt`.
    public static func timestamp(_ now: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let fraction = now.timeIntervalSince1970 - now.timeIntervalSince1970.rounded(.down)
        let nanos = min(999_999_999, Int((fraction * 1_000_000_000).rounded(.down)))
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%09dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, nanos)
    }

    // MARK: Flux

    private static func annotations(_ pairs: [(String, String)]) -> JSONValue {
        var a: [String: JSONValue] = [:]
        for (k, v) in pairs { a[k] = .string(v) }
        return ["metadata": ["annotations": .object(a)]]
    }

    /// `merge` patch: `requestedAt = <at>`.
    public static func fluxReconcile(at: String) -> KubePatch { .merge(annotations([(requestedAtKey, at)])) }
    /// HelmRelease Force: `requestedAt` and `forceAt` set to the same value.
    public static func fluxForce(at: String) -> KubePatch { .merge(annotations([(requestedAtKey, at), (forceAtKey, at)])) }
    /// HelmRelease Reset (retries exhausted): `requestedAt` and `resetAt`, same value.
    public static func fluxReset(at: String) -> KubePatch { .merge(annotations([(requestedAtKey, at), (resetAtKey, at)])) }
    public static func fluxSuspend(_ suspend: Bool) -> KubePatch { .merge(["spec": ["suspend": .bool(suspend)]]) }

    // MARK: Argo CD

    /// `normal` or `hard` refresh annotation.
    public static func argoRefresh(hard: Bool) -> KubePatch { .merge(annotations([(argoRefreshKey, hard ? "hard" : "normal")])) }

    /// Refuses when a sync is running or already queued.
    public static func checkSyncAllowed(_ app: ArgoView) throws {
        if app.isSyncRunning { throw GitOpsActionError.syncAlreadyRunning }
        if app.operationPending { throw GitOpsActionError.operationPending }
    }

    public static func argoSync(_ r: ArgoSyncRequest) -> KubePatch {
        var sync: [String: JSONValue] = ["prune": .bool(r.prune), "dryRun": .bool(r.dryRun)]
        if let revision = r.revision { sync["revision"] = .string(revision) }
        if !r.revisions.isEmpty { sync["revisions"] = .array(r.revisions.map(JSONValue.string)) }
        if let source = r.source { sync["source"] = source }
        if !r.sources.isEmpty { sync["sources"] = .array(r.sources) }
        var options = r.syncOptions
        if r.applyOutOfSyncOnly, !options.contains("ApplyOutOfSyncOnly=true") { options.append("ApplyOutOfSyncOnly=true") }
        if !options.isEmpty { sync["syncOptions"] = .array(options.map(JSONValue.string)) }
        if !r.resources.isEmpty {
            sync["resources"] = .array(r.resources.map { res in
                var o: [String: JSONValue] = ["group": .string(res.group), "kind": .string(res.kind), "name": .string(res.name)]
                if let ns = res.namespace, !ns.isEmpty { o["namespace"] = .string(ns) }
                return .object(o)
            })
        }
        return .merge(["operation": [
            "initiatedBy": ["username": .string(argoUsername)],
            "info": [["name": "Reason", "value": "Wheelhouse"]],
            "sync": .object(sync),
        ]])
    }

    /// The Application CRD has no status subresource, and the controller honours the phase as the API server's terminate does.
    public static func argoTerminate() -> KubePatch { .merge(["status": ["operationState": ["phase": "Terminating"]]]) }

    public static func argoAutoSync(enabled: Bool, prune: Bool = false, selfHeal: Bool = false) -> KubePatch {
        .merge(["spec": ["syncPolicy": ["automated": enabled ? ["prune": .bool(prune), "selfHeal": .bool(selfHeal)] : .null]]])
    }

    /// Roll Back is a Sync at the revision (and source) of a history entry. Requires auto-sync off.
    public static func argoRollback(app: ArgoView, historyID: Int, prune: Bool = false) throws -> KubePatch {
        guard let entry = app.history.first(where: { $0.id == historyID }) else { throw GitOpsActionError.noSuchHistoryEntry(historyID) }
        if app.autoSyncEnabled { throw GitOpsActionError.autoSyncMustBeOff }
        try checkSyncAllowed(app)
        return argoSync(ArgoSyncRequest(revision: entry.sources.isEmpty ? entry.revision : nil, revisions: entry.revisions,
                                        source: entry.sources.isEmpty ? entry.source : nil, sources: entry.sources, prune: prune))
    }
}

// MARK: - Plans

/// One confirmable action: what the sheet says, the patch to dry-run and then apply, and (for Reconcile with Source) the source
/// to annotate first.
public struct GitOpsActionPlan: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case fluxReconcile, fluxReconcileWithSource, fluxForce, fluxReset, fluxSuspend, fluxResume
        case argoRefresh, argoHardRefresh, argoSync, argoTerminate, argoEnableAutoSync, argoDisableAutoSync, argoRollback
    }
    public struct SourceStep: Sendable {
        public var kind: ResourceKind
        public var name: String
        public var namespace: String?
        public var patch: KubePatch
    }

    public var kind: Kind
    public var app: GitOpsApp
    public var title: String
    public var message: String
    public var verb: String
    public var isDestructive: Bool
    public var facts: [(label: String, value: String)]
    public var patch: KubePatch
    public var source: SourceStep?
    /// Resources a pruning sync would delete (listed in the sheet).
    public var pruneList: [ArgoResourceStatus]
    /// The inverse action, offered by the Undo toast (suspend <-> resume, enable <-> disable auto-sync).
    public var inverse: Kind?
    /// For Disable Auto-Sync: the flags to restore when the inverse (Enable) runs.
    public var inverseAutoSync: GitOpsAutoSyncPolicy?
    /// The `requestedAt` token (Flux), used to detect that the controller handled the request.
    public var token: String?

    /// A plain-text summary of the patch, for the sheet and the activity log.
    public var patchSummary: String { patch.body.jsonString(pretty: true) }
}

public enum GitOpsPlanner {
    static let pruneRevisionMessage = "Prune can only be listed for the target revision. Clear the revision or turn Prune off."

    /// Builds the plan for `kind` against `app`. Throws a ``GitOpsActionError`` when the precondition fails.
    public static func plan(_ kind: GitOpsActionPlan.Kind, app: GitOpsApp, detection: GitOpsDetection = GitOpsDetection(),
                            sync: ArgoSyncRequest = ArgoSyncRequest(), historyID: Int? = nil, autoSync: GitOpsAutoSyncPolicy? = nil,
                            now: Date = Date()) throws -> GitOpsActionPlan {
        let at = GitOpsActions.timestamp(now)
        let flux = FluxView(raw: app.raw, flavor: app.flavor)
        let argo = ArgoView(raw: app.raw)
        let isArgo = app.flavor == .argoApplication
        let needsFlux: Set<GitOpsActionPlan.Kind> = [.fluxReconcile, .fluxReconcileWithSource, .fluxForce, .fluxReset, .fluxSuspend, .fluxResume]
        if needsFlux.contains(kind) == isArgo { throw GitOpsActionError.unsupported("This action does not apply to \(app.flavor.title).") }

        var plan = GitOpsActionPlan(kind: kind, app: app, title: "", message: "", verb: "", isDestructive: false,
                                    facts: [("Application", app.name)], patch: GitOpsActions.fluxReconcile(at: at), source: nil,
                                    pruneList: [], inverse: nil, inverseAutoSync: nil, token: nil)
        func fact(_ label: String, _ value: String?) { if let value, !value.isEmpty { plan.facts.append((label, value)) } }
        let target = app.name
        switch kind {
        case .fluxReconcile:
            plan.title = "Reconcile \(target)"
            plan.message = "Asks Flux to reconcile \(app.flavor.title) \(target) now, by setting the requestedAt annotation."
            plan.verb = "Reconcile"
            plan.patch = GitOpsActions.fluxReconcile(at: at)
            plan.token = at
            fact("Last applied revision", GitOpsRevision.short(flux.lastAppliedRevision))
        case .fluxReconcileWithSource:
            guard let ref = flux.sourceRef, let sourceKind = ref.kind.flatMap(detection.sourceKind(named:)) else { throw GitOpsActionError.missingSource }
            plan.title = "Reconcile \(target) with Source"
            plan.message = "Asks Flux to fetch \(ref.kind ?? "the source") \(ref.name) first, then reconcile \(app.flavor.title) \(target) once the new revision is available (or after 60 seconds)."
            plan.verb = "Reconcile with Source"
            plan.patch = GitOpsActions.fluxReconcile(at: at)
            plan.source = .init(kind: sourceKind, name: ref.name, namespace: ref.namespace, patch: GitOpsActions.fluxReconcile(at: at))
            plan.token = at
            fact("Source", "\(ref.kind ?? "")/\(ref.name)")
        case .fluxForce:
            guard app.flavor == .fluxHelmRelease else { throw GitOpsActionError.unsupported("Force applies to HelmReleases only.") }
            plan.title = "Force \(target)"
            plan.message = "Asks Flux to run a one-off forced Helm upgrade of \(target) (forceAt). Resources may be replaced and pods restarted."
            plan.verb = "Force Reconcile"
            plan.isDestructive = true
            plan.patch = GitOpsActions.fluxForce(at: at)
            plan.token = at
        case .fluxReset:
            guard app.flavor == .fluxHelmRelease else { throw GitOpsActionError.unsupported("Reset applies to HelmReleases only.") }
            plan.title = "Reset \(target)"
            plan.message = "Clears the failure count of HelmRelease \(target) (resetAt) so Flux retries after its retries were exhausted."
            plan.verb = "Reset and Reconcile"
            plan.patch = GitOpsActions.fluxReset(at: at)
            plan.token = at
        case .fluxSuspend:
            plan.title = "Suspend \(target)"
            plan.message = "Stops Flux from reconciling \(app.flavor.title) \(target) until it is resumed. Drift is no longer corrected."
            plan.verb = "Suspend"
            plan.patch = GitOpsActions.fluxSuspend(true)
            plan.inverse = .fluxResume
        case .fluxResume:
            plan.title = "Resume \(target)"
            plan.message = "Lets Flux reconcile \(app.flavor.title) \(target) again."
            plan.verb = "Resume"
            plan.patch = GitOpsActions.fluxSuspend(false)
            plan.inverse = .fluxSuspend
        case .argoRefresh, .argoHardRefresh:
            let hard = kind == .argoHardRefresh
            plan.title = "\(hard ? "Hard Refresh" : "Refresh") \(target)"
            plan.message = hard ? "Makes Argo CD drop its manifest cache and compare \(target) with Git again."
                                : "Makes Argo CD compare \(target) with Git again."
            plan.verb = hard ? "Hard Refresh" : "Refresh"
            plan.patch = GitOpsActions.argoRefresh(hard: hard)
        case .argoSync:
            try GitOpsActions.checkSyncAllowed(argo)
            // The prune list is computed from the target revision's comparison, so it is only true for that revision.
            if sync.prune, let r = sync.revision, r != argo.targetRevision { throw GitOpsActionError.unsupported(pruneRevisionMessage) }
            plan.title = "Sync \(target)"
            plan.verb = sync.dryRun ? "Dry-Run Sync" : (sync.prune ? "Sync and Prune" : "Sync")
            plan.isDestructive = sync.prune && !sync.dryRun
            plan.patch = GitOpsActions.argoSync(sync)
            if sync.prune {
                plan.pruneList = argo.pruneCandidates.filter { r in
                    sync.resources.isEmpty || sync.resources.contains(ArgoSyncResource(r))
                }
            }
            plan.message = sync.prune
                ? "Syncs \(target) to \(GitOpsRevision.short(sync.revision) ?? argo.targetRevision ?? "its target") and deletes the resources Git no longer has (listed below)."
                : "Syncs \(target) to \(GitOpsRevision.short(sync.revision) ?? argo.targetRevision ?? "its target revision")."
            fact("Target revision", GitOpsRevision.short(sync.revision) ?? argo.targetRevision)
            fact("Destination namespace", argo.destinationNamespace)
            fact("Prune", sync.prune ? "on" : "off")
            fact("Dry run", sync.dryRun ? "yes" : nil)
            fact("Resources", sync.resources.isEmpty ? "all (\(argo.resources.count))" : "\(sync.resources.count) selected")
            if sync.prune { fact("Will be deleted", "\(plan.pruneList.count)") }
            fact("Out of sync", "\(argo.outOfSyncResources.count)")
        case .argoTerminate:
            guard argo.isSyncRunning else { throw GitOpsActionError.notRunning }
            plan.title = "Terminate Sync of \(target)"
            plan.message = "Stops the running sync of \(target). Resources already applied stay applied."
            plan.verb = "Terminate Sync"
            plan.isDestructive = true
            plan.patch = GitOpsActions.argoTerminate()
        case .argoEnableAutoSync:
            plan.title = "Enable Auto-Sync for \(target)"
            plan.message = "Argo CD will sync \(target) automatically whenever Git changes."
            plan.verb = "Enable Auto-Sync"
            let policy = autoSync ?? GitOpsAutoSyncPolicy(prune: sync.prune, selfHeal: false)
            plan.patch = GitOpsActions.argoAutoSync(enabled: true, prune: policy.prune, selfHeal: policy.selfHeal)
            fact("Self-heal", policy.selfHeal ? "on" : "off")
            plan.inverse = .argoDisableAutoSync
            fact("Prune", policy.prune ? "on" : "off")
        case .argoDisableAutoSync:
            plan.title = "Disable Auto-Sync for \(target)"
            plan.message = "Argo CD will stop syncing \(target) by itself. Changes in Git then wait for a manual Sync."
            plan.verb = "Disable Auto-Sync"
            plan.patch = GitOpsActions.argoAutoSync(enabled: false)
            plan.inverse = .argoEnableAutoSync
            plan.inverseAutoSync = GitOpsAutoSyncPolicy(prune: argo.autoPrune, selfHeal: argo.selfHeal)
        case .argoRollback:
            guard let id = historyID else { throw GitOpsActionError.noSuchHistoryEntry(-1) }
            // A rollback syncs a history revision, not the target revision the prune list was computed for.
            if sync.prune { throw GitOpsActionError.unsupported(pruneRevisionMessage) }
            plan.patch = try GitOpsActions.argoRollback(app: argo, historyID: id, prune: sync.prune)
            let entry = argo.history.first { $0.id == id }
            plan.title = "Roll Back \(target)"
            plan.message = "Syncs \(target) back to deployed revision \(GitOpsRevision.short(entry?.revision ?? entry?.revisions.first) ?? "#\(id)") (history entry \(id))."
            plan.verb = "Roll Back"
            plan.isDestructive = true
            fact("Target revision", GitOpsRevision.short(entry?.revision ?? entry?.revisions.first))
            fact("Destination namespace", argo.destinationNamespace)
            fact("Prune", sync.prune ? "on" : "off")
        }
        return plan
    }
}

// MARK: - Execution

public extension GitOpsActionPlan {
    /// Server dry-run of the same patch(es). Throws the server's error text when the patch would be rejected.
    func dryRun(client: any KubeClientProtocol) async throws {
        let options = MutationOptions(dryRun: true)
        if let source {
            _ = try await client.patch(source.kind, name: source.name, namespace: source.namespace, patch: source.patch, options: options)
        }
        _ = try await client.patch(app.kind, name: app.name, namespace: app.namespace, patch: patch, options: options)
    }

    /// Applies the plan. Reconcile with Source patches the source first and waits until it handled the request (its artifact
    /// revision changed or it echoed our token), or `sourceWait` elapsed, before patching the app.
    func execute(client: any KubeClientProtocol, detection: GitOpsDetection = GitOpsDetection(),
                 sourceWait: Duration = .seconds(60), poll: Duration = .seconds(2)) async throws {
        if let source {
            let before = try await client.getRaw(source.kind, name: source.name, namespace: source.namespace)
            let initial = FluxView(raw: before, flavor: .fluxGitRepository).artifactRevision
            _ = try await client.patch(source.kind, name: source.name, namespace: source.namespace, patch: source.patch)
            let deadline = ContinuousClock.now.advanced(by: sourceWait)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: poll)
                guard let now = try? await client.getRaw(source.kind, name: source.name, namespace: source.namespace) else { continue }
                let view = FluxView(raw: now, flavor: .fluxGitRepository)
                if view.artifactRevision != initial || (token != nil && view.lastHandledReconcileAt == token) { break }
            }
            _ = try await client.patch(app.kind, name: app.name, namespace: app.namespace, patch: patch)
            return
        }
        _ = try await client.patch(app.kind, name: app.name, namespace: app.namespace, patch: patch)
    }
}
