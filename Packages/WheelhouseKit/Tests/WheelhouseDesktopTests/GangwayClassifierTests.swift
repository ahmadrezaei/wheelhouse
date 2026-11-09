#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

private typealias H = HTTPRequestHead.Header

private func classify(_ method: String, _ path: String, query: String? = nil, headers: [H] = [], body: String? = nil, json: Bool = true) throws -> GangwayRequestClass {
    var all = headers
    if body != nil, json { all.append(H(name: "Content-Type", value: "application/json")) }
    return try RequestClassifier.classify(method: method, rawPath: path, rawQuery: query, headers: all, body: body.map { Data($0.utf8) })
}

private func kind(_ method: String, _ path: String, query: String? = nil, headers: [H] = [], body: String? = nil, json: Bool = true) throws -> GangwayClass {
    try classify(method, path, query: query, headers: headers, body: body, json: json).kind
}

@Suite("Gangway classifier")
struct GangwayClassifierTests {
    struct Row: CustomTestStringConvertible, Sendable {
        var name: String
        var method: String
        var path: String
        var query: String? = nil
        var headers: [(String, String)] = []
        var body: String? = nil
        var expected: GangwayClass
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "GET pods is a read", method: "GET", path: "/api/v1/namespaces/shop/pods", expected: .read),
        Row(name: "watch is a read", method: "GET", path: "/api/v1/namespaces/shop/pods", query: "watch=true&resourceVersion=1", expected: .read),
        Row(name: "HEAD and OPTIONS read", method: "HEAD", path: "/version", expected: .read),
        Row(name: "OPTIONS read", method: "OPTIONS", path: "/apis", expected: .read),
        Row(name: "an Upgrade header on a POST is a stream", method: "POST", path: "/api/v1/namespaces/shop/pods/web/exec",
            headers: [("Upgrade", "SPDY/3.1"), ("Connection", "Upgrade")], expected: .stream(.exec(interactive: false))),
        Row(name: "an Upgrade header on a GET of a non-stream path is another upgrade", method: "GET", path: "/api/v1/namespaces/shop/pods",
            headers: [("Connection", "keep-alive, Upgrade")], expected: .stream(.otherUpgrade)),
        Row(name: "exec without an upgrade header is still a stream", method: "GET", path: "/api/v1/namespaces/shop/pods/web/exec", query: "command=ls&stdout=true",
            expected: .stream(.exec(interactive: false))),
        Row(name: "tty and stdin make exec interactive", method: "POST", path: "/api/v1/namespaces/shop/pods/web/exec",
            query: "command=sh&stdin=true&stdout=true&tty=true", headers: [("Upgrade", "websocket")], expected: .stream(.exec(interactive: true))),
        Row(name: "tty alone is not interactive", method: "POST", path: "/api/v1/namespaces/shop/pods/web/exec", query: "tty=true&command=ls",
            expected: .stream(.exec(interactive: false))),
        Row(name: "attach", method: "POST", path: "/api/v1/namespaces/shop/pods/web/attach", query: "stdin=true&tty=true", expected: .stream(.attach(interactive: true))),
        Row(name: "portforward", method: "GET", path: "/api/v1/namespaces/shop/pods/web/portforward", headers: [("Upgrade", "websocket")], expected: .stream(.portForward)),
        Row(name: "pods/proxy with GET is proxy, not read", method: "GET", path: "/api/v1/namespaces/shop/pods/web/proxy/metrics", expected: .proxy(method: "GET")),
        Row(name: "services/proxy with POST", method: "POST", path: "/api/v1/namespaces/shop/services/web:80/proxy/x", expected: .proxy(method: "POST")),
        Row(name: "nodes/proxy", method: "GET", path: "/api/v1/nodes/n1/proxy/stats", expected: .proxy(method: "GET")),
        Row(name: "legacy /api/v1/proxy form", method: "GET", path: "/api/v1/proxy/namespaces/shop/pods/web", expected: .proxy(method: "GET")),
        Row(name: "legacy /api/v1/watch form is a read", method: "GET", path: "/api/v1/watch/namespaces/shop/pods", expected: .read),
        Row(name: "a namespace called proxy is not a proxy", method: "GET", path: "/api/v1/namespaces/proxy/pods", expected: .read),
        Row(name: "POST to pods is a mutation", method: "POST", path: "/api/v1/namespaces/shop/pods", expected: .mutation),
        Row(name: "PUT and PATCH are mutations", method: "PATCH", path: "/apis/apps/v1/namespaces/shop/deployments/web", expected: .mutation),
        Row(name: "PATCH with one dryRun=All is a dry-run", method: "PATCH", path: "/apis/apps/v1/namespaces/shop/deployments/web", query: "dryRun=All", expected: .dryRun),
        Row(name: "POST with server-side apply dry-run", method: "PATCH", path: "/apis/apps/v1/namespaces/shop/deployments/web",
            query: "fieldManager=kubectl&dryRun=All&force=false", expected: .dryRun),
        Row(name: "two dryRun keys are a mutation", method: "PATCH", path: "/api/v1/namespaces/shop/configmaps/a", query: "dryRun=All&dryRun=All", expected: .mutation),
        Row(name: "dryRun=all (lower case) is a mutation", method: "PATCH", path: "/api/v1/namespaces/shop/configmaps/a", query: "dryRun=all", expected: .mutation),
        Row(name: "an escaped second dryRun key is a mutation", method: "PATCH", path: "/api/v1/namespaces/shop/configmaps/a", query: "dry%52un=All&dryRun=All", expected: .mutation),
        Row(name: "dryRun with another value", method: "POST", path: "/api/v1/namespaces/shop/configmaps", query: "dryRun=Foo", expected: .mutation),
        Row(name: "DELETE with dryRun query and no body is a mutation", method: "DELETE", path: "/api/v1/namespaces/shop/pods/a", query: "dryRun=All", expected: .mutation),
        Row(name: "DELETE with a dry-run body is a dry-run", method: "DELETE", path: "/api/v1/namespaces/shop/pods/a", body: #"{"kind":"DeleteOptions","apiVersion":"v1","dryRun":["All"]}"#, expected: .dryRun),
        Row(name: "DELETE collection with a dry-run body", method: "DELETE", path: "/api/v1/namespaces/shop/pods", body: #"{"dryRun":["All"]}"#, expected: .dryRun),
        Row(name: "DELETE with an empty dryRun list is a mutation", method: "DELETE", path: "/api/v1/namespaces/shop/pods/a", body: #"{"dryRun":[]}"#, expected: .mutation),
        Row(name: "DELETE with two entries is a mutation", method: "DELETE", path: "/api/v1/namespaces/shop/pods/a", body: #"{"dryRun":["All","All"]}"#, expected: .mutation),
        Row(name: "a duplicate dryRun key (the last one wins in Go) is a mutation", method: "DELETE", path: "/api/v1/namespaces/shop/pods/a", body: #"{"dryRun":["All"],"dryRun":[]}"#, expected: .mutation),
        Row(name: "an escaped duplicate key is a mutation", method: "DELETE", path: "/api/v1/namespaces/shop/pods/a", body: #"{"dryRun":["All"],"dryRun":[]}"#, expected: .mutation),
        Row(name: "a case variant key is a mutation", method: "DELETE", path: "/api/v1/namespaces/shop/pods/a", body: #"{"dryRun":["All"],"DRYRUN":[]}"#, expected: .mutation),
        Row(name: "a body that is not JSON is a mutation", method: "DELETE", path: "/api/v1/namespaces/shop/pods/a", body: "dryRun: [All]", expected: .mutation),
        Row(name: "an eviction with a dry-run deleteOptions", method: "POST", path: "/api/v1/namespaces/shop/pods/a/eviction",
            body: #"{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"a"},"deleteOptions":{"dryRun":["All"]}}"#, expected: .dryRun),
        Row(name: "an eviction without deleteOptions is a mutation", method: "POST", path: "/api/v1/namespaces/shop/pods/a/eviction", body: #"{"kind":"Eviction"}"#, expected: .mutation),
        Row(name: "an eviction with dryRun only in the query is a mutation", method: "POST", path: "/api/v1/namespaces/shop/pods/a/eviction", query: "dryRun=All", expected: .mutation),
        Row(name: "an eviction with a duplicate deleteOptions is a mutation", method: "POST", path: "/api/v1/namespaces/shop/pods/a/eviction",
            body: #"{"deleteOptions":{"dryRun":["All"]},"deleteOptions":{}}"#, expected: .mutation),
        Row(name: "SelfSubjectAccessReview is a review", method: "POST", path: "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews", expected: .review),
        Row(name: "SelfSubjectRulesReview", method: "POST", path: "/apis/authorization.k8s.io/v1/selfsubjectrulesreviews", expected: .review),
        Row(name: "SelfSubjectReview", method: "POST", path: "/apis/authentication.k8s.io/v1/selfsubjectreviews", expected: .review),
        Row(name: "TokenReview", method: "POST", path: "/apis/authentication.k8s.io/v1/tokenreviews", expected: .review),
        Row(name: "a review path in a wrong version is a mutation", method: "POST", path: "/apis/authorization.k8s.io/v1beta1/selfsubjectaccessreviews", expected: .mutation),
        Row(name: "a review resource in another group is a mutation", method: "POST", path: "/apis/example.com/v1/selfsubjectaccessreviews", expected: .mutation),
        Row(name: "a namespaced review resource is a mutation", method: "POST", path: "/apis/authorization.k8s.io/v1/namespaces/a/selfsubjectaccessreviews", expected: .mutation),
        Row(name: "a subjectaccessreview (not self) is a mutation", method: "POST", path: "/apis/authorization.k8s.io/v1/subjectaccessreviews", expected: .mutation),
        Row(name: "an unknown method is a mutation", method: "PROPFIND", path: "/version", expected: .mutation),
        Row(name: "a trailing slash is allowed", method: "GET", path: "/openapi/v3/", expected: .read),
        Row(name: "discovery paths read", method: "GET", path: "/apis/apps/v1", expected: .read),
    ]

    @Test("classification table", arguments: rows)
    func table(row: Row) throws {
        let method = row.method
        let headers = row.headers.map { H(name: $0.0, value: $0.1) }
        let got = try kind(method, row.path, query: row.query, headers: headers, body: row.body, json: !(row.name.contains("not JSON")))
        #expect(got == row.expected)
    }

    @Test("a lower-case method never reads")
    func lowerCaseMethod() throws {
        #expect(try kind("get", "/api/v1/pods") == .mutation)
        #expect(try kind("Get", "/api/v1/pods") == .mutation)
    }

    @Test("a non-JSON content type or an encoded body is a mutation")
    func bodyTypes() throws {
        let body = #"{"dryRun":["All"]}"#
        #expect(try kind("DELETE", "/api/v1/namespaces/a/pods/b", headers: [H(name: "Content-Type", value: "application/yaml")], body: body, json: false) == .mutation)
        #expect(try kind("DELETE", "/api/v1/namespaces/a/pods/b", headers: [H(name: "Content-Type", value: "application/vnd.kubernetes.protobuf")], body: body, json: false) == .mutation)
        #expect(try kind("DELETE", "/api/v1/namespaces/a/pods/b", headers: [H(name: "Content-Type", value: "application/json"), H(name: "Content-Encoding", value: "gzip")], body: body, json: false) == .mutation)
        #expect(try kind("DELETE", "/api/v1/namespaces/a/pods/b", headers: [H(name: "Content-Type", value: "application/json; charset=utf-8")], body: body, json: false) == .dryRun)
        #expect(try kind("DELETE", "/api/v1/namespaces/a/pods/b", body: body, json: false) == .mutation)       // no content type
    }

    @Test("a body over 64 KB is never a dry-run")
    func oversizedBody() throws {
        let big = #"{"dryRun":["All"],"pad":""# + String(repeating: "a", count: 70_000) + #""}"#
        #expect(try kind("DELETE", "/api/v1/namespaces/a/pods/b", body: big) == .mutation)
    }

    @Test("Impersonate headers are recorded on every class, whatever the case")
    func impersonation() throws {
        let c = try classify("GET", "/api/v1/pods", headers: [H(name: "impersonate-user", value: "alice"), H(name: "Impersonate-Group", value: "devs"),
                                                              H(name: "Impersonate-Extra-scopes", value: "x"), H(name: "Impersonate-Uid", value: "1")])
        #expect(c.kind == .read)
        #expect(c.impersonation.count == 4)
        #expect(c.impersonation.contains(ImpersonationHeader(name: "impersonate-user", value: "alice")))
        let stream = try classify("POST", "/api/v1/namespaces/a/pods/b/exec", headers: [H(name: "Impersonate-User", value: "x")])
        #expect(stream.impersonation.count == 1)
    }

    @Test("path rejections", arguments: [
        "/api/v1//pods", "//api/v1/pods", "/api/v1/./pods", "/api/v1/../pods", "/api/v1/pods/..", "/api/v1/namespaces/a%2Fb/pods", "/api/v1/namespaces/a%2fb/pods",
        "/api/v1/namespaces/a%5Cb/pods", "/api/v1/namespaces/a%5cb/pods", "/api/v1/namespaces/a%2Eb/pods", "/api/v1/namespaces/a%2eb/pods", "/api/v1/pods%00",
        "/api/v1/pod\\s", "/api/v1/namespaces/a%41/pods", "/api/v1/na mespaces", "/api/v1/namespaces/a/pods/b/proxy//x", "/api/v1/namespaces/a/pods/b/proxy/%2e%2e/x",
        "/api/v1/namespaces/a/pods/b/proxy/x%2Fy", "/api/v1/namespaces/a/pods/b/proxy/x\\y", "api/v1/pods", "/api/v1/namespaces/a/pods/b/proxy/%00",
    ])
    func rejectedPaths(path: String) {
        #expect(throws: GangwayRejection.self) { try classify("GET", path) }
    }

    @Test("a percent escape after a proxy segment is allowed, except the dangerous ones")
    func proxyEscapes() throws {
        #expect(try kind("GET", "/api/v1/namespaces/a/services/s:80/proxy/search%20x") == .proxy(method: "GET"))
        #expect(try kind("GET", "/api/v1/namespaces/a/pods/b/proxy/a.b/c") == .proxy(method: "GET"))
    }

    @Test("query parsing follows Go's url.ParseQuery", arguments: [
        ("dryRun=All;x=1", true), ("a=1;b=2", true), ("a=%zz", true), ("a=%2", true), ("a=%", true), ("a=1&b=2", false), ("a=b+c", false), ("a", false), ("&&a=1&&", false),
    ])
    func goQuery(raw: String, fails: Bool) {
        if fails {
            #expect(throws: GangwayRejection.self) { try RequestClassifier.parseQuery(raw) }
        } else {
            #expect(throws: Never.self) { try RequestClassifier.parseQuery(raw) }
        }
    }

    @Test("query values decode plus to space and keys are unescaped")
    func queryDecoding() throws {
        let q = try RequestClassifier.parseQuery("a=b+c&d%41=%e2%82%ac&e=")
        #expect(q.map(\.key) == ["a", "dA", "e"])
        #expect(q.map(\.value) == ["b c", "\u{20AC}", ""])
    }

    @Test("a query with a semicolon makes the whole request a 400")
    func semicolon() {
        #expect(throws: GangwayRejection.self) { try classify("PATCH", "/api/v1/namespaces/a/configmaps/b", query: "dryRun=All;x=1") }
    }

    @Test("path shapes follow the API server's request-info rules")
    func shapes() throws {
        func shape(_ path: String) throws -> APIPathShape { RequestClassifier.shape(of: try RequestClassifier.canonicalSegments(of: path)) }
        let a = try shape("/api/v1/namespaces/shop/pods/web/exec")
        #expect((a.group, a.version, a.namespace, a.resource, a.name, a.subresource) == ("", "v1", "shop", "pods", "web", "exec"))
        let b = try shape("/apis/apps/v1/namespaces/shop/deployments/web/scale")
        #expect((b.group, b.resource, b.subresource) == ("apps", "deployments", "scale"))
        let c = try shape("/api/v1/namespaces/shop")
        #expect((c.resource, c.name, c.namespace) == ("namespaces", "shop", "shop"))
        let d = try shape("/api/v1/namespaces/shop/status")
        #expect((d.resource, d.name, d.subresource) == ("namespaces", "shop", "status"))
        let e = try shape("/api/v1/nodes/n1/proxy/stats")
        #expect((e.resource, e.name, e.subresource, e.namespace) == ("nodes", "n1", "proxy", nil))
        let f = try shape("/version")
        #expect(!f.isResourcePath)
    }
}

@Suite("Gangway policy table")
struct GangwayPolicyTests {
    private func cluster(_ env: ClusterEnvironment, readOnly: Bool = false, allowExec: Bool = false) -> ClusterConfig {
        ClusterConfig(name: "c1", server: URL(string: "https://c1.test:6443")!, environment: env, readOnly: readOnly, allowExecInReadOnly: allowExec)
    }
    private func decide(_ kind: GangwayClass, _ c: ClusterConfig, impersonation: [ImpersonationHeader] = []) -> PolicyVerdict {
        MutationPolicy.decide(gangway: GangwayRequestClass(kind: kind, impersonation: impersonation), cluster: c, origin: nil)
    }

    @Test("reads, reviews and dry-runs pass everywhere")
    func readsPass() {
        for env in [ClusterEnvironment.development, .production] {
            for ro in [true, false] {
                for kind in [GangwayClass.read, .review, .dryRun] { #expect(decide(kind, cluster(env, readOnly: ro)) == .pass) }
            }
        }
    }

    @Test("mutations: refused when read-only, typed on Production, pass elsewhere")
    func mutations() {
        guard case .refuse(let text) = decide(.mutation, cluster(.development, readOnly: true)) else { Issue.record("not refused"); return }
        #expect(text == "Wheelhouse: c1 is read-only. Allow changes in Cluster Settings.")
        #expect(decide(.mutation, cluster(.production)) == .confirm(requiresTyping: true))
        #expect(decide(.mutation, cluster(.development)) == .pass)
        guard case .refuse = decide(.mutation, cluster(.production, readOnly: true)) else { Issue.record("read-only Production must refuse"); return }
    }

    @Test("streams")
    func streams() {
        let interactive = GangwayClass.stream(.exec(interactive: true))
        let plain = GangwayClass.stream(.exec(interactive: false))
        #expect(decide(interactive, cluster(.production)) == .confirm(requiresTyping: false))
        #expect(decide(.stream(.portForward), cluster(.production)) == .confirm(requiresTyping: false))
        #expect(decide(plain, cluster(.production)) == .confirm(requiresTyping: true))
        #expect(decide(.stream(.otherUpgrade), cluster(.production)) == .confirm(requiresTyping: true))
        #expect(decide(interactive, cluster(.development)) == .pass)
        guard case .refuse = decide(interactive, cluster(.development, readOnly: true)) else { Issue.record("not refused"); return }
        #expect(decide(interactive, cluster(.development, readOnly: true, allowExec: true)) == .pass)
        guard case .refuse = decide(.stream(.otherUpgrade), cluster(.development, readOnly: true, allowExec: true)) else { Issue.record("other upgrades stay refused"); return }
    }

    @Test("proxy")
    func proxy() {
        guard case .refuse = decide(.proxy(method: "GET"), cluster(.development, readOnly: true)) else { Issue.record("not refused"); return }
        #expect(decide(.proxy(method: "GET"), cluster(.production)) == .confirm(requiresTyping: false))
        #expect(decide(.proxy(method: "HEAD"), cluster(.production)) == .confirm(requiresTyping: false))
        #expect(decide(.proxy(method: "POST"), cluster(.production)) == .confirm(requiresTyping: true))
        #expect(decide(.proxy(method: "GET"), cluster(.development)) == .pass)
    }

    @Test("Impersonate-* is refused on read-only and Production clusters, even for reads, and passes elsewhere")
    func impersonation() {
        let imp = [ImpersonationHeader(name: "Impersonate-User", value: "alice")]
        guard case .refuse(let text) = decide(.read, cluster(.production), impersonation: imp) else { Issue.record("not refused"); return }
        #expect(text == "Wheelhouse: impersonation is not allowed on c1")
        guard case .refuse = decide(.read, cluster(.development, readOnly: true), impersonation: imp) else { Issue.record("not refused"); return }
        guard case .refuse = decide(.mutation, cluster(.production), impersonation: imp) else { Issue.record("not refused"); return }
        #expect(decide(.read, cluster(.development), impersonation: imp) == .pass)
    }
}
#endif
