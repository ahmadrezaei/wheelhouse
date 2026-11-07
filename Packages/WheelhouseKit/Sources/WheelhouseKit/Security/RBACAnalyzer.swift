import Foundation

/// The RBAC objects and workloads one Survey run looks at (ARCHITECTURE-MAC §6.2). Plain values: the run executes off the main actor.
public struct SurveySnapshot: Sendable {
    public var clusterID: ClusterID
    public var roles: [Role]
    public var clusterRoles: [ClusterRole]
    public var roleBindings: [RoleBinding]
    public var clusterRoleBindings: [ClusterRoleBinding]
    public var serviceAccounts: [ServiceAccount]
    public var namespaces: [Namespace]
    public var workloads: [SurveyWorkload]
    /// Kinds that could not be listed (forbidden or failed). Findings that depend on them are limited; the UI says which.
    public var limitations: [SurveyLimitation]

    public init(clusterID: ClusterID, roles: [Role] = [], clusterRoles: [ClusterRole] = [], roleBindings: [RoleBinding] = [],
                clusterRoleBindings: [ClusterRoleBinding] = [], serviceAccounts: [ServiceAccount] = [], namespaces: [Namespace] = [],
                workloads: [SurveyWorkload] = [], limitations: [SurveyLimitation] = []) {
        self.clusterID = clusterID
        self.roles = roles
        self.clusterRoles = clusterRoles
        self.roleBindings = roleBindings
        self.clusterRoleBindings = clusterRoleBindings
        self.serviceAccounts = serviceAccounts
        self.namespaces = namespaces
        self.workloads = workloads
        self.limitations = limitations
    }

    public var bindingCount: Int { roleBindings.count + clusterRoleBindings.count }
}

/// Effective permissions: `Subject → [PolicyRule]` per namespace scope and cluster scope, with `*` kept symbolic
/// (ARCHITECTURE-MAC §6.2). Built in one pass over the bindings, so a query costs a dictionary lookup.
public struct PermissionIndex: Sendable {
    /// One role granted to one subject by one binding.
    public struct Grant: Sendable {
        public var binding: FindingObject
        public var role: FindingObject
        public var rules: [PolicyRule]
        public var capabilities: Capabilities
        /// The capabilities of each rule, aligned with `rules` (so the finding evidence can name the rule that grants one).
        public var ruleCapabilities: [Capabilities]
        /// The binding is one Kubernetes created itself (bootstrap label or `system:` name).
        public var isDefault: Bool
    }

    public private(set) var clusterGrants: [SubjectKey: [Grant]] = [:]
    public private(set) var namespaceGrants: [SubjectKey: [String: [Grant]]] = [:]

    public init(snapshot: SurveySnapshot) {
        // Role rules, aggregation resolved, with their capabilities computed once per role.
        struct RoleInfo {
            var rules: [PolicyRule]; var ruleCaps: [Capabilities]; var caps: Capabilities
            init(rules: [PolicyRule]) {
                self.rules = rules
                ruleCaps = rules.map { Capabilities.of([$0]) }
                caps = ruleCaps.reduce(into: Capabilities()) { $0.formUnion($1) }
            }
        }
        let clusterRoleRules = Self.resolveClusterRoles(snapshot.clusterRoles)
        var clusterRoles: [String: RoleInfo] = [:]
        clusterRoles.reserveCapacity(clusterRoleRules.count)
        for (name, rules) in clusterRoleRules { clusterRoles[name] = RoleInfo(rules: rules) }
        var roles: [String: RoleInfo] = [:]
        roles.reserveCapacity(snapshot.roles.count)
        for r in snapshot.roles {
            roles["\(r.metadata.namespace ?? "")/\(r.metadata.name)"] = RoleInfo(rules: r.rules)
        }

        for b in snapshot.clusterRoleBindings {
            guard b.roleRef.kind == "ClusterRole", let info = clusterRoles[b.roleRef.name] else { continue }
            let isDefault = SystemSubjects.isDefaultBinding(b.metadata, subjects: b.subjects.map { SubjectKey($0, bindingNamespace: nil) })
            let grant = Grant(binding: FindingObject(kind: "ClusterRoleBinding", name: b.metadata.name),
                              role: FindingObject(kind: "ClusterRole", name: b.roleRef.name), rules: info.rules, capabilities: info.caps, ruleCapabilities: info.ruleCaps, isDefault: isDefault)
            for s in b.subjects { clusterGrants[SubjectKey(s, bindingNamespace: nil), default: []].append(grant) }
        }
        for b in snapshot.roleBindings {
            let ns = b.metadata.namespace ?? ""
            let info: RoleInfo?
            let roleObject: FindingObject
            switch b.roleRef.kind {
            case "ClusterRole": info = clusterRoles[b.roleRef.name]; roleObject = FindingObject(kind: "ClusterRole", name: b.roleRef.name)
            case "Role": info = roles["\(ns)/\(b.roleRef.name)"]; roleObject = FindingObject(kind: "Role", namespace: ns, name: b.roleRef.name)
            default: continue
            }
            guard let info else { continue }
            let isDefault = SystemSubjects.isDefaultBinding(b.metadata, subjects: b.subjects.map { SubjectKey($0, bindingNamespace: ns) })
            let grant = Grant(binding: FindingObject(kind: "RoleBinding", namespace: ns, name: b.metadata.name), role: roleObject,
                              rules: info.rules, capabilities: info.caps, ruleCapabilities: info.ruleCaps, isDefault: isDefault)
            for s in b.subjects { namespaceGrants[SubjectKey(s, bindingNamespace: ns), default: [:]][ns, default: []].append(grant) }
        }
    }

