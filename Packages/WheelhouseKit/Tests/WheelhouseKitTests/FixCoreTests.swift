import Foundation
import Network
import Security
import Testing
@testable import WheelhouseKit

// MARK: - Read-only and transport rules

@Suite("Client transport rules")
struct ClientTransportRulesTests {
    private func client(readOnly: Bool = false, allowExec: Bool = false, environment: ClusterEnvironment = .development,
                        scheme: String = "https") -> LiveKubeClient {
        let config = ClusterConfig(name: "t", server: URL(string: "\(scheme)://127.0.0.1:1")!, environment: environment,
                                   readOnly: readOnly, allowExecInReadOnly: allowExec)
        return LiveKubeClient(config: config, secrets: ClusterSecrets(token: "x"))
    }

    @Test func readOnlyRefusesReplaceAndPortForward() async {
        let c = client(readOnly: true)
        await #expect(throws: KubeError.readOnly) { _ = try await c.replace(.configMap, name: "a", namespace: "d", body: [:], options: MutationOptions()) }
        #expect(throws: KubeError.readOnly) { try c.portForwardWebSocket(namespace: "d", pod: "p", ports: [80]) }
        #expect(throws: KubeError.readOnly) { try c.execWebSocket(namespace: "d", pod: "p", options: ExecOptions()) }
    }

    @Test func allowExecInReadOnlyOpensSockets() throws {
        let c = client(readOnly: true, allowExec: true)
        let ws = try c.execWebSocket(namespace: "d", pod: "p", options: ExecOptions())
        #expect(ws.offeredProtocols.first == "v5.channel.k8s.io")
        ws.close()
        // …but mutations stay refused.
        #expect(throws: Never.self) { _ = try c.portForwardWebSocket(namespace: "d", pod: "p", ports: [80]).close() }
    }

    @Test func accessReviewsAreExemptFromReadOnly() async {
        let c = client(readOnly: true)
        do {
            _ = try await c.create(.selfSubjectAccessReview, namespace: nil, body: [:])
            Issue.record("unexpected success against 127.0.0.1:1")
        } catch let e as KubeError {
            #expect(e != .readOnly)      // it reached the network layer (connection refused)
        } catch {}
    }

    @Test func plainHTTPIsRefusedForProduction() async {
        let prod = client(environment: .production, scheme: "http")
        do {
            _ = try await prod.version()
            Issue.record("expected failure")
        } catch let e as KubeError {
            guard case .unreachable(let cause) = e else { Issue.record("wrong error \(e)"); return }
            #expect(cause.contains("Plain HTTP"))
        } catch {}
        #expect(throws: KubeError.self) { try prod.execWebSocket(namespace: "d", pod: "p", options: ExecOptions()) }
        // Non-production HTTP still reaches the network (and fails with connection refused, not the policy error).
        let dev = client(environment: .development, scheme: "http")
        do { _ = try await dev.version() } catch let e as KubeError {
            if case .unreachable(let cause) = e { #expect(!cause.contains("Plain HTTP")) }
        } catch {}
    }

    @Test func draftAndConfigRejectHTTPForProduction() {
        var d = ClusterDraft()
        d.name = "p"; d.serverText = "http://api.example.com:6443"; d.token = "t"; d.environment = .production
        #expect(d.problems.contains(.httpNotAllowedForProduction))
        d.environment = .staging
        #expect(!d.problems.contains(.httpNotAllowedForProduction))
        let cfg = ClusterConfig(name: "p", server: URL(string: "http://x")!, environment: .production)
        #expect(cfg.violatesHTTPProductionRule)
    }
}

// MARK: - Watch stream robustness (local HTTP server)

/// Serves one canned HTTP/1.1 response on loopback.
private final class OneShotServer: @unchecked Sendable {
    let listener: NWListener
    let port: UInt16
    private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }
    deinit { listener.cancel() }

    static func start(body: Data) async throws -> OneShotServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "oneshot")
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if !done { done = true; cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let e): if !done { done = true; cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return OneShotServer(listener: listener, port: port)
    }
}

