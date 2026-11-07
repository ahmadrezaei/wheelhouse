#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

@Suite("KubeconfigLoader")
struct KubeconfigLoaderTests {
    @Test func defaultSetMergesInOrderAndFirstDefinitionWins() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let a = try s.write("a.yaml", """
        current-context: from-a
        clusters:
        - {name: shared, cluster: {server: "https://a.example.test"}}
        users:
        - {name: u, user: {token: tok-a}}
        contexts:
        - {name: from-a, context: {cluster: shared, user: u}}
        - {name: dup, context: {cluster: shared, user: u}}
        """)
        let b = try s.write("b.yaml", """
        current-context: from-b
        clusters:
        - {name: shared, cluster: {server: "https://b.example.test"}}
        users:
        - {name: u, user: {token: tok-b}}
        contexts:
        - {name: dup, context: {cluster: shared, user: u}}
        - {name: from-b, context: {cluster: shared, user: u}}
        """)
        let set = try KubeconfigLoader(gate: openGate(home: s.root)).loadDefaultSet([a, b])
        let byName = Dictionary(uniqueKeysWithValues: set.contexts.filter { $0.shadowedBy == nil }.map { ($0.context.name, $0) })
        #expect(Set(byName.keys) == ["from-a", "dup", "from-b"])
        #expect(byName["dup"]?.definingFile == a.path)
        #expect(byName["dup"]?.context.server?.host() == "a.example.test")
        // from-b resolves against the MERGED maps: A's `shared` cluster and A's user.
        #expect(byName["from-b"]?.context.server?.host() == "a.example.test")
        #expect(byName["from-b"]?.context.auth == .token("tok-a"))
        #expect(byName["from-a"]?.isCurrent == true)
        #expect(byName["from-b"]?.isCurrent == false)
        let shadowed = try #require(set.contexts.first { $0.shadowedBy != nil })
        #expect(shadowed.context.name == "dup")
        #expect(shadowed.shadowedBy == "a.yaml")
        #expect(shadowed.definingFile == b.path)
    }

    @Test func missingFilesAreSkippedSilently() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let real = try s.write("real.yaml", kubeconfigText())
        let set = try KubeconfigLoader(gate: openGate(home: s.root)).loadDefaultSet([s.root.appending(path: "nope.yaml"), real])
        #expect(set.contexts.count == 1)
        #expect(set.issues.isEmpty)
    }

    @Test func aFileOverFourMegabytesIsRejectedWithAnIssue() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let big = try s.write("big.yaml", kubeconfigText() + "\n# " + String(repeating: "x", count: 4 * 1024 * 1024 + 10))
        let set = try KubeconfigLoader(gate: openGate(home: s.root)).loadStandalone(big)
        #expect(set.contexts.isEmpty)
        #expect(set.issues[big.path]?.contains("unusually large") == true)
    }

    @Test func standaloneFilesKeepTheirOwnContextsEvenWithEqualNames() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let a = try s.write("a.yaml", kubeconfigText(context: "same", server: "https://a.example.test"))
        let b = try s.write("b.yaml", kubeconfigText(context: "same", server: "https://b.example.test"))
        let loader = KubeconfigLoader(gate: openGate(home: s.root))
        let both = try loader.loadStandalone(a).contexts + loader.loadStandalone(b).contexts
        #expect(Set(both.map { DiscoveredContextKey(definingFile: $0.definingFile, contextName: $0.context.name).clusterID }).count == 2)
    }

    @Test func relativeFileReferencesResolveAgainstTheFilesFolder() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("conf/kc.yaml", kubeconfigText(user: "    tokenFile: ../secrets/token"))
        let ctx = try #require(try KubeconfigLoader(gate: openGate(home: s.root)).loadStandalone(file).contexts.first)
        #expect(ctx.context.files?.tokenFile == s.root.appending(path: "secrets/token").path)
    }

    @Test func folderSourcesScanCandidatesOneLevelAndIgnoreTemporaryFiles() throws {
        let s = try Scratch(); defer { s.cleanup() }
        _ = try s.write("folder/a.yaml", kubeconfigText(context: "a"))
        _ = try s.write("folder/b.yml", kubeconfigText(context: "b"))
        _ = try s.write("folder/kubeconfig-c", kubeconfigText(context: "c"))
        _ = try s.write("folder/notes.txt", "hello")
        _ = try s.write("folder/a.yaml.lock", kubeconfigText(context: "lock"))
        _ = try s.write("folder/.#a.yaml", kubeconfigText(context: "emacs"))
        _ = try s.write("folder/backup.yaml~", kubeconfigText(context: "tilde"))
        _ = try s.write("folder/sub/deep.yaml", kubeconfigText(context: "deep"))
        let loader = KubeconfigLoader(gate: openGate(home: s.root))
        let flat = try loader.loadFolder(s.root.appending(path: "folder"), recursive: false)
        #expect(Set(flat.contexts.map(\.context.name)) == ["a", "b", "c"])
        let deep = try loader.loadFolder(s.root.appending(path: "folder"), recursive: true)
        #expect(Set(deep.contexts.map(\.context.name)) == ["a", "b", "c", "deep"])
    }

    @Test func contentHashesLetTheWatcherSkipUnchangedFiles() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", kubeconfigText())
        let loader = KubeconfigLoader(gate: openGate(home: s.root))
        let first = try loader.loadStandalone(file).fileHashes
        try Data(contentsOf: file).write(to: file)   // rewritten with identical contents
        #expect(try loader.loadStandalone(file).fileHashes == first)
        try (kubeconfigText() + "\n# changed").write(to: file, atomically: true, encoding: .utf8)
        #expect(try loader.loadStandalone(file).fileHashes != first)
    }

    @Test func invalidFilesBecomeIssuesNotCrashes() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let bad = try s.write("bad.yaml", "hello: world")
        let set = try KubeconfigLoader(gate: openGate(home: s.root)).loadStandalone(bad)
        #expect(set.contexts.isEmpty)
        #expect(set.issues[bad.path] != nil)
    }

    @Test func clusterIDIsStableAndDependsOnFileAndName() {
        let k = DiscoveredContextKey(definingFile: "/p/config", contextName: "prod")
        #expect(k.clusterID == DiscoveredContextKey(definingFile: "/p/config", contextName: "prod").clusterID)
        #expect(k.clusterID != DiscoveredContextKey(definingFile: "/p/config", contextName: "prod2").clusterID)
        #expect(k.clusterID != DiscoveredContextKey(definingFile: "/q/config", contextName: "prod").clusterID)
        #expect(k.clusterID.hasPrefix("kc-") && k.clusterID.count == 23)
        // Path and name cannot be shifted into each other.
        #expect(DiscoveredContextKey(definingFile: "/a", contextName: "bc").clusterID != DiscoveredContextKey(definingFile: "/ab", contextName: "c").clusterID)
    }

    @Test func fingerprintChangesWithWhatAClientIsBuiltFromButNotWithTheNamespace() throws {
        func ctx(_ yaml: String) throws -> KubeconfigContext {
            try #require(try KubeconfigParser.parse(yaml, environment: .desktop(baseDirectory: URL(fileURLWithPath: "/x"))).contexts.first)
        }
        let base = try DiscoveredContext.fingerprint(of: ctx(kubeconfigText(user: "    token: a")))
        #expect(try DiscoveredContext.fingerprint(of: ctx(kubeconfigText(user: "    token: a"))) == base)
        #expect(try DiscoveredContext.fingerprint(of: ctx(kubeconfigText(user: "    token: b"))) != base)
        #expect(try DiscoveredContext.fingerprint(of: ctx(kubeconfigText(server: "https://other.example.test", user: "    token: a"))) != base)
        let exec1 = try DiscoveredContext.fingerprint(of: ctx(kubeconfigText(user: "    exec: {command: aws, args: [eks, get-token]}")))
        let exec2 = try DiscoveredContext.fingerprint(of: ctx(kubeconfigText(user: "    exec: {command: aws, args: [eks, get-token, --profile, x]}")))
        #expect(exec1 != exec2)
    }
}

