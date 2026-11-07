import Foundation

/// The read-only tool set shared by First Mate and Beacon (ARCHITECTURE-MAC section 9.3).
///
/// - **No mutating API.** The type exposes `call` and `tools` and nothing else. It holds no ``KubeClientProtocol``: clusters are
///   reached only through ``ReadOnlyKubeAccess``, a struct of read closures, so a mutation cannot be written against it.
/// - **Policy is enforced here**, not by callers: every tool, including `list_clusters` and `search`, filters by
///   ``ToolboxPolicy`` before it ranks, counts or truncates. A hidden cluster answers exactly like one that does not exist.
/// - **One redaction point.** Every result passes ``Redactor`` and then ``ToolResultLimiter`` before it is returned.
public struct ClusterToolbox: Sendable {
    public let policy: ToolboxPolicy
    private let source: any ToolboxClusterSource
    private let redactor: Redactor
    private let extensions: [any ToolboxExtensionProviding]

    /// `extensions` supply the tool families that belong to later milestones (Helm, GitOps, Survey, schema). A tool nobody
    /// supplies answers `unavailable`.
    public init(source: any ToolboxClusterSource, policy: ToolboxPolicy, redactor: Redactor = Redactor(), extensions: [any ToolboxExtensionProviding] = []) {
        self.source = source
        self.policy = policy
        self.redactor = redactor
        self.extensions = extensions
    }

    /// The tool definitions this caller is offered (read tools only; proposal tools live in ``ProposalTools``).
    public var tools: [ToolDefinition] { ToolCatalog.definitions(for: policy.caller, includeProposals: false) }

    public func call(named name: String, input: JSONValue) async -> ToolOutput {
        guard let tool = ReadTool(rawValue: name), tool.isOffered(to: policy.caller) else {
            return .error("unknown_tool", "No read tool named \(name).")
        }
        return await call(tool, input: input)
    }

    public func call(_ tool: ReadTool, input: JSONValue) async -> ToolOutput {
        guard tool.isOffered(to: policy.caller) else { return .error("unknown_tool", "No read tool named \(tool.rawValue).") }
        let output: ToolOutput
        switch tool {
        case .listClusters: output = await listClusters()
        case .search: output = await search(input)
        default:
            switch await resolveCluster(input) {
            case .failure(let failure): return failure
            case .success(let (cluster, access)): output = await perCluster(tool, cluster: cluster, access: access, input: input)
            }
        }
        return finish(output)
    }

    // MARK: Finish (the single exit)

    private func finish(_ output: ToolOutput) -> ToolOutput {
        var out = output
        out.json = ToolResultLimiter.limit(redactor.scrubOutput(output.json))
        return out
    }

    // MARK: Cluster resolution and the permission gate

    private func resolveCluster(_ input: JSONValue) async -> Result<(ClusterConfig, ReadOnlyKubeAccess), ToolOutput> {
        guard let reference = input["cluster"]?.stringValue, !reference.isEmpty else {
            return .failure(.error("invalid_input", "cluster is required."))
        }
        // Only clusters the caller may see take part in matching, so a hidden cluster is indistinguishable from a missing one.
        let visible = policy.visible(await source.clusters())
        guard let cluster = visible.first(where: { $0.id == reference }) ?? visible.first(where: { $0.name.lowercased() == reference.lowercased() }) else {
            return .failure(.error("cluster_not_found", "No cluster \"\(reference)\" is available to you."))
        }
        switch policy.visibility(of: cluster) {
        case .hidden: return .failure(.error("cluster_not_found", "No cluster \"\(reference)\" is available to you."))
        case .askPending: return .failure(.permissionRequired(cluster.id))
        case .full: break
        }
        guard let access = await source.access(for: cluster.id) else {
            return .failure(.error("cluster_unavailable", "Cannot connect to \(cluster.name)."))
        }
        return .success((cluster, access))
    }

