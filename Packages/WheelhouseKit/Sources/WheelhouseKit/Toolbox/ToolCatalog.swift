import Foundation

/// The read-only tools (DESIGN-MAC section 6.12, ARCHITECTURE-MAC sections 9.2 and 10.2). Names are the wire names.
public enum ReadTool: String, CaseIterable, Sendable {
    case listClusters = "list_clusters"
    case listResources = "list_resources"
    case getResource = "get_resource"
    case getLogs = "get_logs"
    case getEvents = "get_events"
    case getMetrics = "get_metrics"
    case describeOwnerChain = "describe_owner_chain"
    /// First Mate's single Helm tool (Beacon uses the two below). Stubbed until M6a.
    case helmRelease = "helm_release"
    case helmListReleases = "helm_list_releases"
    case helmGetRelease = "helm_get_release"
    /// Stubbed until M9.
    case gitopsStatus = "gitops_status"
    /// Stubbed until M8a's findings are exposed to the toolbox.
    case surveyFindings = "survey_findings"
    case rbacCanI = "rbac_can_i"
    case search = "search"
    /// Stubbed until M7's schema engine.
    case explainField = "explain_field"

    /// True for tools that act on one cluster and so go through the permission gate for that cluster.
    public var isPerCluster: Bool { self != .listClusters && self != .search }

    /// First Mate and Beacon expose slightly different Helm tools.
    public func isOffered(to caller: ToolboxCaller) -> Bool {
        switch (self, caller) {
        case (.helmRelease, .beacon): false
        case (.helmListReleases, .firstMate), (.helmGetRelease, .firstMate): false
        default: true
        }
    }
}

/// The proposal tools. They only create review cards; nothing here changes a cluster.
public enum ProposalTool: String, CaseIterable, Sendable {
    case proposePatch = "propose_patch"
    case proposeManifest = "propose_manifest"
    case proposeCommand = "propose_command"
    case proposeHelmUpgrade = "propose_helm_upgrade"
    case proposeGitopsAction = "propose_gitops_action"
}

/// One tool as it goes into a model request or an MCP `tools/list`.
public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var isProposal: Bool
}

/// Stable, sorted tool list with JSON schemas. Every schema has `additionalProperties: false` and `required` fields, so the
/// serialised list is byte-stable across launches (it sits in the cached prompt prefix).
public enum ToolCatalog {
    public static func definitions(for caller: ToolboxCaller, includeProposals: Bool = true) -> [ToolDefinition] {
        var out = ReadTool.allCases.filter { $0.isOffered(to: caller) }.map(definition)
        if includeProposals, case .firstMate = caller { out += ProposalTool.allCases.map(definition) }
        return out.sorted { $0.name < $1.name }
    }

    public static func definition(_ tool: ReadTool) -> ToolDefinition {
        ToolDefinition(name: tool.rawValue, description: description(tool), inputSchema: schema(tool), isProposal: false)
    }

    public static func definition(_ tool: ProposalTool) -> ToolDefinition {
        ToolDefinition(name: tool.rawValue, description: description(tool), inputSchema: schema(tool), isProposal: true)
    }

    // MARK: Schema helpers

