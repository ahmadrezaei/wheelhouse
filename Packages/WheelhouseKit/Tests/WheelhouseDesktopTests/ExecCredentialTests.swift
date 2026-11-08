#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

private struct Rig {
    let scratch: Scratch
    let plugin: URL
    let counter: URL
    let infoFile: URL
    let broker: ExecCredentialBroker
    let clock: Clock
    let activity = InMemoryActivityLog()

    static let rerunPause = ExecCredentialBroker.reRunInterval + 1

    final class Clock: @unchecked Sendable {
        private let t = Mutex(Date())
        var now: Date { t.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { t.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    init(limiter: ExecConcurrencyLimiter = ExecConcurrencyLimiter(limit: 3), timeout: Duration = .seconds(20), gate: DevSafetyPolicy? = nil,
         gateProvider: (@Sendable () -> DevSafetyPolicy)? = nil) throws {
        let s = try Scratch()
        scratch = s
        plugin = try s.installPlugin()
        counter = s.root.appending(path: "counter")
        infoFile = s.root.appending(path: "info.json")
        let clock = Clock()
        self.clock = clock
        let snapshot = ShellSnapshot(path: "/usr/bin:/bin", kubeconfig: nil, vars: [:], shell: "/bin/sh")
        let locator = ExecutableLocator(searchPath: ["/usr/bin", "/bin"])
        let builder = EnvironmentBuilder(snapshot: snapshot, paths: AppPaths(gateActive: true, bundleID: "x.debug", home: s.root), home: s.root)
        broker = ExecCredentialBroker(locator: { locator }, environment: { builder }, limiter: limiter, activity: activity,
                                      gate: gateProvider == nil ? (gate ?? openGate(home: s.root)) : nil, gateProvider: gateProvider, timeout: timeout, now: { clock.now })
    }

    func spec(mode: String = "token", env: [String: String] = [:], version: String? = "client.authentication.k8s.io/v1", provideClusterInfo: Bool = false,
              interactiveMode: String? = nil, command: String? = nil) -> KubeconfigExecSpec {
        var vars = ["PLUGIN_MODE": mode, "PLUGIN_COUNTER": counter.path, "PLUGIN_INFO_FILE": infoFile.path]
        vars.merge(env) { _, new in new }
        return KubeconfigExecSpec(apiVersion: version, command: command ?? plugin.path, args: [], env: vars.map { .init(name: $0.key, value: $0.value) },
                                  provideClusterInfo: provideClusterInfo, interactiveMode: interactiveMode)
    }

    func provider(_ spec: KubeconfigExecSpec, server: String = "https://k.example.test:6443") -> ExecCredentialProvider {
        ExecCredentialProvider(spec: spec, cluster: ExecClusterInfo(server: server, tlsServerName: "tls.example.test", certificateAuthorityData: "Q0E=", insecureSkipTLSVerify: false),
                               kubeconfigPath: scratch.root.appending(path: "kc.yaml").path, broker: broker)
    }

    var runs: Int { Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "0") ?? 0 }
}

@Suite("ExecCredential parsing")
struct ExecCredentialParsingTests {
    static let v1 = "client.authentication.k8s.io/v1"

    @Test func tokenWithExpiry() throws {
        let json = #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"abc","expirationTimestamp":"2030-01-02T03:04:05Z"}}"#
        let c = try ExecCredential.parse(Data(json.utf8), expectedAPIVersion: Self.v1)
        #expect(c.token == "abc")
        #expect(c.expirationTimestamp == Date(timeIntervalSince1970: 1_893_553_445))
        #expect(!c.isClientCertificate)
    }

    @Test func fractionalSecondsAreAccepted() throws {
        let json = #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"abc","expirationTimestamp":"2030-01-02T03:04:05.250Z"}}"#
        #expect(try ExecCredential.parse(Data(json.utf8), expectedAPIVersion: Self.v1).expirationTimestamp != nil)
    }

