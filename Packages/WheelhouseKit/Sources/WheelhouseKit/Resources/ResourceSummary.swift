import Foundation

public extension Unstructured {
    func string(_ path: String) -> String? { raw.value(at: path)?.stringValue }
    func int(_ path: String) -> Int? { raw.value(at: path)?.intValue }
    func bool(_ path: String) -> Bool? { raw.value(at: path)?.boolValue }
    func array(_ path: String) -> [JSONValue] { raw.value(at: path)?.arrayValue ?? [] }
    func conditions(_ path: String = "status.conditions") -> [Condition] {
        array(path).compactMap { try? $0.decode(Condition.self) }
    }
}

/// Everything a list row needs for one object, computed once from the raw JSON (kind-specific).
public struct ResourceSummary: Hashable, Sendable {
    public var status: HealthStatus = .unknown
    /// Short status word shown in rows and pills (`Running`, `CrashLoopBackOff`, `Ready`, `Bound`…).
    public var statusText: String = ""
    public var ready: Int?
    public var desired: Int?
    /// Pods: ready containers; deployments: up-to-date replicas.
    public var upToDate: Int?
    public var restarts: Int = 0
    public var nodeName: String?
    /// Kind-specific detail bits shown after the namespace in the subtitle (`ClusterIP · 10.0.0.1 · 80/TCP`).
    public var details: [String] = []
    /// Lowercased haystack for search (name, labels values, images, …).
    public var searchText: String = ""
    public var isCordoned = false
    public var isSuspended = false
    public var isNotReady = false
    public var roles: [String] = []
    public var cpuRequestCores: Double?
    public var memoryRequestBytes: Double?
    public var cpuLimitCores: Double?
    public var memoryLimitBytes: Double?
    public var cpuCapacityCores: Double?
    public var memoryCapacityBytes: Double?

    /// Sort rank: worst first.
    public var severityRank: Int {
        switch status { case .critical: 0; case .warning: 1; case .unknown: 2; case .healthy: 3 }
    }
}

