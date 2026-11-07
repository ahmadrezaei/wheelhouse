import Foundation

public enum PSALevel: String, Codable, Sendable, CaseIterable, Comparable {
    case privileged, baseline, restricted
    public static func < (a: PSALevel, b: PSALevel) -> Bool { a.order < b.order }
    private var order: Int { switch self { case .privileged: 0; case .baseline: 1; case .restricted: 2 } }
}

public struct PSAViolation: Hashable, Codable, Sendable {
    /// The Pod Security Standards control, for example `Privileged Containers`.
    public var control: String
    public var detail: String
}

/// How one workload fares against the two Pod Security Standards levels.
public struct PSAWorkloadResult: Hashable, Sendable, Identifiable {
    public var workload: WorkloadRef
    public var baseline: [PSAViolation]
    /// The controls the `restricted` level adds on top of `baseline`.
    public var restricted: [PSAViolation]
    public var id: String { "\(workload.kind)/\(workload.namespace)/\(workload.name)" }
    public var failsBaseline: Bool { !baseline.isEmpty }
    /// `restricted` includes every baseline control.
    public var failsRestricted: Bool { !baseline.isEmpty || !restricted.isEmpty }
}

/// The Pod Security Admission labels of a namespace and what they would do to its workloads.
public struct PSANamespaceReport: Hashable, Sendable, Identifiable {
    public var namespace: String
    public var enforce: PSALevel?
    public var audit: PSALevel?
    public var warn: PSALevel?
    public var results: [PSAWorkloadResult]
    public var id: String { namespace }
    public var workloadCount: Int { results.count }
    public var failingBaseline: [PSAWorkloadResult] { results.filter(\.failsBaseline) }
    public var failingRestricted: [PSAWorkloadResult] { results.filter(\.failsRestricted) }
    public var hasLabels: Bool { enforce != nil || audit != nil || warn != nil }
    /// "payments would fail restricted: 4 workloads"
    public var summary: String {
        let r = failingRestricted.count
        return r == 0 ? "\(namespace) passes restricted" : "\(namespace) would fail restricted: \(r) workload\(r == 1 ? "" : "s")"
    }
}

/// A Kit port of the Pod Security Standards checks (https://kubernetes.io/docs/concepts/security/pod-security-standards/).
public enum PSAEvaluator {
    static let allowedBaselineCapabilities: Set<String> = [
        "AUDIT_WRITE", "CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "MKNOD", "NET_BIND_SERVICE", "SETFCAP", "SETGID", "SETPCAP", "SETUID", "SYS_CHROOT",
    ]
    static let allowedSELinuxTypes: Set<String> = ["container_t", "container_init_t", "container_kvm_t", "container_engine_t"]
    static let safeSysctls: Set<String> = [
        "kernel.shm_rmid_forced", "net.ipv4.ip_local_port_range", "net.ipv4.tcp_syncookies", "net.ipv4.ping_group_range",
        "net.ipv4.ip_unprivileged_port_start", "net.ipv4.ip_local_reserved_ports", "net.ipv4.tcp_keepalive_time",
        "net.ipv4.tcp_fin_timeout", "net.ipv4.tcp_keepalive_intvl", "net.ipv4.tcp_keepalive_probes",
    ]
    static let allowedRestrictedVolumes: Set<String> = ["configMap", "csi", "downwardAPI", "emptyDir", "ephemeral", "persistentVolumeClaim", "projected", "secret"]

    public static func evaluate(_ w: SurveyWorkload) -> PSAWorkloadResult {
        PSAWorkloadResult(workload: w.ref, baseline: baselineViolations(w.spec), restricted: restrictedViolations(w.spec))
    }

    public static func baselineViolations(_ spec: PodSecuritySpec) -> [PSAViolation] {
        var v: [PSAViolation] = []
        var hostNS: [String] = []
        if spec.hostNetwork { hostNS.append("hostNetwork") }
        if spec.hostPID { hostNS.append("hostPID") }
        if spec.hostIPC { hostNS.append("hostIPC") }
        if !hostNS.isEmpty { v.append(PSAViolation(control: "Host Namespaces", detail: hostNS.joined(separator: ", ") + " is true")) }

        for c in spec.containers {
            if c.privileged == true { v.append(PSAViolation(control: "Privileged Containers", detail: "container \(c.name) is privileged")) }
            let added = c.capabilitiesAdd.map(ContainerSecurity.normalizedCapability).filter { !allowedBaselineCapabilities.contains($0) }
            if !added.isEmpty { v.append(PSAViolation(control: "Capabilities", detail: "container \(c.name) adds \(added.joined(separator: ", "))")) }
            if !c.hostPorts.isEmpty { v.append(PSAViolation(control: "Host Ports", detail: "container \(c.name) uses hostPort \(c.hostPorts.map(String.init).joined(separator: ", "))")) }
            if c.appArmorType == "Unconfined" || spec.appArmorType == "Unconfined" { v.append(PSAViolation(control: "AppArmor", detail: "container \(c.name) is unconfined")) }
            if let t = c.procMount, t != "Default" { v.append(PSAViolation(control: "/proc Mount Type", detail: "container \(c.name) uses procMount \(t)")) }
            if let t = c.seLinuxType ?? spec.seLinuxType, !allowedSELinuxTypes.contains(t) { v.append(PSAViolation(control: "SELinux", detail: "container \(c.name) sets type \(t)")) }
            if c.seLinuxUser != nil || c.seLinuxRole != nil || spec.seLinuxUser != nil || spec.seLinuxRole != nil {
                v.append(PSAViolation(control: "SELinux", detail: "container \(c.name) sets an SELinux user or role"))
            }
            if spec.effectiveSeccomp(c) == "Unconfined" { v.append(PSAViolation(control: "Seccomp", detail: "container \(c.name) uses Unconfined")) }
        }
        for vol in spec.volumes where vol.type == "hostPath" {
            v.append(PSAViolation(control: "HostPath Volumes", detail: "volume \(vol.name) mounts \(vol.hostPath ?? "a host path")"))
        }
        let unsafe = spec.sysctls.filter { !safeSysctls.contains($0) }
        if !unsafe.isEmpty { v.append(PSAViolation(control: "Sysctls", detail: "unsafe sysctls: \(unsafe.joined(separator: ", "))")) }
        return v
    }

