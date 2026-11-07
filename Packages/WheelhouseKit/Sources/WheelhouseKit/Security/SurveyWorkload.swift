import Foundation

/// The security-relevant slice of a container, read from raw JSON so the rules do not depend on the display models.
public struct ContainerSecurity: Hashable, Sendable {
    public var name: String
    public var isInit: Bool
    public var image: String
    public var privileged: Bool?
    public var allowPrivilegeEscalation: Bool?
    public var runAsNonRoot: Bool?
    public var runAsUser: Int?
    public var readOnlyRootFilesystem: Bool?
    public var capabilitiesAdd: [String]
    public var capabilitiesDrop: [String]
    public var seccompType: String?
    public var appArmorType: String?
    public var procMount: String?
    public var seLinuxType: String?
    public var seLinuxUser: String?
    public var seLinuxRole: String?
    public var hostPorts: [Int]
    public var hasCPULimit: Bool
    public var hasMemoryLimit: Bool

    public init(name: String, isInit: Bool = false, image: String = "", privileged: Bool? = nil, allowPrivilegeEscalation: Bool? = nil,
                runAsNonRoot: Bool? = nil, runAsUser: Int? = nil, readOnlyRootFilesystem: Bool? = nil, capabilitiesAdd: [String] = [],
                capabilitiesDrop: [String] = [], seccompType: String? = nil, appArmorType: String? = nil, procMount: String? = nil,
                seLinuxType: String? = nil, seLinuxUser: String? = nil, seLinuxRole: String? = nil, hostPorts: [Int] = [],
                hasCPULimit: Bool = false, hasMemoryLimit: Bool = false) {
        self.name = name; self.isInit = isInit; self.image = image; self.privileged = privileged
        self.allowPrivilegeEscalation = allowPrivilegeEscalation; self.runAsNonRoot = runAsNonRoot; self.runAsUser = runAsUser
        self.readOnlyRootFilesystem = readOnlyRootFilesystem; self.capabilitiesAdd = capabilitiesAdd; self.capabilitiesDrop = capabilitiesDrop
        self.seccompType = seccompType; self.appArmorType = appArmorType; self.procMount = procMount; self.seLinuxType = seLinuxType
        self.seLinuxUser = seLinuxUser; self.seLinuxRole = seLinuxRole; self.hostPorts = hostPorts
        self.hasCPULimit = hasCPULimit; self.hasMemoryLimit = hasMemoryLimit
    }

    init(json c: JSONValue, isInit: Bool) {
        let sc = c["securityContext"]
        let caps = sc?["capabilities"]
        func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }
        let limits = c.value(at: "resources.limits")
        func present(_ key: String) -> Bool {
            guard let v = limits?[key] else { return false }
            if let s = v.stringValue { return !s.isEmpty && s != "0" }
            if let i = v.intValue { return i != 0 }
            return !v.isNull
        }
        self.init(
            name: c["name"]?.stringValue ?? "", isInit: isInit, image: c["image"]?.stringValue ?? "",
            privileged: sc?["privileged"]?.boolValue, allowPrivilegeEscalation: sc?["allowPrivilegeEscalation"]?.boolValue,
            runAsNonRoot: sc?["runAsNonRoot"]?.boolValue, runAsUser: sc?["runAsUser"]?.intValue,
            readOnlyRootFilesystem: sc?["readOnlyRootFilesystem"]?.boolValue,
            capabilitiesAdd: strings(caps?["add"]), capabilitiesDrop: strings(caps?["drop"]),
            seccompType: sc?.value(at: "seccompProfile.type")?.stringValue, appArmorType: sc?.value(at: "appArmorProfile.type")?.stringValue,
            procMount: sc?["procMount"]?.stringValue,
            seLinuxType: sc?.value(at: "seLinuxOptions.type")?.stringValue, seLinuxUser: sc?.value(at: "seLinuxOptions.user")?.stringValue,
            seLinuxRole: sc?.value(at: "seLinuxOptions.role")?.stringValue,
            hostPorts: (c["ports"]?.arrayValue ?? []).compactMap { $0["hostPort"]?.intValue }.filter { $0 != 0 },
            hasCPULimit: present("cpu"), hasMemoryLimit: present("memory"))
    }

    /// `CAP_` prefix removed and upper-cased, so `cap_sys_admin` and `SYS_ADMIN` compare equal.
    public static func normalizedCapability(_ c: String) -> String {
        let u = c.uppercased()
        return u.hasPrefix("CAP_") ? String(u.dropFirst(4)) : u
    }

    public var hasDigest: Bool { image.contains("@sha256:") || image.contains("@sha512:") }
    /// `latest` for `nginx:latest` or `nginx`; the tag otherwise; nil when pinned by digest.
    public var imageTag: String? {
        guard !hasDigest else { return nil }
        let last = image.split(separator: "/").last.map(String.init) ?? image
        if let colon = last.lastIndex(of: ":") { return String(last[last.index(after: colon)...]) }
        return "latest"
    }
}

