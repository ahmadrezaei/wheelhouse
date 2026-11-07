#if os(macOS)
import Testing
import Foundation
@testable import WheelhouseDesktop
import WheelhouseKit

private let team = "JCZY58QP3L"
private let release = "com.ahmadrezaei.wheelhouse.mac"

/// A scratch home directory with a `.kube` folder (symlinks resolved so comparisons are exact).
private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "wh-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home.appending(path: ".kube"), withIntermediateDirectories: true)
    return home.resolvingSymlinksInPath()
}

@Suite("DevSafety: the gate truth table")
struct DevSafetyGateTests {
    @Test func missingKeyIsOn() {
        #expect(DevSafety.evaluate(info: [:], bundleID: release, signature: .developerID(team: team)))
    }

    @Test(arguments: ["YES", "yes", "no", "", "true", "0", " NO", "NO "])
    func anythingButExactlyNOIsOn(_ value: String) {
        #expect(DevSafety.evaluate(info: ["WHDevSafety": value], bundleID: release, signature: .developerID(team: team)))
    }

    @Test func nonStringValueIsOn() {
        #expect(DevSafety.evaluate(info: ["WHDevSafety": false], bundleID: release, signature: .developerID(team: team)))
        #expect(DevSafety.evaluate(info: ["WHDevSafety": 0], bundleID: release, signature: .developerID(team: team)))
    }

    @Test func NOWithDebugBundleIDIsOn() {
        #expect(DevSafety.evaluate(info: ["WHDevSafety": "NO"], bundleID: release + ".debug", signature: .developerID(team: team)))
    }

    @Test func NOWithMissingOrForeignBundleIDIsOn() {
        #expect(DevSafety.evaluate(info: ["WHDevSafety": "NO"], bundleID: nil, signature: .developerID(team: team)))
        #expect(DevSafety.evaluate(info: ["WHDevSafety": "NO"], bundleID: "com.ahmadrezaei.wheelhouse", signature: .developerID(team: team)))
        #expect(DevSafety.evaluate(info: ["WHDevSafety": "NO"], bundleID: release + ".mcp", signature: .developerID(team: team)))
    }

    @Test func NOWithAppleDevelopmentAdHocOrUnsignedIsOn() {
        for sig in [CodeSignature.appleDevelopment, .adHoc, .unsigned] {
            #expect(DevSafety.evaluate(info: ["WHDevSafety": "NO"], bundleID: release, signature: sig))
        }
    }

    @Test func NOWithDeveloperIDOfAnotherTeamIsOn() {
        #expect(DevSafety.evaluate(info: ["WHDevSafety": "NO"], bundleID: release, signature: .developerID(team: "OTHERTEAM1")))
    }

    @Test func onlyAllThreeTurnsTheGateOff() {
        #expect(!DevSafety.evaluate(info: ["WHDevSafety": "NO"], bundleID: release, signature: .developerID(team: team)))
    }

    @Test func theRunningTestProcessKeepsTheGateOn() {
        // A test host is never the Distribution app: Info.plist has no WHDevSafety = NO and it is not Developer ID signed.
        #expect(DevSafety.isActive)
    }

    @Test func requirementStringNamesTheTeamAndDeveloperIDOIDs() {
        let r = CodeSignature.developerIDRequirement(team: team)
        #expect(r.contains("anchor apple generic"))
        #expect(r.contains("1.2.840.113635.100.6.2.6"))
        #expect(r.contains("1.2.840.113635.100.6.1.13"))
        #expect(r.contains("leaf[subject.OU] = \"JCZY58QP3L\""))
    }
}

@Suite("DevSafety: discovery, hosts and paths while active")
struct DevSafetyEnforcementTests {
    @Test func defaultSourcesWhileActiveAreOnlyTheExplicitFile() throws {
        let home = try makeHome()
        let explicit = home.appending(path: "tests/kubeconfig")
        let p = KubeconfigDiscoveryPolicy(gate: DevSafetyPolicy(isActive: true, home: home))
        let sources = try p.defaultSources(explicitTest: explicit, shellKubeconfig: "\(home.path)/.kube/config:\(home.path)/.kube/other")
        #expect(sources == [explicit])
    }

    @Test func defaultSourcesWhileActiveWithNoExplicitFileAreEmpty() throws {
        let home = try makeHome()
        let p = KubeconfigDiscoveryPolicy(gate: DevSafetyPolicy(isActive: true, home: home))
        #expect(try p.defaultSources(explicitTest: nil, shellKubeconfig: "/Users/x/.kube/config").isEmpty)
    }

