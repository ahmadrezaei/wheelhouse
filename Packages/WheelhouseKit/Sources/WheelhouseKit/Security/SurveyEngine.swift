import Foundation

/// The result of one Survey run over one cluster.
public struct SurveyReport: Sendable {
    public var clusterID: ClusterID
    public var findings: [SecurityFinding]
    public var psa: [PSANamespaceReport]
    public var limitations: [SurveyLimitation]
    public var generatedAt: Date
    public var bindingCount: Int
    public var workloadCount: Int
    /// Wall-clock time of the rule run, in milliseconds.
    public var durationMs: Double
    /// `Kind/namespace/name` of the workloads that Helm, Argo CD or Flux manage, with the tool: a patch applied in the cluster is reverted.
    public var managedBy: [String: String] = [:]

    public func managingTool(for f: SecurityFinding) -> String? {
        f.workload.flatMap { managedBy["\($0.kind)/\($0.namespace)/\($0.name)"] }
    }

    public var accessFindings: [SecurityFinding] { findings.filter { $0.category == .access } }
    public var workloadFindings: [SecurityFinding] { findings.filter { $0.category == .workload } }

    public func counts(_ list: [SecurityFinding]? = nil) -> [Severity: Int] {
        (list ?? findings).reduce(into: [:]) { $0[$1.severity, default: 0] += 1 }
    }

    /// 0 (nothing found) to 100, weighted by severity, from the access findings. Shown per cluster in the Overview.
    public var accessRiskScore: Int {
        let weight: [Severity: Int] = [.critical: 25, .high: 10, .medium: 4, .low: 1, .unknown: 0]
        return min(100, accessFindings.reduce(0) { $0 + (weight[$1.severity] ?? 0) })
    }
}

/// Runs every built-in rule over a snapshot. Pure and `Sendable`: the app runs it off the main actor.
public enum SurveyEngine {
    /// Off the main actor (`@concurrent`), so a large cluster never blocks the UI.
    @concurrent
    public static func run(_ snapshot: SurveySnapshot) async -> SurveyReport {
        runSync(snapshot)
    }

    public static func runSync(_ snapshot: SurveySnapshot) -> SurveyReport {
        let start = ContinuousClock.now
        let index = PermissionIndex(snapshot: snapshot)
        var findings = RBACAnalyzer.analyze(snapshot: snapshot, index: index)
        findings += WorkloadRules.analyze(snapshot: snapshot)
        findings.sort { a, b in
            if a.severity != b.severity { return a.severity < b.severity }
            if a.ruleID != b.ruleID { return a.ruleID < b.ruleID }
            return a.id < b.id
        }
        let psa = PSAEvaluator.evaluate(snapshot: snapshot)
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        var managed: [String: String] = [:]
        for w in snapshot.workloads { if let tool = w.managedBy { managed["\(w.ref.kind)/\(w.ref.namespace)/\(w.ref.name)"] = tool } }
        return SurveyReport(clusterID: snapshot.clusterID, findings: findings, psa: psa, limitations: snapshot.limitations, generatedAt: Date(),
                            bindingCount: snapshot.bindingCount, workloadCount: snapshot.workloads.count, durationMs: ms, managedBy: managed)
    }
}

// MARK: - Building snapshots

public extension SurveySnapshot {
    /// Controllers whose pod templates are judged; their Pods are skipped so a Deployment is not reported once per replica.
    static let controllerKinds = ["Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"]

