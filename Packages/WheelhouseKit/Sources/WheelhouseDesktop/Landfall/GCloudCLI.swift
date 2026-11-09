#if os(macOS)
import Foundation

/// GKE through `gcloud` (ARCHITECTURE-MAC §8.1): `auth list`, `projects list`, `container clusters list`.
public struct GCloudCLI: CloudProviderAdapter {
    public let provider = CloudProvider.gcp
    private let runner: any CLIRunner

    public init(runner: any CLIRunner) { self.runner = runner }

    public func status() async -> CLIStatus {
        do {
            let version = CLIJSON.object(try await runner.json(.gcp, ["version", "--format=json", "--quiet"]))
            let v = CLIJSON.string(version["Google Cloud SDK"]) ?? "unknown"
            let auth = try await runner.json(.gcp, ["auth", "list", "--format=json", "--quiet"])
            if CLIJSON.array(auth).isEmpty { return .signedOut }
            return .installed(version: v)
        } catch CLIError.notInstalled { return .notFound(installHint: provider.installHint) }
        catch CLIError.disabled(let why) { return .disabled(why) }
        catch { return .failed(error.localizedDescription) }
    }

    public func accounts() async throws -> [CloudAccount] {
        let projects = CLIJSON.array(try await runner.json(.gcp, ["projects", "list", "--format=json", "--quiet"]))
        return projects.compactMap { p in
            guard let id = CLIJSON.string(p["projectId"]) else { return nil }
            return CloudAccount(provider: .gcp, accountID: id, name: CLIJSON.string(p["name"]) ?? id, detail: id)
        }.sorted { $0.accountID < $1.accountID }
    }

    public func scan(account: CloudAccount, options: ScanOptions, now: Date) async -> AccountScan {
        let scope = "project \(account.accountID)"
        do {
            let list = CLIJSON.array(try await runner.json(.gcp, ["container", "clusters", "list", "--project", account.accountID, "--format=json", "--quiet"]))
            let clusters = list.compactMap { Self.cluster(from: $0, account: account) }.sorted { ($0.region, $0.name) < ($1.region, $1.name) }
            return AccountScan(account: account, clusters: clusters, issues: [], scannedAt: now)
        } catch {
            var failure = CLIFailure.classify(error)
            if case .accessDenied(nil) = failure { failure = .accessDenied(action: "container.clusters.list") }
            return AccountScan(account: account, clusters: [], issues: [failure.issue(scope: scope)], scannedAt: now)
        }
    }

    static func cluster(from c: [String: Any], account: CloudAccount) -> CloudCluster? {
        guard let name = CLIJSON.string(c["name"]), let location = CLIJSON.string(c["location"]) else { return nil }
        let privateConfig = CLIJSON.object(c["privateClusterConfig"])
        let isPrivate = CLIJSON.bool(privateConfig["enablePrivateEndpoint"]) == true
        let host = isPrivate ? (CLIJSON.string(privateConfig["privateEndpoint"]) ?? CLIJSON.string(c["endpoint"])) : CLIJSON.string(c["endpoint"])
        guard let host, CLIJSON.isHTTPSEndpoint("https://\(host)") else { return nil }
        let status = CLIJSON.string(c["status"]) ?? "UNKNOWN"
        return CloudCluster(
            provider: .gcp, accountID: account.accountID, accountName: account.name, name: name, region: location, endpoint: "https://\(host)",
            caData: CLIJSON.string(CLIJSON.object(c["masterAuth"])["clusterCaCertificate"]), version: CLIJSON.string(c["currentMasterVersion"]),
            status: status.prefix(1).uppercased() + status.dropFirst().lowercased(), access: isPrivate ? .privateEndpoint : .publicEndpoint,
            tags: CLIJSON.stringMap(c["resourceLabels"]), nodeCount: c["currentNodeCount"] as? Int,
            contextName: "gke_\(account.accountID)_\(location)_\(name)")
    }

    public func loginCommand(for account: CloudAccount?) -> CLICommand { CLICommand(provider: .gcp, arguments: ["auth", "login"]) }
}
#endif
