import Foundation

struct DemoRNG {
    private var state: UInt64
    init(seed: String) {
        var h: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        state = h
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func double() -> Double { Double(next() % 1_000_000) / 1_000_000 }
    mutating func token(_ n: Int) -> String {
        let chars = Array("bcdfghjklmnpqrstvwxz2456789")
        return String((0..<n).map { _ in chars[Int(next() % UInt64(chars.count))] })
    }
}

enum DemoPodState {
    case running
    case crashLoopOOM
    case pending(String)
    case imagePull
    case completed
    case failedJob
}

/// Generates one cluster's worth of Kubernetes objects as JSON.
struct DemoDataBuilder {
    var objects: [String: [JSONValue]] = [:]
    var rng: DemoRNG
    let now: Date
    let clusterName: String
    var nodeNames: [String] = []

    init(clusterName: String, now: Date = Date()) {
        self.clusterName = clusterName
        self.now = now
        self.rng = DemoRNG(seed: clusterName)
    }

    // MARK: Helpers

    func iso(_ ago: TimeInterval) -> JSONValue { .string(now.addingTimeInterval(-ago).formatted(.iso8601)) }

    mutating func uid() -> String {
        let a = rng.token(8), b = rng.token(4), c = rng.token(4), d = rng.token(4), e = rng.token(12)
        return "\(a)-\(b)-\(c)-\(d)-\(e)"
    }

    mutating func meta(_ name: String, ns: String? = nil, labels: [String: String] = [:], annotations: [String: String] = [:],
                       age: TimeInterval, owner: (kind: String, name: String, uid: String)? = nil) -> JSONValue {
        var m: [String: JSONValue] = ["name": .string(name), "uid": .string(uid()), "resourceVersion": .string(String(1000 + Int(rng.next() % 9000))),
                                      "creationTimestamp": iso(age)]
        if let ns { m["namespace"] = .string(ns) }
        if !labels.isEmpty { m["labels"] = .object(labels.mapValues { .string($0) }) }
        if !annotations.isEmpty { m["annotations"] = .object(annotations.mapValues { .string($0) }) }
        if let owner {
            m["ownerReferences"] = [["apiVersion": "apps/v1", "kind": .string(owner.kind), "name": .string(owner.name), "uid": .string(owner.uid), "controller": true]]
        }
        return .object(m)
    }

    mutating func add(_ kind: ResourceKind, _ object: JSONValue) {
        var o = object
        if o["apiVersion"] == nil { o["apiVersion"] = .string(kind.apiVersion) }
        if o["kind"] == nil { o["kind"] = .string(kind.kind) }
        objects[kind.id, default: []].append(o)
    }

    // MARK: Nodes

