import Foundation

// MARK: - Subjects

/// A normalised RBAC subject. `User` names of the form `system:serviceaccount:<ns>:<name>` are folded into `ServiceAccount`.
public struct SubjectKey: Hashable, Codable, Sendable {
    public var kind: String
    public var name: String
    public var namespace: String?

    public init(kind: String, name: String, namespace: String? = nil) {
        self.kind = kind
        self.name = name
        self.namespace = namespace
    }

    public static func serviceAccount(_ name: String, namespace: String) -> SubjectKey { SubjectKey(kind: "ServiceAccount", name: name, namespace: namespace) }
    public static func user(_ name: String) -> SubjectKey { SubjectKey(kind: "User", name: name) }
    public static func group(_ name: String) -> SubjectKey { SubjectKey(kind: "Group", name: name) }

    /// Normalises a binding subject. A ServiceAccount subject without a namespace takes the binding's namespace.
    public init(_ subject: Subject, bindingNamespace: String?) {
        switch subject.kind {
        case "ServiceAccount":
            self.init(kind: "ServiceAccount", name: subject.name, namespace: subject.namespace ?? bindingNamespace)
        case "User":
            let prefix = "system:serviceaccount:"
            if subject.name.hasPrefix(prefix) {
                let rest = subject.name.dropFirst(prefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if rest.count == 2 {
                    self.init(kind: "ServiceAccount", name: String(rest[1]), namespace: String(rest[0]))
                    return
                }
            }
            self.init(kind: "User", name: subject.name)
        default:
            self.init(kind: subject.kind, name: subject.name)
        }
    }

    public var display: String {
        kind == "ServiceAccount" ? "ServiceAccount \(namespace ?? "?")/\(name)" : "\(kind) \(name)"
    }

    /// Groups every subject belongs to implicitly (the authenticator adds them).
    public var impliedGroups: [SubjectKey] {
        switch kind {
        case "ServiceAccount":
            [.group("system:serviceaccounts"), .group("system:serviceaccounts:\(namespace ?? "")"), .group("system:authenticated")]
        case "User":
            name == "system:anonymous" ? [.group("system:unauthenticated")] : [.group("system:authenticated")]
        default:
            []
        }
    }
}

/// The exclusion list of the access rules (ARCHITECTURE-MAC §6.2): subjects that belong to the control plane and the roles and
/// bindings Kubernetes creates itself. This is data, not logic; extend it here.
public enum SystemSubjects {
    public static let exactNames: Set<String> = [
        "system:masters", "system:nodes", "system:bootstrappers", "system:kube-controller-manager", "system:kube-scheduler",
        "system:kube-proxy", "system:node", "system:coredns", "system:volume-scheduler", "system:public-info-viewer",
        "system:monitoring", "system:certificates.k8s.io:certificatesigningrequests:nodeclient",
    ]
    public static let namePrefixes: [String] = [
        "system:kube-", "system:node", "system:controller:", "system:bootstrap", "system:apiserver", "system:aggregate",
    ]
    /// Subjects that are broad on purpose and are therefore never excluded.
    public static let broadGroups: Set<String> = ["system:authenticated", "system:unauthenticated", "system:anonymous", "system:serviceaccounts"]

    public static func isSystem(_ subject: SubjectKey) -> Bool {
        guard subject.kind != "ServiceAccount" else { return subject.name.hasPrefix("system:") && !broadGroups.contains(subject.name) }
        if broadGroups.contains(subject.name) || subject.name.hasPrefix("system:serviceaccounts:") { return false }
        if exactNames.contains(subject.name) { return true }
        return namePrefixes.contains { subject.name.hasPrefix($0) }
    }

    /// Roles and bindings created by Kubernetes carry this label.
    public static let bootstrapLabel = ("kubernetes.io/bootstrapping", "rbac-defaults")

    public static func isDefaultObject(_ meta: ObjectMeta) -> Bool {
        meta.labels[bootstrapLabel.0] == bootstrapLabel.1 || meta.name.hasPrefix("system:")
    }
}

// MARK: - Rule matching (the semantics of the RBAC authorizer)

public extension PolicyRule {
    /// True when the rule allows `verb` on `resource` (`pods`, or `pods/exec` with its subresource) in `apiGroup`.
    /// `name` is nil for requests that carry no name (list, create); a rule restricted by `resourceNames` then does not match.
    func allows(verb: String, apiGroup: String, resource: String, name: String? = nil) -> Bool {
        guard verbs.contains("*") || verbs.contains(verb) else { return false }
        guard apiGroups.contains("*") || apiGroups.contains(apiGroup) else { return false }
        guard resources.contains(where: { Self.resourceMatches($0, requested: resource) }) else { return false }
        if !resourceNames.isEmpty {
            guard let name, resourceNames.contains(name) else { return false }
        }
        return true
    }

