#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

final class CountingAuthenticator: BeaconAuthenticating, @unchecked Sendable {
    let lock = NSLock()
    var calls: [String] = []
    var succeed = true
    func authenticate(reason: String) async throws {
        lock.withLock { calls.append(reason) }
        if !succeed { throw BeaconAuthenticationFailed() }
    }
    var count: Int { lock.withLock { calls.count } }
}

final class ScriptedApprover: BeaconApproving, @unchecked Sendable {
    let lock = NSLock()
    var requests: [BeaconApprovalRequest] = []
    var decision: BeaconApprovalDecision = .deny
    var holds = false
    func approve(_ request: BeaconApprovalRequest) async -> BeaconApprovalDecision {
        lock.withLock { requests.append(request) }
        while holds && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        return lock.withLock { decision }
    }
    var count: Int { lock.withLock { requests.count } }
}

struct TwoClusters: ToolboxClusterSource {
    func clusters() async -> [ClusterConfig] { [testCluster("dev", env: .development), testCluster("prod", env: .production)] }
    func access(for cluster: ClusterID) async -> ReadOnlyKubeAccess? { nil }
}

func testCluster(_ id: String, env: ClusterEnvironment) -> ClusterConfig {
    ClusterConfig(id: id, name: "\(id)-name", server: URL(string: "https://\(id).example.com")!, environment: env)
}

func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite("BeaconHub", .serialized)
struct BeaconHubTests {
    final class Rig: @unchecked Sendable {
        let dir = ShortDir()
        let store: BeaconClientStore
        let secrets = InMemoryBeaconSecrets()
        let auth = CountingAuthenticator()
        let approver = ScriptedApprover()
        let log = InMemoryActivityLog()
        let peer = LockedPeer(BeaconPeer.fake(key: "p", team: "TEAM123456", signingID: "com.anthropic.claude-code"))
        let hub: BeaconHub

        final class LockedPeer: @unchecked Sendable {
            var value: BeaconPeer
            init(_ v: BeaconPeer) { value = v }
        }
        struct PeerVerifier: BeaconPeerVerifying {
            let peer: LockedPeer
            func verify(fd: Int32) -> Result<BeaconPeer, BeaconRejection> { .success(peer.value) }
        }

        init() {
            let file = FileManager.default.temporaryDirectory.appending(path: "beacon-\(UUID().uuidString).json")
            store = BeaconClientStore(fileURL: file, secrets: secrets)
            let peerBox = peer
            hub = BeaconHub(store: store, source: TwoClusters(), socketURL: dir.socket, verifier: PeerVerifier(peer: peerBox), approver: approver,
                            authenticator: auth, activity: log, isLocked: { false })
        }
        deinit { hub.turnOff(); dir.cleanup() }

