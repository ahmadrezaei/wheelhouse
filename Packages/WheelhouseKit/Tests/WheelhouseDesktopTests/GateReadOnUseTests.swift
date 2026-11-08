#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// The app builds its client factory, broker and Moorings configuration in `App.init`, before the allowed test hosts are configured.
/// Every one of them must therefore read the gate each time it is used (the bug of review finding 1 on M1b).
@Suite("The gate is read on use")
struct GateReadOnUseTests {
    private func factory(_ s: Scratch, hosts: @escaping @Sendable () -> Set<String>) throws -> DesktopClientFactory {
        let home = try s.home()
        let state = MooringsState(overrides: DiscoveredClusterStore(fileURL: s.root.appending(path: "d.json")),
                                  preferences: MooringsPreferencesStore(fileURL: s.root.appending(path: "p.json")))
        let broker = ExecCredentialBroker(locator: { ExecutableLocator(searchPath: []) }, environment: { EnvironmentBuilder(snapshot: nil) })
        return DesktopClientFactory(state: state, settings: MacClusterSettingsStore(fileURL: s.root.appending(path: "cs.json")), broker: broker,
                                    gateProvider: { activeGate(home: home, hosts: hosts()) })
    }

    @Test func theFactoryFollowsTheAllowedHostsConfiguredAfterItWasBuilt() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let hosts = Mutex<Set<String>>([])
        let factory = try factory(s) { hosts.withLock { $0 } }
        let config = ClusterConfig(name: "t", server: URL(string: "https://cluster.example.com:6443")!, environment: .development)
        #expect(factory.make(config: config, secrets: ClusterSecrets(token: "x")) is RefusedKubeClient)
        hosts.withLock { $0 = ["cluster.example.com"] }
        #expect(factory.make(config: config, secrets: ClusterSecrets(token: "x")) is LiveKubeClient)
        hosts.withLock { $0 = [] }
        #expect(factory.make(config: config, secrets: ClusterSecrets(token: "x")) is RefusedKubeClient)
    }

    @Test func aBlockedHostMakesNoRequestAndDemoIsNeverGated() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let factory = try factory(s) { ["allowed.example.com"] }
        let blocked = factory.make(config: ClusterConfig(name: "p", server: URL(string: "https://prod.example.com")!, environment: .production),
                                   secrets: ClusterSecrets(token: "x"))
        await #expect(throws: KubeError.self) { _ = try await blocked.version() }
        #expect(!(factory.make(config: DemoFleet.configs[0], secrets: ClusterSecrets()) is RefusedKubeClient))
    }

    @Test func theConfigurationGateFollowsItsProviderAndAFixedGateStillWorks() {
        let tmp = URL(fileURLWithPath: "/tmp")
        let hosts = Mutex<Set<String>>([])
        let config = MooringsConfiguration(gateProvider: { activeGate(home: tmp, hosts: hosts.withLock { $0 }) })
        #expect(!config.gate.isAllowed(server: URL(string: "https://a.example.com")))
        hosts.withLock { $0 = ["a.example.com"] }
        #expect(config.gate.isAllowed(server: URL(string: "https://a.example.com")))
        var fixed = MooringsConfiguration(gate: activeGate(home: tmp))
        #expect(fixed.gate.isActive)
        fixed.gate = openGate(home: tmp)
        #expect(!fixed.gate.isActive)
    }

    @Test func providerPrefersAnExplicitProviderThenAFixedPolicy() {
        let home = URL(fileURLWithPath: "/tmp")
        #expect(!DevSafetyPolicy.provider(fixed: openGate(home: home), provider: nil)().isActive)
        #expect(DevSafetyPolicy.provider(fixed: openGate(home: home), provider: { activeGate(home: home) })().isActive)
        #expect(DevSafetyPolicy.provider(fixed: nil, provider: nil)().isActive == DevSafety.isActive)
    }

    @Test func onlyAddedContextsAreManagedAndAllowChangesUsesTheMooringsPath() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try MooringsHarness(files: [try MooringsServiceTests.threeContexts(s)], scratch: s)
        await h.service.rescan()
        let ctx = try #require(h.state.contexts.first { $0.context.name == "stg-1" })
        #expect(!h.service.managesChanges(for: ctx.id))                     // discovered but not added yet
        #expect(!h.service.managesChanges(for: "no-such-cluster"))
        try await h.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .staging)])
        #expect(h.service.managesChanges(for: ctx.id))
        #expect(try #require(h.state.listedConfigs().first { $0.id == ctx.id }).readOnly)     // starts read-only
        let allowing: any ClusterChangeAllowing = h.service
        try await allowing.allowChanges(id: ctx.id, environment: .staging)
        #expect(try #require(h.state.listedConfigs().first { $0.id == ctx.id }).readOnly == false)
    }
}
#endif