    mutating func addNode(_ name: String, cpu: Int, memGi: Int, instance: String, zone: String, pool: String, ready: Bool = true,
                          cordoned: Bool = false, age: TimeInterval = 86_400 * 40, kubelet: String = "v1.31.4", control: Bool = false, provider: String = "EKS") {
        nodeNames.append(name)
        var labels = ["kubernetes.io/hostname": name, "node.kubernetes.io/instance-type": instance, "topology.kubernetes.io/zone": zone,
                      "kubernetes.io/os": "linux", "kubernetes.io/arch": "amd64"]
        let providerID: String, osImage: String
        switch provider {
        case "GKE":
            labels["cloud.google.com/gke-nodepool"] = pool
            providerID = "gce://wheelhouse-demo/\(zone)/\(name)"
            osImage = "Container-Optimized OS from Google"
        case "k3s":
            labels["node.kubernetes.io/instance-type"] = "k3s"
            providerID = "k3s://\(name)"
            osImage = "Debian GNU/Linux 12 (bookworm)"
        default:
            labels["eks.amazonaws.com/nodegroup"] = pool
            providerID = "aws:///\(zone)/i-0\(rng.token(10))"
            osImage = "Amazon Linux 2023"
        }
        if control { labels["node-role.kubernetes.io/control-plane"] = "" }
        var spec: [String: JSONValue] = ["providerID": .string(providerID)]
        var taints: [JSONValue] = []
        if !ready { taints.append(["key": "node.kubernetes.io/unreachable", "effect": "NoSchedule"]) }
        if cordoned { spec["unschedulable"] = true }
        if !taints.isEmpty { spec["taints"] = .array(taints) }
        let transition = iso(86_400 * 3)
        let cond: (String, Bool, String) -> JSONValue = { type, ok, reason in
            ["type": .string(type), "status": .string(ok ? "True" : "False"), "reason": .string(reason), "lastTransitionTime": transition]
        }
        let ip = "10.2.\(Int(rng.next() % 200) + 10).\(Int(rng.next() % 200) + 10)"
        var conditions: [JSONValue] = [cond("MemoryPressure", false, "KubeletHasSufficientMemory"), cond("DiskPressure", false, "KubeletHasNoDiskPressure"), cond("PIDPressure", false, "KubeletHasSufficientPID")]
        if ready { conditions.append(cond("Ready", true, "KubeletReady")) }
        else {
            conditions.append(["type": "Ready", "status": "Unknown", "reason": "NodeStatusUnknown", "message": "Kubelet stopped posting node status.", "lastTransitionTime": iso(17 * 60)])
        }
        let status: JSONValue = [
            "capacity": ["cpu": .string(String(cpu)), "memory": .string("\(memGi * 1024 * 1024)Ki"), "pods": "110", "ephemeral-storage": "104845292Ki"],
            "allocatable": ["cpu": .string("\(cpu * 1000 - 90)m"), "memory": .string("\(memGi * 1024 * 1024 - 900_000)Ki"), "pods": "110"],
            "conditions": .array(conditions),
            "addresses": [["type": "InternalIP", "address": .string(ip)], ["type": "Hostname", "address": .string(name)]],
            "nodeInfo": ["kubeletVersion": .string(kubelet), "osImage": .string(osImage), "kernelVersion": "6.1.115", "containerRuntimeVersion": "containerd://1.7.23",
                         "operatingSystem": "linux", "architecture": "amd64"],
        ]
        add(.node, ["metadata": meta(name, labels: labels, age: age), "spec": .object(spec), "status": status])
    }

    // MARK: Workloads

    struct Workload {
        var name: String
        var ns: String
        var replicas: Int
        var image: String
        var cpuRequest = "250m"
        var memRequest = "256Mi"
        var memLimit = "512Mi"
        var port = 8080
        var states: [DemoPodState] = []   // overrides for the first N pods; the rest are running
        var kind: ResourceKind = .deployment
        var age: TimeInterval = 86_400 * 21
    }

    func podSpec(_ w: Workload) -> JSONValue {
        let container: JSONValue = [
            "name": .string(w.name), "image": .string(w.image), "ports": [["containerPort": .int(w.port), "protocol": "TCP"]],
            "resources": ["requests": ["cpu": .string(w.cpuRequest), "memory": .string(w.memRequest)], "limits": ["memory": .string(w.memLimit)]],
        ]
        return ["containers": [container], "serviceAccountName": .string(w.name)]
    }