        func connect(secret: String? = nil, name: String = "Claude Code") async -> SocketClient? {
            guard let c = SocketClient(path: dir.socket.path) else { return nil }
            c.hello(secret: secret)
            guard c.receive()?["ok"]?.boolValue == true else { return nil }
            _ = c.call(1, "initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": .string(name), "version": "1"]])
            return c
        }

        func tools(_ c: SocketClient, id: Int = 2) -> [String] {
            c.call(id, "tools/list")?.value(at: "result.tools")?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        }
    }

    @Test func everyTurnOnAuthenticates_andAFailureLeavesBeaconOff() async throws {
        let rig = Rig()
        rig.auth.succeed = false
        await #expect(throws: BeaconAuthenticationFailed.self) { try await rig.hub.turnOn() }
        #expect(!rig.hub.isOn)
        #expect(SocketClient(path: rig.dir.socket.path) == nil)
        rig.auth.succeed = true
        try await rig.hub.turnOn()
        rig.hub.turnOff()
        try await rig.hub.turnOn()
        #expect(rig.auth.count == 3)   // not only the first time
        #expect(rig.hub.isOn)
    }

    @Test func anUnknownSecretIsSentToApprovalAndGetsNoToolsUntilApproved() async throws {
        let rig = Rig()
        try await rig.hub.turnOn()
        rig.approver.holds = true
        let client = try #require(await rig.connect(secret: "not-a-real-secret"))
        #expect(await waitUntil { rig.approver.count == 1 })
        #expect(rig.approver.requests[0].secretState == .unknown)
        #expect(rig.approver.requests[0].launcher.team == "TEAM123456")
        #expect(rig.tools(client).isEmpty)   // nothing before the person decides
        rig.approver.lock.withLock { rig.approver.decision = .allow(readClusters: ["dev"], remember: false); rig.approver.holds = false }
        // The client is told its tool list changed.
        var sawChange = false
        while let m = client.receive(timeout: 2) { if m["method"]?.stringValue == "notifications/tools/list_changed" { sawChange = true; break } }
        #expect(sawChange)
        let names = rig.tools(client, id: 3)
        #expect(names.contains("list_clusters"))
        // Session-only: no record, no persisted scope, and no change tools (they need Touch ID in Settings).
        #expect(rig.store.records.isEmpty)
        #expect(!names.contains { $0.hasPrefix("request_") })
    }

    @Test func missingSecretAlsoGoesToApprovalWithSessionScopeOnly() async throws {
        let rig = Rig()
        try await rig.hub.turnOn()
        rig.approver.decision = .allow(readClusters: ["dev", "prod"], remember: true)
        let client = try #require(await rig.connect(secret: nil))
        #expect(await waitUntil { rig.approver.count == 1 })
        #expect(rig.approver.requests[0].secretState == BeaconSecretState.none)
        #expect(await waitUntil { !rig.tools(client, id: 9).isEmpty })
        #expect(rig.store.records.isEmpty)   // remember is meaningless without a secret
    }

    @Test func aDeniedClientIsDisconnectedAndNotAskedAgainForAWhile() async throws {
        let rig = Rig()
        try await rig.hub.turnOn()
        rig.approver.decision = .deny
        let first = try #require(await rig.connect())
        #expect(first.isClosed())
        #expect(rig.approver.count == 1)
        let second = try #require(await rig.connect())
        #expect(second.isClosed())
        #expect(rig.approver.count == 1)   // cooldown: no second sheet
    }

    @Test func aKnownSecretIsBoundOnFirstApprovalAndThenNeedsNoSheet() async throws {
        let rig = Rig()
        let (record, secret) = try rig.store.createClient(label: "Claude Code")
        try await rig.hub.turnOn()
        rig.approver.decision = .allow(readClusters: ["dev"], remember: true)
        let first = try #require(await rig.connect(secret: secret))
        #expect(await waitUntil { rig.approver.count == 1 })
        #expect(rig.approver.requests[0].secretState == .unbound)
        #expect(await waitUntil { !rig.tools(first, id: 5).isEmpty })
        let saved = try #require(rig.store.record(id: record.id))
        #expect(saved.isBound && saved.readClusters == ["dev"] && saved.boundName == "Claude Code")
        // Second connection, same program and name: approved silently with the stored scope.
        let second = try #require(await rig.connect(secret: secret))
        #expect(await waitUntil { !rig.tools(second, id: 6).isEmpty })
        #expect(rig.approver.count == 1)
    }

    @Test func aKnownSecretFromAnotherProgramIsAskedAboutAndIsSessionOnly() async throws {
        let rig = Rig()
        let (record, secret) = try rig.store.createClient(label: "Claude Code")
        try rig.store.bind(id: record.id, name: "Claude Code", launcher: rig.peer.value.launcher, readClusters: ["dev"])
        try await rig.hub.turnOn()
        // Another program presents the same secret.
        rig.peer.value = BeaconPeer(pid: 9, uid: getuid(), launcher: BeaconLauncher(pid: 8, path: "/tmp/evil", signingID: nil, team: nil))
        rig.approver.decision = .allow(readClusters: ["dev"], remember: false)
        let client = try #require(await rig.connect(secret: secret))
        #expect(await waitUntil { rig.approver.count == 1 })
        guard case .mismatch = rig.approver.requests[0].secretState else { Issue.record("expected mismatch"); return }
        #expect(await waitUntil { !rig.tools(client, id: 5).isEmpty })
        // The stored binding is untouched.
        #expect(rig.store.record(id: record.id)?.launcherKey == "signed:TEAM123456:com.anthropic.claude-code")
        // Same name, different program: the approved scope was not inherited as persisted state.
        #expect(rig.store.records.count == 1)
    }

    @Test func revokeDeletesTheSecretAndDisconnectsLiveSessions() async throws {
        let rig = Rig()
        let (record, secret) = try rig.store.createClient(label: "Claude Code")
        try rig.store.bind(id: record.id, name: "Claude Code", launcher: rig.peer.value.launcher, readClusters: ["dev"])
        try await rig.hub.turnOn()
        let client = try #require(await rig.connect(secret: secret))
        #expect(await waitUntil { !rig.tools(client, id: 5).isEmpty })
        try rig.hub.revoke(clientID: record.id)
        #expect(client.isClosed())
        #expect(rig.secrets.secret(for: record.id) == nil)
        #expect(rig.store.match(secret: secret) == nil)
    }

    @Test func lockedAppQueuesNoSheetAndCallsAnswerLocked() async throws {
        final class Flag: @unchecked Sendable { var on = true }
        let flag = Flag()
        let dir = ShortDir()
        defer { dir.cleanup() }
        let secrets = InMemoryBeaconSecrets()
        let store = BeaconClientStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "b-\(UUID().uuidString).json"), secrets: secrets)
        let approver = ScriptedApprover()
        approver.decision = .allow(readClusters: ["dev"], remember: false)
        let hub = BeaconHub(store: store, source: TwoClusters(), socketURL: dir.socket, verifier: FixedVerifier(result: .success(.fake())), approver: approver,
                            authenticator: CountingAuthenticator(), isLocked: { flag.on })
        try await hub.turnOn()
        defer { hub.turnOff() }
        let client = try #require(SocketClient(path: dir.socket.path))
        client.hello()
        _ = client.receive()
        _ = client.call(1, "initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": "X"]])
        try await Task.sleep(for: .milliseconds(100))
        #expect(approver.count == 0)
        let locked1 = client.call(2, "tools/call", ["name": "list_clusters", "arguments": [:]])
        #expect(locked1?.value(at: "result.content")?.arrayValue?.first?["text"]?.stringValue == "Wheelhouse is locked")
        flag.on = false
        hub.lockChanged()
        #expect(await waitUntil { approver.count == 1 })
    }

    @Test func turningOffClosesEverythingAndTheSocketFile() async throws {
        let rig = Rig()
        try await rig.hub.turnOn()
        rig.approver.holds = true
        let client = try #require(await rig.connect())
        #expect(await waitUntil { rig.approver.count == 1 })
        rig.hub.turnOff()
        #expect(client.isClosed())
        #expect(!FileManager.default.fileExists(atPath: rig.dir.socket.path))
        #expect(rig.hub.sessionCount == 0)
        rig.approver.holds = false
    }

    @Test func enablingChangeRequestsNeedsAuthenticationButReadScopeDoesNot() async throws {
        let rig = Rig()
        let (record, _) = try rig.store.createClient(label: "C")
        try await rig.hub.setScope(clientID: record.id, read: ["dev"], changeRequests: [])
        #expect(rig.auth.count == 0)
        try await rig.hub.setScope(clientID: record.id, read: ["dev"], changeRequests: ["dev"])
        #expect(rig.auth.count == 1)
        rig.auth.succeed = false
        await #expect(throws: BeaconAuthenticationFailed.self) { try await rig.hub.setScope(clientID: record.id, read: ["dev", "prod"], changeRequests: ["dev", "prod"]) }
        #expect(rig.store.record(id: record.id)?.changeRequestClusters == ["dev"])
    }

    @Test func secretsAreComparedWithoutShortcuts() throws {
        let secrets = InMemoryBeaconSecrets()
        let store = BeaconClientStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "b-\(UUID().uuidString).json"), secrets: secrets)
        let (a, secretA) = try store.createClient(label: "A")
        let (b, secretB) = try store.createClient(label: "B")
        #expect(secretA.count == 64 && secretA != secretB)   // 256 bits of hex
        #expect(store.match(secret: secretA)?.id == a.id)
        #expect(store.match(secret: secretB)?.id == b.id)
        #expect(store.match(secret: String(secretA.dropLast()) + "0") == nil || secretA.hasSuffix("0"))
        #expect(store.match(secret: "") == nil)
        #expect(BeaconClientStore.constantTimeEquals("abc", "abc") && !BeaconClientStore.constantTimeEquals("abc", "abd") && !BeaconClientStore.constantTimeEquals("abc", "ab"))
    }

    @Test func recordsPersistWithoutSecretsAndScopeIsClampedAndReconciled() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "b-\(UUID().uuidString).json")
        let secrets = InMemoryBeaconSecrets()
        let store = BeaconClientStore(fileURL: file, secrets: secrets)
        let (record, secret) = try store.createClient(label: "Claude\u{202E}")
        try store.setScope(id: record.id, read: ["dev"], changeRequests: ["dev", "prod"])   // prod is not readable: clamped
        #expect(store.record(id: record.id)?.changeRequestClusters == ["dev"])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(secret))
        let reloaded = BeaconClientStore(fileURL: file, secrets: secrets)
        #expect(reloaded.records.first?.label == "Claude")
        reloaded.reconcile(existing: ["other"])
        #expect(reloaded.record(id: record.id)?.readClusters.isEmpty == true)
        // A session client id cannot alias a persisted record.
        reloaded.setSessionScope(BeaconScope(readClusters: ["x"]), for: "session-1")
        #expect(reloaded.beaconScope(client: "session-1").readClusters == ["x"])
        reloaded.dropSession("session-1")
        #expect(reloaded.beaconScope(client: "session-1").readClusters.isEmpty)
    }
}

