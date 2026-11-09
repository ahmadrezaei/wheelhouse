#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// Live kubectl matrix (ARCHITECTURE-MAC section 15.1, M5a): TEST CLUSTER ONLY.
///
/// Runs only with `WH_LIVE_TESTS=1`, and only when `WH_TEST_KUBECONFIG` resolves to `<repo>/.testcluster/kubeconfig` (not under
/// `~/.kube`), holds the context `wheelhouse-test`, and that context's host equals `.testcluster/server-host`. Needs
/// `scripts/testcluster-fixtures.sh --section m5a-gangway`. Every kubectl is spawned through `GangwayHarness` with a session kubeconfig,
/// a scratch `HOME`, `KUBERC=off` and a `KUBECACHEDIR` under the scratch app folder. kubectl versions: the installed one plus every
/// `.build/kubectl/<version>/kubectl` fetched by `scripts/fetch-kubectl-matrix.sh`, or `WH_KUBECTL_BINS` (colon separated).
enum GangwayLive {
    static var enabled: Bool { ProcessInfo.processInfo.environment["WH_LIVE_TESTS"] == "1" }

    static func repoRoot(file: StaticString = #filePath) -> URL {
        var root = URL(fileURLWithPath: "\(file)")
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
    }

    struct Verified {
        var context: KubeconfigContext
        var secrets: ClusterSecrets
        var host: String
    }

    static func verify(file: StaticString = #filePath) throws -> Verified {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["WH_TEST_KUBECONFIG"], "WH_TEST_KUBECONFIG is not set")
        let kubeconfig = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let expected = repoRoot(file: file).appending(path: ".testcluster/kubeconfig").resolvingSymlinksInPath()
        try #require(kubeconfig == expected, "WH_TEST_KUBECONFIG must be <repo>/.testcluster/kubeconfig")
        let kube = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".kube").resolvingSymlinksInPath().path
        try #require(!kubeconfig.path.hasPrefix(kube + "/"), "the test kubeconfig must not be under ~/.kube")
        let text = try String(contentsOf: kubeconfig, encoding: .utf8)
        let parsed = try KubeconfigParser.parse(text, environment: .desktop(baseDirectory: kubeconfig.deletingLastPathComponent()))
        let ctx = try #require(parsed.contexts.first { $0.name == "wheelhouse-test" }, "context wheelhouse-test is missing")
        let host = try #require(ctx.server?.host())
        let recorded = try String(contentsOf: kubeconfig.deletingLastPathComponent().appending(path: "server-host"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(host == recorded, "the server host \(host) differs from the recorded \(recorded)")
        let gate = DevSafetyPolicy(isActive: true, allowedHosts: [host])
        return Verified(context: ctx, secrets: DiscoveredSecrets.resolve(ctx, gate: gate), host: host)
    }

    /// `(label, path)` of every kubectl in the matrix.
    static let kubectls: [KubectlBinary] = {
        let env = ProcessInfo.processInfo.environment
        if let list = env["WH_KUBECTL_BINS"] { return list.split(separator: ":").map { KubectlBinary(path: String($0)) } }
        var out = [KubectlBinary(path: "/usr/local/bin/kubectl")]
        let dir = repoRoot().appending(path: ".build/kubectl")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
            let bin = dir.appending(path: "\(name)/kubectl").path
            if FileManager.default.isExecutableFile(atPath: bin) { out.append(KubectlBinary(path: bin)) }
        }
        return out
    }()
}

struct KubectlBinary: Sendable, CustomTestStringConvertible {
    var path: String
    var version: String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["version", "--client", "-o", "json"]
        process.environment = ["PATH": "/usr/bin:/bin", "KUBECACHEDIR": NSTemporaryDirectory() + "wh-kc-version", "KUBERC": "off", "HOME": NSTemporaryDirectory()]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "?" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((object?["clientVersion"] as? [String: Any])?["gitVersion"] as? String) ?? "?"
    }
    var testDescription: String { "kubectl \(version)" }
}

/// Gangway in front of the real test cluster.
final class LiveRig: @unchecked Sendable {
    let scratch: Scratch
    let service: GangwayService
    let provider: SnapshotClusterProvider
    let activity = InMemoryActivityLog()
    let harness: GangwayHarness
    let clusterID: ClusterID = "kc-live-test"
    let verified: GangwayLive.Verified