    mutating func addWorkload(_ w: Workload) {
        let labels = ["app": w.name, "app.kubernetes.io/name": w.name]
        let selector: JSONValue = ["matchLabels": ["app": .string(w.name)]]
        let template: JSONValue = ["metadata": ["labels": .object(labels.mapValues { .string($0) })], "spec": podSpec(w)]
        let wlMeta = meta(w.name, ns: w.ns, labels: labels, annotations: w.kind == .deployment ? ["deployment.kubernetes.io/revision": "14"] : [:], age: w.age)
        let wlUID = wlMeta["uid"]?.stringValue ?? ""

        // Build pods first so status can reflect them.
        let hash = rng.token(9)
        var rsOwner: (kind: String, name: String, uid: String) = (w.kind.kind, w.name, wlUID)
        let rsName = "\(w.name)-\(hash)"
        var rsUID = ""
        if w.kind == .deployment {
            var rsLabels = labels; rsLabels["pod-template-hash"] = hash
            let rsMeta = meta(rsName, ns: w.ns, labels: rsLabels, annotations: ["deployment.kubernetes.io/revision": "14"], age: w.age / 2, owner: (w.kind.kind, w.name, wlUID))
            rsUID = rsMeta["uid"]?.stringValue ?? ""
            rsOwner = ("ReplicaSet", rsName, rsUID)
        }
        var ready = 0
        var available = 0
        for i in 0..<w.replicas {
            let state = i < w.states.count ? w.states[i] : .running
            let podName: String
            switch w.kind {
            case .statefulSet: podName = "\(w.name)-\(i)"
            case .daemonSet, .deployment: podName = "\(rsName)-\(rng.token(5))"
            default: podName = "\(w.name)-\(rng.token(5))"
            }
            if case .running = state { ready += 1; available += 1 }
            let node = nodeNames.isEmpty ? "node-1" : nodeNames[(i + Int(rng.next() % 3)) % nodeNames.count]
            addPod(name: podName, workload: w, labels: labels, state: state, node: node, owner: rsOwner)
        }
        if w.kind == .deployment {
            let rsStatus: JSONValue = ["replicas": .int(w.replicas), "readyReplicas": .int(ready), "availableReplicas": .int(available)]
            add(.replicaSet, ["metadata": meta(rsName, ns: w.ns, labels: labels, annotations: ["deployment.kubernetes.io/revision": "14"], age: w.age / 2, owner: (w.kind.kind, w.name, wlUID)),
                              "spec": ["replicas": .int(w.replicas), "selector": selector, "template": template], "status": rsStatus])
        }
        let availCond: JSONValue = ["type": "Available", "status": .string(available > 0 ? "True" : "False"), "reason": .string(available >= w.replicas ? "MinimumReplicasAvailable" : "MinimumReplicasUnavailable"), "lastTransitionTime": iso(3600)]
        switch w.kind {
        case .deployment:
            add(.deployment, ["metadata": wlMeta,
                              "spec": ["replicas": .int(w.replicas), "selector": selector, "template": template, "strategy": ["type": "RollingUpdate", "rollingUpdate": ["maxSurge": "25%", "maxUnavailable": "25%"]]],
                              "status": ["replicas": .int(w.replicas), "readyReplicas": .int(ready), "availableReplicas": .int(available), "updatedReplicas": .int(w.replicas),
                                         "unavailableReplicas": .int(w.replicas - available), "conditions": [availCond]]])
        case .statefulSet:
            add(.statefulSet, ["metadata": wlMeta, "spec": ["replicas": .int(w.replicas), "selector": selector, "template": template, "serviceName": .string(w.name)],
                               "status": ["replicas": .int(w.replicas), "readyReplicas": .int(ready), "availableReplicas": .int(available)]])
        case .daemonSet:
            add(.daemonSet, ["metadata": wlMeta, "spec": ["selector": selector, "template": template],
                             "status": ["desiredNumberScheduled": .int(w.replicas), "currentNumberScheduled": .int(w.replicas), "numberReady": .int(ready), "numberAvailable": .int(available), "updatedNumberScheduled": .int(w.replicas)]])
        default: break
        }
    }