    @Test func clientCertificate() throws {
        let json = #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"clientCertificateData":"C","clientKeyData":"K"}}"#
        let c = try ExecCredential.parse(Data(json.utf8), expectedAPIVersion: Self.v1)
        #expect(c.isClientCertificate && c.token == nil)
        #expect(c.certificateMaterial == ClientCertificateMaterial(certificatePEM: "C", keyPEM: "K"))
    }

    @Test(arguments: [
        "not json",
        #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"Other","status":{"token":"a"}}"#,
        #"{"apiVersion":"client.authentication.k8s.io/v1beta1","kind":"ExecCredential","status":{"token":"a"}}"#,
        #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential"}"#,
        #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{}}"#,
        #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"clientCertificateData":"C"}}"#,
        #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"a","expirationTimestamp":"tomorrow"}}"#,
    ])
    func invalidOutputIsRejected(_ json: String) {
        #expect(throws: ExecCredentialError.self) { _ = try ExecCredential.parse(Data(json.utf8), expectedAPIVersion: Self.v1) }
    }

    @Test func outputOverOneMegabyteIsRejected() {
        let huge = Data(repeating: 0x20, count: ExecCredential.maxOutput + 1)
        #expect(throws: ExecCredentialError.self) { _ = try ExecCredential.parse(huge, expectedAPIVersion: Self.v1) }
    }

    @Test func refreshesSixtySecondsEarlyOrAtEightyPercentOfALifetimeThatIsShorter() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var c = ExecCredential(token: "t")
        #expect(c.refreshDate(obtainedAt: t0) == nil)
        c.expirationTimestamp = t0.addingTimeInterval(3600)
        #expect(c.refreshDate(obtainedAt: t0) == t0.addingTimeInterval(2880))      // 80 % of an hour comes before expiry - 60 s
        c.expirationTimestamp = t0.addingTimeInterval(100)       // 80 % = 80 s; expiry - 60 = 40 s: the sooner wins
        #expect(c.refreshDate(obtainedAt: t0) == t0.addingTimeInterval(40))
        c.expirationTimestamp = t0.addingTimeInterval(-5)        // already expired
        #expect(c.refreshDate(obtainedAt: t0) == t0)
    }

    @Test func stderrIsRedactedAndLimitedToTwentyLines() {
        let lines = (0..<30).map { "line \($0)" } + ["token=abcdef0123456789abcdef", "Authorization: Bearer eyJabcdefghij.klmnopqrstu.vwxyz0123", "k8s-aws-v1.aHR0cHM6Ly9zdHM", "plain text"]
        let out = StderrRedactor.tail(Data(lines.joined(separator: "\n").utf8))
        #expect(out.split(separator: "\n").count == 20)
        #expect(!out.contains("abcdef0123456789abcdef"))
        #expect(!out.contains("eyJabcdefghij"))
        #expect(!out.contains("aHR0cHM6Ly9zdHM"))
        #expect(out.contains("plain text"))
        #expect(out.contains("token=[redacted]"))
    }
}

@Suite("ExecCredentialProvider (fake plugins)", .serialized)
struct ExecCredentialProviderTests {
    @Test func runsTheV1PluginAndCachesTheCredentialInMemory() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let p = r.provider(r.spec())
        #expect(try await p.authorization() == "tok-1")
        #expect(try await p.authorization() == "tok-1")
        #expect(r.runs == 1)
        // Activity records only that the plugin ran.
        let entries = r.activity.entries
        #expect(entries.count == 1)
        #expect(entries[0].result.hasPrefix("plugin ran: plugin.sh, "))
        #expect(entries[0].result.hasSuffix("exit 0"))
        #expect(!entries[0].result.contains("tok-"))
    }

