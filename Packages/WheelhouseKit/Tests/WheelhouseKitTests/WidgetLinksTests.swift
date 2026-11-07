import Testing
@testable import WheelhouseKit
@testable import WheelhouseUI

@Suite struct WidgetLinksTests {
    @Test func deepLinkFormat() {
        #expect(WidgetLinks.cluster("abc")?.absoluteString == "wheelhouse://cluster/abc")
        #expect(WidgetLinks.pod(cluster: "abc", namespace: "shop", name: "api-1")?.absoluteString == "wheelhouse://cluster/abc/ns/shop/pods/api-1?view=logs")
        #expect(WidgetLinks.fleet(.sample)?.absoluteString == "wheelhouse://cluster/prod")
    }
}
