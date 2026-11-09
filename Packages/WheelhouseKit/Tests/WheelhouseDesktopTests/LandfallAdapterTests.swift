#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// Recorded CLI output (Fixtures/landfall): answers by provider and arguments, and counts every call. No process is started.
final class RecordedRunner: CLIRunner, @unchecked Sendable {
    struct Call: Equatable { var provider: CloudProvider; var args: [String] }
    typealias Responder = @Sendable (CloudProvider, [String]) -> CLIOutput?
    private let calls = Mutex<[Call]>([])
    private let responder: Responder
    init(_ responder: @escaping Responder) { self.responder = responder }

    var recorded: [Call] { calls.withLock { $0 } }
    var count: Int { calls.withLock { $0.count } }
    func calls(matching word: String) -> [Call] { recorded.filter { $0.args.contains(word) } }

    func run(_ provider: CloudProvider, _ arguments: [String], environment: [String: String]) async throws -> CLIOutput {
        calls.withLock { $0.append(Call(provider: provider, args: arguments)) }
        return responder(provider, arguments) ?? CLIOutput(exitCode: 1, stdout: Data(), stderr: "no recording for \(provider.tool) \(arguments.joined(separator: " "))")
    }
}

func landfallFixture(_ path: String) -> Data {
    let ns = path as NSString
    let name = "Fixtures/landfall/" + ns.deletingPathExtension
    guard let url = Bundle.module.url(forResource: name, withExtension: ns.pathExtension), let data = try? Data(contentsOf: url) else {
        Issue.record("missing fixture \(path)")
        return Data()
    }
    return data
}

final class ArgLog: @unchecked Sendable {
    private let state = Mutex<[[String]]>([])
    func add(_ a: [String]) { state.withLock { $0.append(a) } }
    var all: [[String]] { state.withLock { $0 } }
}

func ok(_ path: String) -> CLIOutput { CLIOutput(exitCode: 0, stdout: landfallFixture(path)) }
func fail(_ message: String, code: Int32 = 255) -> CLIOutput { CLIOutput(exitCode: code, stdout: Data(), stderr: message) }

/// Everything `aws` is asked for in the recorded session.
func awsRecording(expiredProfiles: Set<String> = [], denyListIn: Set<String> = [], denyAccountRegions: Bool = false) -> RecordedRunner.Responder {
    { provider, a in
        guard provider == .aws else { return nil }
        func value(after flag: String) -> String? { a.firstIndex(of: flag).flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil } }
        if a == ["--version"] { return CLIOutput(exitCode: 0, stdout: Data("aws-cli/2.17.0 Python/3.12.4 Darwin/27.0 source/arm64\n".utf8)) }
        if a.prefix(2) == ["configure", "list-profiles"] { return ok("aws/profiles.txt") }
        if let p = value(after: "--profile"), expiredProfiles.contains(p) {
            return fail("Error loading SSO Token: Token for \(p) does not exist or has expired. To refresh, run: aws sso login --profile \(p)")
        }
        if a.prefix(2) == ["sts", "get-caller-identity"] { return ok("aws/sts.json") }
        if a.prefix(2) == ["account", "list-regions"] {
            return denyAccountRegions ? fail("An error occurred (AccessDeniedException) when calling the ListRegions operation: User is not authorized to perform: account:ListRegions") : ok("aws/regions.json")
        }
        if a.prefix(2) == ["ec2", "describe-regions"] { return ok("aws/regions.json") }
        if a.prefix(2) == ["eks", "list-clusters"], let r = value(after: "--region") {
            if denyListIn.contains(r) { return fail("An error occurred (AccessDeniedException) when calling the ListClusters operation: User: arn:aws:sts::1:assumed-role/x is not authorized to perform: eks:ListClusters on resource: arn:aws:eks:\(r):1:cluster/*") }
            return ok("aws/list-\(r).json")
        }
        if a.prefix(2) == ["eks", "describe-cluster"], let n = value(after: "--name") { return ok("aws/describe-\(n).json") }
        return nil
    }
}