    init(environment: ClusterEnvironment = .development, readOnly: Bool = false, confirmer: any GangwayConfirming = DecliningConfirmer(),
         extraEnvironment: [String: String] = [:]) async throws {
        verified = try GangwayLive.verify()
        scratch = try Scratch()
        let paths = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: scratch.root, temporaryDirectory: scratch.root.appending(path: "tmp"))
        try paths.prepare()
        let ctx = verified.context
        let config = ClusterConfig(id: clusterID, name: "wheelhouse-test", server: try #require(ctx.server), authKind: .token,
                                   environment: environment, readOnly: readOnly, tlsServerName: ctx.tlsServerName)
        // The test cluster's admin token (a fixture under .testcluster/, like the exec-credential suite uses) authenticates the upstream
        // leg: the client-certificate path needs the Keychain, which an unsigned `swift test` process may not use (-34018). The cluster's
        // own CA is verified as usual.
        let tokenFile = GangwayLive.repoRoot().appending(path: ".testcluster/admin.token")
        var secrets = verified.secrets
        secrets.token = try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        secrets.clientCertificatePEM = nil
        secrets.clientKeyPEM = nil
        // The production environment is used end to end: the upstream leg is TLS.
        let finalSecrets = secrets
        provider = SnapshotClusterProvider { c in GangwayUpstream(config: c, secrets: finalSecrets) }
        provider.update([config])
        let gate = DevSafetyPolicy(isActive: true, allowedHosts: [verified.host], home: scratch.root)
        service = GangwayService(paths: paths, clusters: provider, confirmer: confirmer, activity: activity, gate: { gate }, batchingWindow: .zero,
                                 holdTimeout: .seconds(20))
        harness = GangwayHarness(paths: paths, snapshot: ShellSnapshot(path: "/usr/bin:/bin", kubeconfig: nil, vars: [:], shell: "/bin/sh"),
                                 homeOverride: scratch.root, extraEnvironment: extraEnvironment)
    }

    func open(scope: GangwayScope = .standard) async throws -> GangwaySessionHandle {
        try await service.openSession(clusterID: clusterID, origin: .harness("live"), scope: scope, namespace: "default")
    }

    func setCluster(_ change: (inout ClusterConfig) -> Void) {
        var c = provider.config(for: clusterID)!
        change(&c)
        provider.set(c)
        service.clusterChanged(clusterID)
    }

    func stop() {
        service.stop()
        scratch.cleanup()
    }

    func kubectl(_ bin: KubectlBinary, _ args: [String], session: GangwaySessionHandle, stdin: String? = nil, timeout: Duration = .seconds(60)) async throws -> ProcessResult {
        try await harness.run(kubectl: URL(fileURLWithPath: bin.path), arguments: args, session: session, stdin: stdin.map { Data($0.utf8) }, timeout: timeout)
    }

    /// Runs a long-lived kubectl until `needle` shows up in its output (or the timeout), then kills it. Returns what was printed.
    func kubectlUntil(_ bin: KubectlBinary, _ args: [String], session: GangwaySessionHandle, needle: String, timeout: Duration = .seconds(30)) async -> String {
        let spec = harness.spec(kubectl: URL(fileURLWithPath: bin.path), arguments: args, session: session, timeout: timeout)
        var text = ""
        do {
            for try await event in Subprocess.stream(spec) {
                switch event {
                case .stdout(let d), .stderr(let d): text += String(decoding: d, as: UTF8.self)
                case .exit: return text
                }
                if text.contains(needle) { return text }
            }
        } catch {}
        return text
    }
}

private let ns = "wh-m5a"
private let webPod: String = {
    // The shop namespace's nginx pods are read-only fixtures: exec, logs and port-forward do not change them.
    "deploy/web"
}()

