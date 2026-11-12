import Testing
import Foundation
@testable import WheelhouseKit
@testable import WheelhouseUI

@Suite("Proposal review preview")
@MainActor
struct ProposalPreviewTests {
    private let dev = testCluster("dev")

    private func change(_ payload: ProposalPayload, cluster: ClusterConfig? = nil) throws -> ProposedChange {
        let coordinator = ProposalCoordinator()
        return try coordinator.submit(conversation: "c1", cluster: (cluster ?? dev).id, payload: payload, reason: "why")
    }

    private func deployment(_ memory: String) -> JSONValue {
        ["apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "web", "namespace": "apps", "resourceVersion": "12", "managedFields": [["manager": "x"]]],
         "spec": ["replicas": 2, "limits": ["memory": .string(memory)]], "status": ["ready": 1]]
    }

    @Test func aPatchIsShownAsALiveVersusDryRunDiffAndOnlyEverDryRuns() async throws {
        let client = RecordingClient()
        let live = deployment("256Mi"), result = deployment("512Mi")
        client.getRawHandler = { _, _, _ in live }
        client.patchHandler = { _ in result }
        let proposal = try change(.patch(kind: .deployment, name: "web", namespace: "apps", patchType: "merge", body: ["spec": ["limits": ["memory": "512Mi"]]]))
        let preview = await ProposalPreview.load(for: proposal, cluster: dev, client: client)
        let entry = try #require(preview.entries.first)
        #expect(entry.problem == nil && !entry.isNew)
        #expect(entry.diff.contains { $0.kind == .removed && $0.text.contains("256Mi") })
        #expect(entry.diff.contains { $0.kind == .added && $0.text.contains("512Mi") })
        // Per-write noise is not part of the diff.
        #expect(!entry.diff.contains { $0.text.contains("resourceVersion") || $0.text.contains("managedFields") || $0.text.contains("status") })
        #expect(client.mutations == [.init(verb: "patch", dryRun: true)])      // never a real write
    }

    @Test func aNewObjectIsAllAdditions() async throws {
        let client = RecordingClient()
        let result = deployment("512Mi")
        client.getRawHandler = { _, _, _ in throw KubeError.notFound(message: nil) }
        client.patchHandler = { _ in result }
        let doc: JSONValue = ["apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "web", "namespace": "apps"]]
        let preview = await ProposalPreview.load(for: try change(.manifest(yaml: "x", documents: [doc])), cluster: dev, client: client)
        let entry = try #require(preview.entries.first)
        #expect(entry.isNew)
        #expect(entry.diff.allSatisfy { $0.kind == .added })
        let all = client.mutations
        #expect(all.allSatisfy { $0.dryRun })
    }

    @Test func aServerRejectionIsShownAsAProblem() async throws {
        let client = RecordingClient()
        let live = deployment("256Mi")
        client.getRawHandler = { _, _, _ in live }
        client.patchHandler = { _ in throw KubeError.unsupported("field is immutable") }
        let preview = await ProposalPreview.load(for: try change(.patch(kind: .deployment, name: "web", namespace: "apps", patchType: "merge", body: ["spec": ["a": 1]])), cluster: dev, client: client)
        #expect(preview.entries.first?.problem?.isEmpty == false)
        #expect(preview.entries.first?.diff.isEmpty == true)
    }

    @Test func secretsAreShownAsKeysAndSizesNeverValues() async throws {
        let client = RecordingClient()
        let value = Data("hunter2-value".utf8).base64EncodedString()
        let other = Data("another-secret".utf8).base64EncodedString()
        let secret: @Sendable (String) -> JSONValue = { v in ["apiVersion": "v1", "kind": "Secret", "metadata": ["name": "s", "namespace": "apps"], "type": "Opaque", "data": ["password": .string(v)]] }
        client.getRawHandler = { _, _, _ in secret(value) }
        client.patchHandler = { _ in secret(other) }
        let preview = await ProposalPreview.load(for: try change(.patch(kind: .secret, name: "s", namespace: "apps", patchType: "merge", body: ["stringData": ["password": "x"]])), cluster: dev, client: client)
        let text = preview.entries.flatMap(\.diff).map(\.text).joined(separator: "\n")
        #expect(!text.contains(value) && !text.contains("hunter2") && !text.contains(other))
    }

    @Test func aReadOnlyClusterGetsANoteAndNoRequest() async throws {
        let readOnly = testCluster("ro", readOnly: true)
        let client = RecordingClient()
        let preview = await ProposalPreview.load(for: try change(.patch(kind: .deployment, name: "web", namespace: "apps", patchType: "merge", body: ["a": 1]), cluster: readOnly), cluster: readOnly, client: client)
        #expect(preview.entries.isEmpty && !preview.notes.isEmpty)
        #expect(client.mutations.isEmpty)
    }

    @Test func commandsHelmAndGitOpsHaveNothingToDiff() async throws {
        let client = RecordingClient()
        for payload in [ProposalPayload.command("kubectl get pods"),
                        .helmUpgrade(release: "r", namespace: "n", chart: "c", version: nil, valuesYAML: nil),
                        .gitopsAction(controller: "flux", action: "reconcile", kind: "Kustomization", name: "k", namespace: "flux-system")] {
            let preview = await ProposalPreview.load(for: try change(payload), cluster: dev, client: client)
            #expect(preview.entries.isEmpty && preview.notes.count == 1)
        }
        #expect(client.mutations.isEmpty)
    }
}