    private func perCluster(_ tool: ReadTool, cluster: ClusterConfig, access: ReadOnlyKubeAccess, input: JSONValue) async -> ToolOutput {
        do {
            switch tool {
            case .listResources: return try await listResources(cluster, access, input)
            case .getResource: return try await getResource(cluster, access, input)
            case .getLogs: return try await getLogs(cluster, access, input)
            case .getEvents: return try await getEvents(cluster, access, input)
            case .getMetrics: return try await getMetrics(cluster, access, input)
            case .describeOwnerChain: return try await ownerChain(cluster, access, input)
            case .rbacCanI: return try await canI(cluster, access, input)
            case .helmRelease, .helmListReleases, .helmGetRelease, .gitopsStatus, .surveyFindings, .explainField:
                guard let provider = extensions.first(where: { $0.tools.contains(tool) }) else {
                    return .unavailable(tool.rawValue, "This tool arrives with \(tool.family?.milestone ?? "a later milestone").")
                }
                return ToolOutput(json: try await provider.call(tool, cluster: cluster, access: access, input: input, redactor: redactor))
            case .listClusters, .search:
                return .error("unknown_tool")
            }
        } catch let error as KubeError {
            return .error("kube_error", error.summary)
        } catch is CancellationError {
            return .error("cancelled")
        } catch let failure as InputFailure {
            return .error("invalid_input", failure.message)
        } catch {
            return .error("error", error.localizedDescription)
        }
    }

    private struct InputFailure: Error { let message: String }

    // MARK: Input helpers

    private func required(_ input: JSONValue, _ key: String) throws -> String {
        guard let value = input[key]?.stringValue, !value.isEmpty else { throw InputFailure(message: "\(key) is required.") }
        return value
    }

    private func namespace(_ input: JSONValue) throws -> String? {
        guard let value = input["namespace"]?.stringValue, !value.isEmpty else { return nil }
        guard KubeNames.isDNSLabel(value) else { throw InputFailure(message: "namespace must be a DNS label.") }
        return value
    }

    private func objectName(_ input: JSONValue, _ key: String) throws -> String {
        let value = try required(input, key)
        guard KubeNames.isObjectName(value) else { throw InputFailure(message: "\(key) is not a valid Kubernetes name.") }
        return value
    }

    private func kind(_ input: JSONValue, _ access: ReadOnlyKubeAccess) async throws -> ResourceKind {
        let text = try required(input, "kind")
        if let known = KindResolver.resolve(text) { return known }
        if let found = KindResolver.resolve(text, discovery: try? await access.discovery()) { return found }
        throw InputFailure(message: "Unknown kind \"\(text)\".")
    }

    private func boundedInt(_ input: JSONValue, _ key: String, default value: Int, max: Int) -> Int {
        Swift.min(Swift.max(input[key]?.intValue ?? value, 1), max)
    }

    // MARK: list_clusters

    private func listClusters() async -> ToolOutput {
        let visible = policy.visible(await source.clusters()).sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        var rows: [JSONValue] = []
        for cluster in visible {
            var row: [String: JSONValue] = ["id": .string(cluster.id), "name": .string(cluster.name), "environment": .string(cluster.environment.rawValue)]
            if policy.visibility(of: cluster) == .askPending {
                // Name and environment only: nothing about the contents or the state of a cluster the user has not allowed.
                row["access"] = "ask"
            } else {
                row["access"] = "allowed"
                row["read_only"] = .bool(cluster.readOnly)
                row["reachability"] = .string(await source.reachability(of: cluster.id))
            }
            rows.append(.object(row))
        }
        return ToolOutput(json: ["count": .int(rows.count), "clusters": .array(rows)])
    }

    // MARK: list_resources

    private func listResources(_ cluster: ClusterConfig, _ access: ReadOnlyKubeAccess, _ input: JSONValue) async throws -> ToolOutput {
        let kind = try await kind(input, access)
        let namespace = try namespace(input)
        let limit = boundedInt(input, "limit", default: 100, max: ToolResultLimiter.maxListItems)
        let options = ListOptions(labelSelector: input["label_selector"]?.stringValue, fieldSelector: input["field_selector"]?.stringValue, limit: limit)
        let raw = try await access.listRaw(kind, namespace, options)
        let items = raw["items"]?.arrayValue ?? []
        let rows: [JSONValue] = items.prefix(limit).map { row(for: $0, kind: kind) }
        var out: [String: JSONValue] = [
            "cluster": .string(cluster.id), "kind": .string(kind.kind), "count": .int(rows.count), "items": .array(rows),
        ]
        if let namespace { out["namespace"] = .string(namespace) }
        if raw.value(at: "metadata.continue")?.stringValue?.isEmpty == false || items.count > limit {
            out["truncated"] = true
            out["more_available"] = true
        }
        return ToolOutput(json: .object(out))
    }