    mutating func addPod(name: String, workload w: Workload, labels: [String: String], state: DemoPodState, node: String, owner: (kind: String, name: String, uid: String)?) {
        var podLabels = labels
        podLabels["pod-template-hash"] = name.split(separator: "-").dropLast().last.map(String.init) ?? ""
        var spec = podSpec(w)
        if case .pending = state {} else { spec["nodeName"] = .string(node) }
        let age: TimeInterval
        if case .pending = state { age = 17 * 60 } else if case .crashLoopOOM = state { age = 86_400 * 2 } else { age = 3600 * Double(2 + Int(rng.next() % 300)) }
        var status: [String: JSONValue] = [:]
        let imageID = "docker-pullable://\(w.image)@sha256:\(rng.token(32))"
        func containerStatus(ready: Bool, restarts: Int, stateJSON: JSONValue, last: JSONValue? = nil) -> JSONValue {
            var c: [String: JSONValue] = ["name": .string(w.name), "ready": .bool(ready), "restartCount": .int(restarts), "image": .string(w.image), "imageID": .string(imageID),
                                          "containerID": .string("containerd://\(name.hashValue.magnitude)"), "started": .bool(ready), "state": stateJSON]
            if let last { c["lastState"] = last }
            return .object(c)
        }
        let readyConds: [JSONValue] = [["type": "Ready", "status": "True"], ["type": "ContainersReady", "status": "True"], ["type": "PodScheduled", "status": "True"]]
        switch state {
        case .running:
            status = ["phase": "Running", "podIP": .string("10.2.\(Int(rng.next() % 250)).\(Int(rng.next() % 250))"), "hostIP": "10.2.22.10", "qosClass": "Burstable", "startTime": iso(age),
                      "conditions": .array(readyConds),
                      "containerStatuses": [containerStatus(ready: true, restarts: Int(rng.next() % 3) == 0 ? 1 : 0, stateJSON: ["running": ["startedAt": iso(age)]])]]
        case .crashLoopOOM:
            let term: JSONValue = ["terminated": ["exitCode": 137, "reason": "OOMKilled", "startedAt": iso(150), "finishedAt": iso(70)]]
            status = ["phase": "Running", "podIP": "10.2.41.17", "hostIP": "10.2.22.10", "qosClass": "Burstable", "startTime": iso(age),
                      "conditions": [["type": "Ready", "status": "False", "reason": "ContainersNotReady"], ["type": "ContainersReady", "status": "False", "reason": "ContainersNotReady"], ["type": "PodScheduled", "status": "True"]],
                      "containerStatuses": [containerStatus(ready: false, restarts: 14,
                                                            stateJSON: ["waiting": ["reason": "CrashLoopBackOff", "message": .string("back-off 5m0s restarting failed container=\(w.name) pod=\(name)")]], last: term)]]
        case .pending(let reason):
            status = ["phase": "Pending", "qosClass": "Burstable",
                      "conditions": [["type": "PodScheduled", "status": "False", "reason": "Unschedulable", "message": .string(reason), "lastTransitionTime": iso(age)]]]
        case .imagePull:
            status = ["phase": "Pending", "podIP": "10.42.0.31", "hostIP": "192.168.1.21", "startTime": iso(age),
                      "conditions": [["type": "Ready", "status": "False", "reason": "ContainersNotReady"], ["type": "PodScheduled", "status": "True"]],
                      "containerStatuses": [containerStatus(ready: false, restarts: 0, stateJSON: ["waiting": ["reason": "ImagePullBackOff", "message": .string("Back-off pulling image \"\(w.image)\"")]])]]
        case .completed:
            status = ["phase": "Succeeded", "startTime": iso(age), "conditions": [["type": "Ready", "status": "False", "reason": "PodCompleted"]],
                      "containerStatuses": [containerStatus(ready: false, restarts: 0, stateJSON: ["terminated": ["exitCode": 0, "reason": "Completed", "startedAt": iso(age), "finishedAt": iso(age - 40)]])]]
        case .failedJob:
            status = ["phase": "Failed", "startTime": iso(age), "conditions": [["type": "Ready", "status": "False", "reason": "PodFailed"]],
                      "containerStatuses": [containerStatus(ready: false, restarts: 0, stateJSON: ["terminated": ["exitCode": 1, "reason": "Error", "startedAt": iso(age), "finishedAt": iso(age - 120)]])]]
        }
        add(.pod, ["metadata": meta(name, ns: w.ns, labels: podLabels, age: age, owner: owner), "spec": spec, "status": .object(status)])
    }

    // MARK: Misc objects

    mutating func addNamespace(_ name: String) {
        add(.namespace, ["metadata": meta(name, labels: ["kubernetes.io/metadata.name": name], age: 86_400 * 90), "status": ["phase": "Active"]])
    }