    public static func restrictedViolations(_ spec: PodSecuritySpec) -> [PSAViolation] {
        var v: [PSAViolation] = []
        for vol in spec.volumes where !allowedRestrictedVolumes.contains(vol.type) && vol.type != "hostPath" {
            v.append(PSAViolation(control: "Volume Types", detail: "volume \(vol.name) is of type \(vol.type)"))
        }
        // hostPath is a baseline violation already; the restricted level repeats it under Volume Types, which is not counted twice.
        let everyContainerNonRoot = !spec.containers.isEmpty && spec.containers.allSatisfy { spec.effectiveRunAsNonRoot($0) == true }
        if spec.runAsNonRoot != true, !everyContainerNonRoot {
            v.append(PSAViolation(control: "Running as Non-root", detail: "runAsNonRoot is not true on the Pod or on every container"))
        }
        for c in spec.containers {
            if c.allowPrivilegeEscalation != false { v.append(PSAViolation(control: "Privilege Escalation", detail: "container \(c.name) does not set allowPrivilegeEscalation: false")) }
            if c.runAsNonRoot == false { v.append(PSAViolation(control: "Running as Non-root", detail: "container \(c.name) sets runAsNonRoot: false")) }
            if spec.effectiveRunAsUser(c) == 0 { v.append(PSAViolation(control: "Running as Non-root user", detail: "container \(c.name) runs as UID 0")) }
            let seccomp = spec.effectiveSeccomp(c)
            if seccomp != "RuntimeDefault", seccomp != "Localhost" {
                v.append(PSAViolation(control: "Seccomp", detail: "container \(c.name) has seccompProfile \(seccomp ?? "not set")"))
            }
            let dropped = c.capabilitiesDrop.map(ContainerSecurity.normalizedCapability)
            if !dropped.contains("ALL") { v.append(PSAViolation(control: "Capabilities", detail: "container \(c.name) does not drop ALL")) }
            let extra = c.capabilitiesAdd.map(ContainerSecurity.normalizedCapability).filter { $0 != "NET_BIND_SERVICE" }
            if !extra.isEmpty { v.append(PSAViolation(control: "Capabilities", detail: "container \(c.name) adds \(extra.joined(separator: ", "))")) }
        }
        if spec.runAsUser == 0 { v.append(PSAViolation(control: "Running as Non-root user", detail: "the Pod runs as UID 0")) }
        if spec.runAsNonRoot == false { v.append(PSAViolation(control: "Running as Non-root", detail: "the Pod sets runAsNonRoot: false")) }
        return v
    }

    /// One report per namespace that has workloads (and per namespace with PSA labels), sorted by name.
    public static func evaluate(snapshot s: SurveySnapshot) -> [PSANamespaceReport] {
        var results: [String: [PSAWorkloadResult]] = [:]
        for w in s.workloads { results[w.ref.namespace, default: []].append(evaluate(w)) }
        func level(_ ns: Namespace, _ suffix: String) -> PSALevel? { ns.metadata.labels["pod-security.kubernetes.io/\(suffix)"].flatMap(PSALevel.init(rawValue:)) }
        var reports: [PSANamespaceReport] = []
        var seen = Set<String>()
        for ns in s.namespaces {
            seen.insert(ns.metadata.name)
            let r = results[ns.metadata.name] ?? []
            let report = PSANamespaceReport(namespace: ns.metadata.name, enforce: level(ns, "enforce"), audit: level(ns, "audit"), warn: level(ns, "warn"),
                                            results: r.sorted { $0.id < $1.id })
            if !r.isEmpty || report.hasLabels { reports.append(report) }
        }
        for (name, r) in results where !seen.contains(name) {
            reports.append(PSANamespaceReport(namespace: name, enforce: nil, audit: nil, warn: nil, results: r.sorted { $0.id < $1.id }))
        }
        return reports.sorted { $0.namespace < $1.namespace }
    }
}