    private func row(for item: JSONValue, kind: ResourceKind) -> JSONValue {
        let name = item.value(at: "metadata.name")?.stringValue ?? ""
        let namespace = item.value(at: "metadata.namespace")?.stringValue
        var row: [String: JSONValue] = ["name": .string(name)]
        if let namespace { row["namespace"] = .string(namespace) }
        if kind == .secret {
            // Names, type and key count only. The values never reach this process's output.
            row["type"] = item["type"] ?? "Opaque"
            row["key_count"] = .int((item["data"]?.objectValue?.count ?? 0) + (item["binaryData"]?.objectValue?.count ?? 0))
            return .object(row)
        }
        var object = item
        if object["kind"] == nil { object["kind"] = .string(kind.kind) }
        if object["apiVersion"] == nil { object["apiVersion"] = .string(kind.apiVersion) }
        let summary = ResourceSummarizer.summarize(kind: kind, object: Unstructured(raw: object))
        if !summary.statusText.isEmpty { row["status"] = .string(summary.statusText) }
        if let ready = summary.ready, let desired = summary.desired { row["ready"] = .string("\(ready)/\(desired)") }
        if summary.restarts > 0 { row["restarts"] = .int(summary.restarts) }
        if let node = summary.nodeName { row["node"] = .string(node) }
        if !summary.details.isEmpty { row["details"] = .array(summary.details.prefix(4).map { .string($0) }) }
        if let created = item.value(at: "metadata.creationTimestamp")?.stringValue { row["created"] = .string(created) }
        return .object(row)
    }

    // MARK: get_resource

    private func getResource(_ cluster: ClusterConfig, _ access: ReadOnlyKubeAccess, _ input: JSONValue) async throws -> ToolOutput {
        let kind = try await kind(input, access)
        let name = try objectName(input, "name")
        let namespace = try namespace(input)
        if kind.namespaced, namespace == nil { throw InputFailure(message: "namespace is required for \(kind.kind).") }
        let raw = try await access.getRaw(kind, name, kind.namespaced ? namespace : nil)
        // Redaction happens before anything else sees the object; a Secret leaves as {type, keys, sizes}.
        return ToolOutput(json: ["cluster": .string(cluster.id), "kind": .string(kind.kind), "object": redactor.resource(raw, kind: kind)])
    }

    // MARK: get_logs

    private func getLogs(_ cluster: ClusterConfig, _ access: ReadOnlyKubeAccess, _ input: JSONValue) async throws -> ToolOutput {
        guard let namespace = try namespace(input) else { throw InputFailure(message: "namespace is required.") }
        let pod = try objectName(input, "pod")
        var container: String?
        if let c = input["container"]?.stringValue, !c.isEmpty {
            guard KubeNames.isDNSLabel(c) else { throw InputFailure(message: "container must be a DNS label.") }
            container = c
        }
        let tail = boundedInt(input, "tail_lines", default: 200, max: ToolResultLimiter.maxLogLines)
        let options = LogOptions(container: container, follow: false, previous: input["previous"]?.boolValue ?? false, timestamps: true,
                                 tailLines: tail, sinceSeconds: input["since_seconds"]?.intValue)
        var lines: [String] = []
        for try await chunk in access.logs(namespace, pod, options) {
            lines.append(contentsOf: chunk.split(whereSeparator: \.isNewline).map(String.init))
            if lines.count >= ToolResultLimiter.maxLogLines * 4 { break }
        }
        // Redact everything fetched first, then take the tail: a cut that lands inside a PEM block must not leak its body.
        let kept = Array(redactor.redactLog(lines).suffix(tail))
        var out: [String: JSONValue] = [
            "cluster": .string(cluster.id), "namespace": .string(namespace), "pod": .string(pod),
            "line_count": .int(kept.count), "lines": .array(kept.map { .string($0) }),
        ]
        if let container { out["container"] = .string(container) }
        return ToolOutput(json: .object(out))
    }

    // MARK: get_events