    /// ClusterRole name → effective rules. A ClusterRole with an `aggregationRule` and no server-populated rules gets the union of the
    /// rules of the ClusterRoles its selectors match (nested aggregation resolved, cycles cut).
    static func resolveClusterRoles(_ roles: [ClusterRole]) -> [String: [PolicyRule]] {
        var result: [String: [PolicyRule]] = [:]
        result.reserveCapacity(roles.count)
        var aggregated: [ClusterRole] = []
        for r in roles {
            if r.aggregationRule != nil, r.rules.isEmpty { aggregated.append(r) } else { result[r.metadata.name] = r.rules }
        }
        guard !aggregated.isEmpty else { return result }
        func selectors(_ r: ClusterRole) -> [LabelSelector] {
            (r.aggregationRule?["clusterRoleSelectors"]?.arrayValue ?? []).compactMap { try? $0.decode(LabelSelector.self) }
        }
        let byName = Dictionary(roles.map { ($0.metadata.name, $0) }, uniquingKeysWith: { a, _ in a })
        func resolve(_ role: ClusterRole, visiting: Set<String>) -> [PolicyRule] {
            if let done = result[role.metadata.name] { return done }
            guard !visiting.contains(role.metadata.name) else { return [] }
            var rules: [PolicyRule] = []
            let sels = selectors(role)
            for candidate in roles where candidate.metadata.name != role.metadata.name {
                guard sels.contains(where: { Self.matches($0, labels: candidate.metadata.labels) }) else { continue }
                if candidate.aggregationRule != nil, candidate.rules.isEmpty {
                    rules += resolve(byName[candidate.metadata.name] ?? candidate, visiting: visiting.union([role.metadata.name]))
                } else {
                    rules += candidate.rules
                }
            }
            result[role.metadata.name] = rules
            return rules
        }
        for r in aggregated { _ = resolve(r, visiting: []) }
        return result
    }

    static func matches(_ selector: LabelSelector, labels: [String: String]) -> Bool {
        if selector.matchLabels.isEmpty, selector.matchExpressions.isEmpty { return false }   // an empty selector selects nothing here
        for (k, v) in selector.matchLabels where labels[k] != v { return false }
        for e in selector.matchExpressions {
            switch e.operator {
            case "In": if !(labels[e.key].map(e.values.contains) ?? false) { return false }
            case "NotIn": if labels[e.key].map(e.values.contains) ?? false { return false }
            case "Exists": if labels[e.key] == nil { return false }
            case "DoesNotExist": if labels[e.key] != nil { return false }
            default: return false
            }
        }
        return true
    }

    // MARK: Queries

