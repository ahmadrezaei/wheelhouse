import Foundation
@testable import WheelhouseKit

/// Builders for Survey fixtures. Objects are made from raw JSON like the API server returns them.
enum SF {
    static let cluster = "test-cluster"

    static func decode<T: Decodable>(_ v: JSONValue) -> T { try! v.decode(T.self) }

    static func rule(groups: [String] = [""], resources: [String], verbs: [String], names: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = ["apiGroups": .array(groups.map(JSONValue.string)), "resources": .array(resources.map(JSONValue.string)),
                                      "verbs": .array(verbs.map(JSONValue.string))]
        if !names.isEmpty { o["resourceNames"] = .array(names.map(JSONValue.string)) }
        return .object(o)
    }

    static func meta(_ name: String, ns: String? = nil, labels: [String: String] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "labels": .object(labels.mapValues(JSONValue.string))]
        if let ns { o["namespace"] = .string(ns) }
        return .object(o)
    }

    static func role(_ name: String, ns: String, rules: [JSONValue], labels: [String: String] = [:]) -> Role {
        decode(["metadata": meta(name, ns: ns, labels: labels), "rules": .array(rules)])
    }

    static func clusterRole(_ name: String, rules: [JSONValue], labels: [String: String] = [:], aggregate: [[String: String]]? = nil) -> ClusterRole {
        var o: [String: JSONValue] = ["metadata": meta(name, labels: labels), "rules": .array(rules)]
        if let aggregate {
            o["aggregationRule"] = ["clusterRoleSelectors": .array(aggregate.map { ["matchLabels": .object($0.mapValues(JSONValue.string))] })]
        }
        return decode(.object(o))
    }

    static func subject(_ kind: String, _ name: String, ns: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["kind": .string(kind), "name": .string(name)]
        if let ns { o["namespace"] = .string(ns) }
        if kind != "ServiceAccount" { o["apiGroup"] = "rbac.authorization.k8s.io" }
        return .object(o)
    }

    static func clusterBinding(_ name: String, role: String, subjects: [JSONValue], labels: [String: String] = [:]) -> ClusterRoleBinding {
        decode(["metadata": meta(name, labels: labels), "roleRef": ["apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": .string(role)],
                "subjects": .array(subjects)])
    }

    static func binding(_ name: String, ns: String, roleKind: String = "ClusterRole", role: String, subjects: [JSONValue], labels: [String: String] = [:]) -> RoleBinding {
        decode(["metadata": meta(name, ns: ns, labels: labels), "roleRef": ["apiGroup": "rbac.authorization.k8s.io", "kind": .string(roleKind), "name": .string(role)],
                "subjects": .array(subjects)])
    }

    static func namespace(_ name: String, labels: [String: String] = [:]) -> Namespace { decode(["metadata": meta(name, labels: labels)]) }

    static func serviceAccount(_ name: String, ns: String, automount: Bool? = nil) -> ServiceAccount {
        var o: [String: JSONValue] = ["metadata": meta(name, ns: ns)]
        if let automount { o["automountServiceAccountToken"] = .bool(automount) }
        return decode(.object(o))
    }

    // MARK: Workloads

    /// A container JSON object. `security` is the container's securityContext.
    static func container(_ name: String = "app", image: String = "registry.example.com/team/app@sha256:abc", security: JSONValue? = nil, limits: Bool = true) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "image": .string(image)]
        if let security { o["securityContext"] = security }
        if limits { o["resources"] = ["limits": ["cpu": "500m", "memory": "256Mi"]] }
        return .object(o)
    }

    /// A container that satisfies every WH-W rule and the restricted PSA level.
    static var hardenedSecurity: JSONValue {
        ["allowPrivilegeEscalation": false, "runAsNonRoot": true, "runAsUser": 10001, "readOnlyRootFilesystem": true,
         "capabilities": ["drop": ["ALL"]], "seccompProfile": ["type": "RuntimeDefault"]]
    }

    static func podSpec(containers: [JSONValue], extra: [String: JSONValue] = [:]) -> JSONValue {
        var o = extra
        o["containers"] = .array(containers)
        return .object(o)
    }

    static func deployment(_ name: String = "web", ns: String = "shop", spec: JSONValue, labels: [String: String] = [:]) -> SurveyWorkload {
        let raw: JSONValue = ["metadata": meta(name, ns: ns, labels: labels), "spec": ["template": ["spec": spec]]]
        return SurveyWorkload(raw: raw, kind: "Deployment")!
    }

    static func hardened(_ name: String = "web", ns: String = "shop") -> SurveyWorkload {
        deployment(name, ns: ns, spec: podSpec(containers: [container(security: hardenedSecurity)]))
    }

    static func snapshot(roles: [Role] = [], clusterRoles: [ClusterRole] = [], roleBindings: [RoleBinding] = [], clusterRoleBindings: [ClusterRoleBinding] = [],
                         serviceAccounts: [ServiceAccount] = [], namespaces: [Namespace] = [], workloads: [SurveyWorkload] = []) -> SurveySnapshot {
        SurveySnapshot(clusterID: cluster, roles: roles, clusterRoles: clusterRoles, roleBindings: roleBindings, clusterRoleBindings: clusterRoleBindings,
                       serviceAccounts: serviceAccounts, namespaces: namespaces, workloads: workloads)
    }

    static func run(_ s: SurveySnapshot) -> SurveyReport { SurveyEngine.runSync(s) }

    static func ids(_ report: SurveyReport, _ rule: String) -> [String] { report.findings.filter { $0.ruleID == rule }.map(\.id) }
    static func has(_ report: SurveyReport, _ rule: String, object: String? = nil) -> Bool {
        report.findings.contains { $0.ruleID == rule && (object == nil || $0.object.name == object) }
    }
}