    mutating func addService(_ name: String, ns: String, port: Int, targetPort: Int? = nil, type: String = "ClusterIP", lb: String? = nil) {
        var status: JSONValue = [:]
        if let lb { status = ["loadBalancer": ["ingress": [["hostname": .string(lb)]]]] }
        add(.service, ["metadata": meta(name, ns: ns, labels: ["app": name], age: 86_400 * 60),
                       "spec": ["type": .string(type), "clusterIP": .string("172.20.\(Int(rng.next() % 200)).\(Int(rng.next() % 200))"), "selector": ["app": .string(name)],
                                "ports": [["name": "http", "port": .int(port), "targetPort": .int(targetPort ?? port), "protocol": "TCP"]]],
                       "status": status])
        add(.endpoints, ["metadata": meta(name, ns: ns, age: 86_400 * 60),
                         "subsets": [["addresses": [["ip": "10.2.41.\(Int(rng.next() % 250))"], ["ip": "10.2.52.\(Int(rng.next() % 250))"]], "ports": [["name": "http", "port": .int(targetPort ?? port), "protocol": "TCP"]]]]])
    }

    mutating func addConfigMap(_ name: String, ns: String, data: [String: String]) {
        add(.configMap, ["metadata": meta(name, ns: ns, age: 86_400 * 30), "data": .object(data.mapValues { .string($0) })])
    }

    mutating func addSecret(_ name: String, ns: String, type: String = "Opaque", keys: [String]) {
        var data: [String: JSONValue] = [:]
        for k in keys { data[k] = .string(Data("demo-\(k)-value".utf8).base64EncodedString()) }
        add(.secret, ["metadata": meta(name, ns: ns, age: 86_400 * 30), "type": .string(type), "data": .object(data)])
    }

    mutating func addEvent(ns: String, object: (kind: String, name: String), type: String, reason: String, message: String, count: Int, ago: TimeInterval) {
        add(.event, ["metadata": meta("\(object.name).\(rng.token(10))", ns: ns, age: ago),
                     "involvedObject": ["kind": .string(object.kind), "name": .string(object.name), "namespace": .string(ns)],
                     "reason": .string(reason), "message": .string(message), "type": .string(type), "count": .int(count),
                     "firstTimestamp": iso(ago + 600), "lastTimestamp": iso(ago), "source": ["component": "kubelet"]])
    }

    mutating func addPVC(_ name: String, ns: String, size: String, phase: String = "Bound", sc: String = "gp3") {
        add(.persistentVolumeClaim, ["metadata": meta(name, ns: ns, age: 86_400 * 50),
                                     "spec": ["accessModes": ["ReadWriteOnce"], "storageClassName": .string(sc), "resources": ["requests": ["storage": .string(size)]], "volumeName": phase == "Bound" ? .string("pvc-\(rng.token(12))") : .null],
                                     "status": ["phase": .string(phase), "capacity": phase == "Bound" ? ["storage": .string(size)] : .null]])
    }

    mutating func addJob(_ name: String, ns: String, failed: Bool, ago: TimeInterval) {
        let conds: JSONValue = failed
            ? [["type": "Failed", "status": "True", "reason": "BackoffLimitExceeded", "message": "Job has reached the specified backoff limit", "lastTransitionTime": iso(ago)]]
            : [["type": "Complete", "status": "True", "lastTransitionTime": iso(ago)]]
        let tmpl: JSONValue = ["spec": ["containers": [["name": "job", "image": "registry.example.com/reports:2.4.1"]], "restartPolicy": "Never"]]
        add(.job, ["metadata": meta(name, ns: ns, age: ago + 300), "spec": ["completions": 1, "parallelism": 1, "backoffLimit": 3, "template": tmpl],
                   "status": ["startTime": iso(ago + 300), "completionTime": failed ? .null : iso(ago), "succeeded": failed ? 0 : 1, "failed": failed ? 4 : 0, "conditions": conds]])
        let w = Workload(name: name, ns: ns, replicas: 0, image: "registry.example.com/reports:2.4.1")
        addPod(name: "\(name)-\(rng.token(5))", workload: w, labels: ["job-name": name], state: failed ? .failedJob : .completed, node: nodeNames.first ?? "node-1", owner: nil)
    }

