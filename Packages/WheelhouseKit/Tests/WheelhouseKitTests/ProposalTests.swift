import Testing
import Foundation
@testable import WheelhouseKit
@testable import WheelhouseUI

@Suite("Proposals")
@MainActor
struct ProposalTests {
    private let dev = testCluster("dev")
    private let prod = testCluster("prod", env: .production)

    private func tools(grants: ConversationGrants? = nil, clusters: [ClusterConfig]? = nil) -> (ProposalTools, ProposalCoordinator, FakeToolboxSource) {
        let source = FakeToolboxSource(clusters ?? [dev, prod])
        let coordinator = ProposalCoordinator()
        let policy = ToolboxPolicy(caller: .firstMate(conversation: "c1"), grants: grants)
        return (ProposalTools(source: source, policy: policy, coordinator: coordinator), coordinator, source)
    }

    // MARK: Tools create cards only

    @Test func everyProposalToolReturnsPendingReviewAndCreatesACard() async {
        let (tools, coordinator, _) = tools()
        for tool in ProposalTool.allCases {
            let out = await tools.call(tool, input: sampleProposalInput(tool, cluster: "dev"))
            #expect(!out.isError, "\(tool): \(out.text)")
            #expect(out.json["status"]?.stringValue == "pending_user_review")
            #expect(out.json["proposal_id"]?.stringValue?.hasPrefix("p-") == true)
        }
        #expect(coordinator.proposals.count == ProposalTool.allCases.count)
        #expect(coordinator.proposals.allSatisfy { $0.state == .pending && $0.conversation == "c1" && $0.origin == .firstMate(conversation: "c1") })
    }

    @Test func aReadOnlyClusterCannotBeProposedAChange() async {
        let ro = testCluster("ro", readOnly: true)
        let (tools, coordinator, _) = tools(clusters: [ro])
        let patch = await tools.call(.proposePatch, input: sampleProposalInput(.proposePatch, cluster: "ro"))
        #expect(patch.json["error"]?.stringValue == "cluster_read_only")
        #expect(coordinator.proposals.isEmpty)
        // A command is only typed into the terminal, which stays guarded by Gangway.
        let command = await tools.call(.proposeCommand, input: sampleProposalInput(.proposeCommand, cluster: "ro"))
        #expect(!command.isError)
    }

    @Test func aGrantedProductionClusterAcceptsProposals() async {
        let grants = ConversationGrants(conversation: "c1")
        let (tools, coordinator, _) = tools(grants: grants)
        let before = await tools.call(.proposePatch, input: sampleProposalInput(.proposePatch, cluster: "prod"))
        #expect(before.json["error"]?.stringValue == "permission_required")
        grants.grant("prod")
        let after = await tools.call(.proposePatch, input: sampleProposalInput(.proposePatch, cluster: "prod"))
        #expect(!after.isError)
        #expect(coordinator.proposals.count == 1)
    }

    @Test func beaconCannotUseProposalTools() async {
        let source = FakeToolboxSource([dev])
        let policy = ToolboxPolicy(caller: .beacon(client: "x"), settings: StaticToolboxSettings(beacon: ["x": BeaconScope(readClusters: ["dev"])]))
        let tools = ProposalTools(source: source, policy: policy, coordinator: ProposalCoordinator())
        let out = await tools.call(.proposePatch, input: sampleProposalInput(.proposePatch, cluster: "dev"))
        #expect(out.json["error"]?.stringValue == "unknown_tool")
    }

    // MARK: Validation

    private func rejected(_ tool: ProposalTool, _ edit: (inout JSONValue) -> Void, sourceLine: UInt = #line) async -> String? {
        let (tools, coordinator, _) = tools()
        var input = sampleProposalInput(tool, cluster: "dev")
        edit(&input)
        let out = await tools.call(tool, input: input)
        #expect(coordinator.proposals.isEmpty, "a rejected input must not create a card (line \(sourceLine))")
        return out.json["error"]?.stringValue
    }