    @Test func v1beta1IsAcceptedAndMustMatchTheRequestedVersion() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let beta = r.provider(r.spec(env: ["PLUGIN_API_VERSION": "client.authentication.k8s.io/v1beta1"], version: "client.authentication.k8s.io/v1beta1"))
        #expect(try await beta.authorization() == "tok-1")
        // The plugin answers v1beta1 although v1 was requested: invalid.
        let mismatch = r.provider(r.spec(env: ["PLUGIN_API_VERSION": "client.authentication.k8s.io/v1beta1"]), server: "https://other.example.test")
        await #expect(throws: ExecCredentialError.self) { _ = try await mismatch.authorization() }
        // v1alpha1 is rejected without running anything.
        let before = r.runs
        let alpha = r.provider(r.spec(version: "client.authentication.k8s.io/v1alpha1"), server: "https://third.example.test")
        await #expect(throws: ExecCredentialError.unsupportedAPIVersion("client.authentication.k8s.io/v1alpha1")) { _ = try await alpha.authorization() }
        #expect(r.runs == before)
    }

    @Test func aMissingStanzaVersionDefaultsToV1() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        #expect(try await r.provider(r.spec(version: nil)).authorization() == "tok-1")
    }

    @Test func expiringCredentialsAreRefreshedBeforeTheyExpire() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let expiry = rfc3339(r.clock.now.addingTimeInterval(3600))
        let p = r.provider(r.spec(env: ["PLUGIN_EXPIRY": expiry]))
        #expect(try await p.authorization() == "tok-1")
        r.clock.advance(2800)
        #expect(try await p.authorization() == "tok-1")      // not due yet (due at 80 % of the lifetime: 2880 s)
        r.clock.advance(100)                                 // now 2900 s
        #expect(try await p.authorization() == "tok-2")
        #expect(r.runs == 2)
    }

    @Test func aCredentialWithoutAnExpiryIsReusedUntilA401() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let p = r.provider(r.spec())
        _ = try await p.authorization()
        r.clock.advance(86_400)
        #expect(try await p.authorization() == "tok-1")
        r.clock.advance(11)                                  // a 401 more than 10 s after the run
        await p.invalidate()
        #expect(try await p.authorization() == "tok-2")
    }

    @Test func reRunsAreRateLimitedToOncePerTenSeconds() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let p = r.provider(r.spec())
        _ = try await p.authorization()
        r.clock.advance(3)
        await p.invalidate()                                 // 401 three seconds after the run: ignored
        #expect(try await p.authorization() == "tok-1")
        #expect(r.runs == 1)
    }

    @Test func concurrentCallersShareOneRun() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let p = r.provider(r.spec(mode: "sleep", env: ["PLUGIN_SLEEP": "0.4"]))
        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<10 { group.addTask { try await p.authorization() } }
            var out: [String?] = []
            for try await t in group { out.append(t) }
            return out
        }
        #expect(Set(tokens.compactMap { $0 }) == ["tok-1"])
        #expect(r.runs == 1)
    }

    @Test func atMostThreePluginsRunAtOnceAcrossClusters() async throws {
        let limiter = ExecConcurrencyLimiter(limit: 3)
        let r = try Rig(limiter: limiter); defer { r.scratch.cleanup() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                // Different servers: different keys, so no sharing; each plugin sleeps 0.3 s.
                let p = r.provider(r.spec(mode: "sleep", env: ["PLUGIN_SLEEP": "0.3"]), server: "https://c\(i).example.test")
                group.addTask { _ = try await p.authorization() }
            }
            try await group.waitForAll()
        }
        let peak = await limiter.peak
        #expect(peak == 3)
    }

    @Test func aMissingPluginReportsTheHintAndTheInstallCommand() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        var spec = r.spec(command: "kubelogin")
        spec.installHint = "Install kubelogin from the Azure docs"
        let p = r.provider(spec)
        do {
            _ = try await p.authorization()
            Issue.record("expected an error")
        } catch let e as ExecCredentialError {
            guard case .pluginMissing(let cmd, let hint, let suggestion) = e else { Issue.record("wrong error \(e)"); return }
            #expect(cmd == "kubelogin")
            #expect(hint == "Install kubelogin from the Azure docs")
            #expect(suggestion == "brew install Azure/kubelogin/kubelogin")
            #expect(e.localizedDescription.contains("isn’t on your PATH"))
        }
    }

    @Test func aFailingPluginKeepsARedactedStderrTail() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let p = r.provider(r.spec(mode: "fail"))
        do {
            _ = try await p.authorization()
            Issue.record("expected an error")
        } catch let e as ExecCredentialError {
            guard case .failed(_, let code, let tail) = e else { Issue.record("wrong error \(e)"); return }
            #expect(code == 3)
            #expect(tail.contains("aws sso login"))
            #expect(!tail.contains("abcdef0123456789abcdef"))
            #expect(!e.localizedDescription.contains("abcdef0123456789abcdef"))
        }
    }

    @Test func malformedOrEmptyOutputIsInvalid() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        for (i, mode) in ["malformed", "empty"].enumerated() {
            let p = r.provider(r.spec(mode: mode), server: "https://bad\(i).example.test")
            await #expect(throws: ExecCredentialError.self) { _ = try await p.authorization() }
        }
    }

    @Test func aSlowPluginTimesOut() async throws {
        let r = try Rig(timeout: .milliseconds(500)); defer { r.scratch.cleanup() }
        let p = r.provider(r.spec(mode: "slow"))
        let started = ContinuousClock.now
        await #expect(throws: ExecCredentialError.timedOut(command: r.plugin.path)) { _ = try await p.authorization() }
        #expect(started.duration(to: .now) < .seconds(8))
    }

    @Test func clientCertificateCredentialsAreServedAsMaterial() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let p = r.provider(r.spec(mode: "cert"))
        #expect(try await p.authorization() == nil)
        #expect(try await p.clientCertificate() == ClientCertificateMaterial(certificatePEM: "CERT-1", keyPEM: "KEY-1"))
    }

    @Test func aRotatedCertificateTellsTheOwnerToRebuildTheClient() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let expiry = rfc3339(r.clock.now.addingTimeInterval(600))
        let p = r.provider(r.spec(mode: "cert", env: ["PLUGIN_EXPIRY": expiry]))
        let rotations = Mutex(0)
        await p.onCertificateRotation { rotations.withLock { $0 += 1 } }
        _ = try await p.clientCertificate()
        #expect(rotations.withLock { $0 } == 0)
        r.clock.advance(500)
        #expect(try await p.clientCertificate() == ClientCertificateMaterial(certificatePEM: "CERT-2", keyPEM: "KEY-2"))
        #expect(rotations.withLock { $0 } == 1)
    }

    @Test func kubernetesExecInfoCarriesTheClusterOnlyWhenAsked() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        _ = try await r.provider(r.spec()).authorization()
        let plain = try #require(try JSONValue.parse(Data(contentsOf: r.infoFile)).objectValue)
        #expect(plain["apiVersion"]?.stringValue == "client.authentication.k8s.io/v1")
        #expect(plain["kind"]?.stringValue == "ExecCredential")
        #expect(plain["spec"]?.objectValue?["interactive"]?.boolValue == false)
        #expect(plain["spec"]?.objectValue?["cluster"] == nil)

        var withInfo = r.spec(provideClusterInfo: true)
        withInfo.clusterConfig = ["audience": "sts"]
        _ = try await r.provider(withInfo, server: "https://info.example.test:6443").authorization()
        let rich = try #require(try JSONValue.parse(Data(contentsOf: r.infoFile)).objectValue?["spec"]?.objectValue?["cluster"]?.objectValue)
        #expect(rich["server"]?.stringValue == "https://info.example.test:6443")
        #expect(rich["tls-server-name"]?.stringValue == "tls.example.test")
        #expect(rich["certificate-authority-data"]?.stringValue == "Q0E=")
        #expect(rich["insecure-skip-tls-verify"]?.boolValue == false)
        #expect(rich["config"]?.objectValue?["audience"]?.stringValue == "sts")
    }

    @Test func theStanzaEnvAndTheAllowlistReachThePlugin() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let envFile = r.scratch.root.appending(path: "env.txt")
        let script = try r.scratch.write("printenv.sh", "#!/bin/sh\n/usr/bin/env > \(envFile.path)\nprintf '{\"apiVersion\":\"client.authentication.k8s.io/v1\",\"kind\":\"ExecCredential\",\"status\":{\"token\":\"x\"}}'\n", mode: 0o755)
        var spec = KubeconfigExecSpec(command: script.path, env: [.init(name: "MY_STANZA_VAR", value: "from-stanza")])
        spec.apiVersion = "client.authentication.k8s.io/v1"
        _ = try await r.provider(spec).authorization()
        let env = try String(contentsOf: envFile, encoding: .utf8)
        #expect(env.contains("MY_STANZA_VAR=from-stanza"))
        #expect(env.contains("KUBERNETES_EXEC_INFO="))
        #expect(env.contains("KUBECACHEDIR="))
        #expect(!env.contains("ANTHROPIC_API_KEY"))
        #expect(!env.contains("DYLD_"))
    }

    @Test func interactiveModeAlwaysNeedsTheSignInSheet() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let p = r.provider(r.spec(mode: "interactive", interactiveMode: "Always"))
        await #expect(throws: ExecCredentialError.signInRequired(command: r.plugin.path)) { _ = try await p.authorization() }
        #expect(r.runs == 0)
        // The sheet runs the plugin on a PTY (stdout on a pipe) and hands the JSON back.
        let json = #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"from-sheet"}}"#
        try await p.completeSignIn(stdout: Data(json.utf8))
        #expect(try await p.authorization() == "from-sheet")
    }

    @Test func theInteractiveSpecAsksThePluginForInteractiveTrue() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let p = r.provider(r.spec(mode: "interactive", interactiveMode: "Always"))
        let spec = try await p.interactiveSpec()
        let info = try #require(try JSONValue.parse(Data((spec.environment["KUBERNETES_EXEC_INFO"] ?? "").utf8)).objectValue)
        #expect(info["spec"]?.objectValue?["interactive"]?.boolValue == true)
        #expect(spec.timeout == .seconds(300))
        // Run it exactly as the Sign-in sheet does: stdin and stderr on the PTY, stdout on a pipe.
        let pty = try PTYProcess(spec: spec, size: (80, 24), stdoutPipe: true, helper: try PTYHelper.url())
        pty.write(Data("424242\n".utf8))
        var stdout = Data()
        for await chunk in pty.stdout { stdout.append(chunk) }
        try await p.completeSignIn(stdout: stdout)
        #expect(try await p.authorization() == "tok-424242")
    }

    @Test func providerLoginCommandsComeFromTheStanza() {
        let spec = KubeconfigExecSpec(command: "/usr/local/bin/aws", args: ["eks", "get-token", "--cluster-name", "x", "--profile", "platform-prod"])
        let p = ExecCredentialProvider(spec: spec, cluster: nil, kubeconfigPath: "/kc", broker: ExecCredentialBroker(locator: { ExecutableLocator(searchPath: []) }, environment: { EnvironmentBuilder(snapshot: nil) }))
        #expect(p.providerLoginCommand()?.program == "aws")
        #expect(p.providerLoginCommand()?.arguments == ["sso", "login", "--profile", "platform-prod"])
        let g = ExecCredentialProvider(spec: KubeconfigExecSpec(command: "gke-gcloud-auth-plugin"), cluster: nil, kubeconfigPath: "/kc", broker: ExecCredentialBroker(locator: { ExecutableLocator(searchPath: []) }, environment: { EnvironmentBuilder(snapshot: nil) }))
        #expect(g.providerLoginCommand()?.program == "gcloud")
    }

    @Test func refreshTasksExistOnlyForClustersWithConsumers() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        let expiry = rfc3339(r.clock.now.addingTimeInterval(3600))
        let a = r.provider(r.spec(env: ["PLUGIN_EXPIRY": expiry]), server: "https://a.example.test")
        let b = r.provider(r.spec(env: ["PLUGIN_EXPIRY": expiry]), server: "https://b.example.test")
        _ = try await a.authorization()
        _ = try await b.authorization()
        #expect(await r.broker.scheduledRefreshKeys.isEmpty)       // nobody is using either cluster
        await a.beginUse()
        #expect(await r.broker.scheduledRefreshKeys == [a.key])    // only the one with a consumer
        await a.endUse()
        #expect(await r.broker.scheduledRefreshKeys.isEmpty)
        await b.beginUse()
        await b.endUse()
        #expect(await r.broker.scheduledRefreshKeys.isEmpty)
    }

    @Test func theGateBlocksPluginsForNonTestHosts() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let r = try Rig(gate: activeGate(home: s.root, hosts: ["allowed.example.test"])); defer { r.scratch.cleanup() }
        let blocked = r.provider(r.spec(), server: "https://prod.example.com:6443")
        await #expect(throws: ExecCredentialError.self) { _ = try await blocked.authorization() }
        #expect(r.runs == 0)
        #expect(try await r.provider(r.spec(), server: "https://allowed.example.test:6443").authorization() == "tok-1")
        #expect(try await r.provider(r.spec(), server: "https://fixture.test:6443").authorization() != nil)   // reserved fixture names are allowed
    }

    @Test func thePluginGateIsReadOnEveryRunNotWhenTheBrokerIsBuilt() async throws {
        // The broker is built at launch, before the allowed hosts exist; a plugin for the test cluster must run once they are known.
        let s = try Scratch(); defer { s.cleanup() }
        let hosts = Mutex<Set<String>>([])
        let home = s.root
        let r = try Rig(gateProvider: { activeGate(home: home, hosts: hosts.withLock { $0 }) }); defer { r.scratch.cleanup() }
        let p = r.provider(r.spec(), server: "https://allowed.example.com:6443")
        await #expect(throws: ExecCredentialError.self) { _ = try await p.authorization() }
        #expect(r.runs == 0)
        hosts.withLock { $0 = ["allowed.example.com"] }
        r.clock.advance(Rig.rerunPause)                       // a failed run is not repeated within the re-run interval
        #expect(try await p.authorization() == "tok-1")
    }

    @Test func theStanzaCannotPointAPluginAtAnotherKubeconfigWhileTheGateIsActive() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let gated = try Rig(gate: activeGate(home: s.root)); defer { gated.scratch.cleanup() }
        let spec = gated.spec(env: ["KUBECONFIG": "/Users/someone/.kube/config", "KEEP": "yes"])
        let provider = gated.provider(spec)
        let env = await gated.broker.makeProcessSpec(provider.request, executable: gated.plugin, interactive: false).environment
        #expect(env["KUBECONFIG"] == nil)
        #expect(env["KEEP"] == "yes")
        #expect(env["KUBERNETES_EXEC_INFO"] != nil)
        // With the gate off the stanza is honoured as before.
        let open = try Rig(); defer { open.scratch.cleanup() }
        let openEnv = await open.broker.makeProcessSpec(open.provider(open.spec(env: ["KUBECONFIG": "/x/kc"])).request, executable: open.plugin, interactive: false).environment
        #expect(openEnv["KUBECONFIG"] == "/x/kc")
    }

    @Test func nothingIsWrittenToDiskExceptThePluginsOwnFiles() async throws {
        let r = try Rig(); defer { r.scratch.cleanup() }
        _ = try await r.provider(r.spec()).authorization()
        let names = try FileManager.default.contentsOfDirectory(atPath: r.scratch.root.path).sorted()
        #expect(names == ["counter", "info.json", "plugin.sh"])
    }
}
#endif
