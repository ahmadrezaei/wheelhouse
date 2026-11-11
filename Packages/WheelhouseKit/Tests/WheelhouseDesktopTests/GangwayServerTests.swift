#if os(macOS)
import Foundation
import Network
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// Answers every lookup with one fixed peer (the real resolver never finds the test's own process).
struct ObjectPeerResolver: PeerResolving {
    static let helm = PeerProcess(pid: 99, session: 700, group: 700)
    var peer: PeerProcess?
    func resolve(clientPort: UInt16, listenerPort: UInt16, scope: PeerSearchScope) -> PeerProcess? { peer }
}

@Suite("Gangway server", .serialized)
struct GangwayServerTests {
    @Test("a read is forwarded with a fresh head: Host and Authorization rewritten, hop-by-hop and the session token gone, base path kept")
    func forwardsReads() async throws {
        let rig = try await GangwayRig(basePath: "/k8s/clusters/c-x")
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        rig.upstream.handler = { _ in .json(200, #"{"kind":"PodList"}"#) }
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/api/v1/namespaces/shop/pods?limit=5", token: token,
                                     extra: "Connection: keep-alive\r\nKeep-Alive: timeout=5\r\nProxy-Authorization: Basic eA==\r\nProxy-Connection: x\r\nTE: trailers\r\nAccept: application/json\r\n"))
        let r = try #require(await c.readResponse())
        #expect(r.status == 200)
        #expect(r.body == #"{"kind":"PodList"}"#)
        let got = try #require(rig.upstream.received.first)
        #expect(got.path == "/k8s/clusters/c-x/api/v1/namespaces/shop/pods?limit=5")
        #expect(got.headers["host"] == "127.0.0.1:\(rig.upstream.port)")
        #expect(got.headers["authorization"] == "Bearer backend-token")
        #expect(!got.head.contains("whg_"))
        #expect(got.headers["accept"] == "application/json")
        for dropped in ["keep-alive", "proxy-authorization", "proxy-connection", "te", "connection"] { #expect(got.headers[dropped] == nil, Comment(rawValue: dropped)) }
        c.close()
    }

    @Test("without a backend token no Authorization header is sent (the session token is never forwarded)")
    func noBackendToken() async throws {
        let rig = try await GangwayRig(token: nil)
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/version", token: token))
        _ = try #require(await c.readResponse())
        let got = try #require(rig.upstream.received.first)
        #expect(got.headers["authorization"] == nil)
        #expect(!got.head.contains("whg_"))
    }

    @Test("keep-alive: several requests on one connection use one upstream connection")
    func keepAlive() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        for i in 0..<5 {
            try await c.send(rig.request("GET", "/api/v1/namespaces/n\(i)/pods", token: token))
            #expect(try #require(await c.readResponse()).status == 200)
        }
        #expect(rig.upstream.received.count == 5)
        #expect(rig.upstream.connections == 1)
    }

    @Test("authentication: no token, a wrong token and a revoked token are 401 with a readable Status")
    func authentication() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (handle, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send("GET /c/kc-test1/version HTTP/1.1\r\nHost: 127.0.0.1:\(rig.service.port!)\r\n\r\n")
        var r = try #require(await c.readResponse())
        #expect(r.status == 401)
        #expect(r.body.contains("Wheelhouse: no session token"))
        #expect(r.body.contains(#""kind":"Status""#))
        try await c.send(rig.request("GET", "/version", token: "whg_wrong"))
        #expect(try #require(await c.readResponse()).status == 401)
        try await c.send(rig.request("GET", "/version", token: token))
        #expect(try #require(await c.readResponse()).status == 200)
        rig.service.closeSession(handle)
        let d = try await rig.client()
        try await d.send(rig.request("GET", "/version", token: token))
        r = try #require(await d.readResponse())
        #expect(r.status == 401)
        #expect(rig.upstream.received.count == 1)
        #expect(!FileManager.default.fileExists(atPath: handle.directory.path))
    }

    @Test("the loopback leg is TLS 1.3 with ALPN http/1.1 and this launch's certificate; plain HTTP, TLS 1.2 and h2-only clients are refused")
    func tlsLeg() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (handle, token) = try await rig.open()
        let port = try #require(rig.service.port)
        let der = try #require(rig.service.context.tlsCertificateDER)
        // The kubeconfig trusts exactly that certificate and carries the token as the user's bearer token.
        let text = try String(contentsOf: handle.kubeconfig, encoding: .utf8)
        #expect(text.contains("https://127.0.0.1:\(port)/c/kc-test1\""))
        #expect(!text.contains("/\(token)\""))
        let c = try await RawClient(port: port, certificateDER: der)
        try await c.send(rig.request("GET", "/version", token: token))
        #expect(try #require(await c.readResponse()).status == 200)
        // Plain HTTP on the TLS port gets nothing usable.
        let plain = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let plainStream = NWStream(plain, queue: DispatchQueue(label: "plain"))
        try await plainStream.start()
        try await plainStream.send(Data("GET /c/kc-test1/version HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8))
        let reply = try? await plainStream.receive()
        #expect(reply == nil || !String(decoding: reply ?? Data(), as: UTF8.self).hasPrefix("HTTP/1.1"))
        plainStream.cancel()
        // TLS 1.2 only, and an h2-only ALPN, do not get a session.
        await #expect(throws: (any Error).self) { _ = try await RawClient(port: port, certificateDER: der, maxTLS: .TLSv12) }
        await #expect(throws: (any Error).self) { _ = try await RawClient(port: port, certificateDER: der, alpn: "h2") }
        // A client that does not trust this certificate cannot connect either.
        await #expect(throws: (any Error).self) { _ = try await RawClient(port: port, certificateDER: Data([1, 2, 3])) }
        #expect(rig.upstream.received.count == 1)
    }

    @Test("a request without the /c/<id> prefix (kubectl get --raw replaces the path) is the session's cluster; a prefix must match")
    func prefixOptional() async throws {
        let rig = try await GangwayRig(basePath: "/base")
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let port = try #require(rig.service.port)
        let c = try await rig.client()
        try await c.send("GET /version HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n\r\n")
        #expect(try #require(await c.readResponse()).status == 200)
        #expect(rig.upstream.received[0].path == "/base/version")
        try await c.send("GET /c/other/version HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n\r\n")
        #expect(try #require(await c.readResponse()).status == 403)
        // The token in the path is just a path now: it is not a credential.
        try await c.send("GET /c/kc-test1/\(token)/version HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer whg_wrong\r\n\r\n")
        #expect(try #require(await c.readResponse()).status == 401)
        #expect(rig.upstream.received.count == 1)
    }

    @Test("the path prefix must name the session's cluster, on a segment boundary")
    func clusterPrefix() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        for path in ["/c/other/version", "/c/kc-test1x/version", "/c/kc-test1/../x"] {
            try await c.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(rig.service.port!)\r\nAuthorization: Bearer \(token)\r\n\r\n")
            let r = try #require(await c.readResponse())
            #expect(r.status == 403 || r.status == 400, Comment(rawValue: path))
        }
        #expect(rig.upstream.received.isEmpty)
    }