@Suite("Landfall adapters (recorded CLI output)")
struct LandfallAdapterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func awsScanFindsClustersWithVendorContextNamesAndTags() async throws {
        let runner = RecordedRunner(awsRecording())
        let aws = AWSCLI(runner: runner)
        #expect(try await aws.accounts().map(\.accountID) == ["default", "platform-prod", "dev-sandbox"])
        let scan = await aws.scan(account: CloudAccount(provider: .aws, accountID: "platform-prod", name: "platform-prod"), options: ScanOptions(), now: now)
        #expect(scan.issues.isEmpty)
        #expect(scan.account.detail == "Account 123456789012")
        #expect(scan.clusters.map(\.name) == ["payments-prd", "tagged-only"])
        let payments = scan.clusters[0]
        #expect(payments.contextName == "arn:aws:eks:eu-west-1:123456789012:cluster/payments-prd")
        #expect(payments.region == "eu-west-1")
        #expect(payments.version == "1.30")
        #expect(payments.status == "Active")
        #expect(payments.access == .publicEndpoint)
        #expect(payments.caData == "Q0EtUEFZTUVOVFM=")
        let tagged = scan.clusters[1]
        #expect(tagged.access == .privateEndpoint)
        #expect(tagged.tags == ["env": "prod"])
        // Both are suggested as Production: one by its name ("prd"), one only by the tag.
        #expect(payments.isSuggestedProduction)
        #expect(tagged.isSuggestedProduction)
        #expect(tagged.suggestion?.reasons.contains { $0.contains("tag env") } == true)
    }

    @Test func awsAccountsWithExpiredSSOShowSignInAndNothingElseRuns() async throws {
        let runner = RecordedRunner(awsRecording(expiredProfiles: ["platform-prod"]))
        let scan = await AWSCLI(runner: runner).scan(account: CloudAccount(provider: .aws, accountID: "platform-prod", name: "platform-prod"), options: ScanOptions(), now: now)
        #expect(scan.clusters.isEmpty)
        #expect(scan.issues == [.signInRequired(scope: "profile platform-prod")])
        #expect(runner.count == 1)
        #expect(AWSCLI(runner: runner).loginCommand(for: scan.account).arguments == ["sso", "login", "--profile", "platform-prod"])
    }

    @Test func awsListDeniedInARegionIsARowLevelErrorNamingTheAction() async throws {
        let runner = RecordedRunner(awsRecording(denyListIn: ["us-east-1"]))
        let scan = await AWSCLI(runner: runner).scan(account: CloudAccount(provider: .aws, accountID: "p", name: "p"), options: ScanOptions(), now: now)
        #expect(scan.clusters.count == 2)
        #expect(scan.issues == [.accessDenied(scope: "p in us-east-1", action: "eks:ListClusters")])
    }

    @Test func awsFallsBackToEC2RegionsAndHonoursAPickedRegionList() async throws {
        let denied = RecordedRunner(awsRecording(denyAccountRegions: true))
        _ = await AWSCLI(runner: denied).scan(account: CloudAccount(provider: .aws, accountID: "p", name: "p"), options: ScanOptions(), now: now)
        #expect(denied.calls(matching: "describe-regions").count == 1)
        let picked = RecordedRunner(awsRecording())
        let scan = await AWSCLI(runner: picked).scan(account: CloudAccount(provider: .aws, accountID: "p", name: "p"), options: ScanOptions(awsRegions: ["us-east-1"]), now: now)
        #expect(scan.clusters.isEmpty)
        #expect(picked.calls(matching: "list-regions").isEmpty)
        #expect(picked.calls(matching: "list-clusters").count == 1)
    }

    @Test func awsStatusReportsVersionAndMissingTool() async {
        #expect(await AWSCLI(runner: RecordedRunner(awsRecording())).status() == .installed(version: "2.17.0"))
        struct Missing: CLIRunner { func run(_ provider: CloudProvider, _ arguments: [String], environment: [String: String]) async throws -> CLIOutput { throw CLIError.notInstalled("aws") } }
        #expect(await AWSCLI(runner: Missing()).status() == .notFound(installHint: "brew install awscli"))
        struct Disabled: CLIRunner { func run(_ provider: CloudProvider, _ arguments: [String], environment: [String: String]) async throws -> CLIOutput { throw CLIError.disabled("off") } }
        #expect(await AWSCLI(runner: Disabled()).status() == .disabled("off"))
    }

    func gcloudRecording(signedIn: Bool = true) -> RecordedRunner.Responder {
        { provider, a in
            guard provider == .gcp else { return nil }
            if a.first == "version" { return ok("gcloud/version.json") }
            if a.prefix(2) == ["auth", "list"] { return signedIn ? ok("gcloud/auth-list.json") : CLIOutput(exitCode: 0, stdout: Data("[]".utf8)) }
            if a.prefix(2) == ["projects", "list"] { return ok("gcloud/projects.json") }
            if a.prefix(3) == ["container", "clusters", "list"], a.contains("lab-2") { return ok("gcloud/clusters-lab-2.json") }
            if a.prefix(3) == ["container", "clusters", "list"] { return fail("ERROR: (gcloud.container.clusters.list) PERMISSION_DENIED: Required \"container.clusters.list\" permission", code: 1) }
            return nil
        }
    }

    @Test func gcloudListsProjectsAndClustersWithPrivateEndpoints() async throws {
        let gcloud = GCloudCLI(runner: RecordedRunner(gcloudRecording()))
        #expect(await gcloud.status() == .installed(version: "512.0.0"))
        let accounts = try await gcloud.accounts()
        #expect(accounts.map(\.accountID) == ["lab-2", "shop-prod-1"])
        let scan = await gcloud.scan(account: accounts[0], options: ScanOptions(), now: now)
        #expect(scan.clusters.map(\.contextName) == ["gke_lab-2_europe-west4_internal", "gke_lab-2_europe-west4-a_scratch"])
        let internalCluster = scan.clusters[0]
        #expect(internalCluster.access == .privateEndpoint)
        #expect(internalCluster.endpoint == "https://10.0.0.2")
        #expect(internalCluster.status == "Reconciling")
        #expect(scan.clusters[1].tags == ["stage": "dev"])
        #expect(scan.clusters[1].nodeCount == 3)
        #expect(scan.clusters[1].caData == "R0tFLUNB")
    }

    @Test func gcloudSignedOutAndPermissionDenied() async throws {
        #expect(await GCloudCLI(runner: RecordedRunner(gcloudRecording(signedIn: false))).status() == .signedOut)
        let scan = await GCloudCLI(runner: RecordedRunner(gcloudRecording())).scan(account: CloudAccount(provider: .gcp, accountID: "shop-prod-1", name: "Shop"), options: ScanOptions(), now: now)
        #expect(scan.issues == [.accessDenied(scope: "project shop-prod-1", action: "container.clusters.list")])
    }

    func azRecording(_ calls: ArgLog? = nil) -> RecordedRunner.Responder {
        { provider, a in
            guard provider == .azure else { return nil }
            calls?.add(a)
            if a.first == "version" { return ok("az/version.json") }
            if a.prefix(2) == ["account", "list"] { return ok("az/account-list.json") }
            if a.prefix(2) == ["aks", "list"] { return ok("az/aks-list.json") }
            if a.prefix(2) == ["aks", "get-credentials"] { return CLIOutput(exitCode: 0, stdout: landfallFixture("az/get-credentials-aad.yaml")) }
            return nil
        }
    }

    @Test func azureListsEnabledSubscriptionsAndOnlyEntraClustersAreAddable() async throws {
        let calls = ArgLog()
        let az = AzureCLI(runner: RecordedRunner(azRecording(calls)))
        #expect(await az.status() == .installed(version: "2.66.0"))
        let accounts = try await az.accounts()
        #expect(accounts.map(\.name) == ["Platform"])
        let scan = await az.scan(account: accounts[0], options: ScanOptions(), now: now)
        let edge = try #require(scan.clusters.first { $0.name == "edge-aks" })
        #expect(edge.addable && edge.unsupportedReason == nil)
        #expect(edge.nodeCount == 5)
        #expect(edge.endpoint == "https://edge-dns-1.hcp.westeurope.azmk8s.io:443")
        #expect(edge.tags == ["environment": "production"])
        #expect(edge.isSuggestedProduction)
        let legacy = try #require(scan.clusters.first { $0.name == "legacy-aks" })
        #expect(!legacy.addable)
        #expect(legacy.status == "Stopped")
        #expect(legacy.unsupportedReason?.contains("local accounts") == true)
        // Scanning never fetches credentials.
        #expect(!calls.all.contains { $0.contains("get-credentials") })
    }

    @Test func azureFetchesTheCAOnlyForEntraRowsBeingAdded() async throws {
        let calls = ArgLog()
        let az = AzureCLI(runner: RecordedRunner(azRecording(calls)))
        let scan = await az.scan(account: CloudAccount(provider: .azure, accountID: "00000000-0000-0000-0000-0000000000aa", name: "Platform"), options: ScanOptions(), now: now)
        let edge = try #require(scan.clusters.first { $0.name == "edge-aks" })
        let prepared = try await az.prepareToAdd(edge)
        #expect(prepared.caData == "QVpVUkUtQ0E=")
        let legacy = try #require(scan.clusters.first { $0.name == "legacy-aks" })
        await #expect(throws: CLIError.self) { _ = try await az.prepareToAdd(legacy) }
        let credentialCalls = calls.all.filter { $0.contains("get-credentials") }
        #expect(credentialCalls.count == 1)
        #expect(credentialCalls[0].contains("--file") && credentialCalls[0].contains("-"))
    }

    @Test func clusterNamesDoNotCollideAcrossResourceGroups() {
        let a = CloudCluster(provider: .azure, accountID: "s", accountName: "S", name: "aks", region: "r", endpoint: "https://a", status: "Active", contextName: "aks", resourceGroup: "rg1")
        var b = a; b.resourceGroup = "rg2"
        #expect(AzureCLI.disambiguated([a, b]).map(\.contextName) == ["aks-rg1", "aks-rg2"])
    }

    @Test func kubeconfigEntriesUseTheVendorExecShapes() throws {
        let aws = CloudCluster(provider: .aws, accountID: "123456789012", accountName: "p", name: "payments", region: "eu-west-1", endpoint: "https://x.eks.amazonaws.com",
                               caData: "Q0E=", status: "Active", contextName: "arn:aws:eks:eu-west-1:123456789012:cluster/payments")
        let gcp = CloudCluster(provider: .gcp, accountID: "lab", accountName: "Lab", name: "scratch", region: "eu", endpoint: "https://1.2.3.4", caData: "Q0E=", status: "Running", contextName: "gke_lab_eu_scratch")
        let az = CloudCluster(provider: .azure, accountID: "sub", accountName: "S", name: "edge", region: "we", endpoint: "https://e:443", caData: "Q0E=", status: "Active", contextName: "edge")
        let entries = LandfallKubeconfig.entries(for: [aws, gcp, az])
        #expect(entries.contexts.map(\.name) == [aws.contextName, "gke_lab_eu_scratch", "edge"])
        let exec = entries.users.map(\.user.exec)
        #expect(exec[0].command == "aws")
        #expect(exec[0].args == ["--region", "eu-west-1", "eks", "get-token", "--cluster-name", "payments", "--output", "json"])
        #expect(exec[0].env == [.init(name: "AWS_PROFILE", value: "123456789012")])
        #expect(exec[1].command == "gke-gcloud-auth-plugin" && exec[1].provideClusterInfo == true && exec[1].interactiveMode == "IfAvailable")
        #expect(exec[2].command == "kubelogin" && exec[2].args.contains(AzureCLI.serverID))
        // No secret anywhere: the YAML has no token or key fields.
        let yaml = try entries.yaml()
        #expect(!yaml.contains("token:") && !yaml.contains("client-key") && !yaml.contains("password"))
        // A numeric profile stays a string in the YAML.
        #expect(yaml.contains("'123456789012'") || yaml.contains("\"123456789012\""))
    }

    @Test func cliDerivedValuesAreValidatedBeforeTheyReachAnArgvOrAURL() {
        let account = CloudAccount(provider: .azure, accountID: "00000000-0000-0000-0000-0000000000aa", name: "S")
        func aks(_ name: String, group: String, managed: Bool? = true, sub: CloudAccount? = nil) -> CloudCluster? {
            var c: [String: Any] = ["name": name, "resourceGroup": group, "location": "we", "fqdn": "x.hcp.we.azmk8s.io"]
            if let managed { c["aadProfile"] = ["managed": managed] }
            return AzureCLI.cluster(from: c, account: sub ?? account)
        }
        #expect(aks("edge-aks", group: "rg-edge")?.addable == true)
        #expect(aks("edge-aks", group: "rg-edge", managed: false)?.addable == false)          // aadProfile without managed: not addable
        #expect(aks("edge-aks", group: "rg-edge", managed: nil)?.addable == false)
        #expect(aks("--bad", group: "rg")?.addable == false)
        #expect(aks("ok", group: "rg; rm")?.addable == false)
        #expect(aks("ok", group: "rg", sub: CloudAccount(provider: .azure, accountID: "--subscription x", name: "S"))?.addable == false)
        let acct = CloudAccount(provider: .aws, accountID: "p", name: "p")
        func eks(_ endpoint: String) -> CloudCluster? {
            AWSCLI.cluster(from: ["endpoint": endpoint, "status": "ACTIVE", "arn": "arn:aws:eks:r:1:cluster/n"], name: "n", region: "r", account: acct)
        }
        #expect(eks("https://AAAA.gr7.eu-west-1.eks.amazonaws.com") != nil)
        #expect(eks("http://aaaa.example.test") == nil)
        #expect(eks("https://user@host.example.test") == nil)
        #expect(eks("https://host.example.test/path?x") == nil)
        #expect(eks("https://host example.test") == nil)
    }

    @Test func wheelhouseBackupsTempFilesAndLocksAreNotKubeconfigSources() {
        for name in ["config.wheelhouse-backup-20261109-070000", "config.wheelhouse-backup-20261109-070000-2", ".config.wheelhouse-tmp-1F2E", "config.lock", "landfall.yaml.wheelhouse-backup-1"] {
            #expect(!KubeconfigLoader.isCandidateName(name), "\(name)")
        }
        #expect(KubeconfigLoader.isCandidateName("config"))
        #expect(KubeconfigLoader.isCandidateName("work.yaml"))
    }

    @Test func gkeAndAKSEndpointsAreValidatedToo() {
        let lab = CloudAccount(provider: .gcp, accountID: "lab", name: "Lab")
        func gke(_ endpoint: String) -> CloudCluster? { GCloudCLI.cluster(from: ["name": "c", "location": "eu", "endpoint": endpoint], account: lab) }
        #expect(gke("34.90.0.10") != nil)
        #expect(gke("evil host") == nil)
        #expect(gke("x/y?z") == nil)
        let sub = CloudAccount(provider: .azure, accountID: "00000000-0000-0000-0000-0000000000aa", name: "S")
        func aks(_ fqdn: String) -> CloudCluster? { AzureCLI.cluster(from: ["name": "n", "resourceGroup": "rg", "location": "we", "fqdn": fqdn, "aadProfile": ["managed": true]], account: sub) }
        #expect(aks("n-dns.hcp.we.azmk8s.io") != nil)
        #expect(aks("n-dns.hcp.we.azmk8s.io/evil") == nil)
        #expect(aks("a b") == nil)
    }
}
#endif