@Suite("BeaconClientConfig")
struct BeaconClientConfigTests {
    private let release = BeaconClientConfig(helperPath: "/Users/x/Library/Application Support/Wheelhouse/bin/wheelhouse-mcp", developmentBuild: false)
    private let dev = BeaconClientConfig(helperPath: "/Users/x/Library/Application Support/Wheelhouse-Debug/bin/wheelhouse-mcp", developmentBuild: true)
    private let open = DevSafetyPolicy(isActive: false)

    @Test func snippetsPutTheSecretInEnvAndNeverInServerArguments() {
        let args = release.claudeCodeArguments(secret: "S")
        #expect(args == ["mcp", "add", "--transport", "stdio", "--scope", "user", "--env", "WHEELHOUSE_BEACON_SECRET=S", "wheelhouse", "--", release.helperPath])
        #expect(release.claudeCodeCommand(secret: "S", home: "/Users/x") == "claude mcp add --transport stdio --scope user --env WHEELHOUSE_BEACON_SECRET=S wheelhouse -- \"$HOME/Library/Application Support/Wheelhouse/bin/wheelhouse-mcp\"")
        let json = release.projectMCPJSON(secret: "S")
        #expect(json.contains("\"WHEELHOUSE_BEACON_SECRET\"") && json.contains("\"args\""))
        let parsed = try? JSONValue.parse(Data(json.utf8))
        #expect(parsed?.value(at: "mcpServers.wheelhouse.args")?.arrayValue?.isEmpty == true)
        // Development builds register as wheelhouse-debug, local scope only.
        let d = dev.claudeCodeArguments(secret: "S")
        #expect(d.contains("local") && d.contains("wheelhouse-debug") && !d.contains("user"))
    }