    /// `*`, an exact match, `*/sub` for a subresource, or `res/*` for every subresource of `res`.
    static func resourceMatches(_ rule: String, requested: String) -> Bool {
        if rule == "*" || rule == requested { return true }
        guard let slash = requested.firstIndex(of: "/") else { return false }
        let base = requested[..<slash]
        let sub = requested[requested.index(after: slash)...]
        if rule == "*/\(sub)" { return true }
        if rule.hasSuffix("/*"), rule.dropLast(2) == base { return true }
        return false
    }

    var hasWildcardVerbOrResource: Bool { verbs.contains("*") || resources.contains("*") }
}

// MARK: - Capabilities (what a set of rules can do that matters to the access rules)

public struct Capabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// `*` verbs on `*` resources in `*` API groups (cluster-admin and its copies).
    public static let superuser = Capabilities(rawValue: 1 << 0)
    public static let readSecrets = Capabilities(rawValue: 1 << 1)
    public static let escalate = Capabilities(rawValue: 1 << 2)
    public static let bind = Capabilities(rawValue: 1 << 3)
    public static let impersonate = Capabilities(rawValue: 1 << 4)
    public static let createPods = Capabilities(rawValue: 1 << 5)
    public static let execPods = Capabilities(rawValue: 1 << 6)
    public static let writeWebhooks = Capabilities(rawValue: 1 << 7)
    public static let nodesProxy = Capabilities(rawValue: 1 << 8)
    public static let createServiceAccountTokens = Capabilities(rawValue: 1 << 9)

    /// "Powerful" for WH-A08: a Pod that can run code as such a ServiceAccount hands that capability to an attacker.
    public static let powerful: Capabilities = [.superuser, .readSecrets, .escalate, .bind, .impersonate, .execPods, .writeWebhooks, .nodesProxy,
                                                 .createServiceAccountTokens]

    /// The capabilities a list of rules grants. Rules restricted by `resourceNames` are ignored: they do not grant the broad capability.
    public static func of(_ rules: [PolicyRule]) -> Capabilities {
        var result: Capabilities = []
        for rule in rules where rule.resourceNames.isEmpty && !rule.resources.isEmpty {
            let verbs = rule.verbs
            let allVerbs = verbs.contains("*")
            func has(_ v: String) -> Bool { allVerbs || verbs.contains(v) }
            let groups = rule.apiGroups
            let anyGroup = groups.contains("*")
            let core = anyGroup || groups.contains("")
            let rbac = anyGroup || groups.contains("rbac.authorization.k8s.io")
            let admission = anyGroup || groups.contains("admissionregistration.k8s.io")
            let allResources = rule.resources.contains("*")
            if allVerbs && allResources && anyGroup { result.insert(.superuser) }
            for r in rule.resources {
                let all = r == "*"
                if core {
                    if (all || r == "secrets") && (has("get") || has("list") || has("watch")) { result.insert(.readSecrets) }
                    if (all || r == "pods") && has("create") { result.insert(.createPods) }
                    if (all || r == "pods/exec" || r == "pods/*" || r == "*/exec") && has("create") { result.insert(.execPods) }
                    if (all || r == "nodes/proxy" || r == "nodes/*" || r == "*/proxy") && (has("create") || has("update") || has("patch") || has("get")) {
                        result.insert(.nodesProxy)
                    }
                    if (all || r == "serviceaccounts/token" || r == "serviceaccounts/*" || r == "*/token") && has("create") { result.insert(.createServiceAccountTokens) }
                    if (all || r == "users" || r == "groups" || r == "serviceaccounts" || r == "uids") && has("impersonate") { result.insert(.impersonate) }
                }
                if rbac, all || r == "roles" || r == "clusterroles" {
                    if has("escalate") { result.insert(.escalate) }
                    if has("bind") { result.insert(.bind) }
                }
                if admission, all || r == "validatingwebhookconfigurations" || r == "mutatingwebhookconfigurations",
                   has("create") || has("update") || has("patch") {
                    result.insert(.writeWebhooks)
                }
            }
        }
        if result.contains(.superuser) { result.formUnion([.readSecrets, .escalate, .bind, .impersonate, .createPods, .execPods, .writeWebhooks, .nodesProxy, .createServiceAccountTokens]) }
        return result
    }
}