    /// The subject and the groups the authenticator adds to it.
    private func keys(for subject: SubjectKey) -> [SubjectKey] { [subject] + subject.impliedGroups }

    /// Every rule that applies to `subject`: cluster-wide grants, plus the grants of `namespace` when one is given.
    public func rules(for subject: SubjectKey, namespace: String? = nil) -> [PolicyRule] {
        var out: [PolicyRule] = []
        for k in keys(for: subject) {
            for g in clusterGrants[k] ?? [] { out += g.rules }
            if let namespace { for g in namespaceGrants[k]?[namespace] ?? [] { out += g.rules } }
        }
        return out
    }

    /// The effective capabilities of a subject in a namespace (or cluster-wide when `namespace` is nil).
    public func capabilities(of subject: SubjectKey, namespace: String? = nil) -> Capabilities {
        var caps: Capabilities = []
        for k in keys(for: subject) {
            for g in clusterGrants[k] ?? [] { caps.formUnion(g.capabilities) }
            if let namespace { for g in namespaceGrants[k]?[namespace] ?? [] { caps.formUnion(g.capabilities) } }
        }
        return caps
    }

    /// `kubectl auth can-i` for a subject: used by the `rbac_can_i` tool and by "who can" queries.
    /// `namespace` nil means a cluster-scoped request; groups of the user can be passed in `groups`.
    public func can(_ subject: SubjectKey, verb: String, resource: String, apiGroup: String = "", namespace: String? = nil, name: String? = nil,
                    groups: [String] = []) -> Bool {
        var subjects = [subject]
        subjects += groups.map { SubjectKey.group($0) }
        for s in subjects {
            if rules(for: s, namespace: namespace).contains(where: { $0.allows(verb: verb, apiGroup: apiGroup, resource: resource, name: name) }) { return true }
        }
        return false
    }

    /// Every subject that can do `verb` on `resource` (a "who can" query). Group subjects are listed as themselves.
    public func whoCan(verb: String, resource: String, apiGroup: String = "", namespace: String? = nil, name: String? = nil) -> [SubjectKey] {
        var all = Set(clusterGrants.keys)
        all.formUnion(namespaceGrants.keys)
        return all.filter { can($0, verb: verb, resource: resource, apiGroup: apiGroup, namespace: namespace, name: name) }
            .sorted { ($0.kind, $0.name, $0.namespace ?? "") < ($1.kind, $1.name, $1.namespace ?? "") }
    }

    var allSubjects: [SubjectKey] {
        var s = Set(clusterGrants.keys)
        s.formUnion(namespaceGrants.keys)
        return Array(s)
    }
}

