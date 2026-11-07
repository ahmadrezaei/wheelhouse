import Testing
import Foundation
@testable import WheelhouseKit

/// Every tool, with a cluster set to Never, to Ask (not granted) and out of a Beacon client's scope.
@Suite("ToolboxPolicyFilter")
struct ToolboxPolicyFilterTests {
    // dev and staging are allowed by default, prod asks, secret-lab is set to Never.
    private let dev = testCluster("dev", env: .development)
    private let staging = testCluster("stg", env: .staging)
    private let prod = testCluster("prod", env: .production)
    private let never = testCluster("never", env: .development)

    private var firstMateSettings: StaticToolboxSettings { StaticToolboxSettings(firstMate: ["never": .never]) }

    private func firstMate(grants: ConversationGrants? = nil) -> (ClusterToolbox, FakeToolboxSource) {
        let source = FakeToolboxSource([dev, staging, prod, never])
        return (ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c1"), settings: firstMateSettings, grants: grants)), source)
    }

    private func beacon(scope: BeaconScope) -> (ClusterToolbox, FakeToolboxSource) {
        let source = FakeToolboxSource([dev, staging, prod, never])
        let settings = StaticToolboxSettings(beacon: ["claude-code": scope])
        return (ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .beacon(client: "claude-code"), settings: settings)), source)
    }

    // MARK: First Mate: Never

    @Test(arguments: ReadTool.allCases.filter { $0.isPerCluster && $0.isOffered(to: .firstMate(conversation: "c")) })
    func neverClusterLooksMissingForEveryPerClusterTool(tool: ReadTool) async {
        let (toolbox, source) = firstMate()
        let out = await toolbox.call(tool, input: sampleInput(tool, cluster: "never"))
        #expect(out.isError)
        #expect(out.json["error"]?.stringValue == "cluster_not_found")
        #expect(out.permissionRequired == nil)
        #expect(!source.touchedClusters.contains("never"))
        // Same answer as a cluster that does not exist: nothing tells the model the cluster is there.
        let missing = await toolbox.call(tool, input: sampleInput(tool, cluster: "does-not-exist"))
        #expect(missing.json["error"] == out.json["error"])
        #expect(missing.json["message"]?.stringValue?.replacingOccurrences(of: "does-not-exist", with: "X")
                == out.json["message"]?.stringValue?.replacingOccurrences(of: "never", with: "X"))
    }

    @Test func neverClusterIsAbsentFromListClusters() async {
        let (toolbox, _) = firstMate()
        let out = await toolbox.call(.listClusters, input: [:])
        let ids = out.json["clusters"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        #expect(!ids.contains("never"))
        #expect(Set(ids) == ["dev", "stg", "prod"])
        #expect(out.json["count"]?.intValue == 3)
    }

    @Test func neverClusterContributesNothingToSearch() async {
        let (toolbox, source) = firstMate()
        let out = await toolbox.call(.search, input: ["query": "web"])
        let clusters = Set(out.json["items"]?.arrayValue?.compactMap { $0["cluster"]?.stringValue } ?? [])
        #expect(clusters == ["dev", "stg"])
        #expect(out.json["total"]?.intValue == 2 * 11)
        #expect(!source.touchedClusters.contains("never"))
    }

    // MARK: First Mate: Ask

    @Test(arguments: ReadTool.allCases.filter { $0.isPerCluster && $0.isOffered(to: .firstMate(conversation: "c")) })
    func askClusterRequiresPermissionForEveryPerClusterTool(tool: ReadTool) async {
        let (toolbox, source) = firstMate()
        let out = await toolbox.call(tool, input: sampleInput(tool, cluster: "prod"))
        #expect(out.isError)
        #expect(out.json["error"]?.stringValue == "permission_required")
        #expect(out.permissionRequired == "prod")
        #expect(!source.touchedClusters.contains("prod"))
    }

    @Test func askClusterAppearsInListClustersWithNameAndEnvironmentOnly() async throws {
        let (toolbox, _) = firstMate()
        let out = await toolbox.call(.listClusters, input: [:])
        let row = try #require(out.json["clusters"]?.arrayValue?.first { $0["id"]?.stringValue == "prod" })
        #expect(row["access"]?.stringValue == "ask")
        #expect(row["environment"]?.stringValue == "production")
        #expect(row["name"]?.stringValue == "prod-name")
        #expect(Set(row.objectValue?.keys.map { $0 } ?? []) == ["id", "name", "environment", "access"])
    }

    @Test func askClusterContributesNothingToSearchAndNothingToTheCounts() async {
        let (toolbox, source) = firstMate()
        let out = await toolbox.call(.search, input: ["query": "web", "limit": 1])
        // Only dev and stg are readable: total counts only their hits, and "omitted" is derived from the same set.
        let kindsSearched = 11
        #expect(out.json["total"]?.intValue == 2 * kindsSearched)
        #expect(out.json["omitted"]?.intValue == 2 * kindsSearched - 1)
        #expect(!source.touchedClusters.contains("prod"))
        #expect(!source.touchedClusters.contains("never"))
    }

    @Test func grantingProductionOpensItForThisConversationOnly() async {
        let grants = ConversationGrants(conversation: "c1")
        let (granted, _) = firstMate(grants: grants)
        grants.grant("prod")
        let ok = await granted.call(.listResources, input: sampleInput(.listResources, cluster: "prod"))
        #expect(!ok.isError)
        let list = await granted.call(.listClusters, input: [:])
        let row = list.json["clusters"]?.arrayValue?.first { $0["id"]?.stringValue == "prod" }
        #expect(row?["access"]?.stringValue == "allowed")
        #expect(row?["read_only"]?.boolValue == false)
        // A fresh conversation has no grant.
        let (other, _) = firstMate()
        let denied = await other.call(.listResources, input: sampleInput(.listResources, cluster: "prod"))
        #expect(denied.json["error"]?.stringValue == "permission_required")
        grants.revoke("prod")
        let revoked = await granted.call(.listResources, input: sampleInput(.listResources, cluster: "prod"))
        #expect(revoked.json["error"]?.stringValue == "permission_required")
    }

    @Test func grantsDoNotLeakAcrossConversations() async {
        // One shared grants object, two conversations: only the conversation it belongs to benefits.
        let shared = ConversationGrants(conversation: "c1")
        shared.grant("prod")
        let source = FakeToolboxSource([prod])
        let settings = StaticToolboxSettings()
        let mine = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c1"), settings: settings, grants: shared))
        let other = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c2"), settings: settings, grants: shared))
        let input = sampleInput(.listResources, cluster: "prod")
        #expect(await mine.call(.listResources, input: input).isError == false)
        #expect(await other.call(.listResources, input: input).json["error"]?.stringValue == "permission_required")
        let fresh = ToolboxPolicy(caller: .firstMate(conversation: "c2"))
        #expect(fresh.grants.conversation == "c2")
    }

    @Test func explicitAllowedOverridesTheProductionDefault() async {
        let source = FakeToolboxSource([prod])
        let settings = StaticToolboxSettings(firstMate: ["prod": .allowed])
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c"), settings: settings))
        let out = await toolbox.call(.listResources, input: sampleInput(.listResources, cluster: "prod"))
        #expect(!out.isError)
    }

    @Test func environmentDefaults() {
        #expect(ToolboxPolicy.defaultAccess(for: .development) == .allowed)
        #expect(ToolboxPolicy.defaultAccess(for: .personal) == .allowed)
        #expect(ToolboxPolicy.defaultAccess(for: .staging) == .allowed)
        #expect(ToolboxPolicy.defaultAccess(for: .production) == .ask)
    }

    // MARK: Beacon: out of scope

    private var scope: BeaconScope { BeaconScope(readClusters: ["dev", "prod"]) }

    @Test(arguments: ReadTool.allCases.filter { $0.isPerCluster && $0.isOffered(to: .beacon(client: "x")) })
    func outOfScopeClusterLooksMissingForEveryPerClusterTool(tool: ReadTool) async {
        let (toolbox, source) = beacon(scope: scope)
        for id in ["stg", "never"] {
            let out = await toolbox.call(tool, input: sampleInput(tool, cluster: id))
            #expect(out.json["error"]?.stringValue == "cluster_not_found")
            #expect(out.permissionRequired == nil)
        }
        #expect(source.touchedClusters.isEmpty)
        // In scope works, including Production the user ticked (Beacon has no Ask).
        let prodOut = await toolbox.call(tool, input: sampleInput(tool, cluster: "prod"))
        #expect(prodOut.json["error"]?.stringValue != "cluster_not_found")
        #expect(prodOut.json["error"]?.stringValue != "permission_required")
    }

    @Test func beaconListClustersAndSearchSeeOnlyTheScope() async {
        let (toolbox, source) = beacon(scope: scope)
        let list = await toolbox.call(.listClusters, input: [:])
        #expect(Set(list.json["clusters"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []) == ["dev", "prod"])
        #expect(list.json["count"]?.intValue == 2)
        let found = await toolbox.call(.search, input: ["query": "web", "limit": 1])
        #expect(found.json["total"]?.intValue == 2 * 11)
        #expect(Set(source.touchedClusters).isSubset(of: ["dev", "prod"]))
    }

    @Test func beaconWithNoScopeSeesNothing() async {
        let (toolbox, source) = beacon(scope: BeaconScope())
        let list = await toolbox.call(.listClusters, input: [:])
        #expect(list.json["count"]?.intValue == 0)
        let found = await toolbox.call(.search, input: ["query": "web"])
        #expect(found.json["total"]?.intValue == 0)
        #expect(source.touchedClusters.isEmpty)
    }

    // MARK: Proposal tools use the same gate

    @Test(arguments: ProposalTool.allCases)
    @MainActor func proposalToolsHonourNeverAndAsk(tool: ProposalTool) async {
        let source = FakeToolboxSource([dev, prod, never])
        let policy = ToolboxPolicy(caller: .firstMate(conversation: "c1"), settings: firstMateSettings)
        let tools = ProposalTools(source: source, policy: policy, coordinator: ProposalCoordinator())
        let input = sampleProposalInput(tool, cluster: "never")
        let hidden = await tools.call(tool, input: input)
        #expect(hidden.json["error"]?.stringValue == "cluster_not_found")
        let asking = await tools.call(tool, input: sampleProposalInput(tool, cluster: "prod"))
        #expect(asking.json["error"]?.stringValue == "permission_required")
        #expect(source.touchedClusters.isEmpty)
    }

    // MARK: Change requests are never offered for Production or read-only clusters (hard rule)

    @Test func changeRequestsNeverForProductionOrReadOnly() {
        let readOnly = testCluster("ro", readOnly: true)
        let everything = BeaconScope(readClusters: ["dev", "prod", "ro", "stg"], changeRequestClusters: ["dev", "prod", "ro"])
        let policy = ToolboxPolicy(caller: .beacon(client: "c"), settings: StaticToolboxSettings(beacon: ["c": everything]))
        #expect(policy.allowsChangeRequests(on: dev))
        #expect(!policy.allowsChangeRequests(on: prod))
        #expect(!policy.allowsChangeRequests(on: readOnly))
        #expect(!policy.allowsChangeRequests(on: staging))   // readable, but not opted in
        let firstMate = ToolboxPolicy(caller: .firstMate(conversation: "c"))
        #expect(!firstMate.allowsChangeRequests(on: dev))
    }
}

func sampleProposalInput(_ tool: ProposalTool, cluster: String) -> JSONValue {
    let c: JSONValue = .string(cluster)
    switch tool {
    case .proposePatch:
        return ["cluster": c, "kind": "deployment", "name": "web", "namespace": "apps", "patch_type": "merge", "patch": ["spec": ["replicas": 3]], "reason": "scale"]
    case .proposeManifest:
        return ["cluster": c, "yaml": "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n  namespace: apps\ndata:\n  a: b\n", "reason": "add"]
    case .proposeCommand:
        return ["cluster": c, "command": "kubectl get pods -n apps", "reason": "look"]
    case .proposeHelmUpgrade:
        return ["cluster": c, "release": "web", "namespace": "apps", "chart": "repo/web", "reason": "upgrade"]
    case .proposeGitopsAction:
        return ["cluster": c, "controller": "flux", "action": "reconcile", "kind": "Kustomization", "name": "apps", "namespace": "flux-system", "reason": "sync"]
    }
}