    @Test func patchValidation() async {
        #expect(await rejected(.proposePatch) { $0["patch_type"] = "nope" } == "invalid_input")
        #expect(await rejected(.proposePatch) { $0["kind"] = "nonsense" } == "invalid_input")
        #expect(await rejected(.proposePatch) { $0["name"] = "Bad_Name" } == "invalid_input")
        #expect(await rejected(.proposePatch) { $0["namespace"] = "Bad.NS" } == "invalid_input")
        #expect(await rejected(.proposePatch) { $0["namespace"] = nil } == "invalid_input")           // namespaced kind
        #expect(await rejected(.proposePatch) { $0["patch"] = [1, 2] } == "invalid_input")             // merge needs an object
        #expect(await rejected(.proposePatch) { $0["patch_type"] = "json"; $0["patch"] = ["a": 1] } == "invalid_input")
        #expect(await rejected(.proposePatch) { $0["patch_type"] = "json"; $0["patch"] = [["op": "add"]] } == "invalid_input")
        #expect(await rejected(.proposePatch) { $0["patch"] = [:] } == "invalid_input")
    }

    @Test func jsonPatchIsAccepted() async {
        let (tools, coordinator, _) = tools()
        var input = sampleProposalInput(.proposePatch, cluster: "dev")
        input["patch_type"] = "json"
        input["patch"] = [["op": "replace", "path": "/spec/replicas", "value": 2]]
        let out = await tools.call(.proposePatch, input: input)
        #expect(!out.isError, "\(out.text)")
        #expect(coordinator.proposals.count == 1)
    }

    @Test func manifestValidation() async {
        #expect(await rejected(.proposeManifest) { $0["yaml"] = "a: [unclosed" } == "invalid_input")
        #expect(await rejected(.proposeManifest) { $0["yaml"] = "kind: ConfigMap\nmetadata:\n  name: x\n" } == "invalid_input")   // no apiVersion
        #expect(await rejected(.proposeManifest) { $0["yaml"] = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: Bad_Name\n" } == "invalid_input")
        #expect(await rejected(.proposeManifest) { $0["yaml"] = "- a\n- b\n" } == "invalid_input")
        #expect(await rejected(.proposeManifest) { $0["yaml"] = "  \n" } == "invalid_input")
    }

    @Test func commandMustBeASingleLineWithoutControlCharacters() async {
        for bad in ["kubectl get pods\nkubectl delete ns prod", "kubectl get pods\r", "echo \u{1B}[2J", "ls\u{7}", "a\u{2028}b", ""] {
            #expect(await rejected(.proposeCommand) { $0["command"] = .string(bad) } == "invalid_input", "\(bad.debugDescription)")
        }
        #expect(await rejected(.proposeCommand) { $0["command"] = .string(String(repeating: "a", count: 3000)) } == "invalid_input")
    }

    @Test func helmAndGitopsValidation() async {
        #expect(await rejected(.proposeHelmUpgrade) { $0["release"] = "BAD" } == "invalid_input")
        #expect(await rejected(.proposeHelmUpgrade) { $0["values_yaml"] = "a: [" } == "invalid_input")
        #expect(await rejected(.proposeHelmUpgrade) { $0["chart"] = "" } == "invalid_input")
        #expect(await rejected(.proposeGitopsAction) { $0["controller"] = "jenkins" } == "invalid_input")
        #expect(await rejected(.proposeGitopsAction) { $0["action"] = "rm -rf" } == "invalid_input")
        #expect(await rejected(.proposeGitopsAction) { $0["kind"] = "Kust;omization" } == "invalid_input")
    }

    @Test func tooManyOpenProposalsAreRefused() async {
        let (tools, coordinator, _) = tools()
        for _ in 0..<ProposalCoordinator.maxOpenPerConversation {
            _ = await tools.call(.proposeCommand, input: sampleProposalInput(.proposeCommand, cluster: "dev"))
        }
        let out = await tools.call(.proposeCommand, input: sampleProposalInput(.proposeCommand, cluster: "dev"))
        #expect(out.json["error"]?.stringValue == "too_many_proposals")
        #expect(coordinator.proposals.count == ProposalCoordinator.maxOpenPerConversation)
    }

