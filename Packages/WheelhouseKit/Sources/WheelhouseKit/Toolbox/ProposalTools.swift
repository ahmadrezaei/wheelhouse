import Foundation

/// The proposal tools (`propose_patch`, `propose_manifest`, `propose_command`, `propose_helm_upgrade`, `propose_gitops_action`).
///
/// Each call validates its input, creates a ``ProposedChange`` and answers `{"status":"pending_user_review","proposal_id":"p-3"}`.
/// Nothing is executed: this type holds no client and no way to run a mutation. It reads discovery (through
/// ``ReadOnlyKubeAccess``) only to resolve custom resource kinds. First Mate only; Beacon's change requests are a separate path
/// (M12) with their own opt-in.
public struct ProposalTools: Sendable {
    public static let maxManifestDocuments = 20
    public static let maxManifestBytes = 256 * 1024
    public static let maxCommandLength = 2_000
    public static let maxReasonLength = 2_000

    private let source: any ToolboxClusterSource
    private let policy: ToolboxPolicy
    private let coordinator: ProposalCoordinator

    public init(source: any ToolboxClusterSource, policy: ToolboxPolicy, coordinator: ProposalCoordinator) {
        self.source = source
        self.policy = policy
        self.coordinator = coordinator
    }

    public var tools: [ToolDefinition] { ProposalTool.allCases.map(ToolCatalog.definition).sorted { $0.name < $1.name } }

    public func call(named name: String, input: JSONValue) async -> ToolOutput {
        guard let tool = ProposalTool(rawValue: name) else { return .error("unknown_tool", "No proposal tool named \(name).") }
        return await call(tool, input: input)
    }

    public func call(_ tool: ProposalTool, input: JSONValue) async -> ToolOutput {
        guard case .firstMate(let conversation) = policy.caller else {
            return .error("unknown_tool", "Proposal tools are offered to First Mate only.")
        }
        // The cluster must exist, be visible to this caller and be allowed (Production on Ask asks first).
        guard let reference = input["cluster"]?.stringValue, !reference.isEmpty else { return .error("invalid_input", "cluster is required.") }
        let visible = policy.visible(await source.clusters())
        guard let cluster = visible.first(where: { $0.id == reference }) ?? visible.first(where: { $0.name.lowercased() == reference.lowercased() }) else {
            return .error("cluster_not_found", "No cluster \"\(reference)\" is available to you.")
        }
        guard policy.visibility(of: cluster) == .full else { return .permissionRequired(cluster.id) }
        // A read-only cluster cannot be changed, so there is nothing to review (a command is only typed into a terminal and
        // stays guarded by Gangway, so it is still accepted).
        if tool != .proposeCommand, case .refuse(let reason) = MutationPolicy.decide(.mutation(dryRun: false), cluster: cluster, origin: policy.caller.origin) {
            return .error("cluster_read_only", reason)
        }
        let reason = String((input["reason"]?.stringValue ?? "").prefix(Self.maxReasonLength))
        do {
            let payload = try await payload(for: tool, input: input, cluster: cluster)
            let change = try await coordinator.submit(conversation: conversation, cluster: cluster.id, payload: payload, reason: reason)
            return ToolOutput(json: ["status": "pending_user_review", "proposal_id": .string(change.id)])
        } catch let failure as Invalid {
            return .error("invalid_input", failure.message)
        } catch ProposalCoordinator.SubmitError.tooManyOpen {
            return .error("too_many_proposals", "Too many proposals are waiting for review. Ask the user to review or decline some first.")
        } catch {
            return .error("error", error.localizedDescription)
        }
    }

    // MARK: Validation

    private struct Invalid: Error { let message: String }

    private func payload(for tool: ProposalTool, input: JSONValue, cluster: ClusterConfig) async throws -> ProposalPayload {
        switch tool {
        case .proposePatch: return try await patchPayload(input, cluster: cluster)
        case .proposeManifest: return try manifestPayload(input)
        case .proposeCommand: return try commandPayload(input)
        case .proposeHelmUpgrade: return try helmPayload(input)
        case .proposeGitopsAction: return try gitopsPayload(input)
        }
    }

    private func name(_ input: JSONValue, _ key: String) throws -> String {
        guard let value = input[key]?.stringValue, KubeNames.isObjectName(value) else { throw Invalid(message: "\(key) must be a valid Kubernetes name.") }
        return value
    }

    private func namespace(_ input: JSONValue, required: Bool) throws -> String? {
        guard let value = input["namespace"]?.stringValue, !value.isEmpty else {
            if required { throw Invalid(message: "namespace is required.") }
            return nil
        }
        guard KubeNames.isDNSLabel(value) else { throw Invalid(message: "namespace must be a DNS label.") }
        return value
    }