public struct VolumeSecurity: Hashable, Sendable {
    public var name: String
    /// The volume source key: `hostPath`, `emptyDir`, `configMap`, ...
    public var type: String
    public var hostPath: String?
    public init(name: String, type: String, hostPath: String? = nil) {
        self.name = name
        self.type = type
        self.hostPath = hostPath
    }
}

/// The security-relevant slice of a pod spec (a Pod's, or a controller's pod template's).
public struct PodSecuritySpec: Hashable, Sendable {
    public var hostNetwork: Bool
    public var hostPID: Bool
    public var hostIPC: Bool
    public var serviceAccountName: String?
    public var automountServiceAccountToken: Bool?
    public var runAsNonRoot: Bool?
    public var runAsUser: Int?
    public var seccompType: String?
    public var appArmorType: String?
    public var seLinuxType: String?
    public var seLinuxUser: String?
    public var seLinuxRole: String?
    public var sysctls: [String]
    public var containers: [ContainerSecurity]
    public var volumes: [VolumeSecurity]

    public init(hostNetwork: Bool = false, hostPID: Bool = false, hostIPC: Bool = false, serviceAccountName: String? = nil,
                automountServiceAccountToken: Bool? = nil, runAsNonRoot: Bool? = nil, runAsUser: Int? = nil, seccompType: String? = nil,
                appArmorType: String? = nil, seLinuxType: String? = nil, seLinuxUser: String? = nil, seLinuxRole: String? = nil,
                sysctls: [String] = [], containers: [ContainerSecurity] = [], volumes: [VolumeSecurity] = []) {
        self.hostNetwork = hostNetwork; self.hostPID = hostPID; self.hostIPC = hostIPC; self.serviceAccountName = serviceAccountName
        self.automountServiceAccountToken = automountServiceAccountToken; self.runAsNonRoot = runAsNonRoot; self.runAsUser = runAsUser
        self.seccompType = seccompType; self.appArmorType = appArmorType; self.seLinuxType = seLinuxType; self.seLinuxUser = seLinuxUser
        self.seLinuxRole = seLinuxRole; self.sysctls = sysctls; self.containers = containers; self.volumes = volumes
    }