    private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.sorted().map { .string($0) }), "additionalProperties": false]
    }
    private static func string(_ description: String, enumValues: [String]? = nil) -> JSONValue {
        var v: JSONValue = ["type": "string", "description": .string(description)]
        if let enumValues { v["enum"] = .array(enumValues.map { .string($0) }) }
        return v
    }
    private static func integer(_ description: String, min: Int, max: Int) -> JSONValue {
        ["type": "integer", "description": .string(description), "minimum": .int(min), "maximum": .int(max)]
    }
    private static let cluster = string("Cluster id or name, from list_clusters.")
    private static let namespace = string("Namespace (DNS label).")

    static func schema(_ tool: ReadTool) -> JSONValue {
        switch tool {
        case .listClusters:
            object([:], required: [])
        case .listResources:
            object([
                "cluster": cluster, "kind": string("Kind or plural, for example Deployment, pods, or a custom resource kind."),
                "namespace": namespace, "label_selector": string("Kubernetes label selector."),
                "field_selector": string("Kubernetes field selector."),
                "limit": integer("Maximum items (at most 500).", min: 1, max: 500),
            ], required: ["cluster", "kind"])
        case .getResource:
            object(["cluster": cluster, "kind": string("Kind or plural."), "name": string("Object name."), "namespace": namespace],
                   required: ["cluster", "kind", "name"])
        case .getLogs:
            object([
                "cluster": cluster, "namespace": namespace, "pod": string("Pod name."), "container": string("Container name."),
                "previous": ["type": "boolean", "description": "Logs of the previous container instance."],
                "tail_lines": integer("Lines from the end (at most 2000, default 200).", min: 1, max: 2000),
                "since_seconds": integer("Only lines newer than this many seconds.", min: 1, max: 604_800),
            ], required: ["cluster", "namespace", "pod"])
        case .getEvents:
            object([
                "cluster": cluster, "namespace": namespace, "object_name": string("Only events about this object name."),
                "type": string("Event type.", enumValues: ["Normal", "Warning"]),
                "limit": integer("Maximum events (at most 200).", min: 1, max: 200),
            ], required: ["cluster"])
        case .getMetrics:
            object([
                "cluster": cluster, "scope": string("What to measure.", enumValues: ["nodes", "pods"]), "namespace": namespace,
            ], required: ["cluster", "scope"])
        case .describeOwnerChain:
            object(["cluster": cluster, "kind": string("Kind or plural."), "name": string("Object name."), "namespace": namespace],
                   required: ["cluster", "kind", "name"])
        case .helmRelease, .helmGetRelease:
            object(["cluster": cluster, "release": string("Release name."), "namespace": namespace], required: ["cluster", "release"])
        case .helmListReleases:
            object(["cluster": cluster, "namespace": namespace], required: ["cluster"])
        case .gitopsStatus:
            object(["cluster": cluster, "namespace": namespace], required: ["cluster"])
        case .surveyFindings:
            object(["cluster": cluster, "namespace": namespace], required: ["cluster"])
        case .rbacCanI:
            object([
                "cluster": cluster, "verb": string("Verb, for example get, list, patch, delete."), "resource": string("Plural resource name."),
                "group": string("API group; empty for the core group."), "namespace": namespace,
                "name": string("Object name."), "subresource": string("Subresource, for example scale."),
            ], required: ["cluster", "resource", "verb"])
        case .search:
            object([
                "query": string("Text to look for in object names."),
                "kinds": ["type": "array", "items": ["type": "string"], "description": "Restrict to these kinds."],
                "limit": integer("Maximum results (at most 100).", min: 1, max: 100),
            ], required: ["query"])
        case .explainField:
            object(["cluster": cluster, "kind": string("Kind."), "path": string("Field path, for example spec.template.spec.containers.")],
                   required: ["cluster", "kind", "path"])
        }
    }

    static func schema(_ tool: ProposalTool) -> JSONValue {
        let reason = string("One sentence for the reviewer: why this change.")
        switch tool {
        case .proposePatch:
            return object([
                "cluster": cluster, "kind": string("Kind or plural."), "name": string("Object name."), "namespace": namespace,
                "patch_type": string("Patch flavour.", enumValues: ["json", "merge", "strategic", "apply"]),
                "patch": ["anyOf": [["type": "object"], ["type": "array"]], "description": "The patch body: a JSON array for json, an object otherwise."],
                "reason": reason,
            ], required: ["cluster", "kind", "name", "patch", "patch_type", "reason"])
        case .proposeManifest:
            return object(["cluster": cluster, "yaml": string("One or more YAML documents."), "reason": reason],
                          required: ["cluster", "reason", "yaml"])
        case .proposeCommand:
            return object([
                "cluster": cluster, "command": string("A single-line kubectl, helm or flux command. It is inserted into the terminal, never run."),
                "reason": reason,
            ], required: ["cluster", "command", "reason"])
        case .proposeHelmUpgrade:
            return object([
                "cluster": cluster, "release": string("Release name."), "namespace": namespace, "chart": string("Chart reference."),
                "version": string("Chart version."), "values_yaml": string("Values overrides as YAML."), "reason": reason,
            ], required: ["chart", "cluster", "namespace", "reason", "release"])
        case .proposeGitopsAction:
            return object([
                "cluster": cluster, "controller": string("GitOps controller.", enumValues: ["argocd", "flux"]),
                "action": string("Action.", enumValues: ["prune-sync", "reconcile", "refresh", "resume", "suspend", "sync"]),
                "kind": string("Kind of the Flux object or Argo Application."), "name": string("Object name."), "namespace": namespace,
                "reason": reason,
            ], required: ["action", "cluster", "controller", "kind", "name", "namespace", "reason"])
        }
    }

    static func description(_ tool: ReadTool) -> String {
        switch tool {
        case .listClusters: "List the clusters you may use, with environment, read-only flag and reachability. Clusters that need the user's permission show access \"ask\" and no contents."
        case .listResources: "List objects of one kind in a cluster (at most 500). Secrets list names, types and key counts only."
        case .getResource: "Get one object. Secrets return type, key names and sizes, never values. Sensitive values are masked."
        case .getLogs: "Read recent log lines of a pod container (at most 2,000). Secrets and tokens are masked."
        case .getEvents: "List recent events in a cluster, optionally for one object."
        case .getMetrics: "Current CPU and memory use of nodes or pods from the metrics API."
        case .describeOwnerChain: "Follow ownerReferences from an object up to its top-level owner."
        case .helmRelease: "Describe a Helm release (values masked). Not available yet."
        case .helmListReleases: "List Helm releases. Not available yet."
        case .helmGetRelease: "Get one Helm release (values masked). Not available yet."
        case .gitopsStatus: "Summarise Flux or Argo CD state. Not available yet."
        case .surveyFindings: "List security findings from Survey. Not available yet."
        case .rbacCanI: "Ask whether the current identity may perform a verb on a resource (a SelfSubjectAccessReview)."
        case .search: "Search object names across all clusters you may read."
        case .explainField: "Explain a field of a resource schema. Not available yet."
        }
    }

    static func description(_ tool: ProposalTool) -> String {
        switch tool {
        case .proposePatch: "Propose a patch. This only creates a card for the user to review; nothing is changed until they approve it."
        case .proposeManifest: "Propose applying YAML manifests. This only creates a card for the user to review."
        case .proposeCommand: "Propose a command to insert into the user's terminal. It is never run for them."
        case .proposeHelmUpgrade: "Propose a Helm upgrade for the user to review."
        case .proposeGitopsAction: "Propose a GitOps action (reconcile, suspend, sync) for the user to review."
        }
    }
}