@Suite("Watch stream")
struct WatchRobustnessTests {
    @Test func undecodableObjectsAreSkippedAndLinesSplitOnLFOnly() async throws {
        func frame(_ type: String, _ name: String, note: String = "") -> String {
            #"{"type":"\#(type)","object":{"apiVersion":"v1","kind":"Pod","metadata":{"name":"\#(name)","namespace":"d","annotations":{"note":"\#(note)"}},"spec":{"containers":[]}}}"#
        }
        let bad = #"{"type":"ADDED","object":{"apiVersion":"v1","kind":"Pod","metadata":{"name":12,"namespace":[]}}}"#
        // U+2028 / U+0085 inside a string value must not split the frame (`bytes.lines` would).
        let body = [frame("ADDED", "a", note: "x\u{2028}y\u{0085}z"), bad, "not json at all", frame("MODIFIED", "a"), frame("DELETED", "a")]
            .joined(separator: "\n") + "\n"
        let server = try await OneShotServer.start(body: Data(body.utf8))
        let config = ClusterConfig(name: "w", server: URL(string: "http://127.0.0.1:\(server.port)")!)
        let client = LiveKubeClient(config: config, secrets: ClusterSecrets(token: "x"))
        var kinds: [String] = []
        for try await event in client.watch(Pod.self, namespace: "d", options: WatchOptions()) {
            switch event {
            case .added(let p): kinds.append("added:\(p.metadata.name)")
            case .modified(let p): kinds.append("modified:\(p.metadata.name)")
            case .deleted(let p): kinds.append("deleted:\(p.metadata.name)")
            default: break
            }
        }
        #expect(kinds == ["added:a", "modified:a", "deleted:a"], "got \(kinds)")
        #expect(client.skippedWatchObjectCount >= 1)
    }

    @Test func errorFramesAreFatal() async throws {
        let body = #"{"type":"ERROR","object":{"kind":"Status","apiVersion":"v1","status":"Failure","message":"too old resource version","reason":"Expired","code":410}}"# + "\n"
        let server = try await OneShotServer.start(body: Data(body.utf8))
        let config = ClusterConfig(name: "w", server: URL(string: "http://127.0.0.1:\(server.port)")!)
        let client = LiveKubeClient(config: config, secrets: ClusterSecrets(token: "x"))
        await #expect(throws: KubeError.self) {
            for try await _ in client.watch(Pod.self, namespace: "d", options: WatchOptions()) {}
        }
    }
}

// MARK: - Credentials and metadata sync

@Suite("Keychain ordering")
struct KeychainOrderingTests {
    let service = "svc", account = "acct"

    @Test func syncOffWritesLocalCopyBeforeRemovingTheSyncedOne() throws {
        let kc = InMemoryKeychain()
        try KeychainAccess.write(Data("v1".utf8), service: service, account: account, synchronizable: true, in: kc)
        #expect(kc.variants(service: service, account: account).synced == Data("v1".utf8))
        try KeychainAccess.write(Data("v1".utf8), service: service, account: account, synchronizable: false, in: kc)
        let v = kc.variants(service: service, account: account)
        #expect(v.local == Data("v1".utf8))
        #expect(v.synced == nil)
    }

    @Test func aFailedAddNeverLosesTheExistingItem() throws {
        let kc = InMemoryKeychain()
        try KeychainAccess.write(Data("secret".utf8), service: service, account: account, synchronizable: true, in: kc)
        kc.failUpserts = true
        #expect(throws: KeychainError.self) {
            try KeychainAccess.write(Data("secret".utf8), service: service, account: account, synchronizable: false, in: kc)
        }
        #expect(kc.variants(service: service, account: account).synced == Data("secret".utf8))
    }

    @Test func credentialStoreRoundTripsAndSwitchesVariants() throws {
        let kc = InMemoryKeychain()
        let store = KeychainCredentialStore(backend: kc)
        try store.save(ClusterSecrets(token: "t1"), clusterID: "c1", synchronizable: true)
        #expect(try store.load(clusterID: "c1").token == "t1")
        try store.save(ClusterSecrets(token: "t2"), clusterID: "c1", synchronizable: false)
        let v = kc.variants(service: "app.wheelhouse.credentials", account: "c1")
        #expect(v.synced == nil)
        #expect(v.local != nil)
        #expect(try store.load(clusterID: "c1").token == "t2")
        try store.delete(clusterID: "c1")
        #expect(try store.load(clusterID: "c1").isEmpty)
    }

    @Test func missingCredentialsAreDetected() {
        #expect(ClusterSecrets().isMissingCredentials(for: .token))
        #expect(!ClusterSecrets(token: "x").isMissingCredentials(for: .token))
        #expect(ClusterSecrets(clientCertificatePEM: "c").isMissingCredentials(for: .clientCertificate))
        #expect(!ClusterSecrets().isMissingCredentials(for: .none))
    }
}