    @Test("a wrong Host, an Origin header and a second session on one connection are refused")
    func hostOriginPinning() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, t1) = try await rig.open()
        let (_, t2) = try await rig.open()
        for text in [rig.request("GET", "/version", token: t1, host: "evil.example:80"), rig.request("GET", "/version", token: t1, extra: "Origin: http://evil.example\r\n")] {
            let c = try await rig.client()
            try await c.send(text)
            let r = try #require(await c.readResponse())
            #expect(r.status == 400)
            #expect(await c.isClosedByPeer())
        }
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/version", token: t1))
        #expect(try #require(await c.readResponse()).status == 200)
        try await c.send(rig.request("GET", "/version", token: t2))
        #expect(try #require(await c.readResponse()).status == 400)
        #expect(rig.upstream.received.count == 1)
    }

    @Test("framing errors are 400 and the connection closes: Content-Length with Transfer-Encoding, pipelining, bad paths")
    func framingErrors() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let port = rig.service.port!
        let both = "POST /c/kc-test1/api/v1/namespaces/a/configmaps HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}"
        let pipelined = rig.request("GET", "/version", token: token) + rig.request("GET", "/version", token: token)
        let doubleSlash = rig.request("GET", "/api/v1//pods", token: token)
        let dots = rig.request("GET", "/api/v1/namespaces/a/pods/../secrets", token: token)
        let encoded = rig.request("GET", "/api/v1/namespaces/a%2Fb/pods", token: token)
        let semicolon = rig.request("PATCH", "/api/v1/namespaces/a/configmaps/b?dryRun=All;x=1", token: token, body: "{}")
        for (name, text) in [("both", both), ("pipelined", pipelined), ("double slash", doubleSlash), ("dots", dots), ("encoded slash", encoded), ("semicolon", semicolon)] {
            let c = try await rig.client()
            try await c.send(text)
            let r = try #require(await c.readResponse(), Comment(rawValue: name))
            #expect(r.status == 400, Comment(rawValue: name))
            #expect(r.body.contains("Wheelhouse"))
            #expect(await c.isClosedByPeer(), Comment(rawValue: name))
        }
        #expect(rig.upstream.received.isEmpty)
    }

    @Test("a read-only cluster refuses changes with a readable 403, drains the body, and the connection stays usable")
    func readOnlyRefusal() async throws {
        let rig = try await GangwayRig(readOnly: true)
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/a/deployments/b", token: token, body: #"{"spec":{"replicas":9}}"#))
        let r = try #require(await c.readResponse())
        #expect(r.status == 403)
        #expect(r.body.contains("Wheelhouse: test-one is read-only. Allow changes in Cluster Settings."))
        try await c.send(rig.request("GET", "/api/v1/namespaces/a/pods", token: token))
        #expect(try #require(await c.readResponse()).status == 200)
        #expect(rig.upstream.received.count == 1)
        #expect(rig.upstream.received[0].method == "GET")
        let audit = rig.activity.entries
        #expect(audit.count == 1)
        #expect(audit[0].verb == "patch")
        #expect(audit[0].result.hasPrefix("refused"))
    }

    @Test("dry-runs and reviews pass a read-only cluster; a dry-run DELETE needs the body")
    func dryRunsOnReadOnly() async throws {
        let rig = try await GangwayRig(readOnly: true)
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send(rig.request("PATCH", "/api/v1/namespaces/a/configmaps/b?dryRun=All", token: token, body: "{}"))
        #expect(try #require(await c.readResponse()).status == 200)
        try await c.send(rig.request("POST", "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews", token: token, body: "{}"))
        #expect(try #require(await c.readResponse()).status == 200)
        try await c.send(rig.request("DELETE", "/api/v1/namespaces/a/configmaps/b", token: token, body: #"{"dryRun":["All"]}"#))
        #expect(try #require(await c.readResponse()).status == 200)
        // The body reaches the API server with a Content-Length (it was buffered).
        #expect(rig.upstream.received[2].body == Data(#"{"dryRun":["All"]}"#.utf8))
        try await c.send(rig.request("DELETE", "/api/v1/namespaces/a/configmaps/b?dryRun=All", token: token))
        #expect(try #require(await c.readResponse()).status == 403)
        try await c.send(rig.request("DELETE", "/api/v1/namespaces/a/configmaps/b", token: token, body: #"{"dryRun":["All"],"dryRun":[]}"#))
        #expect(try #require(await c.readResponse()).status == 403)
        #expect(rig.upstream.received.count == 3)
    }

    @Test("a delete body over 64 KB is 413 and the connection closes")
    func oversizedDelete() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let big = #"{"dryRun":["All"],"pad":""# + String(repeating: "a", count: 70_000) + #""}"#
        let c = try await rig.client()
        try await c.send(rig.request("DELETE", "/api/v1/namespaces/a/pods/b", token: token, body: big))
        let r = try #require(await c.readResponse())
        #expect(r.status == 413)
        #expect(rig.upstream.received.isEmpty)
    }

    @Test("a large refused body is fully answered (no reset before the 403 is read)")
    func refusedBodyDrained() async throws {
        let rig = try await GangwayRig(readOnly: true)
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let body = #"{"data":{"a":""# + String(repeating: "x", count: 300_000) + #""}}"#
        let c = try await rig.client()
        try await c.send(rig.request("PATCH", "/api/v1/namespaces/a/configmaps/b", token: token, body: body))
        let r = try #require(await c.readResponse())
        #expect(r.status == 403)
        try await c.send(rig.request("GET", "/version", token: token))
        #expect(try #require(await c.readResponse()).status == 200)
    }

    @Test("a streamed body is forwarded with its length, and a chunked body is written again")
    func bodies() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        let body = String(repeating: "y", count: 200_000)
        try await c.send(rig.request("POST", "/api/v1/namespaces/a/configmaps", token: token, body: body))
        #expect(try #require(await c.readResponse()).status == 200)
        #expect(rig.upstream.received[0].body.count == 200_000)
        let port = rig.service.port!
        try await c.send("POST /c/kc-test1/api/v1/namespaces/a/configmaps HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n5;x=1\r\nhello\r\n0\r\n\r\n")
        #expect(try #require(await c.readResponse()).status == 200)
        #expect(String(decoding: rig.upstream.received[1].body, as: UTF8.self) == "5\r\nhello\r\n0\r\n\r\n")
        #expect(rig.upstream.received[1].headers["transfer-encoding"] == "chunked")
    }

    @Test("Production: a change is held, declined means 403 not confirmed, approved means forwarded")
    func productionHold() async throws {
        let approve = Mutex(false)
        let confirmer = ScriptedConfirmer { _ in approve.withLock { $0 } }
        let rig = try await GangwayRig(environment: .production, confirmer: confirmer)
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/a/deployments/web", token: token, body: "{}"))
        var r = try #require(await c.readResponse())
        #expect(r.status == 403)
        #expect(r.body.contains("Wheelhouse: change not confirmed"))
        #expect(rig.upstream.received.isEmpty)                      // nothing was sent upstream while held or declined
        approve.withLock { $0 = true }
        try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/a/deployments/web", token: token, body: "{}"))
        r = try #require(await c.readResponse())
        #expect(r.status == 200)
        #expect(rig.upstream.received.count == 1)
        let sheet = try #require(confirmer.sheets.all.last)
        #expect(sheet.kind == .requests)
        #expect(sheet.requiresTyping)
        #expect(sheet.holds[0].path == "/apis/apps/v1/namespaces/a/deployments/web")
        #expect(sheet.holds[0].method == "PATCH")
        // Reads, reviews and dry-runs never prompt.
        let before = confirmer.sheets.all.count
        try await c.send(rig.request("GET", "/api/v1/pods", token: token))
        _ = try #require(await c.readResponse())
        try await c.send(rig.request("PATCH", "/api/v1/namespaces/a/configmaps/b?dryRun=All", token: token, body: "{}"))
        _ = try #require(await c.readResponse())
        #expect(confirmer.sheets.all.count == before)
    }

    @Test("an approval covers exactly the requests listed in the sheet; later ones need their own")
    func batchApproval() async throws {
        let confirmer = ScriptedConfirmer { _ in true }
        let rig = try await GangwayRig(environment: .production, confirmer: confirmer, window: .milliseconds(300))
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let a = try await rig.client(), b = try await rig.client()
        try await a.send(rig.request("POST", "/api/v1/namespaces/a/configmaps", token: token, body: "{}"))
        try await b.send(rig.request("POST", "/api/v1/namespaces/a/secrets", token: token, body: "{}"))
        #expect(try #require(await a.readResponse()).status == 200)
        #expect(try #require(await b.readResponse()).status == 200)
        #expect(confirmer.sheets.all.count == 1, "both arrived within the batching window")
        #expect(confirmer.sheets.all[0].holds.count == 2)
        try await a.send(rig.request("POST", "/api/v1/namespaces/a/configmaps", token: token, body: "{}"))
        #expect(try #require(await a.readResponse()).status == 200)
        #expect(confirmer.sheets.all.count == 2, "a later identical request is a new request with its own sheet")
    }

    @Test("a cluster that turns read-only while a request is held refuses it after the approval")
    func readOnlyDuringHold() async throws {
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let entered = Mutex(false)
        let rigBox = Mutex<GangwayRig?>(nil)
        let confirmer = ScriptedConfirmer { _ in
            entered.withLock { $0 = true }
            await withCheckedContinuation { c in gate.withLock { $0 = c } }
            return true
        }
        let rig = try await GangwayRig(environment: .production, confirmer: confirmer)
        rigBox.withLock { $0 = rig }
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send(rig.request("POST", "/api/v1/namespaces/a/configmaps", token: token, body: "{}"))
        for _ in 0..<200 where !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
        rig.setCluster { $0.readOnly = true }
        gate.withLock { $0 }?.resume()
        let r = try #require(await c.readResponse())
        #expect(r.status == 403)
        #expect(r.body.contains("read-only"))
        #expect(rig.upstream.received.isEmpty)
    }

    @Test("Impersonate-* is refused on Production and read-only clusters, logged, and passes (logged) elsewhere")
    func impersonation() async throws {
        let prod = try await GangwayRig(environment: .production)
        defer { prod.stop() }
        let (_, token) = try await prod.open()
        let c = try await prod.client()
        try await c.send(prod.request("GET", "/api/v1/namespaces/a/pods", token: token, extra: "Impersonate-User: alice\r\nImpersonate-Group: system:masters\r\n"))
        let r = try #require(await c.readResponse())
        #expect(r.status == 403)
        #expect(r.body.contains("Wheelhouse: impersonation is not allowed on test-one"))
        #expect(prod.upstream.received.isEmpty)
        let entry = try #require(prod.activity.entries.first)
        #expect(entry.result.contains("Impersonate-User=alice"))
        #expect(entry.result.hasPrefix("refused"))

        let dev = try await GangwayRig()
        defer { dev.stop() }
        let (_, devToken) = try await dev.open()
        let d = try await dev.client()
        try await d.send(dev.request("GET", "/api/v1/namespaces/a/pods", token: devToken, extra: "Impersonate-User: alice\r\n"))
        #expect(try #require(await d.readResponse()).status == 200)
        try await Task.sleep(for: .milliseconds(100))
        #expect(dev.activity.entries.count == 2)                      // forwarded, then the response status
        #expect(dev.activity.entries.allSatisfy { $0.result.contains("Impersonate-User=alice") })
        #expect(dev.upstream.received[0].headers["impersonate-user"] == "alice")
    }

    @Test("audit: changes, streams and proxy requests are recorded with the status; plain reads are not")
    func audit() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        rig.upstream.handler = { $0.method == "DELETE" ? .json(404, "{}") : .json(200, "{}") }
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/api/v1/pods", token: token)); _ = await c.readResponse()
        try await c.send(rig.request("DELETE", "/api/v1/namespaces/a/pods/gone", token: token, body: #"{"gracePeriodSeconds":0}"#)); _ = await c.readResponse()
        try await c.send(rig.request("GET", "/api/v1/namespaces/a/pods/p/proxy/metrics", token: token)); _ = await c.readResponse()
        try await Task.sleep(for: .milliseconds(100))
        let entries = rig.activity.entries
        #expect(entries.map(\.verb) == ["delete", "delete", "proxy", "proxy"])
        #expect(entries.map(\.result) == ["forwarded", "HTTP 404", "forwarded", "HTTP 200"])
        #expect(entries[0].object == "a/pods/gone")
        // Bodies are never recorded.
        #expect(!entries.contains { ($0.object ?? "").contains("gracePeriod") || $0.result.contains("gracePeriod") })
    }

    @Test("an upgraded stream becomes a raw pipe and closes when the cluster becomes read-only")
    func streamsCloseOnReadOnly() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        rig.upstream.handler = { _ in .upgradeEcho }
        let c = try await rig.client()
        try await c.send(rig.request("POST", "/api/v1/namespaces/a/pods/p/exec?command=sh&stdin=true&tty=true", token: token, extra: "Connection: Upgrade\r\nUpgrade: websocket\r\n"))
        let first = try #require(await c.readBytes(count: 12))
        #expect(String(decoding: first, as: UTF8.self) == "HTTP/1.1 101")
        // raw echo both ways
        try await c.send(Data([1, 2, 3, 4, 5]))
        for _ in 0..<5 { _ = await c.readBytes(count: 0) }
        #expect(rig.service.context.openStreamCount == 1)
        rig.setCluster { $0.readOnly = true }
        #expect(await c.isClosedByPeer())
        #expect(rig.service.context.openStreamCount == 0)
        #expect(rig.activity.entries.contains { $0.verb == "stream closed" && $0.result.contains("read-only") })
    }

    @Test("streams close when the app locks, when the cluster becomes Production, and when the session ends")
    func streamsCloseOnLockProductionRevoke() async throws {
        for trigger in ["lock", "production", "revoke"] {
            let rig = try await GangwayRig()
            defer { rig.stop() }
            let (handle, token) = try await rig.open()
            rig.upstream.handler = { _ in .upgradeEcho }
            let c = try await rig.client()
            try await c.send(rig.request("GET", "/api/v1/namespaces/a/pods/p/portforward", token: token, extra: "Connection: Upgrade\r\nUpgrade: websocket\r\n"))
            _ = try #require(await c.readBytes(count: 12))
            #expect(rig.service.context.openStreamCount == 1)
            switch trigger {
            case "lock": rig.service.lock()
            case "production": rig.setCluster { $0.environment = .production }
            default: rig.service.closeSession(handle)
            }
            #expect(await c.isClosedByPeer(), Comment(rawValue: trigger))
        }
    }

    @Test("a locked app refuses new streams and changes but keeps serving reads")
    func locked() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        rig.service.lock()
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/api/v1/pods", token: token))
        #expect(try #require(await c.readResponse()).status == 200)
        try await c.send(rig.request("POST", "/api/v1/namespaces/a/configmaps", token: token, body: "{}"))
        let r = try #require(await c.readResponse())
        #expect(r.status == 403)
        #expect(r.body.contains("locked"))
        rig.service.unlock()
        try await c.send(rig.request("POST", "/api/v1/namespaces/a/configmaps", token: token, body: "{}"))
        #expect(try #require(await c.readResponse()).status == 200)
    }

    @Test("revoking a session closes its running watch")
    func revokeClosesWatch() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (handle, token) = try await rig.open()
        rig.upstream.handler = { _ in .hang }
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/api/v1/pods?watch=true", token: token))
        for _ in 0..<100 where rig.upstream.received.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        rig.service.closeSession(handle)
        #expect(await c.isClosedByPeer())
    }

    @Test("dry-run-only sessions pass reads and dry-runs and refuse changes, streams and proxies without a sheet")
    func dryRunOnly() async throws {
        let confirmer = ScriptedConfirmer { _ in true }
        let rig = try await GangwayRig(environment: .production, confirmer: confirmer)
        defer { rig.stop() }
        let (_, token) = try await rig.open(scope: .dryRunOnly)
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/api/v1/pods", token: token)); #expect(try #require(await c.readResponse()).status == 200)
        try await c.send(rig.request("PATCH", "/api/v1/namespaces/a/configmaps/b?dryRun=All", token: token, body: "{}")); #expect(try #require(await c.readResponse()).status == 200)
        try await c.send(rig.request("PATCH", "/api/v1/namespaces/a/configmaps/b", token: token, body: "{}")); #expect(try #require(await c.readResponse()).status == 403)
        try await c.send(rig.request("GET", "/api/v1/namespaces/a/pods/p/proxy/x", token: token)); #expect(try #require(await c.readResponse()).status == 403)
        #expect(confirmer.sheets.all.isEmpty)
    }

    @Test("an object session lets the reviewed changes through and refuses everything else, never with a sheet")
    func objectSession() async throws {
        let confirmer = ScriptedConfirmer { _ in true }
        let rig = try await GangwayRig(environment: .production, confirmer: confirmer, resolver: ObjectPeerResolver(peer: ObjectPeerResolver.helm))
        defer { rig.stop() }
        let (handle, token) = try await rig.open(scope: .objects, binding: .isolatedGroup(700))
        rig.service.grants.setObjects(session: handle.session, objects: [GrantedObject(group: "apps", resource: "deployments", namespace: "shop", name: "web")])
        let c = try await rig.client()
        try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/shop/deployments/web", token: token, body: "{}")); #expect(try #require(await c.readResponse()).status == 200)
        try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/shop/deployments/other", token: token, body: "{}"))
        let r = try #require(await c.readResponse())
        #expect(r.status == 403)
        #expect(r.body.contains("not part of the reviewed operation"))
        #expect(confirmer.sheets.all.isEmpty)
    }

    @Test("an object session refuses a request from any other process, reads included")
    func objectSessionWrongPeer() async throws {
        for peer in [nil, PeerProcess(pid: 5, session: 700, group: 701), PeerProcess(pid: 5, session: 1, group: 700)] {
            let rig = try await GangwayRig(resolver: ObjectPeerResolver(peer: peer))
            defer { rig.stop() }
            let (handle, token) = try await rig.open(scope: .objects, binding: .isolatedGroup(700))
            rig.service.grants.setObjects(session: handle.session, objects: [GrantedObject(group: "apps", resource: "deployments", namespace: "shop", name: "web")])
            let c = try await rig.client()
            try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/shop/deployments/web", token: token, body: "{}"))
            let r = try #require(await c.readResponse())
            #expect(r.status == 403 && r.body.contains("does not come from the reviewed operation"))
            try await c.send(rig.request("GET", "/api/v1/namespaces/shop/pods", token: token))
            #expect(try #require(await c.readResponse()).status == 403)
            #expect(rig.upstream.received.isEmpty)
        }
    }

    @Test("an object session covers nothing before it is bound to its process, and works after")
    func objectSessionBindLater() async throws {
        let rig = try await GangwayRig(resolver: ObjectPeerResolver(peer: ObjectPeerResolver.helm))
        defer { rig.stop() }
        let (handle, token) = try await rig.open(scope: .objects, binding: .none)
        rig.service.grants.setObjects(session: handle.session, objects: [GrantedObject(group: "apps", resource: "deployments", namespace: "shop", name: "web")])
        let c = try await rig.client()
        try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/shop/deployments/web", token: token, body: "{}"))
        #expect(try #require(await c.readResponse()).status == 403)
        #expect(handle.session.bindIsolatedGroup(700))
        try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/shop/deployments/web", token: token, body: "{}"))
        #expect(try #require(await c.readResponse()).status == 200, "the same connection is looked up again once bound")
    }

    @Test("a create under an object grant is matched by the name in its body")
    func objectSessionCreate() async throws {
        let rig = try await GangwayRig(resolver: ObjectPeerResolver(peer: ObjectPeerResolver.helm))
        defer { rig.stop() }
        let (handle, token) = try await rig.open(scope: .objects, binding: .isolatedGroup(700))
        rig.service.grants.setObjects(session: handle.session, objects: [
            GrantedObject(resource: "configmaps", namespace: "shop", name: "listed"),
            GrantedObject(resource: "secrets", namespace: "shop", namePrefix: "sh.helm.release.v1.web.v"),
        ])
        let c = try await rig.client()
        func post(_ path: String, _ json: String, extra: String = "") async throws -> Int {
            try await c.send(rig.request("POST", path, token: token, extra: extra, body: json))
            return try #require(await c.readResponse()).status
        }
        #expect(try await post("/api/v1/namespaces/shop/configmaps", #"{"metadata":{"name":"listed"}}"#) == 200)
        #expect(try await post("/api/v1/namespaces/shop/configmaps", #"{"metadata":{"name":"unlisted"}}"#) == 403)
        #expect(try await post("/api/v1/namespaces/shop/configmaps", #"{"metadata":{"name":"listed","name":"unlisted"}}"#) == 403)
        #expect(try await post("/api/v1/namespaces/shop/configmaps", #"{"metadata":{"generateName":"listed"}}"#) == 403)
        #expect(try await post("/api/v1/namespaces/shop/configmaps", "not json") == 403)
        #expect(try await post("/api/v1/namespaces/shop/secrets", #"{"metadata":{"name":"sh.helm.release.v1.web.v3"}}"#) == 200)
        #expect(try await post("/api/v1/namespaces/shop/secrets", #"{"metadata":{"name":"sh.helm.release.v1.api.v3"}}"#) == 403)
        #expect(try await post("/api/v1/namespaces/shop/configmaps", #"{"metadata":{"name":"listed"}}"#, extra: "Impersonate-User: root\r\n") == 403)
        #expect(rig.upstream.received.count == 2)
    }

    @Test("a create body over 3 MB gets a readable 413")
    func objectSessionBigCreate() async throws {
        let rig = try await GangwayRig(resolver: ObjectPeerResolver(peer: ObjectPeerResolver.helm))
        defer { rig.stop() }
        let (handle, token) = try await rig.open(scope: .objects, binding: .isolatedGroup(700))
        rig.service.grants.setObjects(session: handle.session, objects: [GrantedObject(resource: "configmaps", namespace: "shop", name: "listed")])
        let c = try await rig.client()
        let big = #"{"metadata":{"name":"listed"},"data":{"x":""# + String(repeating: "a", count: GrantBody.maxCreateBody) + #""}}"#
        try await c.send(rig.request("POST", "/api/v1/namespaces/shop/configmaps", token: token, body: big))
        #expect(try #require(await c.readResponse()).status == 413)
        #expect(rig.upstream.received.isEmpty)
    }

    @Test("a real child started suspended in its own session is bound before it runs; a sibling process is refused")
    func objectSessionRealChild() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (handle, token) = try await rig.open(scope: .objects, binding: .none)
        rig.service.grants.setObjects(session: handle.session, objects: [GrantedObject(group: "apps", resource: "deployments", namespace: "shop", name: "web")])
        let url = "https://127.0.0.1:\(try #require(rig.service.port))/c/\(rig.clusterID)/apis/apps/v1/namespaces/shop/deployments/web"
        let args = ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "-X", "PATCH", "-H", "Authorization: Bearer \(token)", "-H", "Content-Type: application/merge-patch+json", "-d", "{}", url]
        let env = ["PATH": "/usr/bin:/bin"]
        let session = handle.session
        let inGroup = ProcessSpec(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: args, environment: env, timeout: .seconds(20), newSession: true,
                                  spawnGate: { session.bindIsolatedGroup($0) })
        let ok = try await Subprocess.run(inGroup)
        #expect(ok.stdoutString == "200", Comment(rawValue: ok.stdoutString + ok.stderrString))
        let sibling = try await Subprocess.run(ProcessSpec(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: args, environment: env, timeout: .seconds(20)))
        #expect(sibling.stdoutString == "403", "a process outside the bound group is refused")
        #expect(rig.upstream.received.count == 1)
        // A second bind (another run started for the same session) is refused and that child never runs.
        let again = ProcessSpec(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: args, environment: env, timeout: .seconds(20), newSession: true,
                                spawnGate: { session.bindIsolatedGroup($0) })
        let killed = try await Subprocess.run(again)
        #expect(killed.exit.signal == SIGKILL)
    }

    @Test("an expired object grant, another session's token and a revoked session are refused")
    func objectSessionLifetimes() async throws {
        let rig = try await GangwayRig(resolver: ObjectPeerResolver(peer: ObjectPeerResolver.helm))
        defer { rig.stop() }
        let (a, tokenA) = try await rig.open(scope: .objects, binding: .isolatedGroup(700))
        let (_, tokenB) = try await rig.open(scope: .objects, binding: .isolatedGroup(700))
        let objects: Set = [GrantedObject(group: "apps", resource: "deployments", namespace: "shop", name: "web")]
        rig.service.grants.setObjects(session: a.session, objects: objects)
        let path = "/apis/apps/v1/namespaces/shop/deployments/web"
        let b = try await rig.client()
        try await b.send(rig.request("PATCH", path, token: tokenB, body: "{}"))
        #expect(try #require(await b.readResponse()).status == 403, "session B has no grant")
        let c = try await rig.client()
        rig.service.grants.setObjects(session: a.session, objects: objects, lifetime: -1)
        try await c.send(rig.request("PATCH", path, token: tokenA, body: "{}"))
        #expect(try #require(await c.readResponse()).status == 403, "expired")
        rig.service.grants.setObjects(session: a.session, objects: objects)
        rig.service.closeSession(a)
        let d = try await rig.client()
        try await d.send(rig.request("PATCH", path, token: tokenA, body: "{}"))
        #expect(try #require(await d.readResponse()).status == 401, "the helm run ended")
    }

    @Test("a command grant covers a held change when the peer is the bound foreground job")
    func commandGrantThroughSheet() async throws {
        struct FixedResolver: PeerResolving {
            func resolve(clientPort: UInt16, listenerPort: UInt16, scope: PeerSearchScope) -> PeerProcess? { PeerProcess(pid: 99, session: 500, group: 700) }
        }
        let confirmer = ScriptedConfirmer { _ in true }
        let rig = try await GangwayRig(environment: .production, confirmer: confirmer, resolver: FixedResolver())
        defer { rig.stop() }
        let (handle, token) = try await rig.open(binding: .pty(device: 0, session: 500, foreground: { 700 }))
        handle.session.reportedCommand = ReportedCommand(id: "c1", line: "kubectl rollout restart deployment/web")
        let c = try await rig.client()
        try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/a/deployments/web", token: token, body: "{}"))
        #expect(try #require(await c.readResponse()).status == 200)
        #expect(confirmer.sheets.all.count == 1)
        #expect(confirmer.sheets.all[0].kind == .command(line: "kubectl rollout restart deployment/web"))
        // The command's next change is covered without a sheet; a stream still gets its own.
        try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/a/deployments/api", token: token, body: "{}"))
        #expect(try #require(await c.readResponse()).status == 200)
        #expect(confirmer.sheets.all.count == 1)
        // After the command ends the grant is gone.
        rig.service.grants.endCommand(session: handle.session, commandID: "c1")
        handle.session.reportedCommand = nil
        try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/a/deployments/api", token: token, body: "{}"))
        #expect(try #require(await c.readResponse()).status == 200)
        #expect(confirmer.sheets.all.count == 2)
        #expect(confirmer.sheets.all[1].kind == .requests)
    }

    @Test("an approved proxy request on Production is forwarded (an approval covers exactly that request, whatever its class)")
    func approvedProxy() async throws {
        let confirmer = ScriptedConfirmer { _ in true }
        let rig = try await GangwayRig(environment: .production, confirmer: confirmer)
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/api/v1/namespaces/a/services/proxy/proxy/admin", token: token))
        #expect(try #require(await c.readResponse()).status == 200)
        #expect(confirmer.sheets.all.count == 1)
        #expect(!confirmer.sheets.all[0].requiresTyping, "a GET proxy is a button, not typed")
        try await c.send(rig.request("POST", "/api/v1/namespaces/a/pods/p/proxy/do", token: token, body: "{}"))
        #expect(try #require(await c.readResponse()).status == 200)
        #expect(confirmer.sheets.all[1].requiresTyping)
    }

    @Test("an object session refuses a change outside its grant on a non-Production cluster too")
    func objectSessionDevelopment() async throws {
        let rig = try await GangwayRig(resolver: ObjectPeerResolver(peer: ObjectPeerResolver.helm))
        defer { rig.stop() }
        let (handle, token) = try await rig.open(scope: .objects, binding: .isolatedGroup(700))
        rig.service.grants.setObjects(session: handle.session, objects: [GrantedObject(group: "apps", resource: "deployments", namespace: "shop", name: "web")])
        let c = try await rig.client()
        try await c.send(rig.request("PATCH", "/apis/apps/v1/namespaces/shop/deployments/web", token: token, body: "{}"))
        #expect(try #require(await c.readResponse()).status == 200)
        try await c.send(rig.request("DELETE", "/api/v1/namespaces/shop/configmaps/x", token: token))
        #expect(try #require(await c.readResponse()).status == 403)
        #expect(rig.upstream.received.count == 1)
    }

    @Test("the app locking while a request is held refuses it after the approval; nothing reaches the API server")
    func lockDuringHold() async throws {
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let entered = Mutex(false)
        let confirmer = ScriptedConfirmer { _ in
            entered.withLock { $0 = true }
            await withCheckedContinuation { c in gate.withLock { $0 = c } }
            return true
        }
        let rig = try await GangwayRig(environment: .production, confirmer: confirmer)
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send(rig.request("POST", "/api/v1/namespaces/a/configmaps", token: token, body: "{}"))
        for _ in 0..<200 where !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
        rig.service.lock()
        gate.withLock { $0 }?.resume()
        let r = try #require(await c.readResponse())
        #expect(r.status == 403)
        #expect(rig.upstream.received.isEmpty)
    }

    @Test("an upgrade is only accepted as the first request on a connection")
    func upgradeNeedsFreshConnection() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/version", token: token))
        _ = try #require(await c.readResponse())
        try await c.send(rig.request("GET", "/api/v1/namespaces/a/pods/p/portforward", token: token, extra: "Connection: Upgrade\r\nUpgrade: websocket\r\n"))
        let r = try #require(await c.readResponse())
        #expect(r.status == 400)
        #expect(await c.isClosedByPeer())
        #expect(rig.upstream.received.count == 1)
    }

    @Test("an upgrade that is not answered with 101 closes the connection")
    func upgradeRefusedUpstream() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        rig.upstream.handler = { _ in .json(400, "{}") }
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/api/v1/namespaces/a/pods/p/portforward", token: token, extra: "Connection: Upgrade\r\nUpgrade: websocket\r\n"))
        #expect(try #require(await c.readResponse()).status == 400)
        #expect(await c.isClosedByPeer())
    }

    @Test("a silent connection and a connection that only gets refused are closed by the idle deadline")
    func silentConnections() async throws {
        let rig = try await GangwayRig(idleTimeout: .seconds(1))
        defer { rig.stop() }
        _ = try await rig.open()
        let silent = try await rig.client()
        #expect(await silent.isClosedByPeer(timeout: .seconds(4)))
        let refused = try await rig.client()
        try await refused.send(rig.request("GET", "/version", token: "whg_wrong"))
        #expect(try #require(await refused.readResponse()).status == 401)
        #expect(await refused.isClosedByPeer(timeout: .seconds(4)))
    }

    @Test("a confirmer that ignores cancellation still ends at the hold timeout")
    func holdTimeout() async throws {
        let confirmer = ScriptedConfirmer { _ in
            // Never answers, and does not look at cancellation.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return true
        }
        let rig = try await GangwayRig(environment: .production, confirmer: confirmer, holdTimeout: .seconds(1))
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        let start = ContinuousClock.now
        try await c.send(rig.request("POST", "/api/v1/namespaces/a/configmaps", token: token, body: "{}"))
        let r = try #require(await c.readResponse(timeout: .seconds(8)))
        #expect(r.status == 403 && r.body.contains("not confirmed"))
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("stale session folders from a run that did not quit cleanly are removed when Gangway starts")
    func staleSweep() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let stale = rig.paths.sessions.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stale.appending(path: "kubeconfig"))
        let (handle, _) = try await rig.open()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: handle.kubeconfig.path))
    }

    @Test("a declined stream is not asked again for the fallback attempt that follows at once")
    func declinedStreamMemory() async throws {
        let confirmer = ScriptedConfirmer { _ in false }
        let rig = try await GangwayRig(environment: .production, confirmer: confirmer)
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        for method in ["GET", "POST", "POST"] {
            let c = try await rig.client()
            try await c.send(rig.request(method, "/api/v1/namespaces/a/pods/p/exec?command=ls&stdout=true", token: token, extra: "Connection: Upgrade\r\nUpgrade: websocket\r\n"))
            #expect(try #require(await c.readResponse()).status == 403)
        }
        #expect(confirmer.sheets.all.count == 1)
        // Another path is a new question.
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/api/v1/namespaces/a/pods/q/exec?command=ls", token: token, extra: "Connection: Upgrade\r\nUpgrade: websocket\r\n"))
        _ = await c.readResponse()
        #expect(confirmer.sheets.all.count == 2)
    }

    @Test("a mutation is audited when it is forwarded, even if the next request is pipelined behind it or the client leaves at once")
    func auditAtForwardTime() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        rig.upstream.handler = { $0.method == "PATCH" ? .silent : .json(200, "{}") }
        // 1. A mutation whose response never comes, followed by the client closing at once.
        let a = try await rig.client()
        try await a.send(rig.request("PATCH", "/apis/apps/v1/namespaces/a/deployments/web", token: token, body: "{}"))
        for _ in 0..<100 where rig.upstream.received.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        a.close()
        try await Task.sleep(for: .milliseconds(300))
        let first = rig.activity.entries.filter { $0.verb == "patch" }
        #expect(first.first?.result == "forwarded")
        #expect(first.contains { $0.result.hasPrefix("forwarded, no response") })
        // 2. A second request on the same connection while the first has no status yet: the first is closed out, not overwritten.
        let mark = rig.activity.entries.count
        rig.upstream.reset()
        rig.upstream.handler = { $0.method == "PATCH" ? .silent : .json(200, "{}") }
        let b = try await rig.client()
        try await b.send(rig.request("PATCH", "/apis/apps/v1/namespaces/a/deployments/web", token: token, body: "{}"))
        for _ in 0..<100 where rig.upstream.received.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await b.send(rig.request("DELETE", "/api/v1/namespaces/a/configmaps/c", token: token, body: #"{"gracePeriodSeconds":0}"#))
        try await Task.sleep(for: .milliseconds(300))
        let entries = Array(rig.activity.entries.dropFirst(mark))
        #expect(entries.contains { $0.verb == "patch" && $0.result == "forwarded" })
        #expect(entries.contains { $0.verb == "patch" && $0.result.hasPrefix("forwarded, response status not seen") })
        #expect(entries.contains { $0.verb == "delete" && $0.result == "forwarded" })
        b.close()
    }

    @Test("a request refused at the last look (the session ended while it waited) is not logged as forwarded")
    func abortedIsNotForwarded() async throws {
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let entered = Mutex(false)
        let confirmer = ScriptedConfirmer { _ in
            entered.withLock { $0 = true }
            await withCheckedContinuation { c in gate.withLock { $0 = c } }
            return true
        }
        let rig = try await GangwayRig(environment: .production, confirmer: confirmer)
        defer { rig.stop() }
        let (handle, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send(rig.request("POST", "/api/v1/namespaces/a/configmaps", token: token, body: "{}"))
        for _ in 0..<200 where !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
        rig.service.closeSession(handle)
        gate.withLock { $0 }?.resume()
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.upstream.received.isEmpty)
        #expect(!rig.activity.entries.contains { $0.result.hasPrefix("forwarded") })
    }

    @Test("a replaced credential, or a changed server, ends the sessions of that cluster; a read-only toggle does not")
    func credentialChangeRevokes() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (handle, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/version", token: token))
        _ = try #require(await c.readResponse())
        rig.setCluster { $0.readOnly = true }
        #expect(!handle.session.isRevoked)
        rig.setCluster { $0.readOnly = false }
        #expect(!handle.session.isRevoked)
        rig.setCluster { $0.server = URL(string: "http://127.0.0.1:1")! }
        #expect(handle.session.isRevoked)
        #expect(await c.isClosedByPeer())
    }

    @Test("an idle keep-alive connection is closed after the idle timeout; active ones are not")
    func idleTimeout() async throws {
        let rig = try await GangwayRig(idleTimeout: .seconds(1))
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        try await c.send(rig.request("GET", "/version", token: token))
        _ = try #require(await c.readResponse())
        try await Task.sleep(for: .milliseconds(600))
        try await c.send(rig.request("GET", "/version", token: token))
        _ = try #require(await c.readResponse())
        try await Task.sleep(for: .milliseconds(600))
        try await c.send(rig.request("GET", "/version", token: token))
        _ = try #require(await c.readResponse(), "traffic re-arms the deadline")
        #expect(await c.isClosedByPeer(timeout: .seconds(4)))
        // A watch is exempt.
        rig.upstream.handler = { _ in .hang }
        let w = try await rig.client()
        try await w.send(rig.request("GET", "/api/v1/pods?watch=true", token: token))
        #expect(!(await w.isClosedByPeer(timeout: .seconds(2))))
    }

    @Test("the port is persisted and reused; a busy port is replaced and persisted; nothing else can bind it")
    func persistedPort() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let port = try await rig.service.start()
        #expect((49152...65535).contains(Int(port)))
        let saved = GangwayServer.persistedPort(rig.paths.root.appending(path: "gangway.json"))
        #expect(saved == port)
        // A second server on the same persisted file finds the port busy and picks another.
        let second = try await GangwayRig()
        defer { second.stop() }
        let file = rig.paths.root.appending(path: "gangway.json")
        let other = GangwayServer(context: second.service.context, portFile: file)
        let secondPort = try await other.start(identity: try LoopbackIdentity.make())
        defer { other.stop() }
        #expect(secondPort != port)
        #expect(GangwayServer.persistedPort(file) == secondPort)
        // A restart on the file reuses the last port.
        other.stop()
        try await Task.sleep(for: .milliseconds(500))      // the listener releases its port asynchronously
        let again = GangwayServer(context: second.service.context, portFile: file)
        defer { again.stop() }
        #expect(try await again.start(identity: try LoopbackIdentity.make()) == secondPort)
        // Plain TCP bind on the port fails while Gangway holds it.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(rc != 0)
    }

    @Test("the listener is bound to loopback only")
    func loopbackOnly() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let port = try await rig.service.start()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        #expect(getifaddrs(&ifaddr) == 0)
        defer { freeifaddrs(ifaddr) }
        var tried = 0
        var cursor = ifaddr
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let ip = addr.sin_addr.s_addr
            guard ip != inet_addr("127.0.0.1"), ip != 0 else { continue }
            tried += 1
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            addr.sin_port = port.bigEndian
            let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            #expect(rc != 0, "the listener must not answer on a non-loopback address")
        }
        _ = tried
    }

    @Test("starting is lazy: a service that was never asked has no listener")
    func lazy() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        #expect(!rig.service.isRunning)
        #expect(rig.service.port == nil)
        _ = try await rig.open()
        #expect(rig.service.isRunning)
    }

    @Test("the safety gate refuses a session and a connection for a host that is not allowed")
    func gateRefuses() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let blocked = ClusterConfig(id: "kc-blocked", name: "prod", server: URL(string: "https://prod.example.com:6443")!)
        rig.provider.set(blocked)
        await #expect(throws: DevSafetyError.self) { try await rig.service.openSession(clusterID: "kc-blocked", origin: .harness("x")) }
        // And the connector refuses on its own, at connect time.
        let connector = UpstreamConnector(gate: { DevSafetyPolicy(isActive: true, allowedHosts: ["127.0.0.1"]) })
        await #expect(throws: DevSafetyError.self) { try await connector.connect(GangwayUpstream(config: blocked, secrets: ClusterSecrets())) }
        // Plain HTTP to Production and an unchecked cluster are refused too.
        var prod = ClusterConfig(id: "p", name: "p", server: URL(string: "http://127.0.0.1:1")!, environment: .production)
        await #expect(throws: UpstreamError.plainHTTPOnProduction) { try await connector.connect(GangwayUpstream(config: prod, secrets: ClusterSecrets())) }
        prod.environment = .development
        await #expect(throws: UpstreamError.contactHeld) { try await connector.connect(GangwayUpstream(config: prod, secrets: ClusterSecrets(), contactHeld: true)) }
    }
}
#endif
