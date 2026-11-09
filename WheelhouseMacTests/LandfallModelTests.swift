import Foundation
import Testing
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// The Landfall view model over a real Moorings stack in a temporary folder and a stub CLI runner. No cloud CLI is started and no real
/// kubeconfig is read: the merge target is a scratch file and every path is under a temporary home.
@Suite("Landfall model", .serialized)
@MainActor
struct LandfallModelTests {
    /// Answers what an AWS profile with two clusters would.
    struct StubAWS: CLIRunner {
        func run(_ provider: CloudProvider, _ arguments: [String], environment: [String: String]) async throws -> CLIOutput {
            func out(_ json: String) -> CLIOutput { CLIOutput(exitCode: 0, stdout: Data(json.utf8)) }
            if arguments.prefix(2) == ["configure", "list-profiles"] { return out("platform\n") }
            if arguments.prefix(2) == ["sts", "get-caller-identity"] { return out(#"{"Account":"123456789012"}"#) }
            if arguments.prefix(2) == ["account", "list-regions"] { return out(#"{"Regions":[{"RegionName":"eu-west-1"}]}"#) }
            if arguments.prefix(2) == ["eks", "list-clusters"] { return out(#"{"clusters":["payments-prd","dev-sandbox"]}"#) }
            if arguments.prefix(2) == ["eks", "describe-cluster"], let i = arguments.firstIndex(of: "--name") {
                let name = arguments[i + 1]
                return out(#"{"cluster":{"name":"\#(name)","arn":"arn:aws:eks:eu-west-1:123456789012:cluster/\#(name)","endpoint":"https://\#(name).gr7.eu-west-1.eks.amazonaws.com","version":"1.30","status":"ACTIVE","certificateAuthority":{"data":"Q0E="},"resourcesVpcConfig":{"endpointPublicAccess":true}}}"#)
            }
            if arguments == ["--version"] { return out("aws-cli/2.17.0 Python/3.12\n") }
            return CLIOutput(exitCode: 1, stdout: Data(), stderr: "unexpected \(arguments)")
        }
    }

    struct Fixture {
        let home: URL
        let userFile: URL
        let moorings: MooringsController
        let model: LandfallModel
    }

    func fixture(mergeIntoUserFile: Bool = false) throws -> Fixture {
        let home = FileManager.default.temporaryDirectory.appending(path: "wh-landfall-\(UUID().uuidString)", directoryHint: .isDirectory).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: home, temporaryDirectory: home)
        try paths.prepare()
        let moorGate: @Sendable () -> DevSafetyPolicy = { DevSafetyPolicy(isActive: true, allowedHosts: [], home: home) }
        let moorings = MooringsController(paths: paths, gate: moorGate, explicitTestKubeconfig: nil, keychainMetadata: InMemoryMetadataStore(),
                                          keychainCredentials: InMemoryCredentialStore(),
                                          shell: ShellEnvironment(gate: moorGate(), home: home, shell: "/usr/bin/true"))
        let userFile = home.appending(path: "user-kubeconfig")
        let open = DevSafetyPolicy(isActive: false, home: home)
        let prefs = LandfallPreferencesStore(fileURL: home.appending(path: "landfall.json"))
        try prefs.update { $0.mergeIntoUserKubeconfig = mergeIntoUserFile; $0.selectedAccounts = ["aws": ["platform"]] }
        let runner = SubprocessCLIRunner(locator: { ExecutableLocator(searchPath: []) }, snapshot: { nil })
        let service = LandfallService(adapters: [AWSCLI(runner: StubAWS())], moorings: moorings.service,
                                      landfallFile: home.appending(path: "kubeconfigs/landfall.yaml"), cacheFile: home.appending(path: "cache.json"),
                                      preferences: prefs, gateProvider: { open }, registry: PeriodicTaskRegistry(), userMergeTarget: userFile)
        let model = LandfallModel(service: service, runner: runner, moorings: moorings, isEnabled: true)
        return Fixture(home: home, userFile: userFile, moorings: moorings, model: model)
    }

    @Test func rowsAreAvailableUntilAddedAndProductionRowsAreExplainedFirst() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.home) }
        let m = f.model
        await m.loadAccounts(force: false)
        await m.scan(force: false)
        #expect(m.clusters.map(\.name) == ["dev-sandbox", "payments-prd"])
        #expect(m.clusters.allSatisfy { m.rowState($0) == .available })
        let prod = try #require(m.clusters.first { $0.name == "payments-prd" })
        let dev = try #require(m.clusters.first { $0.name == "dev-sandbox" })

        // A Production-suggested row is explained and NOT added until confirmed.
        m.requestAdd([prod])
        #expect(m.productionConfirmation?.map(\.name) == ["payments-prd"])
        #expect(m.rowState(prod) == .available)
        #expect(!FileManager.default.fileExists(atPath: f.home.appending(path: "kubeconfigs/landfall.yaml").path))

        // A row that is not Production-suggested is added straight away (requestAdd starts a task, so add directly here).
        await m.add([dev])
        guard case .added(_, let state) = m.rowState(dev) else { Issue.record("not added"); return }
        #expect(state == .notChecked || state == .checking)
        #expect(m.productionConfirmation == nil)

        // Confirming the Production row adds it read-only and not checked.
        await m.add([prod])
        guard case .added(let id, let prodState) = m.rowState(prod) else { Issue.record("not added"); return }
        #expect(prodState == .notChecked)
        #expect(f.moorings.state.overrides.override(for: id)?.readOnly == true)
    }

    @Test func aServerThatIsAlreadyKnownShowsAlreadyAdded() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.home) }
        let m = f.model
        await m.loadAccounts(force: false)
        await m.scan(force: false)
        let dev = try #require(m.clusters.first { $0.name == "dev-sandbox" })
        // Moorings already added a context for that server.
        let key = DiscoveredContextKey(definingFile: "/tmp/other.yaml", contextName: "dev")
        var o = DiscoveredOverride(); o.added = true
        try f.moorings.state.overrides.set(o, for: key.clusterID)
        #expect(m.rowState(dev) == .available)                               // an override alone, with no context, knows no server
        let registry = ClusterRegistry(credentials: f.moorings.credentials, metadata: f.moorings.metadata, defaults: UserDefaults(suiteName: "wh-landfall-\(UUID().uuidString)")!,
                                       clientFactory: f.moorings.clientFactory)
        f.moorings.registry = registry
        let config = ClusterConfig(name: "mine", server: try #require(dev.serverURL), environment: .development)
        try registry.add(config, secrets: ClusterSecrets(token: "t"))
        m.refreshKnownServers()
        #expect(m.rowState(dev) == .alreadyAdded)
        m.requestAdd([dev])                                                  // nothing to add
        #expect(m.productionConfirmation == nil)
    }