/// The gate: development builds never read `~/.kube`, for every source type.
@Suite("Moorings never reads ~/.kube while the gate is active")
struct MooringsGateTests {
    private func homeWithKubeConfig(_ s: Scratch) throws -> (home: URL, config: URL) {
        let home = try s.home()
        // A canary: unreadable (mode 000). Any attempt to open it would be recorded as an issue.
        let config = home.appending(path: ".kube/config")
        try kubeconfigText(context: "production-canary", server: "https://prod.example.com:6443").write(to: config, atomically: true, encoding: .utf8)
        chmod(config.path, 0o000)
        return (home, config)
    }

    @Test func defaultSourcesIsOnlyTheExplicitTestFile() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let (home, config) = try homeWithKubeConfig(s)
        defer { chmod(config.path, 0o600) }
        let test = try s.write("test/kubeconfig", kubeconfigText(server: "https://fixture.test:6443"))
        let policy = KubeconfigDiscoveryPolicy(gate: activeGate(home: home))
        let sources = try policy.defaultSources(explicitTest: test, shellKubeconfig: "\(config.path):\(home.path)/.kube/other")
        #expect(sources == [test])
        #expect(try policy.defaultSources(explicitTest: nil, shellKubeconfig: config.path).isEmpty)
        #expect(policy.sanitizedShellKubeconfig(config.path) == nil)
    }

    @Test func theLoaderRefusesEveryKindOfPathUnderHomeKube() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let (home, config) = try homeWithKubeConfig(s)
        defer { chmod(config.path, 0o600) }
        let loader = KubeconfigLoader(gate: activeGate(home: home))
        // direct
        #expect(throws: DevSafetyError.self) { _ = try loader.loadStandalone(config) }
        #expect(throws: DevSafetyError.self) { _ = try loader.loadDefaultSet([config]) }
        #expect(throws: DevSafetyError.self) { _ = try loader.loadForImport(url: config) }
        #expect(throws: DevSafetyError.self) { _ = try loader.loadFolder(home.appending(path: ".kube"), recursive: false) }
        // a symlink elsewhere pointing into ~/.kube
        let symlinkURL = s.root.appending(path: "innocent.yaml")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: config)
        #expect(throws: DevSafetyError.self) { _ = try loader.loadStandalone(symlinkURL) }
        // a hard link elsewhere to the same inode
        let hard = s.root.appending(path: "hardlink.yaml")
        #expect(link(config.path, hard.path) == 0)
        #expect(throws: DevSafetyError.self) { _ = try loader.loadStandalone(hard) }
    }

    @Test func aServiceInADevelopmentBuildNeverListsOrReadsTheHomeConfig() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let (home, config) = try homeWithKubeConfig(s)
        defer { chmod(config.path, 0o600) }
        let test = try s.write("test/kubeconfig", kubeconfigText(context: "wheelhouse-test", server: "https://fixture.test:6443"))
        let state = MooringsState(overrides: DiscoveredClusterStore(fileURL: s.root.appending(path: "o.json")),
                                  preferences: MooringsPreferencesStore(fileURL: s.root.appending(path: "p.json")), gate: activeGate(home: home))
        try state.preferences.update { $0.homeFilesEnabled = true; $0.shellKubeconfigEnabled = true; $0.userSources = [MooringsSource(kind: .userFile, path: config.path)] }
        let service = MooringsService(config: MooringsConfiguration(gate: activeGate(home: home), home: home, explicitTestKubeconfig: test,
                                                                    shellKubeconfig: { config.path }),
                                      state: state, clients: UnusedClients())
        await service.rescan()
        let names = state.contexts.map(\.context.name)
        #expect(names == ["wheelhouse-test"])
        #expect(!names.contains("production-canary"))
        // the user source under ~/.kube is refused (an issue), never read (the canary is unreadable: no open error was recorded for it)
        let issues = await service.issues
        #expect(issues[config.path]?.contains("can't read ~/.kube") == true)
        // and it cannot be added through the seam either
        await #expect(throws: DevSafetyError.self) { try await service.addFileSource(config) }
    }

    @Test func anExplicitTestFileUnderHomeKubeIsRefused() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let home = try s.home()
        let inside = try s.write("home/.kube/test.yaml", kubeconfigText())
        let policy = KubeconfigDiscoveryPolicy(gate: activeGate(home: home))
        #expect(throws: DevSafetyError.self) { _ = try policy.defaultSources(explicitTest: inside, shellKubeconfig: nil) }
    }

    @Test func withTheGateOffTheHomeConfigIsTheDefault() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let home = try s.home()
        let policy = KubeconfigDiscoveryPolicy(gate: openGate(home: home))
        #expect(try policy.defaultSources(explicitTest: nil, shellKubeconfig: nil) == [home.appending(path: ".kube/config")])
        #expect(try policy.defaultSources(explicitTest: nil, shellKubeconfig: "/a:/b").map(\.path) == ["/a", "/b"])
    }

    @Test func blockedHostsAreMarkedAndNeverAdded() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let home = try s.home()
        let test = try s.write("test/kubeconfig", kubeconfigText(context: "ok", server: "https://fixture.test:6443"))
        let extra = try s.write("extra.yaml", kubeconfigText(context: "prod-real", server: "https://prod.example.com:6443"))
        let state = MooringsState(overrides: DiscoveredClusterStore(fileURL: s.root.appending(path: "o.json")),
                                  preferences: MooringsPreferencesStore(fileURL: s.root.appending(path: "p.json")), gate: activeGate(home: home))
        try state.preferences.update { $0.userSources = [MooringsSource(kind: .userFile, path: extra.path)] }
        let service = MooringsService(config: MooringsConfiguration(gate: activeGate(home: home), home: home, explicitTestKubeconfig: test),
                                      state: state, clients: UnusedClients())
        await service.rescan()
        let rows = await service.firstRunRows()
        let prod = try #require(rows.first { $0.context.context.name == "prod-real" })
        #expect(!prod.selectable)
        #expect(prod.unselectableReason == "Blocked in development builds")
        try await service.completeFirstRun(choices: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, FirstRunChoice(selected: true)) }))
        #expect(state.overrides.override(for: prod.id)?.added != true)
        await #expect(throws: DevSafetyError.self) { _ = try await service.prepareAdoption(id: prod.id) }
    }
}

/// A client maker that must never be used.
struct UnusedClients: MooringsClientMaking {
    func makeClient(config: ClusterConfig, secrets: ClusterSecrets) -> any KubeClientProtocol {
        Issue.record("a client was created for \(config.name)")
        return RefusedKubeClient(error: .unreachable(cause: "unused"))
    }
    func tokenSource(for config: ClusterConfig, secrets: ClusterSecrets) -> BearerTokenSource? { nil }
}
#endif