/// WH-A01 to WH-A10.
public enum RBACAnalyzer {
    public static func analyze(snapshot: SurveySnapshot, index: PermissionIndex) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        out += wildcardRoles(snapshot)
        out += clusterAdminBindings(snapshot)
        out += capabilityFindings(snapshot, index: index)
        out += anonymousBindings(snapshot)
        out += defaultServiceAccountBindings(snapshot)
        out += powerfulServiceAccountWorkloads(snapshot, index: index)
        return out
    }

    private static func excerpt(_ r: PolicyRule) -> String {
        func list(_ a: [String]) -> String { "[" + a.map { $0.isEmpty ? "\"\"" : $0 }.joined(separator: ", ") + "]" }
        var s = "apiGroups: \(list(r.apiGroups)), resources: \(list(r.resources)), verbs: \(list(r.verbs))"
        if !r.resourceNames.isEmpty { s += ", resourceNames: \(list(r.resourceNames))" }
        return s
    }

    // MARK: WH-A01

    static func wildcardRoles(_ s: SurveySnapshot) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        for role in s.roles where !SystemSubjects.isDefaultRole(role.metadata) {
            let bad = role.rules.filter { !$0.resources.isEmpty && $0.hasWildcardVerbOrResource }
            guard !bad.isEmpty else { continue }
            let ns = role.metadata.namespace
            out.append(SecurityFinding(ruleID: "WH-A01", severity: .high, clusterID: s.clusterID, namespace: ns,
                                       object: FindingObject(kind: "Role", namespace: ns, name: role.metadata.name),
                                       title: "Role \(ns.map { $0 + "/" } ?? "")\(role.metadata.name) grants wildcard verbs or resources",
                                       evidence: bad.map(excerpt)))
        }
        for role in s.clusterRoles where role.aggregationRule == nil && !SystemSubjects.isDefaultRole(role.metadata) {
            let bad = role.rules.filter { !$0.resources.isEmpty && $0.hasWildcardVerbOrResource }
            guard !bad.isEmpty else { continue }
            out.append(SecurityFinding(ruleID: "WH-A01", severity: .high, clusterID: s.clusterID, namespace: nil,
                                       object: FindingObject(kind: "ClusterRole", name: role.metadata.name),
                                       title: "ClusterRole \(role.metadata.name) grants wildcard verbs or resources",
                                       evidence: bad.map(excerpt)))
        }
        return out
    }

    // MARK: WH-A02

    static func clusterAdminBindings(_ s: SurveySnapshot) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        for b in s.clusterRoleBindings where b.roleRef.kind == "ClusterRole" && b.roleRef.name == "cluster-admin" {
            let keys = b.subjects.map { SubjectKey($0, bindingNamespace: nil) }
            // Kubernetes binds cluster-admin only to system:masters, and labels that binding: the label alone marks a default here.
            let isDefault = b.metadata.labels[SystemSubjects.bootstrapLabel.0] == SystemSubjects.bootstrapLabel.1
            for subject in keys where subject.name != "system:masters" && !(SystemSubjects.isSystem(subject) && isDefault) {
                out.append(SecurityFinding(
                    ruleID: "WH-A02", severity: .critical, clusterID: s.clusterID, namespace: nil,
                    object: FindingObject(kind: subject.kind, namespace: subject.namespace, name: subject.name), discriminator: "CRB:\(b.metadata.name)",
                    title: "cluster-admin is bound to \(subject.display)",
                    evidence: ["ClusterRoleBinding \(b.metadata.name) → ClusterRole cluster-admin → \(subject.display)"],
                    related: [FindingObject(kind: "ClusterRoleBinding", name: b.metadata.name), FindingObject(kind: "ClusterRole", name: "cluster-admin")]))
            }
        }
        for b in s.roleBindings where b.roleRef.kind == "ClusterRole" && b.roleRef.name == "cluster-admin" {
            let ns = b.metadata.namespace ?? ""
            let keys = b.subjects.map { SubjectKey($0, bindingNamespace: ns) }
            // Kubernetes binds cluster-admin only to system:masters, and labels that binding: the label alone marks a default here.
            let isDefault = b.metadata.labels[SystemSubjects.bootstrapLabel.0] == SystemSubjects.bootstrapLabel.1
            for subject in keys where subject.name != "system:masters" && !(SystemSubjects.isSystem(subject) && isDefault) {
                out.append(SecurityFinding(
                    ruleID: "WH-A02", severity: .critical, clusterID: s.clusterID, namespace: ns,
                    object: FindingObject(kind: subject.kind, namespace: subject.namespace, name: subject.name), discriminator: "RB:\(ns)/\(b.metadata.name)",
                    title: "cluster-admin is bound to \(subject.display) in namespace \(ns)",
                    evidence: ["RoleBinding \(ns)/\(b.metadata.name) → ClusterRole cluster-admin → \(subject.display) (all resources in namespace \(ns))"],
                    related: [FindingObject(kind: "RoleBinding", namespace: ns, name: b.metadata.name), FindingObject(kind: "ClusterRole", name: "cluster-admin")]))
            }
        }
        return out
    }

    // MARK: WH-A03, A04, A05, A09, A10

    private struct Check {
        var ruleID: String
        var severity: Severity
        var clusterMask: Capabilities
        var namespaceMask: Capabilities
        var namespaceFilter: @Sendable (String) -> Bool = { _ in true }
        var title: @Sendable (SubjectKey, Capabilities, String?) -> String
    }

    private static let checks: [Check] = [
        Check(ruleID: "WH-A03", severity: .high, clusterMask: .readSecrets, namespaceMask: [],
              title: { s, _, _ in "\(s.display) can read Secrets cluster-wide" }),
        Check(ruleID: "WH-A04", severity: .critical, clusterMask: [.escalate, .bind, .impersonate], namespaceMask: [.escalate, .bind, .impersonate],
              title: { s, c, ns in "\(s.display) can \(describe(c)) \(ns.map { "in namespace \($0)" } ?? "cluster-wide")" }),
        Check(ruleID: "WH-A05", severity: .high, clusterMask: [.createPods, .execPods], namespaceMask: [.createPods, .execPods],
              namespaceFilter: { $0 == "kube-system" },
              title: { s, c, _ in "\(s.display) can \(describe(c)) in kube-system" }),
        Check(ruleID: "WH-A09", severity: .high, clusterMask: .writeWebhooks, namespaceMask: [],
              title: { s, _, _ in "\(s.display) can change admission webhook configurations" }),
        Check(ruleID: "WH-A10", severity: .high, clusterMask: [.nodesProxy, .createServiceAccountTokens], namespaceMask: .createServiceAccountTokens,
              title: { s, c, ns in "\(s.display) can \(describe(c)) \(ns.map { "in namespace \($0)" } ?? "cluster-wide")" }),
    ]

    static func describe(_ caps: Capabilities) -> String {
        let names: [(Capabilities, String)] = [
            (.readSecrets, "read Secrets"), (.escalate, "escalate roles"), (.bind, "bind roles"), (.impersonate, "impersonate identities"),
            (.createPods, "create Pods"), (.execPods, "exec into Pods"), (.writeWebhooks, "change admission webhooks"),
            (.nodesProxy, "use nodes/proxy"), (.createServiceAccountTokens, "create ServiceAccount tokens"),
        ]
        let hit = names.filter { caps.contains($0.0) }.map(\.1)
        return hit.isEmpty ? "do nothing notable" : hit.joined(separator: ", ")
    }

    private static let allCheckMask: Capabilities = checks.reduce(into: Capabilities()) { $0.formUnion($1.clusterMask); $0.formUnion($1.namespaceMask) }

    static func capabilityFindings(_ s: SurveySnapshot, index: PermissionIndex) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        for subject in index.allSubjects where subject.name != "system:masters" {
            let clusterGrants = index.clusterGrants[subject] ?? []
            let namespaceGrants = index.namespaceGrants[subject] ?? [:]
            // Most subjects hold harmless roles: leave them after one pass over their grants.
            let interesting = clusterGrants.contains { !$0.isDefault && !$0.capabilities.isDisjoint(with: allCheckMask) }
                || namespaceGrants.values.contains { $0.contains { !$0.isDefault && !$0.capabilities.isDisjoint(with: allCheckMask) } }
            guard interesting else { continue }
            let clusterOwn = clusterGrants.filter { !$0.isDefault }
            let nsGrants = namespaceGrants.mapValues { $0.filter { !$0.isDefault } }.filter { !$0.value.isEmpty }
            let clusterCaps = clusterOwn.reduce(into: Capabilities()) { $0.formUnion($1.capabilities) }
            let subjectObject = FindingObject(kind: subject.kind, namespace: subject.namespace, name: subject.name)

            func related(_ grants: [PermissionIndex.Grant], mask: Capabilities) -> [FindingObject] {
                var seen = Set<FindingObject>()
                var list: [FindingObject] = []
                for g in grants where !g.capabilities.isDisjoint(with: mask) {
                    for o in [g.binding, g.role] where seen.insert(o).inserted { list.append(o) }
                }
                return list
            }
            func evidence(_ grants: [PermissionIndex.Grant], mask: Capabilities) -> [String] {
                grants.filter { !$0.capabilities.isDisjoint(with: mask) }.map { g in
                    let i = g.ruleCapabilities.firstIndex { !$0.isDisjoint(with: mask) }
                    let ruleText = i.map { excerpt(g.rules[$0]) } ?? ""
                    return "\(g.binding.kind) \(g.binding.namespace.map { $0 + "/" } ?? "")\(g.binding.name) → \(g.role.kind) \(g.role.name): \(ruleText)"
                }
            }

            for check in checks {
                // Cluster scope. A subject that already holds everything is reported by WH-A01 and WH-A02.
                let hit = clusterCaps.intersection(check.clusterMask)
                if !hit.isEmpty, !clusterCaps.contains(.superuser) {
                    out.append(SecurityFinding(ruleID: check.ruleID, severity: check.severity, clusterID: s.clusterID, namespace: nil, object: subjectObject,
                                               discriminator: "cluster", title: check.title(subject, hit, nil),
                                               evidence: evidence(clusterOwn, mask: check.clusterMask), related: related(clusterOwn, mask: check.clusterMask)))
                }
                guard !check.namespaceMask.isEmpty else { continue }
                for (ns, grants) in nsGrants where check.namespaceFilter(ns) {
                    let nsCaps = grants.reduce(into: Capabilities()) { $0.formUnion($1.capabilities) }
                    let nsHit = nsCaps.intersection(check.namespaceMask)
                    guard !nsHit.isEmpty, !nsCaps.contains(.superuser), !clusterCaps.contains(.superuser),
                          clusterCaps.intersection(check.namespaceMask).isEmpty else { continue }
                    out.append(SecurityFinding(ruleID: check.ruleID, severity: check.severity, clusterID: s.clusterID, namespace: ns, object: subjectObject,
                                               discriminator: "ns:\(ns)", title: check.title(subject, nsHit, ns),
                                               evidence: evidence(grants, mask: check.namespaceMask), related: related(grants, mask: check.namespaceMask)))
                }
            }
        }
        return out
    }

    // MARK: WH-A06

    static let discoveryRoles: Set<String> = ["system:discovery", "system:basic-user", "system:public-info-viewer"]

    static func anonymousBindings(_ s: SurveySnapshot) -> [SecurityFinding] {
        func isAnonymous(_ subject: Subject) -> Bool {
            subject.name == "system:anonymous" || subject.name == "system:unauthenticated"
        }
        var out: [SecurityFinding] = []
        for b in s.clusterRoleBindings where !discoveryRoles.contains(b.roleRef.name) {
            for subject in b.subjects where isAnonymous(subject) {
                out.append(SecurityFinding(ruleID: "WH-A06", severity: .critical, clusterID: s.clusterID, namespace: nil,
                                           object: FindingObject(kind: subject.kind, name: subject.name), discriminator: "CRB:\(b.metadata.name)",
                                           title: "\(subject.name) is bound to \(b.roleRef.name)",
                                           evidence: ["ClusterRoleBinding \(b.metadata.name) → \(b.roleRef.kind) \(b.roleRef.name) → \(subject.kind) \(subject.name)"],
                                           related: [FindingObject(kind: "ClusterRoleBinding", name: b.metadata.name), FindingObject(kind: b.roleRef.kind, name: b.roleRef.name)]))
            }
        }
        for b in s.roleBindings where !discoveryRoles.contains(b.roleRef.name) {
            let ns = b.metadata.namespace ?? ""
            for subject in b.subjects where isAnonymous(subject) {
                out.append(SecurityFinding(ruleID: "WH-A06", severity: .critical, clusterID: s.clusterID, namespace: ns,
                                           object: FindingObject(kind: subject.kind, name: subject.name), discriminator: "RB:\(ns)/\(b.metadata.name)",
                                           title: "\(subject.name) is bound to \(b.roleRef.name) in namespace \(ns)",
                                           evidence: ["RoleBinding \(ns)/\(b.metadata.name) → \(b.roleRef.kind) \(b.roleRef.name) → \(subject.kind) \(subject.name)"],
                                           related: [FindingObject(kind: "RoleBinding", namespace: ns, name: b.metadata.name), FindingObject(kind: b.roleRef.kind, namespace: b.roleRef.kind == "Role" ? ns : nil, name: b.roleRef.name)]))
            }
        }
        return out
    }

    // MARK: WH-A07

    static func defaultServiceAccountBindings(_ s: SurveySnapshot) -> [SecurityFinding] {
        struct Entry { var evidence: [String]; var related: [FindingObject] }
        var byNamespace: [String: Entry] = [:]
        func add(ns: String, binding: FindingObject, roleKind: String, roleName: String) {
            var e = byNamespace[ns] ?? Entry(evidence: [], related: [])
            e.evidence.append("\(binding.kind) \(binding.namespace.map { $0 + "/" } ?? "")\(binding.name) → \(roleKind) \(roleName) → ServiceAccount \(ns)/default")
            e.related.append(binding)
            e.related.append(FindingObject(kind: roleKind, namespace: roleKind == "Role" ? ns : nil, name: roleName))
            byNamespace[ns] = e
        }
        for b in s.clusterRoleBindings where !SystemSubjects.isDefaultBinding(b.metadata, subjects: b.subjects.map { SubjectKey($0, bindingNamespace: nil) }) {
            for subject in b.subjects.map({ SubjectKey($0, bindingNamespace: nil) }) where subject.kind == "ServiceAccount" && subject.name == "default" {
                add(ns: subject.namespace ?? "", binding: FindingObject(kind: "ClusterRoleBinding", name: b.metadata.name), roleKind: b.roleRef.kind, roleName: b.roleRef.name)
            }
        }
        for b in s.roleBindings where !SystemSubjects.isDefaultBinding(b.metadata, subjects: b.subjects.map { SubjectKey($0, bindingNamespace: b.metadata.namespace) }) {
            let ns = b.metadata.namespace ?? ""
            for subject in b.subjects.map({ SubjectKey($0, bindingNamespace: ns) }) where subject.kind == "ServiceAccount" && subject.name == "default" {
                add(ns: subject.namespace ?? ns, binding: FindingObject(kind: "RoleBinding", namespace: ns, name: b.metadata.name), roleKind: b.roleRef.kind, roleName: b.roleRef.name)
            }
        }
        return byNamespace.sorted { $0.key < $1.key }.map { ns, e in
            SecurityFinding(ruleID: "WH-A07", severity: .medium, clusterID: s.clusterID, namespace: ns,
                            object: FindingObject(kind: "ServiceAccount", namespace: ns, name: "default"),
                            title: "The default ServiceAccount of \(ns) has \(e.evidence.count) extra binding\(e.evidence.count == 1 ? "" : "s")",
                            evidence: e.evidence, related: e.related)
        }
    }

    // MARK: WH-A08

    static func powerfulServiceAccountWorkloads(_ s: SurveySnapshot, index: PermissionIndex) -> [SecurityFinding] {
        guard !s.workloads.isEmpty else { return [] }
        var accountMount: [String: Bool?] = [:]
        for sa in s.serviceAccounts { accountMount["\(sa.metadata.namespace ?? "")/\(sa.metadata.name)"] = sa.automountServiceAccountToken }
        var capsCache: [SubjectKey: Capabilities] = [:]
        var out: [SecurityFinding] = []
        for w in s.workloads {
            let saName = w.spec.effectiveServiceAccount
            let sa = SubjectKey.serviceAccount(saName, namespace: w.ref.namespace)
            let accountSetting = accountMount["\(w.ref.namespace)/\(saName)"] ?? nil
            let automount = w.spec.automountServiceAccountToken ?? accountSetting ?? true
            guard automount else { continue }
            let caps: Capabilities
            if let cached = capsCache[sa] { caps = cached } else {
                caps = index.capabilities(of: sa, namespace: w.ref.namespace).intersection(.powerful)
                capsCache[sa] = caps
            }
            guard !caps.isEmpty else { continue }
            let what = caps.contains(.superuser) ? "everything (cluster-admin or equivalent)" : describe(caps)
            out.append(SecurityFinding(
                ruleID: "WH-A08", severity: .medium, clusterID: s.clusterID, namespace: w.ref.namespace,
                object: FindingObject(kind: w.ref.kind, namespace: w.ref.namespace, name: w.ref.name),
                title: "\(w.ref.kind) \(w.ref.name) runs as \(sa.display), which can \(what), and mounts its token",
                evidence: ["serviceAccountName: \(saName)", "automountServiceAccountToken: \(w.spec.automountServiceAccountToken.map(String.init(describing:)) ?? "not set on the Pod")"
                           + (accountSetting.map { " (ServiceAccount: \($0))" } ?? "")],
                related: [FindingObject(kind: "ServiceAccount", namespace: w.ref.namespace, name: saName)], workload: w.ref))
        }
        return out
    }
}
