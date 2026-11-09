#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

private func parse(_ text: String) throws -> (head: HTTPRequestHead, consumed: Int)? {
    try HTTPHeadParser.parse(Data(text.utf8))
}

@Suite("HTTP head parser")
struct HTTPHeadParserTests {
    private let ok = "GET /api/v1/pods?limit=5 HTTP/1.1\r\nHost: 127.0.0.1:50000\r\nAuthorization: Bearer whg_x\r\nAccept: application/json\r\n\r\n"

    @Test("a well-formed head")
    func good() throws {
        let (head, consumed) = try #require(try parse(ok))
        #expect(head.method == "GET")
        #expect(head.rawPath == "/api/v1/pods")
        #expect(head.rawQuery == "limit=5")
        #expect(head.value("authorization") == "Bearer whg_x")
        #expect(consumed == ok.utf8.count)
    }

    @Test("an incomplete head waits for more bytes")
    func incomplete() throws {
        #expect(try parse("GET / HTTP/1.1\r\nHost: a\r\n") == nil)
        #expect(try parse("GET / HT") == nil)
    }

    @Test("bytes after the head are not consumed")
    func trailing() throws {
        let (_, consumed) = try #require(try parse(ok + "GET /next HTTP/1.1\r\n"))
        #expect(consumed == ok.utf8.count)
    }

    @Test("malformed requests are refused", arguments: [
        "GET / HTTP/1.0\r\nHost: a\r\n\r\n",                                                     // not HTTP/1.1
        "GET http://a/ HTTP/1.1\r\nHost: a\r\n\r\n",                                            // absolute-form
        "GET * HTTP/1.1\r\nHost: a\r\n\r\n",                                                    // asterisk-form
        "CONNECT a:443 HTTP/1.1\r\nHost: a\r\n\r\n",                                            // authority-form
        "GET /a#frag HTTP/1.1\r\nHost: a\r\n\r\n",                                              // fragment
        "GET /a\u{7F}b HTTP/1.1\r\nHost: a\r\n\r\n",                                            // non-visible byte
        "GET /caf\u{E9} HTTP/1.1\r\nHost: a\r\n\r\n",                                           // non-ASCII
        "get / HTTP/1.1\r\nHost: a\r\n\r\n",                                                    // lower-case method
        "GET  / HTTP/1.1\r\nHost: a\r\n\r\n",                                                   // two spaces
        "GET / HTTP/1.1\nHost: a\n\n",                                                          // bare LF
        "GET / HTTP/1.1\r\nHost: a\nX: b\r\n\r\n",                                              // bare LF inside
        "GET / HTTP/1.1\r\nHost: a\r\n X: folded\r\n\r\n",                                      // obsolete line folding
        "GET / HTTP/1.1\r\nHost: a\r\n\tX: folded\r\n\r\n",
        "GET / HTTP/1.1\r\nHost : a\r\n\r\n",                                                   // whitespace before the colon
        "GET / HTTP/1.1\r\nHo st: a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nX-Null: a\u{0}b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",                                         // two Host headers
        "GET / HTTP/1.1\r\n\r\n",                                                                // no Host
        "GET / HTTP/1.1\r\nHost: a\r\nAuthorization: x\r\nAuthorization: y\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\n",       // several lengths
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: identity\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: +3\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 3, 3\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0x10\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 99999999999999999999\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nConnection: Impersonate-User\r\n\r\n",                  // unknown Connection token
        "GET / HTTP/1.1\r\nHost: a\r\nConnection: Content-Length\r\n\r\n",
    ])
    func refused(text: String) {
        #expect(throws: HTTPParseError.self) { try parse(text) }
    }

    @Test("a head over 64 KB is refused, complete or not")
    func tooLarge() {
        let big = "GET / HTTP/1.1\r\nHost: a\r\nX: " + String(repeating: "a", count: 70_000)
        #expect(throws: HTTPParseError.self) { try parse(big) }
        #expect(throws: HTTPParseError.self) { try parse(big + "\r\n\r\n") }
    }

    @Test("framing")
    func framing() throws {
        let none = try #require(try parse(ok)).head
        #expect(try HTTPHeadParser.framing(of: none) == .none)
        let length = try #require(try parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 12\r\n\r\n")).head
        #expect(try HTTPHeadParser.framing(of: length) == .length(12))
        let zero = try #require(try parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n")).head
        #expect(try HTTPHeadParser.framing(of: zero) == .none)
        let chunked = try #require(try parse("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: Chunked\r\n\r\n")).head
        #expect(try HTTPHeadParser.framing(of: chunked) == .chunked)
    }

