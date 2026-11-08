#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// A composite over a real `ClusterMetadataStore` with an in-memory mirror, so what would reach iCloud can be inspected.
private struct Stack {
    let scratch: Scratch
    let mirror = InMemoryMetadataMirror()
    let credentials = InMemoryCredentialStore()
    let state: MooringsState
    let settings: MacClusterSettingsStore
    let composite: CompositeMetadataStore
    let creds: CompositeCredentialStore
    let service: MooringsService

    init(files: [URL], scratch s: Scratch, firstRun: Bool = true) throws {
        scratch = s
        let home = try s.home()
        state = MooringsState(overrides: DiscoveredClusterStore(fileURL: s.root.appending(path: "discovered-clusters.json")),
                              preferences: MooringsPreferencesStore(fileURL: s.root.appending(path: "moorings.json")), gate: openGate(home: home))
        try state.preferences.update { $0.firstRunCompleted = firstRun }
        settings = MacClusterSettingsStore(fileURL: s.root.appending(path: "cluster-settings.json"))
        let metadata = ClusterMetadataStore(directory: try s.dir("meta"), mirror: mirror)
        composite = CompositeMetadataStore(keychain: metadata, credentials: credentials, state: state, settings: settings)
        creds = CompositeCredentialStore(keychain: credentials, state: state, gate: openGate(home: home))
        let list = files.map(\.path).joined(separator: ":")
        service = MooringsService(config: MooringsConfiguration(gate: openGate(home: home), home: home, explicitTestKubeconfig: nil, shellKubeconfig: { list }),
                                  state: state, clients: UnusedClients())
    }

    var mirrorText: String { String(decoding: (try? mirror.read()) ?? Data(), as: UTF8.self) }
}

