import Foundation
import Testing
@testable import WheelhouseKit

@Suite struct KubeErrorTests {
    private func decode(_ code: Int, _ json: String) -> KubeError { Status.decodeError(code: code, body: Data(json.utf8)) }

    @Test func forbidden() {
        let body = #"{"kind":"Status","apiVersion":"v1","status":"Failure","message":"pods is forbidden: User \"system:serviceaccount:default:ro\" cannot list resource \"pods\" in API group \"\" in the namespace \"kube-system\"","reason":"Forbidden","details":{"kind":"pods"},"code":403}"#
        guard case .forbidden(let verb, let resource, let ns, let message) = decode(403, body) else { Issue.record("expected forbidden"); return }
        #expect(verb == "list")
        #expect(resource == "pods")
        #expect(ns == "kube-system")
        #expect(message.contains("is forbidden"))
    }

    @Test func unauthorized() {
        guard case .unauthorized(let m) = decode(401, #"{"kind":"Status","status":"Failure","message":"Unauthorized","reason":"Unauthorized","code":401}"#) else { Issue.record("expected unauthorized"); return }
        #expect(m == "Unauthorized")
    }

    @Test func notFoundConflictGone() {
        #expect(decode(404, #"{"kind":"Status","message":"pods \"x\" not found","code":404}"#) == .notFound(message: "pods \"x\" not found"))
        #expect(decode(409, #"{"kind":"Status","message":"the object has been modified","code":409}"#) == .conflict(message: "the object has been modified"))
        #expect(decode(410, #"{"kind":"Status","message":"too old resource version","code":410}"#) == .gone)
    }

    @Test func invalidWithCauses() {
        let body = #"{"kind":"Status","status":"Failure","message":"Deployment.apps \"x\" is invalid: spec.replicas: Invalid value: -1","reason":"Invalid","details":{"name":"x","kind":"Deployment","causes":[{"reason":"FieldValueInvalid","message":"Invalid value: -1","field":"spec.replicas"}]},"code":422}"#
        guard case .invalid(let message, let causes) = decode(422, body) else { Issue.record("expected invalid"); return }
        #expect(message.contains("is invalid"))
        #expect(causes.first?.field == "spec.replicas")
    }

    @Test func serverAndNonStatusBodies() {
        guard case .server(let s) = decode(500, #"{"kind":"Status","message":"etcd timeout","code":500}"#) else { Issue.record("expected server"); return }
        #expect(s.message == "etcd timeout")
        guard case .server(let s2) = decode(502, "<html>Bad Gateway</html>") else { Issue.record("expected server"); return }
        #expect(s2.message?.contains("Bad Gateway") == true)
        #expect(KubeError.server(s).isTransient)
    }

    @Test func readOnlyEnforcedBeforeAnyRequest() async {
        var config = ClusterConfig(name: "ro", server: URL(string: "https://127.0.0.1:1")!, readOnly: true)
        config.environment = .staging
        let client = LiveKubeClient(config: config, secrets: ClusterSecrets(token: "t"))
        await #expect(throws: KubeError.readOnly) { try await client.delete(.pod, name: "x", namespace: "d", options: DeleteOptions()) }
        await #expect(throws: KubeError.readOnly) { _ = try await client.patch(.deployment, name: "x", namespace: "d", patch: .merge(["a": 1])) }
        await #expect(throws: KubeError.readOnly) { _ = try await client.create(.configMap, namespace: "d", body: [:]) }
        #expect(throws: KubeError.readOnly) { try client.execWebSocket(namespace: "d", pod: "p", options: ExecOptions()) }
    }

    @Test func productionNeverSkipsTLS() {
        var c = ClusterConfig(name: "p", server: URL(string: "https://x")!, environment: .production, skipTLSVerify: true)
        #expect(!c.allowsInsecureTLS)
        #expect(c.insecureTLSBlocked)
        c.environment = .staging
        #expect(c.allowsInsecureTLS)
    }
}

@Suite struct ModelDecodingTests {
    @Test func podFixtureAndWatchFrame() throws {
        let json = #"""
        {"apiVersion":"v1","kind":"Pod","metadata":{"name":"api-1","namespace":"prod","uid":"u1","creationTimestamp":"2026-01-02T03:04:05Z","labels":{"app":"api"}},
         "spec":{"containers":[{"name":"api","image":"x:1","resources":{"limits":{"memory":"256Mi"}}}]},
         "status":{"phase":"Running","containerStatuses":[{"name":"api","ready":true,"restartCount":2,"state":{"running":{"startedAt":"2026-01-02T03:04:06.123456Z"}}}]}}
        """#
        let pod = try KubeJSON.decoder.decode(Pod.self, from: Data(json.utf8))
        #expect(pod.metadata.name == "api-1")
        #expect(pod.restartCount == 2)
        #expect(pod.spec.containers.first?.resources?.limits?.memoryBytes == 268_435_456)
        #expect(pod.spec.volumes.isEmpty)
    }

    @Test func listSkipsUndecodableItems() throws {
        let json = #"{"items":[{"metadata":{"name":"a"},"spec":{"template":{"spec":{}}}},{"metadata":{"name":"bad"},"spec":"oops"}]}"#
        let list = try KubeJSON.decoder.decode(KubeList<Deployment>.self, from: Data(json.utf8))
        #expect(list.items.count == 1)
        #expect(list.skippedItems == 1)
    }

    @Test func jsonValueRoundTrip() throws {
        let v: JSONValue = ["a": [1, 2.5, "x", nil, true], "b": ["c": "d"]]
        let back = try JSONValue.parse(try v.data())
        #expect(back == v)
        #expect(v.value(at: "b.c")?.stringValue == "d")
        var w = v
        w.setValue("z", at: "b.e.f")
        #expect(w.value(at: "b.e.f")?.stringValue == "z")
    }

    @Test func labelSelectorQuery() {
        var s = LabelSelector(matchLabels: ["app": "web", "tier": "fe"])
        s.matchExpressions = [LabelSelectorRequirement(key: "env", operator: "In", values: ["a", "b"])]
        #expect(s.queryString == "app=web,tier=fe,env in (a,b)")
    }
}