    @Test("upgrade detection by header or Connection token")
    func upgrade() throws {
        let a = try #require(try parse("GET / HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")).head
        #expect(a.isUpgrade)
        let b = try #require(try parse("GET / HTTP/1.1\r\nHost: a\r\nConnection: keep-alive, upgrade\r\n\r\n")).head
        #expect(b.isUpgrade)
        #expect(!(try #require(try parse(ok)).head.isUpgrade))
    }
}

@Suite("Chunked body re-encoder")
struct ChunkedBodyTests {
    private func run(_ text: String, splitting: Int? = nil) throws -> (String, Int, Bool) {
        var r = ChunkedBodyReencoder()
        var out = Data()
        var used = 0
        let input = Data(text.utf8)
        if let n = splitting {
            var i = 0
            while i < input.count, !r.isFinished {
                let piece = input[i..<min(input.count, i + n)]
                let (o, u) = try r.feed(Data(piece))
                out.append(o)
                used += u
                i += n
            }
        } else {
            let (o, u) = try r.feed(input)
            out = o
            used = u
        }
        return (String(decoding: out, as: UTF8.self), used, r.isFinished)
    }

    @Test("chunks are decoded and written again, extensions dropped")
    func reencode() throws {
        let input = "5;ext=1\r\nhello\r\nA\r\n0123456789\r\n0\r\n\r\n"
        let (out, used, done) = try run(input)
        #expect(out == "5\r\nhello\r\na\r\n0123456789\r\n0\r\n\r\n")
        #expect(done)
        #expect(used == input.utf8.count)
    }

