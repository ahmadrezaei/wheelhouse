import Foundation
import Testing
@testable import WheelhouseKit

@Suite("Artifact Hub")
struct ArtifactHubTests {
    @Test("the search URL is the documented one and an empty query makes none")
    func url() throws {
        let url = try #require(ArtifactHub.searchURL(query: " nginx ingress "))
        #expect(url.host() == "artifacthub.io" && url.path() == "/api/v1/packages/search" && url.scheme == "https")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "kind" }?.value == "0")
        #expect(items.first { $0.name == "ts_query_web" }?.value == "nginx ingress")
        #expect(ArtifactHub.searchURL(query: "  ") == nil)
        #expect(ArtifactHub.searchURL(query: String(repeating: "a", count: 101)) == nil)
    }

    @Test("the answer is read leniently and unsafe repositories are dropped")
    func decode() {
        let json = """
        {"packages":[
          {"name":"nginx","version":"1.2.3","app_version":"1.25","description":"web","repository":{"name":"bitnami","url":"https://charts.bitnami.com/bitnami"}},
          {"name":"oci-chart","version":"0.1.0","repository":{"name":"ghcr","url":"oci://ghcr.io/x"}},
          {"name":"evil","version":"1","repository":{"name":"local","url":"file:///etc"}},
          {"version":"1","repository":{"name":"x","url":"https://x.test"}}
        ]}
        """
        let packages = ArtifactHub.decode(Data(json.utf8))
        #expect(packages.map(\.id) == ["bitnami/nginx", "ghcr/oci-chart"])
        #expect(packages[0].appVersion == "1.25" && packages[0].repositoryURL == "https://charts.bitnami.com/bitnami")
        #expect(ArtifactHub.decode(Data(#"[{"name":"a","repository":{"name":"r","url":"https://r.test"}}]"#.utf8)).count == 1)
        #expect(ArtifactHub.decode(Data("nonsense".utf8)).isEmpty)
    }
}