    private func patchPayload(_ input: JSONValue, cluster: ClusterConfig) async throws -> ProposalPayload {
        guard let kindText = input["kind"]?.stringValue, !kindText.isEmpty else { throw Invalid(message: "kind is required.") }
        var kind = KindResolver.resolve(kindText)
        if kind == nil, let access = await source.access(for: cluster.id) {
            kind = KindResolver.resolve(kindText, discovery: try? await access.discovery())
        }
        guard let kind else { throw Invalid(message: "Unknown kind \"\(kindText)\".") }
        let objectName = try name(input, "name")
        let ns = try namespace(input, required: kind.namespaced)
        guard let type = input["patch_type"]?.stringValue, ["json", "merge", "strategic", "apply"].contains(type) else {
            throw Invalid(message: "patch_type must be json, merge, strategic or apply.")
        }
        guard let body = input["patch"] else { throw Invalid(message: "patch is required.") }
        switch (type, body) {
        case ("json", .array(let ops)):
            guard !ops.isEmpty, ops.allSatisfy({ $0["op"]?.stringValue != nil && $0["path"]?.stringValue != nil }) else {
                throw Invalid(message: "Each JSON patch operation needs op and path.")
            }
        case ("json", _): throw Invalid(message: "A json patch is an array of operations.")
        case (_, .object(let fields)) where !fields.isEmpty: break
        default: throw Invalid(message: "A \(type) patch is a non-empty object.")
        }
        if body.jsonString().utf8.count > Self.maxManifestBytes { throw Invalid(message: "The patch is too large.") }
        return .patch(kind: kind, name: objectName, namespace: kind.namespaced ? ns : nil, patchType: type, body: body)
    }

    private func manifestPayload(_ input: JSONValue) throws -> ProposalPayload {
        guard let yaml = input["yaml"]?.stringValue, !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Invalid(message: "yaml is required.")
        }
        guard yaml.utf8.count <= Self.maxManifestBytes else { throw Invalid(message: "The manifest is too large.") }
        let documents = YAMLCodec.parseDocuments(yaml)
        guard !documents.isEmpty else { throw Invalid(message: "The YAML has no documents.") }
        guard documents.count <= Self.maxManifestDocuments else { throw Invalid(message: "At most \(Self.maxManifestDocuments) documents.") }
        var values: [JSONValue] = []
        for document in documents {
            if let diagnostic = document.diagnostic { throw Invalid(message: "Document \(document.index + 1), line \(diagnostic.line): \(diagnostic.message)") }
            guard let value = document.value, case .object = value else { throw Invalid(message: "Document \(document.index + 1) is not an object.") }
            guard value["apiVersion"]?.stringValue != nil, value["kind"]?.stringValue != nil else {
                throw Invalid(message: "Document \(document.index + 1) needs apiVersion and kind.")
            }
            guard let objectName = document.name, KubeNames.isObjectName(objectName) else {
                throw Invalid(message: "Document \(document.index + 1) needs a valid metadata.name.")
            }
            if let ns = document.namespace, !KubeNames.isDNSLabel(ns) { throw Invalid(message: "Document \(document.index + 1) has an invalid namespace.") }
            values.append(value)
        }
        return .manifest(yaml: yaml, documents: values)
    }

    /// Commands are inserted into the terminal, never run. A newline would press Return for the user, so it is refused;
    /// so is any control character (terminal escape sequences).
    private func commandPayload(_ input: JSONValue) throws -> ProposalPayload {
        guard let text = input["command"]?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { throw Invalid(message: "command is required.") }
        guard text.count <= Self.maxCommandLength else { throw Invalid(message: "The command is too long.") }
        guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format || $0 == "\u{2028}" || $0 == "\u{2029}" }) else {
            throw Invalid(message: "The command must be a single line without control characters.")
        }
        return .command(text)
    }

    private func helmPayload(_ input: JSONValue) throws -> ProposalPayload {
        let release = try name(input, "release")
        guard let ns = try namespace(input, required: true) else { throw Invalid(message: "namespace is required.") }
        guard let chart = input["chart"]?.stringValue, !chart.isEmpty, chart.count <= 512, !chart.contains(where: \.isNewline) else {
            throw Invalid(message: "chart is required.")
        }
        var values: String?
        if let yaml = input["values_yaml"]?.stringValue, !yaml.isEmpty {
            guard yaml.utf8.count <= Self.maxManifestBytes else { throw Invalid(message: "values_yaml is too large.") }
            if let failure = YAMLCodec.parseDocuments(yaml).compactMap(\.diagnostic).first { throw Invalid(message: "values_yaml, line \(failure.line): \(failure.message)") }
            values = yaml
        }
        return .helmUpgrade(release: release, namespace: ns, chart: chart, version: input["version"]?.stringValue, valuesYAML: values)
    }

    private func gitopsPayload(_ input: JSONValue) throws -> ProposalPayload {
        guard let controller = input["controller"]?.stringValue, ["flux", "argocd"].contains(controller) else { throw Invalid(message: "controller must be flux or argocd.") }
        guard let action = input["action"]?.stringValue, ["reconcile", "suspend", "resume", "sync", "refresh", "prune-sync"].contains(action) else {
            throw Invalid(message: "Unknown action.")
        }
        guard let kind = input["kind"]?.stringValue, !kind.isEmpty, kind.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw Invalid(message: "kind must be a Kubernetes kind.") }
        guard let ns = try namespace(input, required: true) else { throw Invalid(message: "namespace is required.") }
        return .gitopsAction(controller: controller, action: action, kind: kind, name: try name(input, "name"), namespace: ns)
    }
}