    @Test("decode mode yields the plain body")
    func decodeMode() throws {
        var r = ChunkedBodyReencoder(decode: true)
        let (out, used) = try r.feed(Data("5;x=1\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8))
        #expect(String(decoding: out, as: UTF8.self) == "hello world")
        #expect(r.isFinished)
        #expect(used == "5;x=1\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8.count)
    }

    @Test("byte-by-byte input gives the same output")
    func split() throws {
        let (out, _, done) = try run("3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n", splitting: 1)
        #expect(out == "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")
        #expect(done)
    }

    @Test("bytes after the last chunk are not consumed")
    func pipelined() throws {
        let body = "1\r\na\r\n0\r\n\r\n"
        let (_, used, done) = try run(body + "GET / HTTP/1.1\r\n")
        #expect(done)
        #expect(used == body.utf8.count)
    }

    @Test("bad chunk framing is refused", arguments: ["zz\r\nab\r\n", "2\nab\r\n", "2\r\nabXX", "0\r\nTrailer: x\r\n\r\n", "\r\n", "123456789\r\n", String(repeating: "1", count: 100)])
    func refused(text: String) {
        #expect(throws: HTTPParseError.self) { try run(text) }
    }
}

@Suite("Session kubeconfig")
struct SessionKubeconfigTests {
    private func rig() throws -> (SessionKubeconfigWriter, Scratch) {
        let scratch = try Scratch()
        let paths = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: scratch.root, temporaryDirectory: scratch.root.appending(path: "tmp"))
        return (SessionKubeconfigWriter(paths: paths), scratch)
    }

    @Test("the file is 0400 in a 0700 folder under the sessions path, never under ~/.kube, and verifies")
    func writes() throws {
        let (writer, scratch) = try rig()
        defer { scratch.cleanup() }
        let id = UUID()
        let cert = Data("not-a-real-certificate".utf8)
        let w = try writer.write(sessionID: id, port: 51234, clusterID: "kc-abc123", clusterName: "prod: \"eu\" # west", token: "whg_secret", namespace: "shop", certificateDER: cert)
        #expect(w.file.path.contains("wheelhouse-debug/sessions/\(id.uuidString.lowercased())/kubeconfig"))
        #expect(!w.file.path.contains("/.kube/"))
        var st = stat()
        #expect(lstat(w.file.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o400)
        #expect(lstat(w.directory.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
        #expect(SessionKubeconfigWriter.verify(file: w.file, hash: w.hash) == .intact)
        // The text is JSON that names the loopback address, the cluster path and the token; hostile names stay inside their strings.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: w.file)) as? [String: Any])
        let clusters = try #require(object["clusters"] as? [[String: Any]])
        let cluster = try #require(clusters[0]["cluster"] as? [String: String])
        #expect(cluster["server"] == "https://127.0.0.1:51234/c/kc-abc123", "no token in the server address: client-go writes it into its discovery cache path")
        #expect(!(cluster["server"] ?? "").contains("whg_"))
        // The CA is this launch's certificate, as the base64 of a PEM text.
        let caText = try #require(cluster["certificate-authority-data"])
        let caData = try #require(Data(base64Encoded: caText))
        let pem = String(decoding: caData, as: UTF8.self)
        #expect(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n") && pem.hasSuffix("-----END CERTIFICATE-----\n"))
        let users = try #require(object["users"] as? [[String: Any]])
        #expect((users[0]["user"] as? [String: String])?["token"] == "whg_secret")
        #expect(object["current-context"] as? String == "prod: \"eu\" # west")
        let contexts = try #require(object["contexts"] as? [[String: Any]])
        #expect((contexts[0]["context"] as? [String: String])?["namespace"] == "shop")
        // kubectl reads it as YAML: slashes must not be escaped (`\/` is not a YAML escape).
        let yaml = try String(contentsOf: w.file, encoding: .utf8)
        #expect(!yaml.contains("\\/"))
        let parsed = try KubeconfigParser.parse(yaml, environment: .desktop(baseDirectory: w.directory))
        #expect(parsed.contexts.first?.server?.absoluteString == "https://127.0.0.1:51234/c/kc-abc123")
        #expect(parsed.contexts.first?.name == "prod: \"eu\" # west")
        // Nothing else is left in the folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.directory.path) == ["kubeconfig"])
    }

    @Test("a changed, replaced or writable file is detected")
    func integrity() throws {
        let (writer, scratch) = try rig()
        defer { scratch.cleanup() }
        let w = try writer.write(sessionID: UUID(), port: 51234, clusterID: "c1", clusterName: "c", token: "whg_t", namespace: nil, certificateDER: Data())
        chmod(w.file.path, 0o600)
        #expect(SessionKubeconfigWriter.verify(file: w.file, hash: w.hash) == .modeChanged)
        try Data("changed".utf8).write(to: w.file)
        chmod(w.file.path, 0o400)
        #expect(SessionKubeconfigWriter.verify(file: w.file, hash: w.hash) == .contentChanged)
        unlink(w.file.path)
        #expect(SessionKubeconfigWriter.verify(file: w.file, hash: w.hash) == .missing)
        symlink("/etc/hosts", w.file.path)
        #expect(SessionKubeconfigWriter.verify(file: w.file, hash: w.hash) == .replaced)
        SessionKubeconfigWriter.remove(directory: w.directory)
        #expect(!FileManager.default.fileExists(atPath: w.directory.path))
    }

    @Test("a cluster ID that is not a path segment is refused")
    func ids() {
        #expect(SessionKubeconfigWriter.isValid(clusterID: "kc-0a1b2c"))
        #expect(SessionKubeconfigWriter.isValid(clusterID: "6f1c8f0a-1b2c-4d3e-8f90-123456789abc"))
        for bad in ["", ".", "..", "a/b", "a b", "a%2F", "a?b", "a#b", "é", String(repeating: "a", count: 129)] { #expect(!SessionKubeconfigWriter.isValid(clusterID: bad), Comment(rawValue: bad)) }
    }

    @Test("a token is random, prefixed and only its digest is registered")
    func tokens() throws {
        let registry = SessionRegistry(gate: { DevSafetyPolicy(isActive: false) })
        let c = ClusterConfig(id: "c1", name: "c", server: URL(string: "https://c.test")!)
        let (s1, t1) = try registry.create(cluster: c, origin: .harness("a"))
        let (s2, t2) = try registry.create(cluster: c, origin: .harness("b"))
        #expect(t1.hasPrefix("whg_") && t1 != t2 && t1.count > 40)
        #expect(registry.session(forToken: t1)?.id == s1.id)
        #expect(registry.session(forToken: t2)?.id == s2.id)
        #expect(registry.session(forToken: "whg_nope") == nil)
        #expect(registry.session(forToken: "Bearer") == nil)
        registry.revoke(s1, reason: "test")
        #expect(registry.session(forToken: t1) == nil)
        #expect(s1.isRevoked)
        #expect(registry.liveSessionCount == 1)
    }

    @Test("the safety gate refuses a session for a host that is not allowed")
    func gate() throws {
        let registry = SessionRegistry(gate: { DevSafetyPolicy(isActive: true, allowedHosts: ["127.0.0.1"]) })
        let prod = ClusterConfig(id: "p", name: "prod", server: URL(string: "https://prod.example.com:6443")!)
        #expect(throws: DevSafetyError.self) { try registry.create(cluster: prod, origin: .harness("x")) }
        let test = ClusterConfig(id: "t", name: "test", server: URL(string: "https://127.0.0.1:52192")!)
        #expect(throws: Never.self) { try registry.create(cluster: test, origin: .harness("x")) }
        let fixture = ClusterConfig(id: "f", name: "fx", server: URL(string: "https://x.test:6443")!)
        #expect(throws: Never.self) { try registry.create(cluster: fixture, origin: .harness("x")) }
    }
}
#endif