public enum ResourceSummarizer {
    public static func summarize(kind: ResourceKind, object o: Unstructured, now: Date = Date()) -> ResourceSummary {
        var s = ResourceSummary()
        var haystack: [String] = [o.metadata.name, o.metadata.namespace ?? ""]
        haystack.append(contentsOf: o.metadata.labels.values)
        haystack.append(contentsOf: o.metadata.labels.keys)

        switch kind.kind {
        case "Pod" where kind.group.isEmpty:
            if let pod = try? o.raw.decode(Pod.self) {
                let st = pod.stateSummary()
                s.status = st.isCompleted ? .healthy : st.severity
                s.statusText = st.reason
                s.ready = pod.readyContainers
                s.desired = pod.totalContainers
                s.restarts = st.restarts
                s.nodeName = pod.spec.nodeName
                let containers = pod.spec.containers
                let cpuReq = containers.compactMap { $0.resources?.requests?.cpuCores }
                let memReq = containers.compactMap { $0.resources?.requests?.memoryBytes }
                let cpuLim = containers.compactMap { $0.resources?.limits?.cpuCores }
                let memLim = containers.compactMap { $0.resources?.limits?.memoryBytes }
                if !cpuReq.isEmpty { s.cpuRequestCores = cpuReq.reduce(0, +) }
                if !memReq.isEmpty { s.memoryRequestBytes = memReq.reduce(0, +) }
                if cpuLim.count == containers.count, !cpuLim.isEmpty { s.cpuLimitCores = cpuLim.reduce(0, +) }
                if memLim.count == containers.count, !memLim.isEmpty { s.memoryLimitBytes = memLim.reduce(0, +) }
                haystack.append(contentsOf: containers.compactMap(\.image))
                haystack.append(contentsOf: [st.reason, pod.spec.nodeName ?? "", pod.status?.podIP ?? ""])
            }
        case "Deployment":
            let desired = o.int("spec.replicas") ?? 1
            let ready = o.int("status.readyReplicas") ?? 0
            s.ready = ready; s.desired = desired
            s.upToDate = o.int("status.updatedReplicas") ?? 0
            let progressing = o.conditions().first { $0.type == "Progressing" }
            let failed = progressing?.status == "False" || progressing?.reason == "ProgressDeadlineExceeded"
            (s.status, s.statusText) = controllerStatus(ready: ready, desired: desired, failed: failed)
            s.details = ["\(s.upToDate ?? 0) up-to-date"]
            haystack.append(contentsOf: templateImages(o, path: "spec.template.spec"))
        case "StatefulSet":
            let desired = o.int("spec.replicas") ?? 1
            let ready = o.int("status.readyReplicas") ?? 0
            s.ready = ready; s.desired = desired
            s.upToDate = o.int("status.updatedReplicas")
            (s.status, s.statusText) = controllerStatus(ready: ready, desired: desired, failed: false)
            haystack.append(contentsOf: templateImages(o, path: "spec.template.spec"))
        case "ReplicaSet":
            let desired = o.int("spec.replicas") ?? 0
            let ready = o.int("status.readyReplicas") ?? 0
            s.ready = ready; s.desired = desired
            (s.status, s.statusText) = controllerStatus(ready: ready, desired: desired, failed: false)
            if let owner = o.metadata.controller { s.details = ["owned by \(owner.name)"] }
            haystack.append(contentsOf: templateImages(o, path: "spec.template.spec"))
        case "DaemonSet":
            let desired = o.int("status.desiredNumberScheduled") ?? 0
            let ready = o.int("status.numberReady") ?? 0
            s.ready = ready; s.desired = desired
            s.upToDate = o.int("status.updatedNumberScheduled")
            (s.status, s.statusText) = controllerStatus(ready: ready, desired: desired, failed: false)
            haystack.append(contentsOf: templateImages(o, path: "spec.template.spec"))
        case "Job":
            let completions = o.int("spec.completions") ?? 1
            let succeeded = o.int("status.succeeded") ?? 0
            let failedCount = o.int("status.failed") ?? 0
            let active = o.int("status.active") ?? 0
            s.ready = succeeded; s.desired = completions
            let conds = o.conditions()
            if conds.contains(where: { $0.type == "Failed" && $0.isTrue }) { s.status = .critical; s.statusText = conds.first { $0.type == "Failed" }?.reason ?? "Failed" }
            else if conds.contains(where: { $0.type == "Complete" && $0.isTrue }) { s.status = .healthy; s.statusText = "Complete" }
            else if active > 0 { s.status = failedCount > 0 ? .warning : .healthy; s.statusText = "Running" }
            else { s.status = failedCount > 0 ? .warning : .unknown; s.statusText = failedCount > 0 ? "Retrying" : "Pending" }
            if failedCount > 0 { s.details = ["\(failedCount) failed"] }
        case "CronJob":
            s.isSuspended = o.bool("spec.suspend") ?? false
            s.statusText = s.isSuspended ? "Suspended" : "Scheduled"
            s.status = s.isSuspended ? .unknown : .healthy
            s.details = [o.string("spec.schedule") ?? "", o.string("status.lastScheduleTime").flatMap(parseDate).map { "last \(shortAge($0, now: now)) ago" } ?? "never run"].filter { !$0.isEmpty }
            let active = o.array("status.active").count
            if active > 0 { s.details.append("\(active) active") }
        case "Service":
            let type = o.string("spec.type") ?? "ClusterIP"
            s.statusText = type
            s.status = .healthy
            var d = [type]
            if let ip = o.string("spec.clusterIP"), ip != "None" { d.append(ip) } else if o.string("spec.clusterIP") == "None" { d.append("headless") }
            if type == "ExternalName", let n = o.string("spec.externalName") { d.append(n) }
            let ports = o.array("spec.ports").compactMap { p -> String? in
                guard let port = p["port"]?.intValue else { return nil }
                return "\(port)/\(p["protocol"]?.stringValue ?? "TCP")"
            }
            if !ports.isEmpty { d.append(ports.joined(separator: ",")) }
            s.details = d
        case "Ingress":
            let hosts = o.array("spec.rules").compactMap { $0["host"]?.stringValue }
            s.status = .healthy
            s.statusText = o.string("spec.ingressClassName") ?? "Ingress"
            s.details = [hosts.isEmpty ? "any host" : hosts.joined(separator: ", ")]
            haystack.append(contentsOf: hosts)
        case "NetworkPolicy":
            s.status = .healthy
            s.statusText = (o.array("spec.policyTypes").compactMap(\.stringValue)).joined(separator: "+")
            s.details = ["pods " + selectorText(o.raw.value(at: "spec.podSelector"))]
        case "Endpoints":
            let addresses = o.array("subsets").reduce(0) { $0 + (($1["addresses"]?.arrayValue ?? []).count) }
            let notReady = o.array("subsets").reduce(0) { $0 + (($1["notReadyAddresses"]?.arrayValue ?? []).count) }
            s.ready = addresses; s.desired = addresses + notReady
            s.status = notReady > 0 ? .warning : (addresses == 0 ? .unknown : .healthy)
            s.statusText = addresses == 0 ? "No endpoints" : "\(addresses) ready"
            s.details = [notReady > 0 ? "\(notReady) not ready" : ""].filter { !$0.isEmpty }
        case "EndpointSlice":
            let eps = o.array("endpoints")
            let ready = eps.filter { $0.value(at: "conditions.ready")?.boolValue != false }.count
            s.ready = ready; s.desired = eps.count
            s.status = eps.isEmpty ? .unknown : (ready == eps.count ? .healthy : .warning)
            s.statusText = "\(ready)/\(eps.count) ready"
            s.details = [o.string("addressType") ?? ""].filter { !$0.isEmpty }
        case "ConfigMap":
            let n = (o.raw["data"]?.objectValue?.count ?? 0) + (o.raw["binaryData"]?.objectValue?.count ?? 0)
            s.status = .healthy; s.statusText = "\(n) keys"
            s.details = ["\(n) key\(n == 1 ? "" : "s")"]
            haystack.append(contentsOf: (o.raw["data"]?.objectValue ?? [:]).keys)
        case "Secret":
            let n = o.raw["data"]?.objectValue?.count ?? 0
            s.status = .healthy; s.statusText = o.string("type") ?? "Opaque"
            s.details = [o.string("type") ?? "Opaque", "\(n) key\(n == 1 ? "" : "s")"]
            haystack.append(contentsOf: (o.raw["data"]?.objectValue ?? [:]).keys)
        case "PersistentVolume":
            let phase = o.string("status.phase") ?? "Unknown"
            s.statusText = phase
            s.status = phase == "Bound" || phase == "Available" ? .healthy : (phase == "Failed" ? .critical : .warning)
            s.details = [o.string("spec.capacity.storage") ?? "", o.string("spec.persistentVolumeReclaimPolicy") ?? "", o.string("spec.storageClassName") ?? ""].filter { !$0.isEmpty }
            if let claim = o.raw.value(at: "spec.claimRef.name")?.stringValue { s.details.append("→ \(claim)") }
        case "PersistentVolumeClaim":
            let phase = o.string("status.phase") ?? "Unknown"
            s.statusText = phase
            s.status = phase == "Bound" ? .healthy : (phase == "Lost" ? .critical : .warning)
            s.details = [o.string("status.capacity.storage") ?? o.string("spec.resources.requests.storage") ?? "", o.string("spec.storageClassName") ?? "", o.string("spec.volumeName") ?? ""].filter { !$0.isEmpty }
        case "StorageClass":
            s.status = .healthy
            let isDefault = o.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true"
            s.statusText = isDefault ? "Default" : "StorageClass"
            s.details = [o.string("provisioner") ?? "", o.string("volumeBindingMode") ?? ""].filter { !$0.isEmpty }
        case "Node":
            let conds = o.conditions()
            let readyCond = conds.first { $0.type == "Ready" }
            let isReady = readyCond?.isTrue ?? false
            s.isCordoned = o.bool("spec.unschedulable") ?? false
            let pressure = conds.filter { $0.type != "Ready" && $0.isTrue }
            s.isNotReady = !isReady
            if !isReady { s.status = .critical; s.statusText = "NotReady" }
            else if !pressure.isEmpty { s.status = .warning; s.statusText = pressure[0].type }
            else if s.isCordoned { s.status = .warning; s.statusText = "Ready" }
            else { s.status = .healthy; s.statusText = "Ready" }
            if s.isCordoned { s.statusText += ",SchedulingDisabled" }
            s.roles = o.metadata.labels.keys.compactMap { $0.hasPrefix("node-role.kubernetes.io/") ? String($0.dropFirst("node-role.kubernetes.io/".count)) : nil }.sorted()
            if s.roles.isEmpty { s.roles = ["worker"] }
            s.details = [s.roles.joined(separator: ","), o.string("status.nodeInfo.kubeletVersion") ?? ""].filter { !$0.isEmpty }
            s.cpuCapacityCores = o.string("status.allocatable.cpu").flatMap { Quantity($0).value }
            s.memoryCapacityBytes = o.string("status.allocatable.memory").flatMap { Quantity($0).value }
            haystack.append(contentsOf: o.array("spec.taints").compactMap { $0["key"]?.stringValue })
            haystack.append(contentsOf: s.roles)
        case "Namespace":
            let phase = o.string("status.phase") ?? "Active"
            s.statusText = phase
            s.status = phase == "Active" ? .healthy : .warning
        case "Event":
            let warning = (o.string("type") ?? "Normal") == "Warning"
            s.status = warning ? .warning : .healthy
            s.statusText = o.string("reason") ?? "Event"
            let obj = [o.string("involvedObject.kind") ?? o.string("regarding.kind"), o.string("involvedObject.name") ?? o.string("regarding.name")].compactMap { $0 }.joined(separator: "/")
            s.details = [obj, o.string("message") ?? o.string("note") ?? ""].filter { !$0.isEmpty }
            haystack.append(contentsOf: s.details + [s.statusText])
        case "CustomResourceDefinition":
            s.status = .healthy
            s.statusText = o.string("spec.scope") ?? "CRD"
            s.details = [o.string("spec.group") ?? "", o.string("spec.scope") ?? ""].filter { !$0.isEmpty }
        case "ServiceAccount":
            s.status = .healthy; s.statusText = "ServiceAccount"
        case "Role", "ClusterRole":
            s.status = .healthy
            let n = o.array("rules").count
            s.statusText = "\(n) rules"; s.details = ["\(n) rule\(n == 1 ? "" : "s")"]
        case "RoleBinding", "ClusterRoleBinding":
            s.status = .healthy
            let subjects = o.array("subjects").compactMap { $0["name"]?.stringValue }
            s.statusText = o.string("roleRef.name") ?? ""
            s.details = ["→ \(o.string("roleRef.name") ?? "?")", subjects.joined(separator: ", ")].filter { !$0.isEmpty }
        default:
            // Custom resources: ready/conditions-based status when present.
            let conds = o.conditions()
            if let ready = conds.first(where: { $0.type == "Ready" || $0.type == "Available" || $0.type == "Established" }) {
                s.status = ready.isTrue ? .healthy : (ready.status == "False" ? .critical : .warning)
                s.statusText = ready.isTrue ? ready.type : (ready.reason ?? "Not \(ready.type)")
            } else if let phase = o.string("status.phase") ?? o.string("status.state") {
                s.statusText = phase
                s.status = ["failed", "error"].contains(phase.lowercased()) ? .critical : .healthy
            } else {
                s.status = .healthy
            }
            if let g = o.apiVersion { s.details = [g] }
        }
        s.searchText = haystack.joined(separator: "\n").lowercased()
        return s
    }

    static func controllerStatus(ready: Int, desired: Int, failed: Bool) -> (HealthStatus, String) {
        if failed { return (.critical, "Failed") }
        if desired == 0 { return (.unknown, "Scaled to 0") }
        if ready >= desired { return (.healthy, "Available") }
        return (ready == 0 ? .critical : .warning, ready == 0 ? "Unavailable" : "Progressing")
    }

    static func templateImages(_ o: Unstructured, path: String) -> [String] {
        o.array("\(path).containers").compactMap { $0["image"]?.stringValue }
    }

    public static func selectorText(_ selector: JSONValue?) -> String {
        guard let ml = selector?["matchLabels"]?.objectValue, !ml.isEmpty else { return "all" }
        return ml.sorted { $0.key < $1.key }.compactMap { k, v in v.stringValue.map { "\(k)=\($0)" } }.joined(separator: ",")
    }

    public static func parseDate(_ s: String) -> Date? { try? KubeJSON.decoder.decode(Date.self, from: Data("\"\(s)\"".utf8)) }

    static func shortAge(_ d: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
