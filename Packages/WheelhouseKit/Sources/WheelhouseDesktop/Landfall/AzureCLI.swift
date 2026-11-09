#if os(macOS)
import Foundation
import WheelhouseKit

/// AKS through `az` (ARCHITECTURE-MAC §8.1): `account list`, `aks list`, and `aks get-credentials --file -` for the CA of a row being added.
///
/// Only Entra ID clusters (`aadProfile` present) are addable: they use `kubelogin`, so the file holds no secret. A local-account cluster
/// would need its credential adopted into the Keychain, which Landfall does not do yet; it is listed with the reason. `get-credentials`
/// is never run for such a cluster, because its output holds a client certificate, key or token.
public struct AzureCLI: CloudProviderAdapter {
    public let provider = CloudProvider.azure
    /// The Entra ID server application every AKS-managed Entra integration uses.
    public static let serverID = "6dae42f8-4368-4678-94ff-3960e28e3630"
    private let runner: any CLIRunner

    public init(runner: any CLIRunner) { self.runner = runner }

    public func status() async -> CLIStatus {
        do {
            let version = CLIJSON.object(try await runner.json(.azure, ["version", "-o", "json", "--only-show-errors"]))
            let v = CLIJSON.string(version["azure-cli"]) ?? "unknown"
            if try await accounts().isEmpty { return .signedOut }
            return .installed(version: v)
        } catch CLIError.notInstalled { return .notFound(installHint: provider.installHint) }
        catch CLIError.disabled(let why) { return .disabled(why) }
        catch let error where CLIFailure.classify(error) == .signedOut { return .signedOut }
        catch { return .failed(error.localizedDescription) }
    }

    public func accounts() async throws -> [CloudAccount] {
        let list = CLIJSON.array(try await runner.json(.azure, ["account", "list", "-o", "json", "--only-show-errors"]))
        return list.compactMap { a in
            guard let id = CLIJSON.string(a["id"]), CLIJSON.string(a["state"]) != "Disabled" else { return nil }
            return CloudAccount(provider: .azure, accountID: id, name: CLIJSON.string(a["name"]) ?? id, detail: CLIJSON.string(a["user"].flatMap { CLIJSON.object($0)["name"] }))
        }.sorted { $0.name < $1.name }
    }

    public func scan(account: CloudAccount, options: ScanOptions, now: Date) async -> AccountScan {
        do {
            let list = CLIJSON.array(try await runner.json(.azure, ["aks", "list", "--subscription", account.accountID, "-o", "json", "--only-show-errors"]))
            let clusters = list.compactMap { Self.cluster(from: $0, account: account) }.sorted { ($0.region, $0.name) < ($1.region, $1.name) }
            return AccountScan(account: account, clusters: Self.disambiguated(clusters), issues: [], scannedAt: now)
        } catch {
            return AccountScan(account: account, clusters: [], issues: [CLIFailure.classify(error).issue(scope: "subscription \(account.name)")], scannedAt: now)
        }
    }

    /// Two clusters with one name (different resource groups) must not share a context name.
    static func disambiguated(_ clusters: [CloudCluster]) -> [CloudCluster] {
        let counts = Dictionary(grouping: clusters, by: \.contextName).mapValues(\.count)
        return clusters.map { c in
            guard (counts[c.contextName] ?? 0) > 1, let group = c.resourceGroup else { return c }
            var copy = c
            copy.contextName = "\(c.name)-\(group)"
            return copy
        }
    }

    static func cluster(from c: [String: Any], account: CloudAccount) -> CloudCluster? {
        guard let name = CLIJSON.string(c["name"]), let location = CLIJSON.string(c["location"]) else { return nil }
        let fqdn = CLIJSON.string(c["fqdn"]), privateFqdn = CLIJSON.string(c["privateFqdn"])
        let isPrivate = CLIJSON.bool(CLIJSON.object(c["apiServerAccessProfile"])["enablePrivateCluster"]) == true || (fqdn == nil && privateFqdn != nil)
        guard let host = isPrivate ? (privateFqdn ?? fqdn) : (fqdn ?? privateFqdn) else { return nil }
        let power = CLIJSON.string(CLIJSON.object(c["powerState"])["code"])
        let provisioning = CLIJSON.string(c["provisioningState"]) ?? "Unknown"
        let status = power == "Stopped" ? "Stopped" : (provisioning == "Succeeded" ? "Active" : provisioning)
        let nodes = CLIJSON.array(c["agentPoolProfiles"]).compactMap { $0["count"] as? Int }.reduce(0, +)
        let entra = CLIJSON.bool(CLIJSON.object(c["aadProfile"])["managed"]) == true
        let group = CLIJSON.string(c["resourceGroup"])
        // These go into argv later: only Azure's own grammar.
        let valid = Self.isValidName(name) && (group.map(Self.isValidResourceGroup) ?? false) && Self.isValidSubscription(account.accountID)
        return CloudCluster(
            provider: .azure, accountID: account.accountID, accountName: account.name, name: name, region: location, endpoint: "https://\(host):443",
            version: CLIJSON.string(c["kubernetesVersion"]), status: status, access: isPrivate ? .privateEndpoint : .publicEndpoint,
            tags: CLIJSON.stringMap(c["tags"]), nodeCount: nodes > 0 ? nodes : nil, contextName: name, resourceGroup: CLIJSON.string(c["resourceGroup"]),
            addable: entra && valid,
            unsupportedReason: !valid ? "The cluster name, resource group or subscription is not in a form Landfall can pass to az."
                : (entra ? nil : "This cluster has no managed Entra ID integration (local accounts only). Adding it would need its credential stored in the Keychain, which Landfall does not do yet."))
    }

    static func isValidName(_ s: String) -> Bool { s.range(of: #"^[A-Za-z0-9]([A-Za-z0-9_-]{0,61}[A-Za-z0-9])?$"#, options: .regularExpression) != nil }
    static func isValidResourceGroup(_ s: String) -> Bool { s.range(of: #"^[A-Za-z0-9._()-]{1,90}$"#, options: .regularExpression) != nil && !s.hasPrefix("-") }
    static func isValidSubscription(_ s: String) -> Bool { s.range(of: #"^[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil }

    /// The CA of an Entra ID cluster, read from `az aks get-credentials --file -`. Only the CA is kept; nothing else of that output is read.
    public func prepareToAdd(_ cluster: CloudCluster) async throws -> CloudCluster {
        guard cluster.addable, let group = cluster.resourceGroup else { throw CLIError.invalidOutput(cluster.unsupportedReason ?? "This cluster cannot be added.") }
        let data = try await runner.output(.azure, ["aks", "get-credentials", "--resource-group", group, "--name", cluster.name,
                                                    "--subscription", cluster.accountID, "--file", "-", "--only-show-errors"])
        guard let ca = Self.certificateAuthority(inKubeconfig: String(decoding: data, as: UTF8.self)) else {
            throw CLIError.invalidOutput("the credentials had no cluster CA")
        }
        var copy = cluster
        copy.caData = ca
        return copy
    }

    static func certificateAuthority(inKubeconfig text: String) -> String? {
        guard let config = try? KubeconfigParser.parse(text, environment: .desktop(baseDirectory: URL(fileURLWithPath: "/"))) else { return nil }
        return config.contexts.lazy.compactMap(\.caPEM).first.map { Data($0.utf8).base64EncodedString() }
    }

    public func loginCommand(for account: CloudAccount?) -> CLICommand { CLICommand(provider: .azure, arguments: ["login"]) }
}
#endif