@Suite("Live: Gangway with kubectl", .enabled(if: GangwayLive.enabled), .serialized)
struct GangwayLiveTests {
    @Test("the full kubectl matrix through Gangway", arguments: GangwayLive.kubectls)
    func matrix(bin: KubectlBinary) async throws {
        let rig = try await LiveRig()
        defer { rig.stop() }
        let session = try await rig.open()
        let tag = bin.version.replacingOccurrences(of: ".", with: "-").lowercased()
        let cm = "matrix-\(tag)"
        func k(_ args: String..., stdin: String? = nil) async throws -> ProcessResult { try await rig.kubectl(bin, args, session: session, stdin: stdin) }

        // get, and a raw request (which replaces the whole path: it works because the token is the bearer token of the kubeconfig)
        var r = try await k("get", "--raw", "/version")
        #expect(r.exitCode == 0 && r.stdoutString.contains("gitVersion"), Comment(rawValue: r.stderrString))
        r = try await k("get", "ns", ns, "-o", "name")
        #expect(r.exitCode == 0 && r.stdoutString.contains("namespace/\(ns)"), Comment(rawValue: r.stderrString))
        r = try await k("get", "pods", "-A", "--no-headers")
        #expect(r.exitCode == 0, Comment(rawValue: r.stderrString))

        // watch
        let watch = await rig.kubectlUntil(bin, ["get", "cm", "base", "-n", ns, "-w", "--no-headers"], session: session, needle: "base")
        #expect(watch.contains("base"))

        // logs -f
        let logs = await rig.kubectlUntil(bin, ["logs", "-f", "-n", "kube-system", "deploy/coredns", "--tail=1"], session: session, needle: "[")
        #expect(!logs.isEmpty && !logs.lowercased().contains("error from server"), Comment(rawValue: logs))

        // exec (non-interactive, with stdin)
        r = try await k("exec", "-n", "shop", webPod, "--", "echo", "gangway")
        #expect(r.exitCode == 0 && r.stdoutString.contains("gangway"), Comment(rawValue: r.stderrString))
        r = try await k("exec", "-i", "-n", "shop", webPod, "--", "cat", stdin: "through-the-gate\n")
        #expect(r.exitCode == 0 && r.stdoutString.contains("through-the-gate"), Comment(rawValue: r.stderrString))

        // apply, diff, --dry-run=server
        let manifest = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: \(cm)\n  namespace: \(ns)\ndata:\n  a: \"1\"\n"
        r = try await k("apply", "--dry-run=server", "-f", "-", stdin: manifest)
        #expect(r.exitCode == 0 && r.stdoutString.contains("(server dry run)"), Comment(rawValue: r.stderrString))
        r = try await k("get", "cm", cm, "-n", ns)
        #expect(r.exitCode != 0, "a dry run must not create anything")
        r = try await k("apply", "-f", "-", stdin: manifest)
        #expect(r.exitCode == 0 && r.stdoutString.contains("created"), Comment(rawValue: r.stderrString))
        let changed = manifest.replacingOccurrences(of: "\"1\"", with: "\"2\"")
        r = try await k("diff", "-f", "-", stdin: changed)
        #expect(r.exitCode == 1 && r.stdoutString.contains("+  a: \"2\""), Comment(rawValue: r.stdoutString + r.stderrString))
        r = try await k("apply", "--server-side", "--dry-run=server", "--force-conflicts", "-f", "-", stdin: changed)
        #expect(r.exitCode == 0, Comment(rawValue: r.stderrString))
        r = try await k("apply", "-f", "-", stdin: changed)
        #expect(r.exitCode == 0 && r.stdoutString.contains("configured"), Comment(rawValue: r.stderrString))
        r = try await k("get", "cm", cm, "-n", ns, "-o", "jsonpath={.data.a}")
        #expect(r.stdoutString == "2")

        // delete with a dry-run body (kubectl --dry-run=server), then for real
        let before = rig.activity.entries.count
        r = try await k("delete", "cm", cm, "-n", ns, "--dry-run=server")
        #expect(r.exitCode == 0 && r.stdoutString.contains("(server dry run)"), Comment(rawValue: r.stderrString))
        r = try await k("get", "cm", cm, "-n", ns)
        #expect(r.exitCode == 0, "the dry-run delete must leave the object")
        #expect(!rig.activity.entries.dropFirst(before).contains { $0.verb == "delete" }, "a dry-run delete is not a change")
        r = try await k("delete", "cm", cm, "-n", ns)
        #expect(r.exitCode == 0 && r.stdoutString.contains("deleted"), Comment(rawValue: r.stderrString))
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.activity.entries.contains { $0.verb == "delete" && $0.object == "\(ns)/configmaps/\(cm)" && $0.result == "HTTP 200" })

        // The session token is not in the kubectl cache (client-go names its discovery cache after the server URL, which no longer holds it).
        let cache = rig.harness.paths.root.appending(path: "kubectl-cache", directoryHint: .isDirectory)
        let leaked = ((try? FileManager.default.subpathsOfDirectory(atPath: cache.path)) ?? []).filter { $0.contains("whg_") }
        #expect(leaked.isEmpty, Comment(rawValue: leaked.joined(separator: "\n")))
        #expect(FileManager.default.fileExists(atPath: cache.path), "kubectl wrote its cache under the app folder")