@Suite("Composite stores and sync safety")
struct CompositeStoreTests {
    @Test func discoveredClustersNeverReachTheICloudMirrorEvenWhenSyncIsSetOnThem() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", kubeconfigText(context: "disc", server: "https://disc.example.test:6443"))
        let st = try Stack(files: [file], scratch: s)
        await st.service.rescan()
        var configs = st.composite.load()
        #expect(configs.map(\.name) == ["disc"])
        configs[0].iCloudSync = true                       // someone tries to sync it
        var keychain = ClusterConfig(id: "k-1", name: "kept", server: URL(string: "https://kept.example.test")!, iCloudSync: true)
        keychain.modifiedAt = Date()
        try st.composite.save(configs + [keychain])
        #expect(st.mirrorText.contains("kept"))
        #expect(!st.mirrorText.contains("disc"))
        #expect(!st.mirrorText.contains(configs[0].id))
        #expect(!st.mirrorText.contains("origin"))
    }

    @Test func execAdoptedAndLoopbackClustersAreSavedWithSyncOff() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let st = try Stack(files: [], scratch: s)
        let adopted = ClusterConfig(id: "adopted-exec", name: "exec", server: URL(string: "https://eks.example.test")!, authKind: .none, iCloudSync: true)
        try st.settings.update("adopted-exec") {
            $0.execAdopted = ExecAdoption(spec: KubeconfigExecSpec(command: "aws"), specHash: "h", kubeconfigPath: "/kc")
        }
        let loopback = ClusterConfig(id: "loop", name: "local", server: URL(string: "https://127.0.0.1:8443")!, iCloudSync: true)
        let localhost = ClusterConfig(id: "lh", name: "lh", server: URL(string: "https://dev.localhost:8443")!, iCloudSync: true)
        let v6 = ClusterConfig(id: "v6", name: "v6", server: URL(string: "https://[::1]:8443")!, iCloudSync: true)
        let net127 = ClusterConfig(id: "n127", name: "n127", server: URL(string: "https://127.5.6.7:8443")!, iCloudSync: true)
        let remote = ClusterConfig(id: "remote", name: "remote", server: URL(string: "https://remote.example.test")!, iCloudSync: true)
        try st.composite.save([adopted, loopback, localhost, v6, net127, remote])
        let saved = Dictionary(uniqueKeysWithValues: st.composite.load().map { ($0.id, $0) })
        for id in ["adopted-exec", "loop", "lh", "v6", "n127"] { #expect(saved[id]?.iCloudSync == false, "\(id) must not sync") }
        #expect(saved["remote"]?.iCloudSync == true)
        #expect(!st.mirrorText.contains("adopted-exec"))
        #expect(!st.mirrorText.contains("loop"))
        #expect(st.mirrorText.contains("remote"))
    }

    @Test func loopbackDetectionMatchesTheSpec() {
        for url in ["https://127.0.0.1", "https://127.255.255.254:1", "https://localhost", "https://a.b.localhost", "https://[::1]:6443", "https://LOCALHOST:1"] {
            #expect(ServerURL.isLoopback(URL(string: url)!), "\(url)")
        }
        for url in ["https://128.0.0.1", "https://10.0.0.1", "https://localhost.example.com", "https://notlocalhost", "https://127.0.0.1.example.test"] {
            #expect(!ServerURL.isLoopback(URL(string: url)!), "\(url)")
        }
    }

    @Test func aDiscoveredClusterResolvesItsCredentialsFromTheFileEveryTime() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let tokenFile = try s.write("sa/token", "token-one\n")
        let ca = try s.write("sa/ca.crt", "-----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----\n")
        let file = try s.write("kc.yaml", kubeconfigText(context: "files", user: "    tokenFile: \(tokenFile.path)", clusterName: "fc")
            .replacingOccurrences(of: "server: https://prod-eu.example.test:6443", with: "server: https://files.example.test:6443\n    certificate-authority: \(ca.path)"))
        let st = try Stack(files: [file], scratch: s)
        await st.service.rescan()
        let id = try #require(st.state.contexts.first?.id)
        #expect(try st.creds.load(clusterID: id).token == "token-one")
        #expect(try st.creds.load(clusterID: id).caPEM?.contains("BEGIN CERTIFICATE") == true)
        // The projected token rotates on disk; the next load sees it.
        try "token-two".write(to: tokenFile, atomically: true, encoding: .utf8)
        #expect(try st.creds.load(clusterID: id).token == "token-two")
    }

    @Test func discoveredCredentialsCannotBeSavedOrDeleted() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let st = try Stack(files: [], scratch: s)
        #expect(throws: CompositeStoreError.notAdopted) { try st.creds.save(ClusterSecrets(token: "t"), clusterID: "kc-abc", synchronizable: true) }
        try st.creds.delete(clusterID: "kc-abc")            // no-op, not an error
        try st.creds.save(ClusterSecrets(token: "t"), clusterID: "uuid-1", synchronizable: false)
        #expect(try st.creds.load(clusterID: "uuid-1").token == "t")
    }

    @Test func credentialFilesMustBeRegularOwnedAndSmall() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let gate = openGate(home: s.root)
        let good = try s.write("good", "abc")
        #expect(try DiscoveredSecrets.readFile(good.path, gate: gate) == "abc")
        #expect(throws: CredentialResolveError.self) { _ = try DiscoveredSecrets.readFile(good.path, uid: getuid() &+ 1, gate: gate) }
        let big = try s.write("big", String(repeating: "x", count: (1 << 20) + 1))
        #expect(throws: CredentialResolveError.self) { _ = try DiscoveredSecrets.readFile(big.path, gate: gate) }
        #expect(throws: CredentialResolveError.self) { _ = try DiscoveredSecrets.readFile(s.root.path, gate: gate) }
        #expect(throws: CredentialResolveError.self) { _ = try DiscoveredSecrets.readFile(s.root.appending(path: "missing").path, gate: gate) }
    }

    @Test func credentialFilesUnderHomeKubeAreRefusedWhileTheGateIsActive() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let home = try s.home()
        let inside = try s.write("home/.kube/token", "secret")
        #expect(throws: DevSafetyError.self) { _ = try DiscoveredSecrets.readFile(inside.path, gate: activeGate(home: home)) }
        #expect(try DiscoveredSecrets.readFile(inside.path, gate: openGate(home: home)) == "secret")
    }

    // MARK: Duplicates (decision 11)

    @Test func aContextWithTheSameServerAndTokenIsOneRowAndTheKeychainEntryWins() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", kubeconfigText(context: "dup", server: "https://Dup.Example.test:443/", user: "    token: shared-token"))
        let st = try Stack(files: [file], scratch: s)
        await st.service.rescan()
        let disc = try #require(st.state.contexts.first)
        try await st.service.completeFirstRun(choices: [disc.id: FirstRunChoice(selected: true)])
        #expect(st.composite.load().count == 1)
        // The same cluster is in the Keychain (synced from the iPhone): same server (normalised) and the same token.
        let kc = ClusterConfig(id: "keychain-1", name: "From iPhone", server: URL(string: "https://dup.example.test")!, iCloudSync: true)
        try st.credentials.save(ClusterSecrets(token: "shared-token"), clusterID: kc.id, synchronizable: true)
        try st.composite.keychainSaveForTest([kc])
        let loaded = st.composite.load()
        #expect(loaded.map(\.id) == ["keychain-1"])
        #expect(st.state.duplicateOf(disc.id) == "keychain-1")
        #expect(st.state.info(for: disc.id)?.duplicateOf == "keychain-1")
    }

    @Test func aDifferentTokenOrServerIsNotADuplicate() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", kubeconfigText(context: "nd", server: "https://nd.example.test:6443", user: "    token: mine"))
        let st = try Stack(files: [file], scratch: s)
        await st.service.rescan()
        let disc = try #require(st.state.contexts.first)
        try await st.service.completeFirstRun(choices: [disc.id: FirstRunChoice(selected: true)])
        let sameServerOtherToken = ClusterConfig(id: "k1", name: "k1", server: URL(string: "https://nd.example.test:6443")!)
        let otherServerSameToken = ClusterConfig(id: "k2", name: "k2", server: URL(string: "https://elsewhere.example.test")!)
        try st.credentials.save(ClusterSecrets(token: "theirs"), clusterID: "k1", synchronizable: false)
        try st.credentials.save(ClusterSecrets(token: "mine"), clusterID: "k2", synchronizable: false)
        try st.composite.keychainSaveForTest([sameServerOtherToken, otherServerSameToken])
        #expect(Set(st.composite.load().map(\.id)) == ["k1", "k2", disc.id])
        #expect(st.state.duplicateOf(disc.id) == nil)
    }

    @Test func removingTheKeychainClusterMakesTheContextARowOfItsOwnAgain() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", kubeconfigText(context: "back", server: "https://back.example.test:6443", user: "    token: tt"))
        let st = try Stack(files: [file], scratch: s)
        await st.service.rescan()
        let disc = try #require(st.state.contexts.first)
        try await st.service.completeFirstRun(choices: [disc.id: FirstRunChoice(selected: true)])
        let kc = ClusterConfig(id: "k", name: "k", server: URL(string: "https://back.example.test:6443")!)
        try st.credentials.save(ClusterSecrets(token: "tt"), clusterID: "k", synchronizable: false)
        try st.composite.keychainSaveForTest([kc])
        #expect(st.composite.load().map(\.id) == ["k"])
        try st.composite.keychainSaveForTest([])
        #expect(st.composite.load().map(\.id) == [disc.id])
    }

    // MARK: Overlay behaviour

    @Test func editsToADiscoveredClusterAreStoredAsOverridesAndReadOnlyCannotBeRelaxedWithoutAnEnvironmentChoice() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", kubeconfigText(context: "ov", server: "https://ov.example.test:6443"))
        let st = try Stack(files: [file], scratch: s)
        await st.service.rescan()
        let disc = try #require(st.state.contexts.first)
        try await st.service.completeFirstRun(choices: [disc.id: FirstRunChoice(selected: true, environment: .staging)])
        var config = try #require(st.composite.load().first)
        #expect(config.readOnly)
        config.readOnly = false                            // the UI is bypassed
        config.name = "Renamed"
        config.pinnedNamespaces = ["kube-system"]
        try st.composite.save([config])
        let reloaded = try #require(st.composite.load().first)
        #expect(reloaded.readOnly, "an unchosen environment keeps the cluster read-only")
        #expect(reloaded.name == "Renamed")
        #expect(reloaded.pinnedNamespaces == ["kube-system"])
        // Once the environment was chosen explicitly, the same edit is honoured.
        try await st.service.allowChanges(id: disc.id, environment: .development)
        var c2 = try #require(st.composite.load().first)
        #expect(!c2.readOnly && c2.environment == .development)
        c2.name = "Renamed again"
        try st.composite.save([c2])
        #expect(st.composite.load().first?.readOnly == false)
        #expect(st.composite.load().first?.name == "Renamed again")
    }

    @Test func removingADiscoveredClusterHidesIt() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", kubeconfigText(context: "rm"))
        let st = try Stack(files: [file], scratch: s)
        await st.service.rescan()
        let disc = try #require(st.state.contexts.first)
        try await st.service.completeFirstRun(choices: [disc.id: FirstRunChoice(selected: true)])
        #expect(st.composite.load().count == 1)
        try st.composite.save([])
        #expect(st.composite.load().isEmpty)
        #expect(st.state.overrides.override(for: disc.id)?.hidden == true)
    }

    // MARK: Adopt

    @Test func adoptCopiesCredentialsIntoANewKeychainClusterWithSyncOff() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let tokenFile = try s.write("tok", "from-file")
        let file = try s.write("kc.yaml", kubeconfigText(context: "ad", server: "https://ad.example.test:6443", user: "    tokenFile: \(tokenFile.path)"))
        let st = try Stack(files: [file], scratch: s)
        await st.service.rescan()
        let disc = try #require(st.state.contexts.first)
        try await st.service.completeFirstRun(choices: [disc.id: FirstRunChoice(selected: true, environment: .staging, environmentPicked: true)])
        let adoption = try await st.service.prepareAdoption(id: disc.id)
        #expect(adoption.config.origin == nil)
        #expect(adoption.config.id != disc.id)
        #expect(adoption.config.iCloudSync == false)
        #expect(adoption.config.environment == .staging)
        #expect(adoption.secrets.token == "from-file")
        #expect(adoption.execAdoption == nil)
    }

    @Test func adoptingAnExecContextKeepsTheStanzaOnTheMacAndTheKeychainHoldsTheCAOnly() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let ca = Data("-----BEGIN CERTIFICATE-----\nQQ==\n-----END CERTIFICATE-----\n".utf8).base64EncodedString()
        let yaml = kubeconfigText(context: "ex", server: "https://ex.example.test:6443", user: "    exec: {apiVersion: client.authentication.k8s.io/v1, command: aws, args: [eks, get-token]}")
            .replacingOccurrences(of: "server: https://ex.example.test:6443", with: "server: https://ex.example.test:6443\n    certificate-authority-data: \(ca)")
        let file = try s.write("kc.yaml", yaml)
        let st = try Stack(files: [file], scratch: s)
        await st.service.rescan()
        let disc = try #require(st.state.contexts.first)
        let adoption = try await st.service.prepareAdoption(id: disc.id)
        #expect(adoption.config.authKind == .none)
        #expect(adoption.secrets.token == nil && adoption.secrets.clientKeyPEM == nil)
        #expect(adoption.secrets.caPEM?.contains("BEGIN CERTIFICATE") == true)
        let exec = try #require(adoption.execAdoption)
        #expect(exec.spec.command == "aws")
        // Committing it (settings first) keeps it off iCloud even when the toggle is on.
        try st.settings.update(adoption.config.id) { $0.execAdopted = exec }
        var synced = adoption.config
        synced.iCloudSync = true
        try st.composite.save([synced])
        #expect(st.composite.load().first { $0.id == synced.id }?.iCloudSync == false)
        #expect(!st.mirrorText.contains(synced.id))
    }

    @Test func settingsKeepFieldsOwnedByLaterMilestones() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let url = s.root.appending(path: "cluster-settings.json")
        try #"{"version":1,"clusters":{"c1":{"firstMateAccess":"ask","terminalMode":"direct","beaconExposure":{"claude":"read"}}},"orphanedAt":{}}"#.write(to: url, atomically: true, encoding: .utf8)
        let store = MacClusterSettingsStore(fileURL: url)
        try store.update("c1") { $0.execAdopted = ExecAdoption(spec: KubeconfigExecSpec(command: "aws"), specHash: "h", kubeconfigPath: "/kc") }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("firstMateAccess") && text.contains("terminalMode") && text.contains("beaconExposure") && text.contains("execAdopted"))
    }

    @MainActor @Test func editingADiscoveredClusterWithACASavesAndLeavesReadOnlyThroughMoorings() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let pem = "-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----\n"                  // the file's CA ends with a newline
        let yaml = """
        clusters:
        - name: c
          cluster: {server: "https://ca.example.test:6443", certificate-authority-data: \(Data(pem.utf8).base64EncodedString())}
        users:
        - {name: u, user: {token: tok}}
        contexts:
        - {name: with-ca, context: {cluster: c, user: u}}
        """
        let st = try Stack(files: [try s.write("kc.yaml", yaml)], scratch: s)
        await st.service.rescan()
        let ctx = try #require(st.state.contexts.first)
        try await st.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .staging, environmentPicked: true)])
        let registry = ClusterRegistry(credentials: st.creds, metadata: st.composite, defaults: try #require(UserDefaults(suiteName: "wh.m3.\(UUID().uuidString)")))
        let current = try #require(registry.clusters.first)
        #expect(current.readOnly)
        let existing = registry.secrets(for: current.id)
        #expect(existing.caPEM == pem)
        var draft = ClusterDraft(editing: current, secrets: existing)
        draft.name = "renamed"
        draft.readOnly = false
        let edited = draft.makeSecrets(existing: existing)
        #expect(edited != existing)                                       // the draft trims the CA: a plain update would try to save it
        let target = try #require(draft.makeConfig())
        let outcome = try await ClusterChangeSaver.save(allowing: st.service, current: current, target: target, environmentConfirmed: false) { config, managed in
            try registry.update(config, secrets: ClusterChangeSaver.secretsToWrite(managed: managed, existing: existing, edited: edited))
        }
        #expect(outcome == .saved)
        registry.reloadFromStore(invalidating: [current.id])              // what Moorings' change notification does
        let after = try #require(registry.clusters.first)
        #expect(after.name == "renamed")
        #expect(after.readOnly == false)
        #expect(st.service.environmentChosen(for: current.id))
        // The plain update that failed before: the composite refuses secrets for a discovered cluster.
        #expect(throws: CompositeStoreError.self) { try st.creds.save(edited, clusterID: current.id, synchronizable: false) }
    }
}

extension CompositeMetadataStore {
    /// Saves Keychain clusters through the real composite save (no discovered clusters in the list).
    func keychainSaveForTest(_ clusters: [ClusterConfig]) throws {
        let discovered = load().filter { $0.origin != nil }
        try save(clusters + discovered)
    }
}
#endif