@Suite("Cluster metadata sync")
struct MetadataSyncTests {
    private func device(_ mirror: InMemoryMetadataMirror) throws -> ClusterMetadataStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-meta-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ClusterMetadataStore(directory: dir, mirror: mirror)
    }
    private func cluster(_ name: String, sync: Bool = true, modified: Date = Date()) -> ClusterConfig {
        ClusterConfig(id: name, name: name, server: URL(string: "https://\(name).example.com")!, iCloudSync: sync, createdAt: modified, modifiedAt: modified)
    }

    @Test func saveMergesClustersAddedOnAnotherDevice() throws {
        let mirror = InMemoryMetadataMirror()
        let a = try device(mirror), b = try device(mirror)
        try a.save([cluster("alpha")])
        try b.save([cluster("beta")])                       // B never loaded A's cluster before saving
        let merged = Set(try device(mirror).load().map(\.id))
        #expect(merged == ["alpha", "beta"])
    }

    @Test func deletionOnOneDeviceIsNotResurrectedFromAnother() throws {
        let mirror = InMemoryMetadataMirror()
        let old = Date().addingTimeInterval(-3600)
        let a = try device(mirror), b = try device(mirror)
        try a.save([cluster("alpha", modified: old)])
        _ = b.load()
        try b.save(b.load())                                // B now has alpha locally
        try a.save([])                                      // A deletes it
        #expect(a.load().isEmpty)
        #expect(b.load().isEmpty)                           // the tombstone removes B's local copy on load
        try b.save(b.load())
        #expect(a.load().isEmpty)
    }

    @Test func newerReAddWinsOverTombstone() throws {
        let mirror = InMemoryMetadataMirror()
        let a = try device(mirror)
        try a.save([cluster("alpha", modified: Date().addingTimeInterval(-100))])
        try a.save([])
        try a.save([cluster("alpha", modified: Date().addingTimeInterval(5))])
        #expect(a.load().map(\.id) == ["alpha"])
    }

    @Test func turningSyncOffPropagatesWithoutDroppingTheCluster() throws {
        let mirror = InMemoryMetadataMirror()
        let a = try device(mirror)
        var c = cluster("alpha", modified: Date().addingTimeInterval(-60))
        try a.save([c])
        c.iCloudSync = false
        c.modifiedAt = Date()
        try a.save([c])
        let other = try device(mirror)
        let loaded = other.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.iCloudSync == false)
    }

    @Test func legacyArrayMirrorStillLoads() throws {
        let mirror = InMemoryMetadataMirror()
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try mirror.write(try e.encode([cluster("legacy")]))
        #expect(try device(mirror).load().map(\.id) == ["legacy"])
    }

    @Test func unsyncedClustersNeverEnterTheMirror() throws {
        let mirror = InMemoryMetadataMirror()
        let a = try device(mirror)
        try a.save([cluster("private", sync: false)])
        #expect(mirror.read() == nil)
    }
}

// MARK: - Redaction, kubeconfig, connection tester