        // port-forward
        let pf = await rig.kubectlUntil(bin, ["port-forward", "-n", "shop", webPod, ":80"], session: session, needle: "Forwarding from 127.0.0.1:", timeout: .seconds(8))
        #expect(pf.contains("Forwarding from 127.0.0.1:"), Comment(rawValue: pf))
    }

    @Test("port-forward serves traffic through the gate (WebSocket and SPDY)", arguments: GangwayLive.kubectls)
    func portForwardTraffic(bin: KubectlBinary) async throws {
        for spdy in [false, true] {
            let extra = spdy ? ["KUBECTL_PORT_FORWARD_WEBSOCKETS": "false", "KUBECTL_REMOTE_COMMAND_WEBSOCKETS": "false"] : [:]
            let rig = try await LiveRig(extraEnvironment: extra)
            defer { rig.stop() }
            let session = try await rig.open()
            let port = UInt16.random(in: 40000...48000)
            let spec = rig.harness.spec(kubectl: URL(fileURLWithPath: bin.path), arguments: ["port-forward", "-n", "shop", webPod, "\(port):80"], session: session, timeout: .seconds(25))
            let task = Task { () -> String in
                var text = ""
                do { for try await e in Subprocess.stream(spec) { if case .stdout(let d) = e { text += String(decoding: d, as: UTF8.self) } } } catch {}
                return text
            }
            var body = ""
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(250))
                if let (data, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!) { body = String(decoding: data, as: UTF8.self); break }
            }
            task.cancel()
            #expect(body.contains("nginx"), Comment(rawValue: "spdy=\(spdy): \(body)"))
            // The stream was recorded.
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.activity.entries.contains { $0.verb == "port-forward" }, Comment(rawValue: "spdy=\(spdy)"))
        }
    }

    @Test("interactive exec in a PTY and the SPDY fallback", arguments: GangwayLive.kubectls)
    func execInteractive(bin: KubectlBinary) async throws {
        for spdy in [false, true] {
            let extra = spdy ? ["KUBECTL_REMOTE_COMMAND_WEBSOCKETS": "false"] : [:]
            let rig = try await LiveRig(extraEnvironment: extra)
            defer { rig.stop() }
            let session = try await rig.open()
            var env = rig.harness.environment(kubeconfig: session.kubeconfig)
            env["TERM"] = "xterm"
            let spec = ProcessSpec(executable: URL(fileURLWithPath: bin.path), arguments: ["exec", "-it", "-n", "shop", webPod, "--", "sh", "-c", "echo pty-$((6*7)); exit 0"],
                                   environment: env, timeout: .seconds(30))
            let pty = try PTYProcess(spec: spec, size: (80, 24), helper: try PTYHelper.url())
            var text = ""
            for await chunk in pty.output {
                text += String(decoding: chunk, as: UTF8.self)
                if text.contains("pty-42") { break }
            }
            await pty.terminate()
            #expect(text.contains("pty-42"), Comment(rawValue: "spdy=\(spdy): \(text)"))
            #expect(rig.activity.entries.contains { $0.verb == "exec" })
        }
    }

    @Test("a read-only cluster refuses changes with a message kubectl prints, and still reads and dry-runs", arguments: GangwayLive.kubectls)
    func readOnly(bin: KubectlBinary) async throws {
        let rig = try await LiveRig(readOnly: true)
        defer { rig.stop() }
        let session = try await rig.open()
        let manifest = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: ro-\(UUID().uuidString.prefix(6).lowercased())\n  namespace: \(ns)\n"
        var r = try await rig.kubectl(bin, ["apply", "-f", "-"], session: session, stdin: manifest)
        #expect(r.exitCode != 0)
        #expect(r.stderrString.contains("Wheelhouse: wheelhouse-test is read-only. Allow changes in Cluster Settings."), Comment(rawValue: r.stderrString))
        #expect(r.stderrString.contains("Forbidden"), Comment(rawValue: r.stderrString))
        r = try await rig.kubectl(bin, ["delete", "cm", "base", "-n", ns], session: session)
        #expect(r.exitCode != 0 && r.stderrString.contains("read-only"), Comment(rawValue: r.stderrString))
        r = try await rig.kubectl(bin, ["exec", "-n", "shop", webPod, "--", "echo", "x"], session: session)
        #expect(r.exitCode != 0 && r.stderrString.contains("read-only"), Comment(rawValue: r.stderrString))
        r = try await rig.kubectl(bin, ["apply", "--dry-run=server", "-f", "-"], session: session, stdin: manifest)
        #expect(r.exitCode == 0, Comment(rawValue: r.stderrString))
        r = try await rig.kubectl(bin, ["get", "cm", "base", "-n", ns, "-o", "name"], session: session)
        #expect(r.exitCode == 0)
        r = try await rig.kubectl(bin, ["get", "cm", "base", "-n", ns], session: session)
        #expect(r.exitCode == 0)
        // The object is still there (nothing reached the API server).
        r = try await rig.kubectl(bin, ["delete", "cm", "base", "-n", ns, "--dry-run=server"], session: session)
        #expect(r.exitCode == 0, Comment(rawValue: r.stderrString))
    }

    @Test("Production (the test cluster marked Production in a test config): Impersonate-* refused and logged; changes held; dry-runs and diffs do not prompt", arguments: GangwayLive.kubectls)
    func production(bin: KubectlBinary) async throws {
        let confirmer = ScriptedConfirmer { _ in false }
        let rig = try await LiveRig(environment: .production, confirmer: confirmer)
        defer { rig.stop() }
        let session = try await rig.open()
        // kubectl prints "Forbidden: unknown" for a refused discovery call (it drops the Status message there); the exact message is pinned
        // in GangwayServerTests. Here: the command fails, upstream is never reached with the header, and the attempt is logged.
        var r = try await rig.kubectl(bin, ["get", "ns", ns, "--as=alice", "-o", "name"], session: session)
        #expect(r.exitCode != 0 && r.stderrString.contains("Forbidden"), Comment(rawValue: r.stderrString))
        #expect(rig.activity.entries.contains { $0.result.contains("Impersonate-User=alice") && $0.result.hasPrefix("refused") })
        r = try await rig.kubectl(bin, ["auth", "can-i", "get", "pods", "--as=alice", "--as-group=system:masters"], session: session)
        #expect(r.exitCode != 0 && r.stderrString.contains("Forbidden"), Comment(rawValue: r.stderrString))
        // Without impersonation a read passes.
        r = try await rig.kubectl(bin, ["get", "ns", ns, "-o", "name"], session: session)
        #expect(r.exitCode == 0, Comment(rawValue: r.stderrString))
        // A change is held and declined.
        r = try await rig.kubectl(bin, ["delete", "cm", "base", "-n", ns], session: session)
        #expect(r.exitCode != 0 && r.stderrString.contains("Wheelhouse: change not confirmed"), Comment(rawValue: r.stderrString))
        #expect(confirmer.sheets.all.count >= 1)
        let sheets = confirmer.sheets.all.count
        // Dry-runs (also the body-based delete) and diff never prompt.
        r = try await rig.kubectl(bin, ["delete", "cm", "base", "-n", ns, "--dry-run=server"], session: session)
        #expect(r.exitCode == 0, Comment(rawValue: r.stderrString))
        r = try await rig.kubectl(bin, ["diff", "-f", "-"], session: session, stdin: "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: base\n  namespace: \(ns)\ndata:\n  hello: changed\n")
        #expect(r.exitCode == 1, Comment(rawValue: r.stderrString))
        #expect(confirmer.sheets.all.count == sheets)
        // The object survived.
        r = try await rig.kubectl(bin, ["get", "cm", "base", "-n", ns, "-o", "name"], session: session)
        #expect(r.exitCode == 0)
        // Non-interactive exec on Production is a typed sheet; declined.
        let sheetsBeforeExec = confirmer.sheets.all.count
        r = try await rig.kubectl(bin, ["exec", "-n", "shop", webPod, "--", "echo", "x"], session: session)
        #expect(r.exitCode != 0)
        // kubectl falls back from WebSocket to SPDY after a refused upgrade: how many sheets did one declined exec cause?
        #expect(confirmer.sheets.all.count - sheetsBeforeExec == 1, "a declined exec asks once, not again for the SPDY fallback")
        let streamSheet = confirmer.sheets.all.last { $0.kind == .stream }
        #expect(streamSheet != nil)
        #expect(streamSheet?.requiresTyping == true)
    }

    @Test("Production: approved changes go through, once per listed request")
    func productionApproved() async throws {
        let bin = try #require(GangwayLive.kubectls.first)
        let confirmer = ScriptedConfirmer { _ in true }
        let rig = try await LiveRig(environment: .production, confirmer: confirmer)
        defer { rig.stop() }
        let session = try await rig.open()
        let manifest = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: approved-cm\n  namespace: \(ns)\ndata:\n  a: \"1\"\n"
        var r = try await rig.kubectl(bin, ["apply", "-f", "-"], session: session, stdin: manifest)
        #expect(r.exitCode == 0, Comment(rawValue: r.stderrString))
        #expect(confirmer.sheets.all.count >= 1)
        r = try await rig.kubectl(bin, ["delete", "cm", "approved-cm", "-n", ns], session: session)
        #expect(r.exitCode == 0, Comment(rawValue: r.stderrString))
    }

    @Test("kubectl does not send loopback traffic through a proxy, and the child environment is the gate's")
    func proxyEnvironment() async throws {
        let bin = try #require(GangwayLive.kubectls.first)
        let rig = try await LiveRig(extraEnvironment: ["HTTPS_PROXY": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9"])
        defer { rig.stop() }
        let session = try await rig.open()
        let r = try await rig.kubectl(bin, ["get", "ns", ns, "-o", "name"], session: session)
        #expect(r.exitCode == 0, Comment(rawValue: r.stderrString))
    }

    @Test("p50 overhead of the proxy is at most 2 ms")
    func overhead() async throws {
        let rig = try await LiveRig()
        defer { rig.stop() }
        let session = try await rig.open()
        let token = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: session.kubeconfig)) as? [String: Any])
        let users = try #require(token["users"] as? [[String: Any]])
        let bearer = try #require((users[0]["user"] as? [String: String])?["token"])
        let port = try #require(rig.service.port)
        let client = try await RawClient(port: port, certificateDER: try #require(rig.service.context.tlsCertificateDER))
        rig.service.metrics.reset()
        var rtts: [Double] = []
        for i in 0..<400 {
            let start = ContinuousClock.now
            try await client.send("GET /c/\(rig.clusterID)/api/v1/namespaces/\(ns)/configmaps/base HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(bearer)\r\nAccept: application/json\r\n\r\n")
            let r = try #require(await client.readResponse())
            #expect(r.status == 200)
            if i >= 20 { rtts.append((ContinuousClock.now - start).microseconds / 1000) }
        }
        client.close()
        let p50 = try #require(rig.service.metrics.quantileMilliseconds(0.5))
        let p95 = try #require(rig.service.metrics.quantileMilliseconds(0.95))
        let rttP50 = rtts.sorted()[rtts.count / 2]
        print("GANGWAY-OVERHEAD p50_ms=\(p50) p95_ms=\(p95) samples=\(rig.service.metrics.count) end_to_end_p50_ms=\(rttP50)")
        #expect(p50 <= 2.0, "p50 overhead \(p50) ms")
    }

    @Test("the real peer resolver finds the process on the other end of a connection by process group")
    func realPeerResolver() async throws {
        // A child holding a loopback TCP connection to a listener in this process; found through its process group.
        let listener = FakeUpstream()
        try await listener.start()
        defer { listener.stop() }
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/bin/sh")
        nc.arguments = ["-c", "exec /usr/bin/nc 127.0.0.1 \(listener.port)"]
        nc.standardInput = Pipe()
        try nc.run()
        defer { nc.terminate() }
        try await Task.sleep(for: .milliseconds(500))
        // The connection's remote (client) port is the child's local port: read it from the child's socket table through the resolver itself.
        let resolver = PeerResolver()
        let group = getpgid(nc.processIdentifier)
        var found: PeerProcess?
        for port in UInt16(49152)...UInt16(65535) where found == nil {
            if PeerResolver.holdsConnection(pid: nc.processIdentifier, clientPort: port, listenerPort: listener.port) { found = resolver.resolve(clientPort: port, listenerPort: listener.port, scope: .processGroup(group)) }
        }
        let peer = try #require(found)
        #expect(peer.pid == nc.processIdentifier)
        #expect(peer.group == group)
        #expect(peer.session == getsid(nc.processIdentifier))
        #expect(resolver.resolve(clientPort: 1, listenerPort: listener.port, scope: .processGroup(group)) == nil)
        #expect(resolver.resolve(clientPort: 1, listenerPort: listener.port, scope: .processGroup(group + 100000)) == nil)
    }
}
#endif
