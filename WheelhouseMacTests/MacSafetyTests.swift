import Testing
import Foundation
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// The Mac app target in its own test host: a Debug or Profile build must keep the gate on and stay out of the shared groups.
@Suite("Mac app safety")
struct MacAppSafetyTests {
    @Test func theGateIsActiveInThisBuild() {
        #expect(DevSafety.isActive)
    }

    @Test func infoPlistCarriesTheDebugIdentity() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["WHDevSafety"] as? String == "YES")
        #expect(Bundle.main.bundleIdentifier == "com.ahmadrezaei.wheelhouse.mac.debug")
        #expect(info["WHKeychainGroupSuffix"] as? String == "com.ahmadrezaei.wheelhouse.mac.debug")
        #expect(info["WHKeychainPrivateGroupSuffix"] as? String == "com.ahmadrezaei.wheelhouse.mac.debug")
        #expect(info["WHAppGroup"] as? String == "JCZY58QP3L.com.ahmadrezaei.wheelhouse.debug")
        #expect((info["SUFeedURL"] as? String ?? "").isEmpty)
        #expect(info["SUEnableAutomaticChecks"] as? String == "NO")
    }

    @Test func appPathsAreIsolated() {
        #expect(AppPaths.current.root.lastPathComponent == "Wheelhouse-Debug")
    }

    @Test func theUpdaterWouldNotStart() {
        #expect(!DevSafetyPolicy.current.shouldStartUpdater(feedURL: "https://example.com/appcast.xml"))
    }

    @MainActor @Test func theGateForcesTheDebugGroupsWhateverInfoPlistSays() {
        _ = MacAppEnvironment.live()
        #expect(IsolationOverride.current == .debug)
        #expect(AppGroup.identifier == "JCZY58QP3L.com.ahmadrezaei.wheelhouse.debug")
        #expect(KeychainGroup.shared.suffix().hasSuffix(".mac.debug"))
        #expect(KeychainGroup.macPrivate.suffix().hasSuffix(".mac.debug"))
        // A second install (anything trying to widen it later) is ignored.
        #expect(!IsolationOverride.install(IsolationValues(appGroup: "JCZY58QP3L.com.ahmadrezaei.wheelhouse", sharedKeychainSuffix: "com.ahmadrezaei.wheelhouse.shared", privateKeychainSuffix: "com.ahmadrezaei.wheelhouse.mac")))
        #expect(IsolationOverride.current == .debug)
    }

    @MainActor @Test func theEnvironmentIsIsolatedAndKeepsOnlyAllowedClusters() {
        let env = MacAppEnvironment.live()
        #expect(env.gateActive)
        #expect(env.paths.isolated)
        #expect(env.safetySummary.hasPrefix("Development safety ON"))
    }

    @MainActor @Test func demoModeShowsOnlySampleClusters() {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        #expect(env.registry.isDemoMode)
        #expect(env.registry.clusters.allSatisfy { $0.isDemo })
        env.registry.exitDemoMode()
    }

    @Test func aClientForAHostThatIsNotAllowedIsPointedAtAnUnresolvableName() {
        let gate = DevSafetyPolicy(isActive: true, allowedHosts: ["127.0.0.1"])
        let real = ClusterConfig(name: "prod", server: URL(string: "https://api.prod.corp.example.com")!, environment: .production)
        #expect(MacAppEnvironment.gatedConfig(real, gate: gate).server.host() == "blocked-in-development.invalid")
        let allowed = ClusterConfig(name: "test", server: URL(string: "https://127.0.0.1:6443")!, environment: .development)
        #expect(MacAppEnvironment.gatedConfig(allowed, gate: gate) == allowed)
        let demo = ClusterConfig(name: "demo", server: URL(string: "https://demo.example.com")!, isDemo: true)
        #expect(MacAppEnvironment.gatedConfig(demo, gate: gate) == demo)
        // An inactive gate (Distribution) leaves everything alone.
        #expect(MacAppEnvironment.gatedConfig(real, gate: DevSafetyPolicy(isActive: false)) == real)
    }
}