    @Test func desktopMergePreservesKeysBacksUpAndWritesPrivately() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let config = try scratch.write("Claude/claude_desktop_config.json", #"{"theme":"dark","mcpServers":{"other":{"command":"x"}}}"#)
        try release.mergeIntoClaudeDesktop(configURL: config, secret: "S", gate: open)
        let merged = try JSONValue.parse(Data(contentsOf: config))
        #expect(merged["theme"]?.stringValue == "dark")
        #expect(merged.value(at: "mcpServers.other.command")?.stringValue == "x")
        #expect(merged.value(at: "mcpServers.wheelhouse.command")?.stringValue == release.helperPath)
        #expect(merged.value(at: "mcpServers.wheelhouse.env.WHEELHOUSE_BEACON_SECRET")?.stringValue == "S")
        let backup = config.deletingLastPathComponent().appending(path: "claude_desktop_config.json.wheelhouse-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("\"theme\":\"dark\""))
        var st = stat()
        stat(config.path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
    }

    @Test func desktopMergeCreatesAMissingFileAndRefusesBrokenJSON() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let fresh = scratch.root.appending(path: "New/claude_desktop_config.json")
        try release.mergeIntoClaudeDesktop(configURL: fresh, secret: "S", gate: open)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        let broken = try scratch.write("Broken/claude_desktop_config.json", "{ not json")
        #expect(throws: BeaconConfigError.self) { try release.mergeIntoClaudeDesktop(configURL: broken, secret: "S", gate: open) }
        #expect(try String(contentsOf: broken, encoding: .utf8) == "{ not json")   // untouched
        let array = try scratch.write("Arr/claude_desktop_config.json", "[1]")
        #expect(throws: BeaconConfigError.self) { try release.mergeIntoClaudeDesktop(configURL: array, secret: "S", gate: open) }
    }

    @Test func desktopMergeIsUnavailableInDevelopmentBuilds() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let target = scratch.root.appending(path: "c.json")
        #expect(throws: BeaconConfigError.unavailableInDevelopmentBuild) { try dev.mergeIntoClaudeDesktop(configURL: target, secret: "S", gate: open) }
        #expect(throws: BeaconConfigError.unavailableInDevelopmentBuild) { try release.mergeIntoClaudeDesktop(configURL: target, secret: "S", gate: DevSafetyPolicy(isActive: true)) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(BeaconClientConfig.claudeDesktopConfigURL(home: URL(fileURLWithPath: "/Users/x")).path == "/Users/x/Library/Application Support/Claude/claude_desktop_config.json")
    }

    final class RecordingRunner: BeaconCommandRunning, @unchecked Sendable {
        var calls: [(URL, [String], URL?)] = []
        var status: Int32 = 0
        func run(_ executable: URL, arguments: [String], currentDirectory: URL?) async throws -> (status: Int32, output: String) {
            calls.append((executable, arguments, currentDirectory))
            return (status, "out")
        }
    }

    @Test func addToClaudeCodeUsesTheLocatedCommandAndAnInjectedRunner() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let bin = try scratch.dir("bin")
        let claude = bin.appending(path: "claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        chmod(claude.path, 0o755)
        let runner = RecordingRunner()
        try await release.addToClaudeCode(secret: "S", locator: ExecutableLocator(searchPath: [bin.path]), runner: runner)
        #expect(runner.calls.count == 1 && runner.calls[0].0 == claude && runner.calls[0].1.contains("WHEELHOUSE_BEACON_SECRET=S"))
        await #expect(throws: BeaconConfigError.claudeNotFound) { try await release.addToClaudeCode(secret: "S", locator: ExecutableLocator(searchPath: []), runner: runner) }
        runner.status = 3
        await #expect(throws: BeaconConfigError.commandFailed(3, "out")) { try await release.addToClaudeCode(secret: "S", locator: ExecutableLocator(searchPath: [bin.path]), runner: runner) }
        // Development builds need a repository for --scope local, and run inside it.
        runner.status = 0
        await #expect(throws: BeaconConfigError.noRepositoryForLocalScope) { try await dev.addToClaudeCode(secret: "S", locator: ExecutableLocator(searchPath: [bin.path]), runner: runner) }
        try await dev.addToClaudeCode(secret: "S", locator: ExecutableLocator(searchPath: [bin.path]), runner: runner, repository: scratch.root)
        #expect(runner.calls.last?.2 == scratch.root)
    }
}
#endif
