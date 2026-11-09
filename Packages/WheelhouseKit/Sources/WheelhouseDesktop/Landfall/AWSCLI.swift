#if os(macOS)
import Foundation

/// Reads CLI JSON without a schema: a missing or mistyped key yields nil, never a crash.
enum CLIJSON {
    static func object(_ any: Any?) -> [String: Any] { any as? [String: Any] ?? [:] }
    static func array(_ any: Any?) -> [[String: Any]] { (any as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
    static func string(_ any: Any?) -> String? { (any as? String).flatMap { $0.isEmpty ? nil : $0 } }
    static func bool(_ any: Any?) -> Bool? { any as? Bool }
    static func strings(_ any: Any?) -> [String] { (any as? [Any])?.compactMap { $0 as? String } ?? [] }
    /// `https://host[:port]` with a plain host name or address: nothing a later URL or argv step could misread.
    static func isHTTPSEndpoint(_ s: String) -> Bool {
        s.range(of: #"^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$"#, options: .regularExpression) != nil
    }
    static func stringMap(_ any: Any?) -> [String: String] {
        (any as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
    }
}

/// EKS through `aws` (ARCHITECTURE-MAC §8.1): profiles, caller identity, enabled regions, `eks list-clusters` and `describe-cluster`.
public struct AWSCLI: CloudProviderAdapter {
    public let provider = CloudProvider.aws
    private let runner: any CLIRunner

    public init(runner: any CLIRunner) { self.runner = runner }

    public func status() async -> CLIStatus {
        do {
            let text = String(decoding: try await runner.output(.aws, ["--version"]), as: UTF8.self)
            // "aws-cli/2.15.30 Python/3.11.8 Darwin/..."
            let version = text.split(separator: " ").first.map { $0.replacingOccurrences(of: "aws-cli/", with: "") } ?? text
            return .installed(version: version.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch CLIError.notInstalled { return .notFound(installHint: provider.installHint) }
        catch CLIError.disabled(let why) { return .disabled(why) }
        catch { return .failed(error.localizedDescription) }
    }

    public func accounts() async throws -> [CloudAccount] {
        let text = String(decoding: try await runner.output(.aws, ["configure", "list-profiles"]), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { CloudAccount(provider: .aws, accountID: $0, name: $0) }
    }

    public func scan(account: CloudAccount, options: ScanOptions, now: Date) async -> AccountScan {
        let profile = account.accountID
        let scope = "profile \(profile)"
        var issues: [LandfallIssue] = []
        var identified = account
        // Who am I: the first call also finds an expired SSO session.
        do {
            let identity = CLIJSON.object(try await runner.json(.aws, ["sts", "get-caller-identity", "--profile", profile, "--output", "json"]))
            if let id = CLIJSON.string(identity["Account"]) { identified.detail = "Account \(id)" }
        } catch {
            return AccountScan(account: identified, clusters: [], issues: [CLIFailure.classify(error).issue(scope: scope)], scannedAt: now)
        }
        let regions: [String]
        if let picked = options.awsRegions, !picked.isEmpty { regions = picked } else {
            do { regions = try await enabledRegions(profile: profile) } catch {
                return AccountScan(account: identified, clusters: [], issues: [CLIFailure.classify(error).issue(scope: "\(scope) regions")], scannedAt: now)
            }
        }
        let named = identified
        let results = await withTaskGroup(of: ([CloudCluster], [LandfallIssue]).self) { group in
            for region in regions { group.addTask { await scanRegion(region, account: named) } }
            var all: [([CloudCluster], [LandfallIssue])] = []
            for await r in group { all.append(r) }
            return all
        }
        var clusters = results.flatMap { $0.0 }
        issues += results.flatMap { $0.1 }
        clusters.sort { ($0.region, $0.name) < ($1.region, $1.name) }
        return AccountScan(account: named, clusters: clusters, issues: issues, scannedAt: now)
    }

    func enabledRegions(profile: String) async throws -> [String] {
        let primary = ["account", "list-regions", "--region-opt-status-contains", "ENABLED", "ENABLED_BY_DEFAULT", "--profile", profile, "--output", "json"]
        let json: Any
        do { json = try await runner.json(.aws, primary) } catch {
            // `account:ListRegions` is often not granted: fall back to EC2's list of regions enabled for the account.
            guard CLIFailure.classify(error) != .signedOut else { throw error }
            json = try await runner.json(.aws, ["ec2", "describe-regions", "--profile", profile, "--output", "json"])
        }
        return CLIJSON.array(CLIJSON.object(json)["Regions"]).compactMap { CLIJSON.string($0["RegionName"]) }.sorted()
    }

    private func scanRegion(_ region: String, account: CloudAccount) async -> ([CloudCluster], [LandfallIssue]) {
        let profile = account.accountID
        let scope = "\(profile) in \(region)"
        let names: [String]
        do {
            let list = CLIJSON.object(try await runner.json(.aws, ["eks", "list-clusters", "--region", region, "--profile", profile, "--output", "json"]))
            names = CLIJSON.strings(list["clusters"])
        } catch {
            let failure = CLIFailure.classify(error)
            if case .accessDenied(let action) = failure { return ([], [.accessDenied(scope: scope, action: action ?? "eks:ListClusters")]) }
            return ([], [failure.issue(scope: scope)])
        }
        return await withTaskGroup(of: (CloudCluster?, LandfallIssue?).self) { group in
            for name in names {
                group.addTask {
                    do {
                        let described = CLIJSON.object(try await runner.json(.aws, ["eks", "describe-cluster", "--name", name, "--region", region,
                                                                                    "--profile", profile, "--output", "json"]))
                        return (Self.cluster(from: CLIJSON.object(described["cluster"]), name: name, region: region, account: account), nil)
                    } catch {
                        let failure = CLIFailure.classify(error)
                        if case .accessDenied(let action) = failure { return (nil, .accessDenied(scope: "\(scope) cluster \(name)", action: action ?? "eks:DescribeCluster")) }
                        return (nil, failure.issue(scope: "\(scope) cluster \(name)"))
                    }
                }
            }
            var clusters: [CloudCluster] = [], issues: [LandfallIssue] = []
            for await (c, i) in group { if let c { clusters.append(c) }; if let i { issues.append(i) } }
            return (clusters, issues)
        }
    }

    /// `aws eks describe-cluster` → a cluster. The context name is the cluster ARN, like `aws eks update-kubeconfig` writes it.
    static func cluster(from c: [String: Any], name: String, region: String, account: CloudAccount) -> CloudCluster? {
        guard let endpoint = CLIJSON.string(c["endpoint"]), CLIJSON.isHTTPSEndpoint(endpoint) else { return nil }
        let vpc = CLIJSON.object(c["resourcesVpcConfig"])
        let publicAccess = CLIJSON.bool(vpc["endpointPublicAccess"])
        let status = CLIJSON.string(c["status"]) ?? "UNKNOWN"
        let arn = CLIJSON.string(c["arn"]) ?? "arn:aws:eks:\(region):\(account.detail?.replacingOccurrences(of: "Account ", with: "") ?? "unknown"):cluster/\(name)"
        return CloudCluster(
            provider: .aws, accountID: account.accountID, accountName: account.name, name: CLIJSON.string(c["name"]) ?? name, region: region, endpoint: endpoint,
            caData: CLIJSON.string(CLIJSON.object(c["certificateAuthority"])["data"]), version: CLIJSON.string(c["version"]),
            status: status.prefix(1).uppercased() + status.dropFirst().lowercased(),
            access: publicAccess == nil ? .unknown : (publicAccess == true ? .publicEndpoint : .privateEndpoint),
            tags: CLIJSON.stringMap(c["tags"]), contextName: arn)
    }

    public func loginCommand(for account: CloudAccount?) -> CLICommand {
        CLICommand(provider: .aws, arguments: ["sso", "login"] + (account.map { ["--profile", $0.accountID] } ?? []))
    }
}
#endif