    public init(json spec: JSONValue) {
        let sc = spec["securityContext"]
        let volumes: [VolumeSecurity] = (spec["volumes"]?.arrayValue ?? []).map { v in
            let name = v["name"]?.stringValue ?? ""
            let type = v.objectValue?.keys.filter { $0 != "name" }.sorted().first ?? "unknown"
            return VolumeSecurity(name: name, type: type, hostPath: type == "hostPath" ? v.value(at: "hostPath.path")?.stringValue : nil)
        }
        let containers = (spec["containers"]?.arrayValue ?? []).map { ContainerSecurity(json: $0, isInit: false) }
            + (spec["initContainers"]?.arrayValue ?? []).map { ContainerSecurity(json: $0, isInit: true) }
        self.init(
            hostNetwork: spec["hostNetwork"]?.boolValue ?? false, hostPID: spec["hostPID"]?.boolValue ?? false,
            hostIPC: spec["hostIPC"]?.boolValue ?? false,
            serviceAccountName: spec["serviceAccountName"]?.stringValue ?? spec["serviceAccount"]?.stringValue,
            automountServiceAccountToken: spec["automountServiceAccountToken"]?.boolValue,
            runAsNonRoot: sc?["runAsNonRoot"]?.boolValue, runAsUser: sc?["runAsUser"]?.intValue,
            seccompType: sc?.value(at: "seccompProfile.type")?.stringValue, appArmorType: sc?.value(at: "appArmorProfile.type")?.stringValue,
            seLinuxType: sc?.value(at: "seLinuxOptions.type")?.stringValue, seLinuxUser: sc?.value(at: "seLinuxOptions.user")?.stringValue,
            seLinuxRole: sc?.value(at: "seLinuxOptions.role")?.stringValue,
            sysctls: (sc?["sysctls"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue },
            containers: containers, volumes: volumes)
    }

    /// The ServiceAccount the Pods run as.
    public var effectiveServiceAccount: String { serviceAccountName ?? "default" }

    // Effective (container over Pod) values, as the Pod Security Standards read them.
    public func effectiveRunAsNonRoot(_ c: ContainerSecurity) -> Bool? { c.runAsNonRoot ?? runAsNonRoot }
    public func effectiveRunAsUser(_ c: ContainerSecurity) -> Int? { c.runAsUser ?? runAsUser }
    public func effectiveSeccomp(_ c: ContainerSecurity) -> String? { c.seccompType ?? seccompType }
}

/// A workload the Survey rules look at: a controller's pod template or a bare Pod.
public struct SurveyWorkload: Hashable, Sendable, Identifiable {
    public var ref: WorkloadRef
    public var spec: PodSecuritySpec
    public var labels: [String: String]
    public var annotations: [String: String]
    public var id: String { "\(ref.kind)/\(ref.namespace)/\(ref.name)" }

    public init(ref: WorkloadRef, spec: PodSecuritySpec, labels: [String: String] = [:], annotations: [String: String] = [:]) {
        self.ref = ref
        self.spec = spec
        self.labels = labels
        self.annotations = annotations
    }

    /// Kinds that carry a pod template, with the path to it.
    static let templatePaths: [String: String] = [
        "Deployment": "spec.template.spec", "StatefulSet": "spec.template.spec", "DaemonSet": "spec.template.spec",
        "ReplicaSet": "spec.template.spec", "Job": "spec.template.spec", "CronJob": "spec.jobTemplate.spec.template.spec",
        "Pod": "spec",
    ]

    public init?(raw: JSONValue, kind: String) {
        guard let path = Self.templatePaths[kind], let spec = raw.value(at: path),
              let name = raw.value(at: "metadata.name")?.stringValue else { return nil }
        let meta = raw["metadata"]
        func map(_ v: JSONValue?) -> [String: String] {
            (v?.objectValue ?? [:]).compactMapValues(\.stringValue)
        }
        self.init(ref: WorkloadRef(kind: kind, namespace: meta?["namespace"]?.stringValue ?? "default", name: name),
                  spec: PodSecuritySpec(json: spec), labels: map(meta?["labels"]), annotations: map(meta?["annotations"]))
    }

    /// Helm, Argo CD or Flux manage this object when their labels or annotations say so: a patch applied in the cluster is reverted.
    public var managedBy: String? {
        if labels["app.kubernetes.io/managed-by"] == "Helm" || annotations["meta.helm.sh/release-name"] != nil { return "Helm" }
        if labels["argocd.argoproj.io/instance"] != nil || annotations["argocd.argoproj.io/tracking-id"] != nil { return "Argo CD" }
        if labels.keys.contains(where: { $0.hasPrefix("kustomize.toolkit.fluxcd.io/") }) || labels.keys.contains(where: { $0.hasPrefix("helm.toolkit.fluxcd.io/") }) { return "Flux" }
        return nil
    }
}