    mutating func addCronJob(_ name: String, ns: String, schedule: String, suspended: Bool = false) {
        let tmpl: JSONValue = ["spec": ["template": ["spec": ["containers": [["name": .string(name), "image": "registry.example.com/reports:2.4.1"]], "restartPolicy": "Never"]]]]
        add(.cronJob, ["metadata": meta(name, ns: ns, age: 86_400 * 100), "spec": ["schedule": .string(schedule), "suspend": .bool(suspended), "concurrencyPolicy": "Forbid", "jobTemplate": tmpl],
                       "status": ["lastScheduleTime": iso(3600 * 5), "lastSuccessfulTime": iso(3600 * 29)]])
    }

    mutating func addIngress(_ name: String, ns: String, host: String, service: String, port: Int) {
        add(.ingress, ["metadata": meta(name, ns: ns, age: 86_400 * 60), "spec": ["ingressClassName": "nginx", "tls": [["hosts": [.string(host)], "secretName": .string("\(name)-tls")]],
                       "rules": [["host": .string(host), "http": ["paths": [["path": "/", "pathType": "Prefix", "backend": ["service": ["name": .string(service), "port": ["number": .int(port)]]]]]]]]],
                       "status": ["loadBalancer": ["ingress": [["hostname": "a1b2c3.elb.eu-west-1.amazonaws.com"]]]]])
    }

    mutating func addStaticObjects(namespaces: [String]) {
        add(.storageClass, ["metadata": meta("gp3", annotations: ["storageclass.kubernetes.io/is-default-class": "true"], age: 86_400 * 90), "provisioner": "ebs.csi.aws.com",
                            "reclaimPolicy": "Delete", "volumeBindingMode": "WaitForFirstConsumer", "allowVolumeExpansion": true])
        add(.persistentVolume, ["metadata": meta("pvc-\(rng.token(12))", age: 86_400 * 50), "spec": ["capacity": ["storage": "100Gi"], "accessModes": ["ReadWriteOnce"], "persistentVolumeReclaimPolicy": "Delete", "storageClassName": "gp3"], "status": ["phase": "Bound"]])
        add(.clusterRole, ["metadata": meta("view", age: 86_400 * 90), "rules": [["apiGroups": [""], "resources": ["pods", "services", "configmaps"], "verbs": ["get", "list", "watch"]]]])
        add(.clusterRole, ["metadata": meta("cluster-admin", age: 86_400 * 90), "rules": [["apiGroups": ["*"], "resources": ["*"], "verbs": ["*"]]]])
        add(.clusterRoleBinding, ["metadata": meta("wheelhouse-view", age: 86_400 * 10), "roleRef": ["apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "view"],
                                  "subjects": [["kind": "ServiceAccount", "name": "wheelhouse", "namespace": "kube-system"]]])
        for ns in namespaces.prefix(3) {
            add(.serviceAccount, ["metadata": meta("default", ns: ns, age: 86_400 * 90)])
            add(.role, ["metadata": meta("pod-reader", ns: ns, age: 86_400 * 40), "rules": [["apiGroups": [""], "resources": ["pods", "pods/log"], "verbs": ["get", "list"]]]])
            add(.roleBinding, ["metadata": meta("pod-reader-binding", ns: ns, age: 86_400 * 40), "roleRef": ["apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "pod-reader"],
                               "subjects": [["kind": "ServiceAccount", "name": "default", "namespace": .string(ns)]]])
        }
        add(.networkPolicy, ["metadata": meta("default-deny", ns: namespaces.first ?? "default", age: 86_400 * 40), "spec": ["podSelector": [:], "policyTypes": ["Ingress"]]])
        add(.podDisruptionBudget, ["metadata": meta("payments-api", ns: "payments", age: 86_400 * 40), "spec": ["minAvailable": 2, "selector": ["matchLabels": ["app": "payments-api"]]],
                                   "status": ["disruptionsAllowed": 0, "currentHealthy": 2, "desiredHealthy": 2, "expectedPods": 3]])
    }
}
