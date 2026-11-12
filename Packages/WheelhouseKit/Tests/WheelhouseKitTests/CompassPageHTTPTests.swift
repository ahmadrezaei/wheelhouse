import Foundation
import Testing
@testable import WheelhouseKit

@Suite("Compass metadata page over HTTP")
struct CompassPageHTTPTests {
    /// The privacy claim: whatever the server sends besides name, namespace, labels and the first owner is never surfaced.
    @Test func onlyIdentityLabelsAndOwnerSurviveAndPagesAreFollowed() async throws {
        let host = "compass-\(UUID().uuidString.lowercased().prefix(8)).test"
        let config = ClusterConfig(name: "t", server: URL(string: "https://\(host):6443")!, environment: .development)
        let client = LiveKubeClient(config: config, secrets: ClusterSecrets(token: "kube-token"), protocolClasses: [ProxyCapturingProtocol.self])
        let sentinel = "SENTINEL-" + "PAYLOAD"
        func item(_ name: String) -> String {
            """
            {"metadata":{"name":"\(name)","namespace":"shop","labels":{"app":"db"},
              "annotations":{"kubectl.kubernetes.io/last-applied-configuration":"{\\"data\\":{\\"password\\":\\"\(sentinel)\\"}}"},
              "managedFields":[{"manager":"\(sentinel)"}],
              "ownerReferences":[{"kind":"StatefulSet","name":"db","uid":"u"},{"kind":"Other","name":"second"}]},
             "data":{"password":"\(sentinel)"},"stringData":{"x":"\(sentinel)"}}
            """
        }
        ProxyCapturingProtocol.script(host: host, [
            (200, "{\"metadata\":{\"continue\":\"page-2\"},\"items\":[\(item("one"))]}"),
            (200, "{\"metadata\":{},\"items\":[\(item("two"))]}"),
        ])
        let first = try await client.listCompassPage(kind: .secret, namespace: nil, continueToken: nil, limit: 1)
        #expect(first.items.map(\.name) == ["one"] && first.continueToken == "page-2")
        let second = try await client.listCompassPage(kind: .secret, namespace: nil, continueToken: first.continueToken, limit: 1)
        #expect(second.items.map(\.name) == ["two"] && second.continueToken == nil)
        let item0 = try #require(first.items.first)
        #expect(item0.namespace == "shop" && item0.labels == ["app": "db"] && item0.ownerKind == "StatefulSet" && item0.ownerName == "db")
        // Nothing of the payload is reachable from the result.
        #expect(!String(describing: first).contains(sentinel) && !String(describing: second).contains(sentinel))
        let requests = ProxyCapturingProtocol.requests(host: host)
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.headers["Accept"] == "application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1" })
        #expect(requests[0].url.absoluteString.contains("/api/v1/secrets") && requests[0].url.absoluteString.contains("limit=1") && !requests[0].url.absoluteString.contains("continue="))
        #expect(requests[1].url.absoluteString.contains("continue=page-2"))
    }

    @Test func demoAnswersAPageAndAnOtherwiseBareClientIsUnsupported() async throws {
        let demo = DemoKubeClient(config: DemoFleet.configs[0])
        let page = try await demo.listCompassPage(kind: .pod, namespace: nil, continueToken: nil, limit: 3)
        #expect(page.items.count == 3 && page.continueToken == nil)
        #expect(try await demo.listCompassPage(kind: .pod, namespace: nil, continueToken: "next", limit: 3).items.isEmpty)
        let recording = RecordingClient()
        await #expect(throws: KubeError.self) { _ = try await recording.listCompassPage(kind: .pod, namespace: nil, continueToken: nil, limit: 3) }
    }
}