    /// Builds the workload list from raw controller lists and the raw Pod list. A Pod owned by a controller whose list is present is
    /// skipped (ReplicaSets count as covered when Deployments are present). Bare Pods and static Pods are judged themselves.
    static func workloads(controllers: [String: [JSONValue]], pods: [JSONValue]?) -> [SurveyWorkload] {
        var covered = Set(controllers.keys)
        if covered.contains("Deployment") { covered.insert("ReplicaSet") }
        var out: [SurveyWorkload] = []
        for (kind, items) in controllers {
            for raw in items {
                // A Job a CronJob created is judged through the CronJob.
                if kind == "Job", (raw.value(at: "metadata.ownerReferences")?.arrayValue ?? []).contains(where: { $0["kind"]?.stringValue == "CronJob" }) { continue }
                if let w = SurveyWorkload(raw: raw, kind: kind) { out.append(w) }
            }
        }
        for raw in pods ?? [] {
            let owners = raw.value(at: "metadata.ownerReferences")?.arrayValue ?? []
            let controller = owners.first { $0["controller"]?.boolValue == true } ?? owners.first
            if let kind = controller?["kind"]?.stringValue, covered.contains(kind) || kind == "ReplicationController" { continue }
            if let w = SurveyWorkload(raw: raw, kind: "Pod") { out.append(w) }
        }
        return out.sorted { $0.id < $1.id }
    }
}

/// One-shot loading of a snapshot through a client (used on open, by exports and by the live tests). The Survey view feeds the same
/// builder from its watching stores while it is visible.
public enum SurveyLoader {
    public static func load(client: any KubeClientProtocol, clusterID: ClusterID) async -> SurveySnapshot {
        async let roles = typed(Role.self, client)
        async let clusterRoles = typed(ClusterRole.self, client)
        async let roleBindings = typed(RoleBinding.self, client)
        async let clusterRoleBindings = typed(ClusterRoleBinding.self, client)
        async let serviceAccounts = typed(ServiceAccount.self, client)
        async let namespaces = typed(Namespace.self, client)
        async let deployments = raw(.deployment, client)
        async let statefulSets = raw(.statefulSet, client)
        async let daemonSets = raw(.daemonSet, client)
        async let jobs = raw(.job, client)
        async let cronJobs = raw(.cronJob, client)
        async let pods = raw(.pod, client)

        var limitations: [SurveyLimitation] = []
        func take<T>(_ r: (T, SurveyLimitation?)) -> T { if let l = r.1 { limitations.append(l) }; return r.0 }
        let roleList = take(await roles), clusterRoleList = take(await clusterRoles), roleBindingList = take(await roleBindings)
        let clusterRoleBindingList = take(await clusterRoleBindings), serviceAccountList = take(await serviceAccounts), namespaceList = take(await namespaces)
        var controllers: [String: [JSONValue]] = [:]
        for (kind, result) in [("Deployment", await deployments), ("StatefulSet", await statefulSets), ("DaemonSet", await daemonSets),
                               ("Job", await jobs), ("CronJob", await cronJobs)] {
            if let list = take(result) { controllers[kind] = list }
        }
        let podList = take(await pods)
        return SurveySnapshot(clusterID: clusterID, roles: roleList, clusterRoles: clusterRoleList, roleBindings: roleBindingList,
                              clusterRoleBindings: clusterRoleBindingList, serviceAccounts: serviceAccountList, namespaces: namespaceList,
                              workloads: SurveySnapshot.workloads(controllers: controllers, pods: podList),
                              limitations: limitations.sorted { $0.kind < $1.kind })
    }

    public static func limitation(_ kind: String, _ error: Error) -> SurveyLimitation {
        let message: String
        if case KubeError.forbidden(_, _, _, let m) = error { message = "Not allowed to list \(kind): \(m)" }
        else if let e = error as? KubeError { message = "Could not list \(kind): \(e.summary)" }
        else { message = "Could not list \(kind): \(error.localizedDescription)" }
        return SurveyLimitation(kind: kind, message: message)
    }

    private static func typed<T: KubeObject>(_ type: T.Type, _ client: any KubeClientProtocol) async -> ([T], SurveyLimitation?) {
        do { return (try await client.list(type, namespace: nil, options: ListOptions()).items, nil) }
        catch { return ([], limitation(T.resourceKind.displayName, error)) }
    }

    private static func raw(_ kind: ResourceKind, _ client: any KubeClientProtocol) async -> ([JSONValue]?, SurveyLimitation?) {
        do { return (try await client.listRaw(kind, namespace: nil, options: ListOptions())["items"]?.arrayValue ?? [], nil) }
        catch { return (nil, limitation(kind.displayName, error)) }
    }
}
