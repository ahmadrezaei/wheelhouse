#if os(macOS)
import Foundation
import WheelhouseKit

/// The cloud providers Landfall discovers clusters in (ARCHITECTURE-MAC §8).
public enum CloudProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case aws, gcp, azure

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .aws: "AWS EKS"
        case .gcp: "Google GKE"
        case .azure: "Azure AKS"
        }
    }
    /// The CLI program.
    public var tool: String {
        switch self {
        case .aws: "aws"
        case .gcp: "gcloud"
        case .azure: "az"
        }
    }
    /// What an account is called in this cloud.
    public var accountNoun: String {
        switch self {
        case .aws: "Profile"
        case .gcp: "Project"
        case .azure: "Subscription"
        }
    }
    public var installHint: String {
        switch self {
        case .aws: "brew install awscli"
        case .gcp: "brew install --cask google-cloud-sdk"
        case .azure: "brew install azure-cli"
        }
    }
    public var toolProfile: EnvironmentBuilder.ToolProfile {
        switch self {
        case .aws: .aws
        case .gcp: .google
        case .azure: .azure
        }
    }
}

/// A profile (AWS), project (Google Cloud) or subscription (Azure).
public struct CloudAccount: Codable, Hashable, Sendable, Identifiable {
    public var provider: CloudProvider
    /// The profile name, project ID or subscription ID.
    public var accountID: String
    public var name: String
    public var detail: String?
    public var id: String { "\(provider.rawValue)|\(accountID)" }

    public init(provider: CloudProvider, accountID: String, name: String, detail: String? = nil) {
        self.provider = provider
        self.accountID = accountID
        self.name = name
        self.detail = detail
    }
}

public enum EndpointAccess: String, Codable, Sendable { case publicEndpoint, privateEndpoint, unknown }

/// One managed cluster found by a CLI. Holds no credential: the endpoint, the public CA certificate and metadata only.
public struct CloudCluster: Codable, Hashable, Sendable, Identifiable {
    public var provider: CloudProvider
    public var accountID: String
    public var accountName: String
    /// The cloud's own name of the cluster.
    public var name: String
    public var region: String
    /// `https://host`.
    public var endpoint: String
    /// Base64 PEM of the cluster CA (not secret). Nil when it still has to be fetched (AKS, on Add only).
    public var caData: String?
    public var version: String?
    public var status: String
    public var access: EndpointAccess
    public var tags: [String: String]
    public var nodeCount: Int?
    /// The kubeconfig context name, by vendor convention.
    public var contextName: String
    /// AKS: the resource group (needed to fetch the CA).
    public var resourceGroup: String?
    /// False when Landfall cannot add the cluster; `unsupportedReason` says why.
    public var addable: Bool
    public var unsupportedReason: String?

    public var id: String { "\(provider.rawValue)|\(accountID)|\(contextName)" }
    public var serverURL: URL? { URL(string: endpoint) }

    public init(provider: CloudProvider, accountID: String, accountName: String, name: String, region: String, endpoint: String, caData: String? = nil,
                version: String? = nil, status: String, access: EndpointAccess = .unknown, tags: [String: String] = [:], nodeCount: Int? = nil,
                contextName: String, resourceGroup: String? = nil, addable: Bool = true, unsupportedReason: String? = nil) {
        self.provider = provider
        self.accountID = accountID
        self.accountName = accountName
        self.name = name
        self.region = region
        self.endpoint = endpoint
        self.caData = caData
        self.version = version
        self.status = status
        self.access = access
        self.tags = tags
        self.nodeCount = nodeCount
        self.contextName = contextName
        self.resourceGroup = resourceGroup
        self.addable = addable
        self.unsupportedReason = unsupportedReason
    }

    /// The environment suggested from the name and the `env`, `environment` and `stage` tags (decision 10: Production means the row is
    /// not contacted until the user presses Check).
    public var suggestion: EnvironmentSuggestion? {
        EnvironmentSuggester.suggest(SuggestionInput(contextName: contextName, clusterName: name, serverHost: serverURL?.host(), cloudTags: tags))
    }
    public var isSuggestedProduction: Bool { suggestion?.environment == .production }
}

/// What the CLI reports about itself.
public enum CLIStatus: Codable, Sendable, Equatable {
    case installed(version: String)
    case notFound(installHint: String)
    /// Installed, but no account is signed in.
    case signedOut
    case failed(String)
    /// Development builds never run cloud CLIs.
    case disabled(String)
}

/// A row-level problem found while scanning an account.
public enum LandfallIssue: Codable, Hashable, Sendable {
    /// The CLI session expired or there is none ("AWS SSO session expired").
    case signInRequired(scope: String)
    /// The account is not allowed to list clusters; `action` is the permission to ask for (`eks:ListClusters`).
    case accessDenied(scope: String, action: String?)
    case failed(scope: String, message: String)

    public var message: String {
        switch self {
        case .signInRequired(let scope): "Sign in again to scan \(scope)."
        case .accessDenied(let scope, let action): "Access denied for \(scope)" + (action.map { ". The account needs \($0)." } ?? ".")
        case .failed(let scope, let message): "\(scope): \(message)"
        }
    }
    public var needsSignIn: Bool { if case .signInRequired = self { true } else { false } }
}

/// The result of scanning one account.
public struct AccountScan: Codable, Hashable, Sendable {
    public var account: CloudAccount
    public var clusters: [CloudCluster]
    public var issues: [LandfallIssue]
    public var scannedAt: Date

    public init(account: CloudAccount, clusters: [CloudCluster], issues: [LandfallIssue], scannedAt: Date) {
        self.account = account
        self.clusters = clusters
        self.issues = issues
        self.scannedAt = scannedAt
    }
}

public struct ScanOptions: Sendable, Equatable {
    /// AWS: only these regions; nil = every enabled region.
    public var awsRegions: [String]?
    public init(awsRegions: [String]? = nil) { self.awsRegions = awsRegions }
}

/// A CLI invocation that is not a discovery call (a login), with the extra environment it needs.
public struct CLICommand: Sendable, Equatable {
    public var provider: CloudProvider
    public var arguments: [String]
    public var environment: [String: String]
    public init(provider: CloudProvider, arguments: [String], environment: [String: String] = [:]) {
        self.provider = provider
        self.arguments = arguments
        self.environment = environment
    }
}

/// A provider's discovery commands, over an injected ``CLIRunner`` (recorded JSON in tests).
public protocol CloudProviderAdapter: Sendable {
    var provider: CloudProvider { get }
    func status() async -> CLIStatus
    func accounts() async throws -> [CloudAccount]
    func scan(account: CloudAccount, options: ScanOptions, now: Date) async -> AccountScan
    /// Fills what a scan leaves out because it is slower or sensitive (the AKS CA). Called only for rows being added.
    func prepareToAdd(_ cluster: CloudCluster) async throws -> CloudCluster
    /// The provider's own login command, run in the Sign-in sheet.
    func loginCommand(for account: CloudAccount?) -> CLICommand
}

public extension CloudProviderAdapter {
    func prepareToAdd(_ cluster: CloudCluster) async throws -> CloudCluster { cluster }
}
#endif