@Suite("Secret redaction")
struct CoreSecretRedactionTests {
    @Test func secretsNeverPrint() {
        let s = ClusterSecrets(token: "TOPSECRET-TOKEN", clientCertificatePEM: "CERTPEM", clientKeyPEM: "KEYPEM-PRIVATE", caPEM: "CAPEM")
        for text in [String(describing: s), String(reflecting: s), "\(s)", dumped(s)] {
            #expect(!text.contains("TOPSECRET"))
            #expect(!text.contains("KEYPEM"))
        }
        let auth = KubeconfigAuth.token("TOPSECRET-TOKEN")
        let cert = KubeconfigAuth.clientCertificate(certificatePEM: "CERTPEM", keyPEM: "KEYPEM-PRIVATE")
        for text in [String(describing: auth), dumped(auth), String(describing: cert), dumped(cert)] {
            #expect(!text.contains("TOPSECRET"))
            #expect(!text.contains("KEYPEM"))
        }
        var draft = ClusterDraft()
        draft.token = "TOPSECRET-TOKEN"
        #expect(!dumped(draft).contains("TOPSECRET"))
        #expect(!dumped(PrometheusEndpoint.url(URL(string: "https://p")!, bearerToken: "TOPSECRET-TOKEN")).contains("TOPSECRET"))
    }
    private func dumped<T>(_ value: T) -> String { var out = ""; dump(value, to: &out); return out }
}

@Suite("Kubeconfig extras")
struct KubeconfigExtrasTests {
    private func yaml(clusterExtra: String) -> String {
        """
        apiVersion: v1
        kind: Config
        current-context: c
        clusters:
        - name: cl
          cluster:
            server: https://203.0.113.5:6443
            \(clusterExtra)
        users:
        - name: u
          user:
            token: abc
        contexts:
        - name: c
          context: {cluster: cl, user: u}
        """
    }

    @Test func parsesTLSServerName() throws {
        let ctx = try #require(try KubeconfigParser.parse(yaml(clusterExtra: "tls-server-name: api.cluster.example")).contexts.first)
        #expect(ctx.tlsServerName == "api.cluster.example")
        #expect(ctx.status == .ready)
    }

    @Test func proxyURLContextsAreFlaggedUnsupported() throws {
        let ctx = try #require(try KubeconfigParser.parse(yaml(clusterExtra: "proxy-url: http://proxy.example:3128")).contexts.first)
        #expect(!ctx.isImportable)
        #expect(ctx.unsupportedReason?.contains("proxy") == true)
    }
}