    @Test func activeNeverListsHomeKubeFiles() throws {
        let home = try makeHome()
        try Data().write(to: home.appending(path: ".kube/config"))
        try Data().write(to: home.appending(path: ".kube/staging.yaml"))
        let p = KubeconfigDiscoveryPolicy(gate: DevSafetyPolicy(isActive: true, home: home))
        let sources = try p.defaultSources(explicitTest: URL(fileURLWithPath: "/tmp/wh-test-kc"), shellKubeconfig: "\(home.path)/.kube/staging.yaml")
        #expect(!sources.contains { $0.path.contains("/.kube/") })
    }

    @Test func inactiveUsesShellKubeconfigThenHome() throws {
        let home = try makeHome()
        let p = KubeconfigDiscoveryPolicy(gate: DevSafetyPolicy(isActive: false, home: home))
        #expect(try p.defaultSources(explicitTest: nil, shellKubeconfig: nil) == [home.appending(path: ".kube/config")])
        #expect(try p.defaultSources(explicitTest: nil, shellKubeconfig: "/a/b:/c/d").map(\.path) == ["/a/b", "/c/d"])
    }

    @Test func shellKubeconfigIsRemovedWhileActive() {
        #expect(KubeconfigDiscoveryPolicy(gate: DevSafetyPolicy(isActive: true)).sanitizedShellKubeconfig("/x") == nil)
        #expect(KubeconfigDiscoveryPolicy(gate: DevSafetyPolicy(isActive: false)).sanitizedShellKubeconfig("/x") == "/x")
    }

    @Test func homeKubePathThrows() throws {
        let home = try makeHome()
        let gate = DevSafetyPolicy(isActive: true, home: home)
        #expect(throws: DevSafetyError.self) { try gate.assertReadable(home.appending(path: ".kube/config")) }
        #expect(throws: DevSafetyError.self) { try gate.assertReadable(home.appending(path: ".kube/cache/x/y.yaml")) }
        #expect(throws: DevSafetyError.self) { try gate.assertReadable(home.appending(path: ".kube")) }
    }