    @Test func theMergeReviewCarriesTheEntriesThatWillBeWritten() async throws {
        let f = try fixture(mergeIntoUserFile: true); defer { try? FileManager.default.removeItem(at: f.home) }
        let m = f.model
        // The user's file already has one of the two clusters.
        let existingName = "arn:aws:eks:eu-west-1:123456789012:cluster/dev-sandbox"
        try "apiVersion: v1\nkind: Config\nclusters:\n- name: \(existingName)\n  cluster: {server: \"https://mine.example.test\"}\n".write(to: f.userFile, atomically: true, encoding: .utf8)
        await m.loadAccounts(force: false)
        await m.scan(force: false)
        await m.add(m.clusters)
        let review = try #require(m.mergeReview)
        #expect(review.leftUnchanged == [existingName])
        #expect(review.entries.contexts.map(\.name) == ["arn:aws:eks:eu-west-1:123456789012:cluster/payments-prd"])
        #expect(review.plan.replaced.isEmpty)
        #expect(review.plan.yaml.contains("payments-prd") && !review.plan.yaml.contains("dev-sandbox"))
        #expect(review.clusters.count == 2)
        // Nothing is written until the user confirms.
        #expect(try String(contentsOf: f.userFile, encoding: .utf8).contains("payments-prd") == false)
    }

    @Test func aDevelopmentBuildGateKeepsTheMergeAndTheCLIsOff() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.home) }
        // The Landfall service of the running (gated) build refuses everything.
        let gated = LandfallService(adapters: [], moorings: f.moorings.service, landfallFile: f.home.appending(path: "x/landfall.yaml"),
                                    cacheFile: f.home.appending(path: "x/cache.json"), preferences: LandfallPreferencesStore(fileURL: f.home.appending(path: "x/p.json")),
                                    gateProvider: { DevSafetyPolicy(isActive: true, home: f.home) })
        #expect(!gated.isEnabled)
        await #expect(throws: DevSafetyError.self) { _ = try await gated.add([]) }
    }
}