private struct ProbeClient: KubeClientProtocol {
    /// Verbs the fake server allows for pods/exec and pods/portforward.
    var allowedVerbs: Set<String>
    let seenNamespaces = LockedBox<[String]>([])
    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue {
        let verb = body.value(at: "spec.resourceAttributes.verb")?.stringValue ?? ""
        if let ns = body.value(at: "spec.resourceAttributes.namespace")?.stringValue { seenNamespaces.mutate { $0.append(ns) } }
        return ["status": ["allowed": .bool(allowedVerbs.contains(verb))]]
    }
    func version() async throws -> KubeVersion { try KubeJSON.decoder.decode(KubeVersion.self, from: Data(#"{"major":"1","minor":"34","gitVersion":"v1.34.0"}"#.utf8)) }
    func discovery() async throws -> DiscoveryInfo { throw KubeError.unsupported("stub") }
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> { KubeList(items: []) }
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { throw KubeError.unsupported("stub") }
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> { AsyncThrowingStream { $0.finish() } }
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { throw KubeError.unsupported("stub") }
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func podMetrics(namespace: String?) async throws -> [PodMetrics] { [] }
    func nodeMetrics() async throws -> [NodeMetrics] { [] }
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { Data() }
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { throw KubeError.unsupported("stub") }
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { throw KubeError.unsupported("stub") }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
    var current: T { lock.withLock { value } }
}

@Suite("Connection tester")
struct ConnectionTesterProbeTests {
    @Test func execAllowedWithEitherGetOrCreate() async {
        for verbs in [["get"], ["create"]] as [Set<String>] {
            let r = await ConnectionTester.run(client: ProbeClient(allowedVerbs: verbs))
            #expect(r.capabilities.first { $0.title == "Exec into pods" }?.allowed == true)
            #expect(r.capabilities.first { $0.title == "Port-forward" }?.allowed == true)
        }
        let none = await ConnectionTester.run(client: ProbeClient(allowedVerbs: []))
        #expect(none.capabilities.first { $0.title == "Exec into pods" }?.allowed == false)
    }

    @Test func probesCarryTheDefaultNamespace() async {
        let client = ProbeClient(allowedVerbs: ["get"])
        _ = await ConnectionTester.run(client: client, namespace: "shop")
        #expect(Set(client.seenNamespaces.current) == ["shop"])
    }
}

// MARK: - Port-forward manager

@Suite("Port-forward manager")
struct PortForwardManagerLifecycleTests {
    private let target = PortForwardTarget(kind: .pod, namespace: "d", name: "p", remotePort: 80)
    private func start(_ m: PortForwardManager, cluster: String = "c1") async throws -> PortForwardInfo {
        try await m.start(clusterID: cluster, clusterName: cluster, client: StubLogClient(lines: []), target: target)
    }

    @Test func readOnlyClusterRefusesUpFront() async {
        let m = PortForwardManager()
        await #expect(throws: KubeError.readOnly) {
            try await m.start(clusterID: "c", clusterName: "c", client: StubLogClient(lines: []), target: target, readOnly: true)
        }
        #expect(await m.snapshot().isEmpty)
        // allowExecInReadOnly lifts the refusal.
        let info = try? await m.start(clusterID: "c", clusterName: "c", client: StubLogClient(lines: []), target: target, readOnly: true, allowExecInReadOnly: true)
        #expect(info != nil)
        await m.stopAll()
    }

    @Test func stopAllForClusterLeavesOtherClustersRunning() async throws {
        let m = PortForwardManager()
        let a = try await start(m, cluster: "A"), b = try await start(m, cluster: "B")
        await m.stopAll(clusterID: "A")
        #expect(await m.info(id: a.id)?.state == .stopped)
        #expect(await m.info(id: b.id)?.state == .active)
        await m.stopAll()
    }

    @Test func stoppedForwardsAreNotResumed() async throws {
        let m = PortForwardManager()
        let a = try await start(m, cluster: "A")
        await m.pauseAll()
        #expect(await m.info(id: a.id)?.state == .suspended)
        await m.stopAll(clusterID: "A")
        await m.resumeAll()
        #expect(await m.info(id: a.id)?.state == .stopped)
    }

    @Test func stopDuringResumeDoesNotResurrectTheForward() async throws {
        let m = PortForwardManager()
        let a = try await start(m)
        await m.pauseAll()
        async let resume: Void = m.resumeAll()
        await m.stop(a.id)
        await resume
        let final = await m.info(id: a.id)
        #expect(final?.state == .stopped)
        // The local port must be free again: nothing keeps listening.
        let probe = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(a.localPort))!, using: .tcp)
        let refused = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            nonisolated(unsafe) var done = false
            probe.stateUpdateHandler = { state in
                switch state {
                case .ready: if !done { done = true; cont.resume(returning: false) }
                case .failed, .waiting: if !done { done = true; cont.resume(returning: true) }
                default: break
                }
            }
            probe.start(queue: .global())
        }
        probe.cancel()
        #expect(refused)
    }
}

// MARK: - Live tests (skipped unless the test cluster env is provided)

private enum LiveCert {
    static var path: String? { ProcessInfo.processInfo.environment["WH_KUBECONFIG"] }
}

@Suite("Client identity (keychain)", .enabled(if: LiveCert.path != nil))
struct ClientIdentityLiveTests {
    /// Needs a host with a keychain (the app-hosted test target); the unsigned package host fails with -34018.
    @Test func duplicateLeafUnderTwoLabelsAndConcurrentBuilds() async throws {
        let text = try String(contentsOfFile: try #require(LiveCert.path), encoding: .utf8)
        let ctx = try #require(try KubeconfigParser.parse(text).contexts.first)
        guard case .clientCertificate(let cert, let key) = ctx.auth else { Issue.record("expected client cert"); return }
        let labels = ["app.wheelhouse.identity.test-a", "app.wheelhouse.identity.test-b"]
        defer { labels.forEach { ClientIdentityBuilder.remove(label: $0) } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask { _ = try ClientIdentityBuilder.build(certificatePEM: cert, keyPEM: key, label: labels[i % 2]) }
            }
            try await group.waitForAll()
        }
        _ = try ClientIdentityBuilder.build(certificatePEM: cert, keyPEM: key, label: labels[0])
        // Removing one cluster's key keeps the shared certificate usable by the other.
        ClientIdentityBuilder.remove(label: labels[0])
        _ = try ClientIdentityBuilder.build(certificatePEM: cert, keyPEM: key, label: labels[1])
    }
}