    @Test func symlinkIntoHomeKubeThrows() throws {
        let home = try makeHome()
        try Data().write(to: home.appending(path: ".kube/config"))
        let link = home.appending(path: "innocent.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appending(path: ".kube/config"))
        let gate = DevSafetyPolicy(isActive: true, home: home)
        #expect(throws: DevSafetyError.self) { try gate.assertReadable(link) }
    }

    @Test func explicitTestPathThatResolvesUnderHomeKubeThrows() throws {
        let home = try makeHome()
        try Data().write(to: home.appending(path: ".kube/config"))
        let dir = home.appending(path: "work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "kubeconfig"), withDestinationURL: home.appending(path: ".kube/config"))
        let p = KubeconfigDiscoveryPolicy(gate: DevSafetyPolicy(isActive: true, home: home))
        #expect(throws: DevSafetyError.self) { try p.defaultSources(explicitTest: dir.appending(path: "kubeconfig"), shellKubeconfig: nil) }
    }

    @Test func aSymlinkedKubeDirectoryItselfIsResolved() throws {
        let home = try makeHome()
        let real = home.appending(path: "dotfiles/kube")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: home.appending(path: ".kube"))
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".kube"), withDestinationURL: real)
        let gate = DevSafetyPolicy(isActive: true, home: home)
        #expect(throws: DevSafetyError.self) { try gate.assertReadable(real.appending(path: "config")) }
    }

    @Test func aHardLinkToHomeKubeConfigThrows() throws {
        let home = try makeHome()
        try Data("x".utf8).write(to: home.appending(path: ".kube/config"))
        let link = home.appending(path: "Documents-copy.yaml")
        try FileManager.default.linkItem(at: home.appending(path: ".kube/config"), to: link)
        let gate = DevSafetyPolicy(isActive: true, home: home)
        #expect(gate.isUnderHomeKube(link))
        #expect(throws: DevSafetyError.self) { try gate.assertReadable(link) }
        // An unrelated file with the same name is fine.
        let other = home.appending(path: "other.yaml"); try Data("y".utf8).write(to: other)
        #expect(!gate.isUnderHomeKube(other))
    }

    @Test func allowedHostsCanBeSetOnlyOnce() {
        let store = AllowedHostsStore()
        #expect(store.value.isEmpty)
        #expect(store.setOnce(["A.test"]))
        #expect(!store.setOnce(["evil.example.com"]))
        #expect(store.value == ["a.test"])
    }

    @Test func fileOutsideHomeKubeIsReadable() throws {
        let home = try makeHome()
        let gate = DevSafetyPolicy(isActive: true, home: home)
        try gate.assertReadable(home.appending(path: "Documents/test-kubeconfig"))
        try gate.assertReadable(home.appending(path: ".kubernetes/config"))   // a sibling prefix is not ~/.kube
    }

    @Test func inactiveGateDoesNotRestrictPaths() throws {
        let home = try makeHome()
        try DevSafetyPolicy(isActive: false, home: home).assertReadable(home.appending(path: ".kube/config"))
    }

    @Test func testKubeconfigHostsBecomeAllowedHosts() throws {
        let url = try #require(Bundle.module.url(forResource: "test-kubeconfig", withExtension: "yaml", subdirectory: "Fixtures"))
        let home = try makeHome()
        let hosts = try KubeconfigDiscoveryPolicy.configureAllowedHosts(testKubeconfig: url, gate: DevSafetyPolicy(isActive: true, home: home))
        #expect(hosts == ["fixture-cluster.test"])
    }

    @Test func testKubeconfigUnderHomeKubeIsRefusedForHosts() throws {
        let home = try makeHome()
        let file = home.appending(path: ".kube/config")
        try Data("apiVersion: v1\nkind: Config\n".utf8).write(to: file)
        #expect(throws: DevSafetyError.self) {
            _ = try KubeconfigDiscoveryPolicy.configureAllowedHosts(testKubeconfig: file, gate: DevSafetyPolicy(isActive: true, home: home))
        }
    }

    @Test func explicitKubeconfigResolutionOrder() {
        let arg = KubeconfigDiscoveryPolicy.explicitTestKubeconfig(arguments: ["app", "-WHKubeconfigPath", "/a/arg"], environment: ["WH_KUBECONFIG_PATH": "/b/env"], info: ["WHDefaultTestKubeconfig": "/c/plist"])
        #expect(arg?.path == "/a/arg")
        let env = KubeconfigDiscoveryPolicy.explicitTestKubeconfig(arguments: ["app"], environment: ["WH_KUBECONFIG_PATH": "/b/env"], info: ["WHDefaultTestKubeconfig": "/c/plist"])
        #expect(env?.path == "/b/env")
        let plist = KubeconfigDiscoveryPolicy.explicitTestKubeconfig(arguments: ["app"], environment: [:], info: ["WHDefaultTestKubeconfig": "/c/plist"])
        #expect(plist?.path == "/c/plist")
        #expect(KubeconfigDiscoveryPolicy.explicitTestKubeconfig(arguments: ["app"], environment: [:], info: ["WHDefaultTestKubeconfig": ""]) == nil)
    }

    // MARK: hosts

    @Test func hostAllowlistWhileActive() {
        let gate = DevSafetyPolicy(isActive: true, allowedHosts: ["192.168.49.2"])
        #expect(gate.isAllowed(server: URL(string: "https://192.168.49.2:8443")))
        #expect(gate.isAllowed(server: URL(string: "https://anything.test:6443")))
        #expect(gate.isAllowed(server: URL(string: "https://anything.example")))
        #expect(gate.isAllowed(server: URL(string: "https://x.invalid")))
        #expect(gate.isAllowed(server: nil))                                              // Demo clusters have no server
        #expect(!gate.isAllowed(server: URL(string: "https://prod.example.com:6443")))
        #expect(!gate.isAllowed(server: URL(string: "https://203.0.113.10")))
        #expect(!gate.isAllowed(server: URL(string: "https://127.0.0.1:6443")))           // not special: only the test cluster's host
        #expect(!gate.isAllowed(server: URL(string: "https://evil.test.attacker.com")))
        #expect(!gate.isAllowed(server: URL(string: "https://notest")))
    }

    @Test func inactiveAllowsEveryHost() {
        #expect(DevSafetyPolicy(isActive: false).isAllowed(server: URL(string: "https://prod.example.com")))
    }

    @Test func validateThrowsHostNotAllowed() {
        let gate = DevSafetyPolicy(isActive: true, allowedHosts: ["10.0.0.1"])
        #expect(throws: DevSafetyError.hostNotAllowed("prod.example.com")) { try gate.validate(server: URL(string: "https://prod.example.com")) }
        #expect(throws: Never.self) { try gate.validate(server: URL(string: "https://10.0.0.1")) }
    }

    // MARK: switched-off features

    @Test func cloudCLIsMergeAndUpdaterAreOffWhileActive() throws {
        let on = DevSafetyPolicy(isActive: true)
        #expect(!on.allowsCloudCLIs && !on.allowsKubeconfigWrites && !on.allowsHomeDiscovery)
        #expect(throws: DevSafetyError.self) { try KubeconfigWriter(gate: on).assertMayWrite() }
        #expect(throws: DevSafetyError.self) { try on.require(on.allowsCloudCLIs, feature: "Landfall") }
        #expect(!on.shouldStartUpdater(feedURL: "https://ahmadrezaei.github.io/wheelhouse/mac/appcast.xml"))
        #expect(!on.shouldStartUpdater(feedURL: ""))
        let off = DevSafetyPolicy(isActive: false)
        #expect(off.allowsCloudCLIs && off.allowsKubeconfigWrites && off.allowsHomeDiscovery)
        #expect(throws: Never.self) { try KubeconfigWriter(gate: off).assertMayWrite() }
        #expect(off.shouldStartUpdater(feedURL: "https://x/appcast.xml"))
        #expect(!off.shouldStartUpdater(feedURL: nil))
        #expect(!off.shouldStartUpdater(feedURL: "  "))
    }

    @Test func perfScenarioIsIgnoredWhenInactive() {
        let args = ["app", "-WHPerfScenario", "idle-1"]
        #expect(DevSafetyPolicy(isActive: true).perfScenario(arguments: args) == "idle-1")
        #expect(DevSafetyPolicy(isActive: false).perfScenario(arguments: args) == nil)
        #expect(DevSafetyPolicy(isActive: true).perfScenario(arguments: ["app", "-WHPerfScenario"]) == nil)
        #expect(DevSafetyPolicy(isActive: true).perfScenario(arguments: ["app"]) == nil)
    }
}