    private func getEvents(_ cluster: ClusterConfig, _ access: ReadOnlyKubeAccess, _ input: JSONValue) async throws -> ToolOutput {
        let namespace = try namespace(input)
        var selectors: [String] = []
        if input["object_name"]?.stringValue?.isEmpty == false { selectors.append("involvedObject.name=\(try objectName(input, "object_name"))") }
        if let type = input["type"]?.stringValue, ["Normal", "Warning"].contains(type) { selectors.append("type=\(type)") }
        let limit = boundedInt(input, "limit", default: 100, max: 200)
        let raw = try await access.listRaw(.event, namespace, ListOptions(fieldSelector: selectors.isEmpty ? nil : selectors.joined(separator: ","), limit: 500))
        struct Row { var time: String; var json: JSONValue }
        let rows: [Row] = (raw["items"]?.arrayValue ?? []).map { e in
            let time = e["lastTimestamp"]?.stringValue ?? e["eventTime"]?.stringValue ?? e.value(at: "metadata.creationTimestamp")?.stringValue ?? ""
            let object = [e.value(at: "involvedObject.kind")?.stringValue, e.value(at: "involvedObject.name")?.stringValue].compactMap { $0 }.joined(separator: "/")
            var json: [String: JSONValue] = [
                "type": e["type"] ?? .null, "reason": e["reason"] ?? .null, "message": e["message"] ?? .null,
                "object": .string(object), "last_seen": .string(time),
            ]
            if let count = e["count"]?.intValue { json["count"] = .int(count) }
            if let ns = e.value(at: "metadata.namespace")?.stringValue { json["namespace"] = .string(ns) }
            return Row(time: time, json: .object(json))
        }
        let sorted = rows.sorted { $0.time > $1.time }
        return ToolOutput(json: ["cluster": .string(cluster.id), "total": .int(sorted.count), "events": .array(sorted.prefix(limit).map(\.json))])
    }

    // MARK: get_metrics

    private func getMetrics(_ cluster: ClusterConfig, _ access: ReadOnlyKubeAccess, _ input: JSONValue) async throws -> ToolOutput {
        let scope = try required(input, "scope")
        func round3(_ v: Double) -> JSONValue { .double((v * 1000).rounded() / 1000) }
        switch scope {
        case "nodes":
            let rows = try await access.nodeMetrics().sorted { $0.cpuCores > $1.cpuCores }.prefix(200).map { m -> JSONValue in
                ["name": .string(m.metadata.name), "cpu_cores": round3(m.cpuCores), "memory_mib": round3(m.memoryBytes / 1_048_576)]
            }
            return ToolOutput(json: ["cluster": .string(cluster.id), "scope": "nodes", "items": .array(Array(rows))])
        case "pods":
            let namespace = try namespace(input)
            let rows = try await access.podMetrics(namespace).sorted { $0.cpuCores > $1.cpuCores }.prefix(200).map { m -> JSONValue in
                ["name": .string(m.metadata.name), "namespace": m.metadata.namespace.map { .string($0) } ?? .null,
                 "cpu_cores": round3(m.cpuCores), "memory_mib": round3(m.memoryBytes / 1_048_576)]
            }
            return ToolOutput(json: ["cluster": .string(cluster.id), "scope": "pods", "items": .array(Array(rows))])
        default:
            throw InputFailure(message: "scope must be nodes or pods.")
        }
    }

    // MARK: describe_owner_chain

    private func ownerChain(_ cluster: ClusterConfig, _ access: ReadOnlyKubeAccess, _ input: JSONValue) async throws -> ToolOutput {
        var kind = try await kind(input, access)
        var name = try objectName(input, "name")
        var namespace = try namespace(input)
        if kind.namespaced, namespace == nil { throw InputFailure(message: "namespace is required for \(kind.kind).") }
        var discovery: DiscoveryInfo?
        var chain: [JSONValue] = []
        var seen = Set<String>()
        for _ in 0..<8 {
            guard kind != .secret else {
                chain.append(["kind": "Secret", "name": .string(name), "note": "not read"])
                break
            }
            let raw = try await access.getRaw(kind, name, kind.namespaced ? namespace : nil)
            let uid = raw.value(at: "metadata.uid")?.stringValue ?? "\(kind.id)/\(namespace ?? "")/\(name)"
            guard seen.insert(uid).inserted else { break }
            var entry: [String: JSONValue] = ["kind": .string(kind.kind), "name": .string(name)]
            if let namespace, kind.namespaced { entry["namespace"] = .string(namespace) }
            chain.append(.object(entry))
            let owners = raw.value(at: "metadata.ownerReferences")?.arrayValue ?? []
            guard let owner = owners.first(where: { $0["controller"]?.boolValue == true }) ?? owners.first,
                  let ownerKind = owner["kind"]?.stringValue, let ownerName = owner["name"]?.stringValue,
                  let apiVersion = owner["apiVersion"]?.stringValue else { break }
            // A name from the cluster ends up in a request path: only a plain object name may.
            guard KubeNames.isObjectName(ownerName) else {
                chain.append(["kind": .string(ownerKind), "note": "invalid owner name"])
                break
            }
            if discovery == nil { discovery = try? await access.discovery() }
            guard let resolved = KindResolver.resolve(apiVersion: apiVersion, kind: ownerKind, discovery: discovery) else {
                chain.append(["kind": .string(ownerKind), "name": .string(ownerName), "note": "kind not resolvable"])
                break
            }
            kind = resolved
            name = ownerName
            if !resolved.namespaced { namespace = nil }
        }
        return ToolOutput(json: ["cluster": .string(cluster.id), "chain": .array(chain)])
    }