    // MARK: Coordinator

    private func submit(_ coordinator: ProposalCoordinator, conversation: String = "c1") throws -> ProposedChange {
        try coordinator.submit(conversation: conversation, cluster: "dev", payload: .command("kubectl get pods"), reason: "r")
    }

    @Test func onlyOneProposalPerConversationIsInASheet() throws {
        let coordinator = ProposalCoordinator()
        let a = try submit(coordinator), b = try submit(coordinator), other = try submit(coordinator, conversation: "c2")
        #expect(coordinator.canBeginReview(a.id) && coordinator.canBeginReview(b.id))
        #expect(coordinator.beginReview(a.id))
        #expect(!coordinator.canBeginReview(b.id))
        #expect(!coordinator.beginReview(b.id))
        #expect(coordinator.canBeginReview(other.id))          // another conversation is independent
        coordinator.cancelReview(a.id)
        #expect(coordinator.proposal(a.id)?.state == .pending)
        #expect(coordinator.beginReview(b.id))
    }

    @Test func outcomesBecomeNotesThatAreTakenOnce() throws {
        let coordinator = ProposalCoordinator()
        let a = try submit(coordinator), b = try submit(coordinator), c = try submit(coordinator)
        coordinator.beginReview(a.id); coordinator.markApplied(a.id)
        coordinator.beginReview(b.id); coordinator.markDeclined(b.id)
        coordinator.beginReview(c.id); coordinator.markFailed(c.id, message: "conflict")
        #expect(coordinator.takeOutcomeNotes(for: "c1") == [
            "Proposal \(a.id) was applied by the user.", "Proposal \(b.id) was declined by the user.",
            "Proposal \(c.id) was approved by the user but failed: conflict",
        ])
        #expect(coordinator.takeOutcomeNotes(for: "c1").isEmpty)
        #expect(coordinator.takeOutcomeNotes(for: "c2").isEmpty)
        // A finished proposal cannot be finished again.
        coordinator.markApplied(b.id)
        #expect(coordinator.proposal(b.id)?.state == .declined)
        #expect(coordinator.takeOutcomeNotes(for: "c1").isEmpty)
    }

    // MARK: Proposals reach a cluster only through ConfirmSheet

    @Test func patchReviewIsANormalConfirmRequestWithFirstMateOrigin() throws {
        let coordinator = ProposalCoordinator()
        let change = try coordinator.submit(conversation: "c1", cluster: "prod", payload: .patch(kind: .deployment, name: "web", namespace: "apps", patchType: "merge", body: ["spec": ["replicas": 3]]), reason: "scale up")
        let recorder = RecordingClient()
        let request = try #require(ProposalConfirmation.request(for: change, cluster: prod, client: recorder, coordinator: coordinator))
        #expect(request.origin == .firstMate(conversation: "c1"))
        #expect(request.inputDelay == 1.0)
        #expect(request.requiresTyping)                               // forced on Production for non-UI origins
        #expect(request.confirmationText == "web")
        #expect(request.facts.contains { $0.label == "Reason" && $0.value == "scale up" })
        // Building the request changed nothing.
        #expect(recorder.mutations.isEmpty)
        #expect(coordinator.proposal(change.id)?.state == .pending)
    }

    @Test func nonUIOriginsCannotUseTheTypingExemptionOnProduction() {
        for origin in [ChangeOrigin.firstMate(conversation: "c"), .beacon(client: "b"), .rigging(pack: "p")] {
            #expect(MutationPolicy.requiresTyping(cluster: prod, origin: origin, exemption: .interactiveShell, alwaysRequireTyping: false))
        }
    }

    @Test func theMutationRunsOnlyWhenTheSheetsActionRuns() async throws {
        let coordinator = ProposalCoordinator()
        let change = try coordinator.submit(conversation: "c1", cluster: "dev", payload: .patch(kind: .deployment, name: "web", namespace: "apps", patchType: "merge", body: ["spec": ["replicas": 3]]), reason: "")
        let recorder = RecordingClient()
        let request = try #require(ProposalConfirmation.request(for: change, cluster: dev, client: recorder, coordinator: coordinator))
        // The dry run is read-only in effect: dryRun true, and it is what the sheet runs first.
        let outcome = await request.dryRun?()
        guard case .passed? = outcome else { Issue.record("dry run did not pass: \(String(describing: outcome))"); return }
        #expect(recorder.mutations == [.init(verb: "patch", dryRun: true)])
        try await request.action()
        #expect(recorder.mutations == [.init(verb: "patch", dryRun: true), .init(verb: "patch", dryRun: false)])
        #expect(coordinator.proposal(change.id)?.state == .applied)
        #expect(coordinator.takeOutcomeNotes(for: "c1") == ["Proposal \(change.id) was applied by the user."])
    }

    @Test func aFailedAttemptKeepsTheSheetRetryableAndAnEventualSuccessIsApplied() async throws {
        let coordinator = ProposalCoordinator()
        let change = try coordinator.submit(conversation: "c1", cluster: "dev", payload: .patch(kind: .deployment, name: "web", namespace: "apps", patchType: "merge", body: ["a": 1]), reason: "")
        coordinator.beginReview(change.id)
        let failing = RecordingClient(failMutations: true)
        let request = try #require(ProposalConfirmation.request(for: change, cluster: dev, client: failing, coordinator: coordinator))
        await #expect(throws: (any Error).self) { try await request.action() }
        #expect(coordinator.proposal(change.id)?.state == .inReview)      // not failed yet: the person may retry
        let working = RecordingClient()
        let retry = try #require(ProposalConfirmation.request(for: change, cluster: dev, client: working, coordinator: coordinator))
        try await retry.action()
        #expect(coordinator.proposal(change.id)?.state == .applied)
        coordinator.reviewDismissed(change.id)                              // closing afterwards changes nothing
        #expect(coordinator.proposal(change.id)?.state == .applied)
    }

    @Test func dismissingAfterOnlyFailuresFailsTheProposalWithARedactedNote() async throws {
        let coordinator = ProposalCoordinator()
        let change = try coordinator.submit(conversation: "c1", cluster: "dev", payload: .patch(kind: .deployment, name: "web", namespace: "apps", patchType: "merge", body: ["a": 1]), reason: "")
        coordinator.beginReview(change.id)
        coordinator.recordAttemptFailure(change.id, message: "webhook rejected: password=hunter2 for https://u:pw@hook.example.com")
        coordinator.reviewDismissed(change.id)
        guard case .failed(let message)? = coordinator.proposal(change.id)?.state else { Issue.record("not failed"); return }
        #expect(!message.contains("hunter2") && !message.contains("u:pw@"))
        let note = coordinator.takeOutcomeNotes(for: "c1").joined()
        #expect(!note.contains("hunter2") && !note.contains("u:pw@"))
    }

    @Test func dismissingWithoutAttemptsReturnsToPendingAndDeclineIsExplicit() throws {
        let coordinator = ProposalCoordinator()
        let a = try submit(coordinator), b = try submit(coordinator)
        coordinator.beginReview(a.id)
        coordinator.reviewDismissed(a.id)
        #expect(coordinator.proposal(a.id)?.state == .pending)
        coordinator.beginReview(b.id)
        coordinator.markDeclined(b.id)
        #expect(coordinator.proposal(b.id)?.state == .declined)
    }

    @Test func aProposalForAnotherClusterIsNotBuiltForThisOne() throws {
        let coordinator = ProposalCoordinator()
        let change = try coordinator.submit(conversation: "c1", cluster: "prod", payload: .patch(kind: .deployment, name: "web", namespace: "apps", patchType: "merge", body: ["a": 1]), reason: "")
        #expect(ProposalConfirmation.request(for: change, cluster: dev, client: RecordingClient(), coordinator: coordinator) == nil)
        #expect(ProposalConfirmation.request(for: change, cluster: prod, client: RecordingClient(), coordinator: coordinator) != nil)
    }

    @Test func theSheetShowsTheChangeAndNeverHidesAnAssumedNamespace() throws {
        let coordinator = ProposalCoordinator()
        let docs: [JSONValue] = [
            ["apiVersion": "v1", "kind": "ConfigMap", "metadata": ["name": "a"]],
            ["apiVersion": "v1", "kind": "Namespace", "metadata": ["name": "team"]],
            ["apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "b", "namespace": "apps"]],
            ["apiVersion": "example.io/v1", "kind": "Widget", "metadata": ["name": "w"]],
        ]
        let change = try coordinator.submit(conversation: "c1", cluster: "dev", payload: .manifest(yaml: "", documents: docs), reason: "")
        let request = try #require(ProposalConfirmation.request(for: change, cluster: dev, client: RecordingClient(), coordinator: coordinator))
        let objects = request.facts.filter { $0.label.hasPrefix("Object") }.map(\.value)
        #expect(objects == ["ConfigMap default/a (namespace not set in the manifest)", "Namespace team (cluster-scoped)", "Deployment apps/b", "Widget w (scope resolved at apply)"])
        let patch = try coordinator.submit(conversation: "c1", cluster: "dev", payload: .patch(kind: .deployment, name: "web", namespace: "apps", patchType: "merge", body: ["spec": ["replicas": 3]]), reason: "")
        let patchRequest = try #require(ProposalConfirmation.request(for: patch, cluster: dev, client: RecordingClient(), coordinator: coordinator))
        #expect(patchRequest.facts.first { $0.label == "Patch" }?.value.contains("replicas") == true)
        #expect(patchRequest.facts.first { $0.label == "Namespace" }?.value == "apps")
    }

    @Test func reasonIsCapped() async {
        let (tools, coordinator, _) = tools()
        var input = sampleProposalInput(.proposeCommand, cluster: "dev")
        input["reason"] = .string(String(repeating: "r", count: 10_000))
        _ = await tools.call(.proposeCommand, input: input)
        #expect(coordinator.proposals.first?.reason.count == ProposalTools.maxReasonLength)
    }

    @Test func manifestReviewAppliesEachDocumentServerSide() async throws {
        let coordinator = ProposalCoordinator()
        let docs: [JSONValue] = [
            ["apiVersion": "v1", "kind": "ConfigMap", "metadata": ["name": "a", "namespace": "apps"]],
            ["apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "b"]],
        ]
        let change = try coordinator.submit(conversation: "c1", cluster: "dev", payload: .manifest(yaml: "", documents: docs), reason: "")
        let recorder = RecordingClient()
        let request = try #require(ProposalConfirmation.request(for: change, cluster: dev, client: recorder, coordinator: coordinator))
        #expect(request.confirmationText == "2")
        try await request.action()
        #expect(recorder.mutations.count == 2 && recorder.mutations.allSatisfy { $0.verb == "patch" && !$0.dryRun })
        #expect(recorder.lastPatchContentTypes == ["application/apply-patch+yaml", "application/apply-patch+yaml"])
    }

    @Test func commandHelmAndGitopsProposalsHaveTheirOwnReviewFlows() throws {
        let coordinator = ProposalCoordinator()
        for payload in [ProposalPayload.command("kubectl get pods"), .helmUpgrade(release: "r", namespace: "n", chart: "c", version: nil, valuesYAML: nil),
                        .gitopsAction(controller: "flux", action: "reconcile", kind: "Kustomization", name: "a", namespace: "flux-system")] {
            let change = try coordinator.submit(conversation: "c1", cluster: "dev", payload: payload, reason: "")
            #expect(ProposalConfirmation.request(for: change, cluster: dev, client: RecordingClient(), coordinator: coordinator) == nil)
        }
    }
}
