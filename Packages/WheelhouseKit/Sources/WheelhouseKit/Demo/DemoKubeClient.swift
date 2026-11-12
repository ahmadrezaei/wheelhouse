import Foundation

/// In-memory mock cluster: realistic objects, metrics, Prometheus-like series, streaming logs and simulated watch updates.
/// Mutations (scale, restart, delete, patch…) really change the in-memory state, so demo flows are interactive.
public actor DemoKubeClient: KubeClientProtocol {
    public nonisolated let config: ClusterConfig
    private let profile: DemoClusters.Profile
    private var store: [String: [String: JSONValue]] = [:]  // kind.id → "ns/name" → object
    private var kindsByID: [String: ResourceKind] = [:]
    private var resourceVersion = 100_000
    private var watchers: [UUID: Watcher] = [:]
    private var tickCount = 0
    private let started = Date()

    private struct Watcher {
        var kindID: String
        var namespace: String?
        var label: String?
        var field: String?
        var deliver: @Sendable (String, JSONValue) -> Void
    }

    public init(config: ClusterConfig) {
        self.config = config
        let profile = DemoClusters.profile(for: config)
        self.profile = profile
        var kinds: [String: ResourceKind] = [:]
        for k in ResourceKind.builtIn + [.podDisruptionBudget, .horizontalPodAutoscaler] { kinds[k.id] = k }
        var s: [String: [String: JSONValue]] = [:]
        for (kindID, objs) in profile.objects {
            for o in objs {
                let ns = o.value(at: "metadata.namespace")?.stringValue ?? ""
                let name = o.value(at: "metadata.name")?.stringValue ?? ""
                s[kindID, default: [:]]["\(ns)/\(name)"] = o
                if kinds[kindID] == nil, let apiVersion = o["apiVersion"]?.stringValue, let kind = o["kind"]?.stringValue {
                    let parts = apiVersion.split(separator: "/").map(String.init)
                    let id = kindID.split(separator: "/").map(String.init)
                    if parts.count == 2, let plural = id.last {
                        kinds[kindID] = .custom(group: parts[0], version: parts[1], kind: kind, plural: plural, namespaced: !ns.isEmpty)
                    }
                }
            }
        }
        self.store = s
        self.kindsByID = kinds
    }

    // MARK: Plumbing

    private func simulateLatency(_ ms: Int = 120) async throws {
        try await Task.sleep(for: .milliseconds(ms))
        if !profile.reachable {
            try await Task.sleep(for: .milliseconds(600))
            throw KubeError.unreachable(cause: "Timed out connecting to \(config.host)")
        }
    }

    private func guardMutable() throws { if config.readOnly { throw KubeError.readOnly } }

    private func nextRV() -> String { resourceVersion += 1; return String(resourceVersion) }

    private func items(_ kind: ResourceKind, namespace: String?, options: ListOptions) -> [JSONValue] {
        let all = (store[kind.id] ?? [:]).values.filter { obj in
            guard kind.namespaced, let namespace else { return true }
            return obj.value(at: "metadata.namespace")?.stringValue == namespace
        }
        let filtered = all.filter { Self.matches($0, label: options.labelSelector, field: options.fieldSelector) }
        let sorted = filtered.sorted {
            let a = ($0.value(at: "metadata.namespace")?.stringValue ?? "", $0.value(at: "metadata.name")?.stringValue ?? "")
            let b = ($1.value(at: "metadata.namespace")?.stringValue ?? "", $1.value(at: "metadata.name")?.stringValue ?? "")
            return a < b
        }
        if let limit = options.limit { return Array(sorted.prefix(limit)) }
        return sorted
    }

    // MARK: Selectors

    static func matches(_ object: JSONValue, label: String?, field: String?) -> Bool {
        if let label, !label.isEmpty {
            let labels = object.value(at: "metadata.labels")?.objectValue?.compactMapValues(\.stringValue) ?? [:]
            for clause in splitClauses(label) where !labelClause(clause, labels) { return false }
        }
        if let field, !field.isEmpty {
            for clause in field.split(separator: ",") {
                let c = String(clause)
                if let r = c.range(of: "!=") {
                    if object.value(at: String(c[..<r.lowerBound]))?.stringValue == String(c[r.upperBound...]) { return false }
                } else if let r = c.range(of: "==") ?? c.range(of: "=") {
                    if object.value(at: String(c[..<r.lowerBound]))?.stringValue != String(c[r.upperBound...]) { return false }
                }
            }
        }
        return true
    }

    private static func splitClauses(_ s: String) -> [String] {
        var out: [String] = [], depth = 0, current = ""
        for ch in s {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == ",", depth == 0 { out.append(current); current = "" } else { current.append(ch) }
        }
        if !current.isEmpty { out.append(current) }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func labelClause(_ c: String, _ labels: [String: String]) -> Bool {
        if let r = c.range(of: " notin ") {
            let key = String(c[..<r.lowerBound]); let vals = list(String(c[r.upperBound...]))
            return !(labels[key].map(vals.contains) ?? false)
        }
        if let r = c.range(of: " in ") {
            let key = String(c[..<r.lowerBound]); let vals = list(String(c[r.upperBound...]))
            return labels[key].map(vals.contains) ?? false
        }
        if let r = c.range(of: "!=") { return labels[String(c[..<r.lowerBound])] != String(c[r.upperBound...]) }
        if let r = c.range(of: "==") ?? c.range(of: "=") { return labels[String(c[..<r.lowerBound])] == String(c[r.upperBound...]) }
        if c.hasPrefix("!") { return labels[String(c.dropFirst())] == nil }
        return labels[c] != nil
    }

    private static func list(_ s: String) -> [String] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "() ")).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Version / discovery

    static func gitVersion(for provider: String?) -> String {
        switch provider {
        case "k3s": "v1.30.6+k3s1"
        case "GKE": "v1.31.3-gke.1162000"
        default: "v1.31.4-eks-aeac579"
        }
    }

    public func version() async throws -> KubeVersion {
        try await simulateLatency(60)
        return KubeVersion(major: "1", minor: "31", gitVersion: Self.gitVersion(for: config.provider), platform: "linux/amd64", buildDate: "2024-11-12T00:00:00Z")
    }

    public func discovery() async throws -> DiscoveryInfo {
        try await simulateLatency()
        let verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
        var kinds = Array(kindsByID.values)
        kinds.append(.podMetrics); kinds.append(.nodeMetrics)
        return DiscoveryInfo(resources: kinds.map {
            APIResource(name: $0.plural, singularName: $0.kind.lowercased(), namespaced: $0.namespaced, kind: $0.kind, verbs: verbs, shortNames: nil, group: $0.group, version: $0.version)
        })
    }

    // MARK: Reads

    private func listJSON(_ kind: ResourceKind, namespace: String?, options: ListOptions) -> JSONValue {
        ["apiVersion": .string(kind.apiVersion), "kind": .string(kind.kind + "List"), "metadata": ["resourceVersion": .string(String(resourceVersion))],
         "items": .array(items(kind, namespace: namespace, options: options))]
    }

    public func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> {
        try await simulateLatency()
        do { return try listJSON(kind, namespace: namespace, options: options).decode(KubeList<T>.self) }
        catch { throw KubeError.decoding("\(error)") }
    }

    public func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T {
        try await simulateLatency(80)
        guard let obj = store[kind.id]?["\(kind.namespaced ? namespace ?? "" : "")/\(name)"] else {
            throw KubeError.notFound(message: "\(kind.plural) \"\(name)\" not found")
        }
        do { return try obj.decode(T.self) } catch { throw KubeError.decoding("\(error)") }
    }

    public func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue {
        try await simulateLatency()
        return listJSON(kind, namespace: namespace, options: options)
    }

    public func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue {
        try await simulateLatency(80)
        guard let obj = store[kind.id]?["\(kind.namespaced ? namespace ?? "" : "")/\(name)"] else {
            throw KubeError.notFound(message: "\(kind.plural) \"\(name)\" not found")
        }
        return obj
    }

    // MARK: Watch

    public nonisolated func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let task = Task {
                await self.addWatcher(id, kindID: kind.id, namespace: kind.namespaced ? namespace : nil,
                                      label: options.labelSelector, field: options.fieldSelector) { type, json in
                    guard let object = try? json.decode(T.self) else { return }
                    switch type {
                    case "ADDED": continuation.yield(.added(object))
                    case "MODIFIED": continuation.yield(.modified(object))
                    case "DELETED": continuation.yield(.deleted(object))
                    default: break
                    }
                }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    await self.tick(kindID: kind.id)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.removeWatcher(id) }
            }
        }
    }

    private func addWatcher(_ id: UUID, kindID: String, namespace: String?, label: String?, field: String?, deliver: @escaping @Sendable (String, JSONValue) -> Void) {
        watchers[id] = Watcher(kindID: kindID, namespace: namespace, label: label, field: field, deliver: deliver)
    }

    private func removeWatcher(_ id: UUID) { watchers[id] = nil }

    private func emit(_ kindID: String, _ type: String, _ object: JSONValue) {
        let ns = object.value(at: "metadata.namespace")?.stringValue
        for w in watchers.values where w.kindID == kindID && (w.namespace == nil || w.namespace == ns) && Self.matches(object, label: w.label, field: w.field) {
            w.deliver(type, object)
        }
    }

    /// Simulated cluster activity: the crash-looping pod keeps restarting and warning events accumulate.
    private func tick(kindID: String) {
        tickCount += 1
        if kindID == ResourceKind.pod.id {
            guard tickCount % 3 == 0 else { return }
            for (key, var pod) in store[kindID] ?? [:] where pod.value(at: "status.containerStatuses")?[0]?["state"]?["waiting"]?["reason"]?.stringValue == "CrashLoopBackOff" {
                let restarts = (pod.value(at: "status.containerStatuses")?[0]?["restartCount"]?.intValue ?? 0) + 1
                var statuses = pod.value(at: "status.containerStatuses")?.arrayValue ?? []
                if var first = statuses.first {
                    first["restartCount"] = .int(restarts)
                    first["lastState"] = ["terminated": ["exitCode": 137, "reason": "OOMKilled", "startedAt": .string(Date().addingTimeInterval(-80).formatted(.iso8601)), "finishedAt": .string(Date().formatted(.iso8601))]]
                    statuses[0] = first
                    pod.setValue(.array(statuses), at: "status.containerStatuses")
                }
                pod.setValue(.string(nextRV()), at: "metadata.resourceVersion")
                store[kindID]?[key] = pod
                emit(kindID, "MODIFIED", pod)
            }
        }
    }

    // MARK: Mutations

    private func stamp(_ object: JSONValue, kind: ResourceKind, namespace: String?) -> JSONValue {
        var o = object
        if o["apiVersion"] == nil { o["apiVersion"] = .string(kind.apiVersion) }
        if o["kind"] == nil { o["kind"] = .string(kind.kind) }
        if o.value(at: "metadata.uid") == nil { o.setValue(.string(UUID().uuidString.lowercased()), at: "metadata.uid") }
        if o.value(at: "metadata.creationTimestamp") == nil { o.setValue(.string(Date().formatted(.iso8601)), at: "metadata.creationTimestamp") }
        if kind.namespaced, o.value(at: "metadata.namespace") == nil, let namespace { o.setValue(.string(namespace), at: "metadata.namespace") }
        o.setValue(.string(nextRV()), at: "metadata.resourceVersion")
        return o
    }

    private func key(_ kind: ResourceKind, name: String, namespace: String?) -> String { "\(kind.namespaced ? namespace ?? "" : "")/\(name)" }

    public func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue {
        try guardMutable()
        try await simulateLatency()
        if subresource == "eviction", let name, let namespace {
            guard store[kind.id]?[key(kind, name: name, namespace: namespace)] != nil else { throw KubeError.notFound(message: "pods \"\(name)\" not found") }
            if !options.dryRun { removeObject(kind, name: name, namespace: namespace); reconcile(namespace: namespace, matching: name) }
            return ["kind": "Status", "status": "Success"]
        }
        if kind == .selfSubjectAccessReview { return ["status": ["allowed": true]] }
        if kind == .selfSubjectRulesReview {
            return ["status": ["resourceRules": [["verbs": ["*"], "apiGroups": ["*"], "resources": ["*"]]], "nonResourceRules": [], "incomplete": false]]
        }
        guard let objName = body.value(at: "metadata.name")?.stringValue else { throw KubeError.invalid(message: "metadata.name: Required value", causes: []) }
        let k = key(kind, name: objName, namespace: body.value(at: "metadata.namespace")?.stringValue ?? namespace)
        if store[kind.id]?[k] != nil { throw KubeError.conflict(message: "\(kind.plural) \"\(objName)\" already exists") }
        let object = stamp(body, kind: kind, namespace: namespace)
        if !options.dryRun {
            store[kind.id, default: [:]][k] = object
            kindsByID[kind.id] = kindsByID[kind.id] ?? kind
            emit(kind.id, "ADDED", object)
        }
        return object
    }

    public func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue {
        try guardMutable()
        try await simulateLatency()
        let k = key(kind, name: name, namespace: namespace)
        guard store[kind.id]?[k] != nil else { throw KubeError.notFound(message: "\(kind.plural) \"\(name)\" not found") }
        let object = stamp(body, kind: kind, namespace: namespace)
        if !options.dryRun {
            store[kind.id]?[k] = object
            emit(kind.id, "MODIFIED", object)
            afterChange(kind, key: k)
        }
        return object
    }

    public func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue {
        try guardMutable()
        try await simulateLatency()
        let k = key(kind, name: name, namespace: namespace)
        guard let existing = store[kind.id]?[k] else { throw KubeError.notFound(message: "\(kind.plural) \"\(name)\" not found") }
        var updated: JSONValue
        switch patch {
        case .merge(let p), .strategicMerge(let p), .apply(let p): updated = Self.merge(existing, p)
        case .json(let ops): updated = try Self.applyJSONPatch(existing, ops)
        }
        updated.setValue(.string(nextRV()), at: "metadata.resourceVersion")
        if !options.dryRun {
            store[kind.id]?[k] = updated
            emit(kind.id, "MODIFIED", updated)
            if case .strategicMerge(let p) = patch, p.value(at: "spec.template.metadata.annotations.kubectl.kubernetes.io/restartedAt") != nil || p["spec"]?["template"]?["metadata"]?["annotations"]?["kubectl.kubernetes.io/restartedAt"] != nil {
                restartPods(of: updated)
            }
            afterChange(kind, key: k)
        }
        return subresource == "scale" ? ["spec": ["replicas": updated.value(at: "spec.replicas") ?? 0]] : updated
    }

    public func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws {
        try guardMutable()
        try await simulateLatency()
        let k = key(kind, name: name, namespace: namespace)
        guard store[kind.id]?[k] != nil else { throw KubeError.notFound(message: "\(kind.plural) \"\(name)\" not found") }
        guard !options.dryRun else { return }
        let wasPod = kind == .pod
        removeObject(kind, name: name, namespace: namespace)
        if wasPod, let namespace { reconcile(namespace: namespace, matching: name) }
    }

    private func removeObject(_ kind: ResourceKind, name: String, namespace: String?) {
        let k = key(kind, name: name, namespace: namespace)
        if let removed = store[kind.id]?.removeValue(forKey: k) { emit(kind.id, "DELETED", removed) }
    }

    // MARK: Controller simulation

    private func afterChange(_ kind: ResourceKind, key k: String) {
        guard kind == .deployment || kind == .statefulSet, let obj = store[kind.id]?[k] else { return }
        let ns = obj.value(at: "metadata.namespace")?.stringValue ?? ""
        let app = obj.value(at: "metadata.name")?.stringValue ?? ""
        syncReplicas(kind: kind, namespace: ns, app: app)
    }

    /// After a pod disappears, the owning Deployment replaces it.
    private func reconcile(namespace: String, matching podName: String) {
        for (k, d) in store[ResourceKind.deployment.id] ?? [:] where d.value(at: "metadata.namespace")?.stringValue == namespace {
            let app = d.value(at: "metadata.name")?.stringValue ?? ""
            if podName.hasPrefix(app + "-") { syncReplicas(kind: .deployment, namespace: namespace, app: app); _ = k }
        }
    }

    private func podsOf(app: String, namespace: String) -> [(String, JSONValue)] {
        (store[ResourceKind.pod.id] ?? [:]).filter { $0.value.value(at: "metadata.namespace")?.stringValue == namespace && $0.value.value(at: "metadata.labels.app")?.stringValue == app }
            .sorted { $0.key < $1.key }
    }

    private func isRunning(_ pod: JSONValue) -> Bool { pod.value(at: "status.phase")?.stringValue == "Running" && pod.value(at: "status.containerStatuses")?[0]?["ready"]?.boolValue == true }

    private func syncReplicas(kind: ResourceKind, namespace: String, app: String) {
        guard var workload = store[kind.id]?["\(namespace)/\(app)"] else { return }
        let desired = workload.value(at: "spec.replicas")?.intValue ?? 1
        var pods = podsOf(app: app, namespace: namespace)
        // Remove surplus pods, unhealthy first.
        while pods.count > desired {
            let victim = pods.first { !isRunning($0.1) } ?? pods[pods.count - 1]
            removeObject(.pod, name: victim.1.value(at: "metadata.name")?.stringValue ?? "", namespace: namespace)
            pods.removeAll { $0.0 == victim.0 }
        }
        // Add missing pods cloned from a healthy sibling.
        if pods.count < desired, let template = pods.first(where: { isRunning($0.1) })?.1 ?? Optional(pods.first?.1) ?? nil {
            let base = (template.value(at: "metadata.name")?.stringValue ?? app).split(separator: "-").dropLast().joined(separator: "-")
            while pods.count < desired {
                var clone = healthyClone(of: template, name: "\(base)-\(Self.randomSuffix())")
                clone = stamp(clone, kind: .pod, namespace: namespace)
                let k = "\(namespace)/\(clone.value(at: "metadata.name")?.stringValue ?? "")"
                store[ResourceKind.pod.id, default: [:]][k] = clone
                emit(ResourceKind.pod.id, "ADDED", clone)
                pods.append((k, clone))
            }
        }
        let ready = pods.filter { isRunning($0.1) }.count
        workload.setValue(.int(pods.count), at: "status.replicas")
        workload.setValue(.int(ready), at: "status.readyReplicas")
        workload.setValue(.int(ready), at: "status.availableReplicas")
        workload.setValue(.int(max(0, desired - ready)), at: "status.unavailableReplicas")
        store[kind.id]?["\(namespace)/\(app)"] = workload
        emit(kind.id, "MODIFIED", workload)
    }

    private func healthyClone(of pod: JSONValue, name: String) -> JSONValue {
        var p = pod
        p.setValue(.string(name), at: "metadata.name")
        p.setValue(nil, at: "metadata.uid")
        p.setValue(.string(Date().formatted(.iso8601)), at: "metadata.creationTimestamp")
        let image = pod.value(at: "spec.containers")?[0]?["image"] ?? .null
        let cname = pod.value(at: "spec.containers")?[0]?["name"] ?? .null
        p.setValue(["phase": "Running", "podIP": .string("10.2.\(Int.random(in: 1...250)).\(Int.random(in: 1...250))"), "hostIP": "10.2.22.10", "qosClass": "Burstable",
                    "startTime": .string(Date().formatted(.iso8601)),
                    "conditions": [["type": "Ready", "status": "True"], ["type": "ContainersReady", "status": "True"], ["type": "PodScheduled", "status": "True"]],
                    "containerStatuses": [["name": cname, "ready": true, "restartCount": 0, "image": image, "started": true, "state": ["running": ["startedAt": .string(Date().formatted(.iso8601))]]]]], at: "status")
        if p.value(at: "spec.nodeName") == nil { p.setValue("node-1", at: "spec.nodeName") }
        return p
    }

    private func restartPods(of workload: JSONValue) {
        guard let ns = workload.value(at: "metadata.namespace")?.stringValue, let app = workload.value(at: "metadata.name")?.stringValue else { return }
        for (_, pod) in podsOf(app: app, namespace: ns) {
            let base = (pod.value(at: "metadata.name")?.stringValue ?? app).split(separator: "-").dropLast().joined(separator: "-")
            removeObject(.pod, name: pod.value(at: "metadata.name")?.stringValue ?? "", namespace: ns)
            var fresh = stamp(healthyClone(of: pod, name: "\(base)-\(Self.randomSuffix())"), kind: .pod, namespace: ns)
            fresh.setValue(.string(nextRV()), at: "metadata.resourceVersion")
            store[ResourceKind.pod.id, default: [:]]["\(ns)/\(fresh.value(at: "metadata.name")?.stringValue ?? "")"] = fresh
            emit(ResourceKind.pod.id, "ADDED", fresh)
        }
    }

    private static func randomSuffix() -> String {
        String((0..<5).map { _ in Array("bcdfghjklmnpqrstvwxz2456789").randomElement() ?? "x" })
    }

    // MARK: Patch helpers

    static func merge(_ base: JSONValue, _ patch: JSONValue) -> JSONValue {
        guard case .object(let p) = patch, case .object(var b) = base else { return patch }
        for (k, v) in p {
            if v.isNull { b[k] = nil } else { b[k] = merge(b[k] ?? .null, v) }
        }
        return .object(b)
    }

    static func applyJSONPatch(_ base: JSONValue, _ ops: [JSONValue]) throws -> JSONValue {
        var result = base
        for op in ops {
            guard let kind = op["op"]?.stringValue, let path = op["path"]?.stringValue else { throw KubeError.invalid(message: "Malformed JSON patch", causes: []) }
            let dotted = path.split(separator: "/").map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }.joined(separator: ".")
            switch kind {
            case "add", "replace": result.setValue(op["value"], at: dotted)
            case "remove": result.setValue(nil, at: dotted)
            default: throw KubeError.unsupported("Demo mode supports add / replace / remove JSON patch operations only")
            }
        }
        return result
    }

    // MARK: Logs

    public nonisolated func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let info = try await self.podLogInfo(namespace: namespace, pod: pod)
                    if options.previous, !info.crashing {
                        throw KubeError.server(Status(status: "Failure", message: "previous terminated container \"\(info.app)\" in pod \"\(pod)\" not found", reason: "BadRequest", code: 400))
                    }
                    var gen = DemoLogGenerator(app: info.app, crashing: info.crashing)
                    let count = min(options.tailLines ?? 300, 300)
                    for i in 0..<count {
                        let age = Double(count - i) * 1.7
                        continuation.yield(gen.line(at: Date().addingTimeInterval(-age), timestamps: options.timestamps, final: options.previous && i == count - 1))
                    }
                    guard options.follow, !options.previous else { continuation.finish(); return }
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(700))
                        continuation.yield(gen.line(at: Date(), timestamps: options.timestamps, final: false))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func podLogInfo(namespace: String, pod: String) async throws -> (app: String, crashing: Bool) {
        try await simulateLatency(80)
        guard let obj = store[ResourceKind.pod.id]?["\(namespace)/\(pod)"] else { throw KubeError.notFound(message: "pods \"\(pod)\" not found") }
        let crashing = obj.value(at: "status.containerStatuses")?[0]?["state"]?["waiting"]?["reason"]?.stringValue == "CrashLoopBackOff"
        return (obj.value(at: "metadata.labels.app")?.stringValue ?? pod, crashing)
    }

    // MARK: Metrics

    private func wave(_ seed: String, period: Double = 240) -> Double {
        let phase = Double(seed.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }) / 10_000
        return sin(Date().timeIntervalSince(started) / period * 2 * .pi + phase)
    }

    public func podMetrics(namespace: String?) async throws -> [PodMetrics] {
        guard profile.hasMetricsServer else { throw KubeError.notFound(message: "the server could not find the requested resource (get pods.metrics.k8s.io)") }
        try await simulateLatency()
        let json: [JSONValue] = items(.pod, namespace: namespace, options: ListOptions()).compactMap { pod in
            guard pod.value(at: "status.phase")?.stringValue == "Running" else { return nil }
            let name = pod.value(at: "metadata.name")?.stringValue ?? ""
            let c = pod.value(at: "spec.containers")?[0]
            let cpuReq = c?["resources"]?["requests"]?["cpu"]?.stringValue.map { Quantity($0).cores } ?? 0.1
            let memReq = c?["resources"]?["requests"]?["memory"]?.stringValue.map { Quantity($0).bytes } ?? 128 * 1_048_576
            let memLimit = c?["resources"]?["limits"]?["memory"]?.stringValue.map { Quantity($0).bytes } ?? memReq * 2
            let crashing = pod.value(at: "status.containerStatuses")?[0]?["state"]?["waiting"] != nil
            let cpu = max(0.002, cpuReq * (0.55 + 0.3 * wave(name)))
            let mem = crashing ? memLimit * 0.99 : memReq * (0.8 + 0.15 * wave(name + "m", period: 600))
            return ["metadata": ["name": .string(name), "namespace": pod.value(at: "metadata.namespace") ?? .null], "timestamp": .string(Date().formatted(.iso8601)), "window": "30s",
                    "containers": [["name": c?["name"] ?? .null, "usage": ["cpu": .string("\(Int(cpu * 1000))m"), "memory": .string("\(Int(mem / 1024))Ki")]]]]
        }
        return try JSONValue.array(json).decode([PodMetrics].self)
    }

    public func nodeMetrics() async throws -> [NodeMetrics] {
        guard profile.hasMetricsServer else { throw KubeError.notFound(message: "the server could not find the requested resource (get nodes.metrics.k8s.io)") }
        try await simulateLatency()
        let nodes = items(.node, namespace: nil, options: ListOptions())
        let json: [JSONValue] = nodes.enumerated().compactMap { i, node in
            guard node.value(at: "status.conditions")?.arrayValue?.contains(where: { $0["type"]?.stringValue == "Ready" && $0["status"]?.stringValue == "True" }) == true else { return nil }
            let name = node.value(at: "metadata.name")?.stringValue ?? ""
            let fraction = i == 2 ? 0.88 + 0.03 * wave(name) : 0.42 + 0.14 * wave(name)
            let memFraction = 0.55 + 0.1 * wave(name + "m")
            return ["metadata": ["name": .string(name)], "timestamp": .string(Date().formatted(.iso8601)), "window": "30s",
                    "usage": ["cpu": .string("\(Int(profile.nodeCPU * fraction * 1000))m"), "memory": .string("\(Int(profile.nodeMemGi * memFraction * 1024 * 1024))Ki")]]
        }
        return try JSONValue.array(json).decode([NodeMetrics].self)
    }

    public func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data {
        try await simulateLatency()
        guard profile.hasPrometheus, store[ResourceKind.service.id]?["\(namespace)/\(service)"] != nil else {
            throw KubeError.notFound(message: "services \"\(service):\(port)\" not found")
        }
        if path.hasSuffix("status/buildinfo") {
            return try JSONValue.object(["status": "success", "data": ["version": "2.55.1"]]).data()
        }
        let q = query["query"] ?? ""
        let end = query["end"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let isRange = path.hasSuffix("query_range")
        let start = query["start"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? end.addingTimeInterval(-3600)
        let step = max(query["step"].flatMap(Double.init) ?? 60, 1)
        let series = promSeries(for: q)
        var result: [JSONValue] = []
        for (labels, base, amp) in series {
            var metric: [String: JSONValue] = [:]
            for (k, v) in labels { metric[k] = .string(v) }
            if isRange {
                var values: [JSONValue] = []
                var t = start
                while t <= end {
                    let v = base + amp * sin(t.timeIntervalSince1970 / 5400 * 2 * .pi + Double(q.utf8.count)) + amp * 0.2 * sin(t.timeIntervalSince1970 / 311)
                    values.append([.double(t.timeIntervalSince1970), .string(String(max(0, v)))])
                    t = t.addingTimeInterval(step)
                }
                result.append(["metric": .object(metric), "values": .array(values)])
            } else {
                result.append(["metric": .object(metric), "value": [.double(end.timeIntervalSince1970), .string(String(base))]])
            }
        }
        return try JSONValue.object(["status": "success", "data": ["resultType": .string(isRange ? "matrix" : "vector"), "result": .array(result)]]).data()
    }

    public func listMetadata(kind: ResourceKind, namespace: String?, labelSelector: String?, limit: Int?) async throws -> ObjectMetadataList {
        try await simulateLatency()
        let all = items(kind, namespace: namespace, options: ListOptions(labelSelector: labelSelector))
        let page = limit.map { Array(all.prefix($0)) } ?? all
        let metas = try page.compactMap { object -> ObjectMeta? in
            guard let m = object["metadata"] else { return nil }
            return try m.decode(ObjectMeta.self)
        }
        return ObjectMetadataList(kind: kind, items: metas, resourceVersion: String(resourceVersion),
                                  continueToken: page.count < all.count ? "demo-\(page.count)" : nil)
    }

    /// Demo data has no continuation: one page of the demo cluster's own sample objects.
    public func listCompassPage(kind: ResourceKind, namespace: String?, continueToken: String?, limit: Int) async throws -> CompassMetadataPage {
        guard continueToken == nil else { return CompassMetadataPage(items: []) }
        let list = try await listMetadata(kind: kind, namespace: namespace, labelSelector: nil, limit: limit)
        return CompassMetadataPage(items: list.items.map {
            CompassMetadataItem(name: $0.name, namespace: $0.namespace, labels: $0.labels, ownerKind: $0.ownerReferences.first?.kind, ownerName: $0.ownerReferences.first?.name)
        })
    }

    public func proxyRequest(method: String, namespace: String, service: String, port: String, path: String, query: [String: String],
                             headers: [String: String], body: Data?) async throws -> ProxyResponse {
        guard method.uppercased() == "GET" else { throw KubeError.unsupported("Demo clusters only answer proxied GET requests.") }
        let data = try await proxyGET(namespace: namespace, service: service, port: port, path: path, query: query)
        return ProxyResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }

    /// (labels, base, amplitude) tuples for a PromQL query, scaled to this cluster's capacity.
    private func promSeries(for query: String) -> [([String: String], Double, Double)] {
        let cores = profile.nodeCPU * Double(profile.nodeCount)
        let mem = profile.nodeMemGi * Double(profile.nodeCount) * 1_073_741_824
        let isMem = query.contains("memory")
        let capacity = isMem ? mem : cores
        if query.contains("node_cpu_seconds_total") {
            return items(.node, namespace: nil, options: ListOptions()).enumerated().map { i, n in
                (["instance": n.value(at: "metadata.name")?.stringValue ?? "node"], i == 2 ? 0.86 : 0.45, 0.08)
            }
        }
        if query.contains("allocatable") { return [([:], capacity * 0.98, 0)] }
        if query.contains("requests") { return [([:], capacity * 0.55, capacity * 0.01)] }
        if query.contains("restarts") { return [(["namespace": "payments", "pod": "payments-api"], 3, 1)] }
        return [([:], capacity * (isMem ? 0.62 : 0.46), capacity * (isMem ? 0.04 : 0.08))]
    }

    // MARK: Sockets

    public nonisolated func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket {
        throw KubeError.unsupported("Shell sessions are not available in Demo mode.")
    }

    public nonisolated func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket {
        throw KubeError.unsupported("Port forwarding is not available in Demo mode.")
    }
}

/// Produces plausible log lines per app in logfmt / nginx / plain formats.
struct DemoLogGenerator {
    var app: String
    var crashing: Bool
    private var rng: DemoRNG
    private var n = 0

    init(app: String, crashing: Bool) {
        self.app = app
        self.crashing = crashing
        rng = DemoRNG(seed: app)
    }

    mutating func line(at time: Date, timestamps: Bool, final: Bool) -> String {
        n += 1
        let ts = time.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
        let body: String
        if final {
            body = "java.lang.OutOfMemoryError: Java heap space\n\tat com.example.payments.BatchProcessor.load(BatchProcessor.java:212)".replacingOccurrences(of: "\n\t", with: " | ")
        } else {
            let id = rng.token(8)
            let ms = Int(rng.next() % 90) + 4
            let roll = rng.next() % 40
            switch app {
            case let a where a.hasPrefix("payments"):
                if roll == 0 { body = "level=error msg=\"charge failed\" err=\"upstream timeout\" charge=ch_\(id) attempt=2" }
                else if roll < 4 { body = "level=warn msg=\"slow query\" duration=\(ms * 10)ms table=charges" }
                else { body = "level=info msg=\"charge processed\" charge=ch_\(id) amount=\(Int(rng.next() % 9000) + 100) currency=EUR duration=\(ms)ms" }
            case let a where a.hasPrefix("checkout") || a.hasPrefix("ingress"):
                body = "10.2.\(Int(rng.next() % 250)).\(Int(rng.next() % 250)) - - \"\(roll == 0 ? "POST /api/cart/checkout HTTP/1.1\" 502" : "GET /api/cart/\(id) HTTP/1.1\" 200") \(Int(rng.next() % 4000) + 200) \(ms)ms"
            default:
                body = "\(roll == 0 ? "ERROR" : roll < 5 ? "WARN " : "INFO ") [\(app)] request \(id) handled in \(ms)ms"
            }
        }
        return timestamps ? "\(ts) \(body)" : body
    }
}