@Suite("DevSafety: AppPaths")
struct AppPathsTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private let tmp = URL(fileURLWithPath: "/var/folders/xx/T", isDirectory: true)

    @Test func gateActiveIsolatesEvenForTheReleaseBundleID() {
        let p = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mac", home: home, temporaryDirectory: tmp)
        #expect(p.root.path == "/Users/someone/Library/Application Support/Wheelhouse-Debug")
        #expect(p.caches.path == "/Users/someone/Library/Caches/com.ahmadrezaei.wheelhouse.mac.debug")
        #expect(p.sessions.path == "/var/folders/xx/T/wheelhouse-debug/sessions")
        #expect(p.binDirectory.path == "/Users/someone/Library/Application Support/Wheelhouse-Debug/bin")
    }

    @Test func debugBundleIDIsolatesEvenWithGateOff() {
        let p = AppPaths(gateActive: false, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: home, temporaryDirectory: tmp)
        #expect(p.root.lastPathComponent == "Wheelhouse-Debug")
    }

    @Test func distributionUsesTheRealPaths() {
        let p = AppPaths(gateActive: false, bundleID: "com.ahmadrezaei.wheelhouse.mac", home: home, temporaryDirectory: tmp)
        #expect(p.root.path == "/Users/someone/Library/Application Support/Wheelhouse")
        #expect(p.caches.path == "/Users/someone/Library/Caches/com.ahmadrezaei.wheelhouse.mac")
        #expect(p.sessions.path == "/var/folders/xx/T/wheelhouse/sessions")
        #expect(p.helmEnvironment.isEmpty)
        #expect(p.workspaceFile.path.hasSuffix("Application Support/Wheelhouse/workspace.json"))
    }

    @Test func everyFileLivesUnderTheRoot() {
        let p = AppPaths(gateActive: true, bundleID: nil, home: home, temporaryDirectory: tmp)
        for url in [p.workspaceFile, p.discoveredClustersFile, p.clusterSettingsFile, p.landfallKubeconfig, p.activityDatabase] {
            #expect(url.path.hasPrefix(p.root.path + "/"))
        }
        #expect(!p.root.path.hasSuffix("/Wheelhouse"))
    }

    @Test func missingBundleIDWithGateActiveIsIsolated() {
        #expect(AppPaths(gateActive: true, bundleID: nil, home: home, temporaryDirectory: tmp).isolated)
    }

    @Test func helmEnvironmentIsIsolatedUnderTheRoot() {
        let p = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: home, temporaryDirectory: tmp)
        let env = p.helmEnvironment
        #expect(Set(env.keys) == ["HELM_CONFIG_HOME", "HELM_CACHE_HOME", "HELM_DATA_HOME", "HELM_REPOSITORY_CONFIG", "HELM_REPOSITORY_CACHE", "HELM_REGISTRY_CONFIG"])
        for value in env.values { #expect(value.hasPrefix("/Users/someone/Library/Application Support/Wheelhouse-Debug/helm/")) }
    }

    @Test func currentPathsAreIsolatedInTests() {
        #expect(AppPaths.current.isolated)
    }
}
#endif