    // MARK: rbac_can_i

    private func canI(_ cluster: ClusterConfig, _ access: ReadOnlyKubeAccess, _ input: JSONValue) async throws -> ToolOutput {
        let verb = try required(input, "verb")
        let resource = try required(input, "resource")
        guard verb.allSatisfy({ $0.isLetter || $0 == "-" }), resource.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "*" }) else {
            throw InputFailure(message: "verb or resource contains characters Kubernetes does not allow.")
        }
        let question = ReadOnlyKubeAccess.AccessQuestion(
            verb: verb, group: input["group"]?.stringValue ?? "", resource: resource, subresource: input["subresource"]?.stringValue,
            namespace: try namespace(input), name: input["name"]?.stringValue)
        let allowed = try await access.canI(question)
        return ToolOutput(json: ["cluster": .string(cluster.id), "verb": .string(verb), "resource": .string(resource), "allowed": .bool(allowed)])
    }

    // MARK: search

    private static let searchKinds: [ResourceKind] = [
        .deployment, .statefulSet, .daemonSet, .service, .ingress, .configMap, .job, .cronJob, .namespace, .node, .pod,
    ]

    private struct Hit: Sendable {
        var score: Int
        var cluster: String
        var clusterName: String
        var kind: String
        var name: String
        var namespace: String?
    }

    private func search(_ input: JSONValue) async -> ToolOutput {
        guard let query = input["query"]?.stringValue?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return .error("invalid_input", "query is required.")
        }
        let needle = query.lowercased()
        let limit = boundedInt(input, "limit", default: 25, max: 100)
        var chosen = Self.searchKinds
        if let names = input["kinds"]?.arrayValue?.compactMap(\.stringValue), !names.isEmpty {
            // Secrets are never searched, whatever the model asks for.
            chosen = names.compactMap { KindResolver.resolve($0) }.filter { $0 != .secret }
            if chosen.isEmpty { return .error("invalid_input", "None of the kinds are searchable.") }
        }
        // The policy filter comes first: hidden and ask-pending clusters never take part, so they cannot affect ranking,
        // totals or the omitted count.
        let kinds = chosen
        let readable = policy.readable(await source.clusters())
        var hits: [Hit] = []
        await withTaskGroup(of: [Hit].self) { group in
            for cluster in readable {
                group.addTask { await self.search(cluster: cluster, kinds: kinds, needle: needle) }
            }
            for await found in group { hits.append(contentsOf: found) }
        }
        hits.sort { ($0.score, $0.clusterName.lowercased(), $0.kind, $0.name, $0.namespace ?? "") < ($1.score, $1.clusterName.lowercased(), $1.kind, $1.name, $1.namespace ?? "") }
        let shown = hits.prefix(limit).map { hit -> JSONValue in
            var row: [String: JSONValue] = ["cluster": .string(hit.cluster), "kind": .string(hit.kind), "name": .string(hit.name)]
            if let ns = hit.namespace { row["namespace"] = .string(ns) }
            return .object(row)
        }
        var out: [String: JSONValue] = ["query": .string(query), "total": .int(hits.count), "items": .array(Array(shown))]
        if hits.count > limit { out["truncated"] = true; out["omitted"] = .int(hits.count - limit) }
        return ToolOutput(json: .object(out))
    }

    private func search(cluster: ClusterConfig, kinds: [ResourceKind], needle: String) async -> [Hit] {
        guard let access = await source.access(for: cluster.id) else { return [] }
        var hits: [Hit] = []
        for kind in kinds {
            guard let raw = try? await access.listRaw(kind, nil, ListOptions(limit: ToolResultLimiter.maxListItems)) else { continue }
            for item in raw["items"]?.arrayValue ?? [] {
                guard let name = item.value(at: "metadata.name")?.stringValue else { continue }
                let lowered = name.lowercased()
                let score: Int
                if lowered == needle { score = 0 } else if lowered.hasPrefix(needle) { score = 1 } else if lowered.contains(needle) { score = 2 } else { continue }
                hits.append(Hit(score: score, cluster: cluster.id, clusterName: cluster.name, kind: kind.kind, name: name,
                                namespace: item.value(at: "metadata.namespace")?.stringValue))
            }
        }
        return hits
    }
}
