import Foundation
import Testing
@testable import WheelhouseKit

@Suite("DeepLink schemes")
struct DeepLinkSchemeTests {
    @Test func theDefaultSchemeIsWheelhouse() {
        #expect(DeepLink.scheme == "wheelhouse")
        #expect(DeepLink.importURL.absoluteString == "wheelhouse://import")
        #expect(DeepLink.accepts("wheelhouse"))
        #expect(!DeepLink.accepts("wheelhouse-mas"))
        #expect(!DeepLink.accepts("Wheelhouse"))
    }

    @Test func aConfiguredSchemeMustBeAPlainLowercaseScheme() {
        #expect(DeepLink.resolveScheme("wheelhouse-mas") == "wheelhouse-mas")
        for bad: Any? in [nil, "", "$(WH_URL_SCHEME)", "Wheelhouse-MAS", "1abc", "a b", "-x", 42] {
            #expect(DeepLink.resolveScheme(bad) == "wheelhouse")
        }
    }

    @Test func anEditionParsesItsOwnAndTheBaseScheme() throws {
        for scheme in ["wheelhouse", "wheelhouse-mas"] {
            let url = try #require(URL(string: "\(scheme)://cluster/prod/ns/web/pods/api-1?view=logs"))
            let link = try #require(DeepLink(url: url, configured: "wheelhouse-mas"))
            #expect(link.clusterID == "prod")
            #expect(link.view == "logs")
            #expect(DeepLink.isImport(try #require(URL(string: "\(scheme)://import")), configured: "wheelhouse-mas"))
        }
        #expect(DeepLink(url: try #require(URL(string: "other://cluster/prod")), configured: "wheelhouse-mas") == nil)
        // A build without a configured scheme refuses the edition's scheme.
        #expect(DeepLink(url: try #require(URL(string: "wheelhouse-mas://cluster/prod")), configured: "wheelhouse") == nil)
        #expect(!DeepLink.isImport(try #require(URL(string: "wheelhouse-mas://import")), configured: "wheelhouse"))
    }

    @Test func anEditionEmitsItsOwnScheme() throws {
        let ref = ResourceRef(clusterID: "prod", kind: .pod, namespace: "web", name: "api-1")
        #expect(DeepLink.url(for: ref, view: "logs")?.scheme == "wheelhouse")
        let url = try #require(DeepLink.url(for: ref, view: "logs", scheme: "wheelhouse-mas"))
        #expect(url.absoluteString == "wheelhouse-mas://cluster/prod/ns/web/pods/api-1?view=logs")
        #expect(DeepLink(url: url, configured: "wheelhouse-mas")?.resourceRef == ref)
    }
}
