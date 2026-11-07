import Foundation

/// WH-W01 to WH-W11 (DESIGN-MAC §6.9). Each rule is a pure function from the snapshot's workloads to findings.
public enum WorkloadRules {
    public static let dangerousCapabilities: Set<String> = ["SYS_ADMIN", "NET_ADMIN", "NET_RAW", "ALL"]
    /// Host paths that give control of the node. A path is critical when it is one of these, lies under one, or is a parent of one.
    public static let criticalHostPaths: [String] = ["/", "/var/run/docker.sock", "/var/run/containerd", "/etc", "/run/docker.sock", "/run/containerd",
                                                     "/var/run/crio", "/run/crio", "/var/lib/kubelet", "/var/lib/docker"]
    public static let psaLabels = ["pod-security.kubernetes.io/enforce", "pod-security.kubernetes.io/audit", "pod-security.kubernetes.io/warn"]

    public static func isCriticalHostPath(_ path: String) -> Bool {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        if p.isEmpty { p = "/" }
        for c in criticalHostPaths {
            if p == c { return true }
            if c == "/" { continue }
            if p.hasPrefix(c + "/") || c.hasPrefix(p + "/") { return true }
        }
        return false
    }

    public static func analyze(snapshot s: SurveySnapshot) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        for w in s.workloads { out += findings(for: w, clusterID: s.clusterID) }
        out += namespacesWithoutPSA(s)
        return out
    }

    /// W01-W09 and W11 for one workload. One finding per rule and workload, listing the containers involved.
    public static func findings(for w: SurveyWorkload, clusterID: ClusterID) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        let object = FindingObject(kind: w.ref.kind, namespace: w.ref.namespace, name: w.ref.name)
        let spec = w.spec
        let noun = "\(w.ref.kind) \(w.ref.name)"

        func emit(_ rule: String, _ severity: Severity, _ title: String, evidence: [String], containers: [String] = []) {
            out.append(SecurityFinding(ruleID: rule, severity: severity, clusterID: clusterID, namespace: w.ref.namespace, object: object,
                                       title: title, evidence: evidence, containers: containers, workload: w.ref))
        }
        func names(_ cs: [ContainerSecurity]) -> [String] { cs.map(\.name) }

        // W01
        let privileged = spec.containers.filter { $0.privileged == true }
        if !privileged.isEmpty {
            emit("WH-W01", .critical, "\(noun) runs privileged containers", evidence: privileged.map { "container \($0.name): securityContext.privileged: true" }, containers: names(privileged))
        }

        // W02
        let hostPaths = spec.volumes.compactMap { v in v.hostPath.map { (v, $0) } }
        if !hostPaths.isEmpty {
            let critical = hostPaths.contains { isCriticalHostPath($0.1) }
            emit("WH-W02", critical ? .critical : .high, "\(noun) mounts \(hostPaths.count == 1 ? "a hostPath volume" : "\(hostPaths.count) hostPath volumes")" + (critical ? " including a critical path" : ""),
                 evidence: hostPaths.map { "volume \($0.0.name): hostPath.path: \($0.1)" + (isCriticalHostPath($0.1) ? " (critical)" : "") })
        }

        // W03
        var hostNamespaces: [String] = []
        if spec.hostNetwork { hostNamespaces.append("hostNetwork: true") }
        if spec.hostPID { hostNamespaces.append("hostPID: true") }
        if spec.hostIPC { hostNamespaces.append("hostIPC: true") }
        if !hostNamespaces.isEmpty { emit("WH-W03", .high, "\(noun) shares the host's namespaces", evidence: hostNamespaces) }

        // W04
        let withCaps = spec.containers.filter { c in c.capabilitiesAdd.contains { dangerousCapabilities.contains(ContainerSecurity.normalizedCapability($0)) } }
        if !withCaps.isEmpty {
            emit("WH-W04", .high, "\(noun) adds dangerous capabilities",
                 evidence: withCaps.map { c in
                     let bad = c.capabilitiesAdd.filter { dangerousCapabilities.contains(ContainerSecurity.normalizedCapability($0)) }
                     return "container \(c.name): capabilities.add: [\(bad.joined(separator: ", "))]"
                 }, containers: names(withCaps))
        }

        // W05 (a privileged container always escalates, and W01 already reports it, but the rule still holds)
        let escalating = spec.containers.filter { $0.allowPrivilegeEscalation != false }
        if !escalating.isEmpty {
            emit("WH-W05", .medium, "\(noun) allows privilege escalation",
                 evidence: escalating.map { "container \($0.name): allowPrivilegeEscalation: \($0.allowPrivilegeEscalation.map { String($0) } ?? "not set")" }, containers: names(escalating))
        }

        // W06
        let mayBeRoot = spec.containers.filter { c in
            if spec.effectiveRunAsNonRoot(c) == true { return false }
            if let uid = spec.effectiveRunAsUser(c), uid != 0 { return false }
            return true
        }
        if !mayBeRoot.isEmpty {
            emit("WH-W06", .medium, "\(noun) may run as root",
                 evidence: mayBeRoot.map { c in
                     "container \(c.name): runAsNonRoot: \(spec.effectiveRunAsNonRoot(c).map { String($0) } ?? "not set"), runAsUser: \(spec.effectiveRunAsUser(c).map { String($0) } ?? "not set")"
                 }, containers: names(mayBeRoot))
        }

        // W07
        let writable = spec.containers.filter { $0.readOnlyRootFilesystem != true }
        if !writable.isEmpty {
            emit("WH-W07", .low, "\(noun) has a writable root filesystem",
                 evidence: writable.map { "container \($0.name): readOnlyRootFilesystem: \($0.readOnlyRootFilesystem.map { String($0) } ?? "not set")" }, containers: names(writable))
        }

        // W08
        let unlimited = spec.containers.filter { !$0.hasCPULimit || !$0.hasMemoryLimit }
        if !unlimited.isEmpty {
            emit("WH-W08", .low, "\(noun) has containers without CPU or memory limits",
                 evidence: unlimited.map { c in
                     let missing = [c.hasCPULimit ? nil : "cpu", c.hasMemoryLimit ? nil : "memory"].compactMap { $0 }
                     return "container \(c.name): no \(missing.joined(separator: " and ")) limit"
                 }, containers: names(unlimited))
        }

        // W09
        let mutable = spec.containers.filter { !$0.hasDigest && !$0.image.isEmpty }
        if !mutable.isEmpty {
            emit("WH-W09", .low, "\(noun) uses images by tag instead of digest",
                 evidence: mutable.map { c in
                     let tag = c.imageTag ?? ""
                     return "container \(c.name): image \(c.image)" + (tag == "latest" ? " (latest)" : " (tag \(tag))")
                 }, containers: names(mutable))
        }

        // W11
        let noSeccomp = spec.containers.filter { c in
            let t = spec.effectiveSeccomp(c)
            return t == nil || t == "Unconfined"
        }
        if !noSeccomp.isEmpty {
            emit("WH-W11", .low, "\(noun) has no seccomp profile",
                 evidence: noSeccomp.map { "container \($0.name): seccompProfile: \(spec.effectiveSeccomp($0) ?? "not set")" }, containers: names(noSeccomp))
        }
        return out
    }

    /// W10: a namespace that runs workloads and has none of the three Pod Security Admission labels.
    public static func namespacesWithoutPSA(_ s: SurveySnapshot) -> [SecurityFinding] {
        let withWorkloads = Set(s.workloads.map(\.ref.namespace))
        return s.namespaces.filter { ns in
            withWorkloads.contains(ns.metadata.name) && !psaLabels.contains { ns.metadata.labels[$0] != nil }
        }.map { ns in
            SecurityFinding(ruleID: "WH-W10", severity: .medium, clusterID: s.clusterID, namespace: ns.metadata.name,
                            object: FindingObject(kind: "Namespace", name: ns.metadata.name),
                            title: "Namespace \(ns.metadata.name) has no Pod Security Admission labels",
                            evidence: ["none of \(psaLabels.joined(separator: ", ")) is set"])
        }
    }
}
