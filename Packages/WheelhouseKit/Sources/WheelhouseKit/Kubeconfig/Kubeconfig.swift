import Foundation
import Yams

/// How a kubeconfig user authenticates.
public enum KubeconfigAuth: Sendable, Equatable {
    case token(String)
    case clientCertificate(certificatePEM: String, keyPEM: String)
    case basic(username: String)
    /// `exec` credential plugin (aws, gke-gcloud-auth-plugin, kubelogin…) — cannot run on iOS.
    case exec(command: String, args: [String])
    /// Legacy `auth-provider` (gcp / oidc / azure).
    case authProvider(name: String)
    /// File references that cannot be read from the sandbox.
    case missingFiles([String])
    case none
}

public enum KubeconfigStatus: String, Sendable, Equatable {
    case ready, local, exec, authProvider, missingFile, basicAuth, invalid
}

public struct KubeconfigContext: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var clusterName: String
    public var userName: String
    public var server: URL?
    public var namespace: String?
    public var caPEM: String?
    public var insecureSkipTLSVerify: Bool
    /// kubeconfig `tls-server-name`: the name the server certificate must be valid for (when the URL host differs).
    public var tlsServerName: String? = nil
    public var auth: KubeconfigAuth
    public var status: KubeconfigStatus
    /// Explains why this context cannot be imported (nil when ready).
    public var unsupportedReason: String?
    public var suggestedEnvironment: ClusterEnvironment

    /// True if the context can be imported without user intervention.
    public var isImportable: Bool { status == .ready }
    /// Contexts that can be recovered by pasting a ServiceAccount token (exec / auth-provider / local).
    public var needsToken: Bool { [.exec, .authProvider].contains(status) }

    /// Builds the persisted config and secrets for an importable context.
    public func makeClusterConfig() -> (config: ClusterConfig, secrets: ClusterSecrets)? {
        guard let server, status == .ready || status == .local else { return nil }
        var secrets = ClusterSecrets(caPEM: caPEM)
        var kind = ClusterAuthKind.none
        switch auth {
        case .token(let t): secrets.token = t; kind = .token
        case .clientCertificate(let c, let k): secrets.clientCertificatePEM = c; secrets.clientKeyPEM = k; kind = .clientCertificate
        default: break
        }
        let config = ClusterConfig(name: name, server: server, authKind: kind, environment: suggestedEnvironment,
                                   skipTLSVerify: insecureSkipTLSVerify && suggestedEnvironment != .production,
                                   defaultNamespace: namespace, tlsServerName: tlsServerName)
        return (config, secrets)
    }
}

public struct Kubeconfig: Sendable, Equatable {
    public var currentContext: String?
    public var contexts: [KubeconfigContext]
    public var clusterCount: Int
    public var userCount: Int
}

public enum KubeconfigError: Error, Equatable, Sendable {
    case notYAML
    case notAKubeconfig
    case empty
}

public enum KubeconfigParser {
    // MARK: Codable mirror of the YAML structure

    private struct File: Decodable {
        var currentContext: String?
        var clusters: [Named<ClusterEntry>]?
        var users: [Named<UserEntry>]?
        var contexts: [Named<ContextEntry>]?
        enum CodingKeys: String, CodingKey {
            case currentContext = "current-context", clusters, users, contexts
        }
    }
    private struct Named<T: Decodable>: Decodable {
        var name: String
        var value: T?
        enum CodingKeys: String, CodingKey { case name, cluster, user, context }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            value = try c.decodeIfPresent(T.self, forKey: .cluster) ?? c.decodeIfPresent(T.self, forKey: .user) ?? c.decodeIfPresent(T.self, forKey: .context)
        }
    }
    private struct ClusterEntry: Decodable {
        var server: String?
        var certificateAuthorityData: String?
        var certificateAuthority: String?
        var insecureSkipTLSVerify: Bool?
        var tlsServerName: String?
        var proxyURL: String?
        enum CodingKeys: String, CodingKey {
            case server
            case tlsServerName = "tls-server-name"
            case proxyURL = "proxy-url"
            case certificateAuthorityData = "certificate-authority-data"
            case certificateAuthority = "certificate-authority"
            case insecureSkipTLSVerify = "insecure-skip-tls-verify"
        }
    }
    private struct ExecEntry: Decodable { var command: String?; var args: [String]? }
    private struct ProviderEntry: Decodable { var name: String? }
    private struct UserEntry: Decodable {
        var token: String?
        var tokenFile: String?
        var clientCertificateData: String?
        var clientKeyData: String?
        var clientCertificate: String?
        var clientKey: String?
        var username: String?
        var password: String?
        var exec: ExecEntry?
        var authProvider: ProviderEntry?
        enum CodingKeys: String, CodingKey {
            case token, tokenFile, username, password, exec
            case clientCertificateData = "client-certificate-data"
            case clientKeyData = "client-key-data"
            case clientCertificate = "client-certificate"
            case clientKey = "client-key"
            case authProvider = "auth-provider"
        }
    }
    private struct ContextEntry: Decodable { var cluster: String?; var user: String?; var namespace: String? }

    // MARK: Parsing

    public static func parse(_ text: String) throws -> Kubeconfig {
        let file: File
        do {
            file = try YAMLDecoder().decode(File.self, from: text)
        } catch let e as DecodingError {
            if case .keyNotFound = e { throw KubeconfigError.notAKubeconfig }
            throw KubeconfigError.notAKubeconfig
        } catch {
            throw KubeconfigError.notYAML
        }
        guard file.contexts != nil || file.clusters != nil else { throw KubeconfigError.notAKubeconfig }
        let clusters = Dictionary((file.clusters ?? []).compactMap { n in n.value.map { (n.name, $0) } }, uniquingKeysWith: { a, _ in a })
        let users = Dictionary((file.users ?? []).compactMap { n in n.value.map { (n.name, $0) } }, uniquingKeysWith: { a, _ in a })
        let contexts = (file.contexts ?? []).compactMap { named -> KubeconfigContext? in
            guard let ctx = named.value else { return nil }
            return makeContext(name: named.name, entry: ctx, cluster: ctx.cluster.flatMap { clusters[$0] }, user: ctx.user.flatMap { users[$0] })
        }
        guard !contexts.isEmpty else { throw KubeconfigError.empty }
        return Kubeconfig(currentContext: file.currentContext, contexts: contexts, clusterCount: clusters.count, userCount: users.count)
    }

    private static func decodeBase64PEM(_ b64: String?) -> String? {
        guard let b64, let data = Data(base64Encoded: b64.filter { !$0.isWhitespace }) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func makeContext(name: String, entry: ContextEntry, cluster: ClusterEntry?, user: UserEntry?) -> KubeconfigContext {
        let server = cluster?.server.flatMap { URL(string: $0) }
        var ctx = KubeconfigContext(
            name: name, clusterName: entry.cluster ?? "", userName: entry.user ?? "", server: server, namespace: entry.namespace,
            caPEM: decodeBase64PEM(cluster?.certificateAuthorityData), insecureSkipTLSVerify: cluster?.insecureSkipTLSVerify ?? false,
            tlsServerName: cluster?.tlsServerName?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            auth: .none, status: .ready, unsupportedReason: nil,
            suggestedEnvironment: .suggested(forName: name))

        guard server != nil, server?.host() != nil else {
            ctx.status = .invalid
            ctx.unsupportedReason = "The cluster has no valid server URL."
            return ctx
        }
        if let proxy = cluster?.proxyURL, !proxy.isEmpty {
            ctx.status = .invalid
            ctx.unsupportedReason = "This cluster is reached through a proxy (proxy-url), which Wheelhouse doesn’t support. Connecting directly would fail or bypass the proxy."
            return ctx
        }
        var missing: [String] = []
        if let path = cluster?.certificateAuthority, cluster?.certificateAuthorityData == nil { missing.append(path) }

        if let exec = user?.exec {
            let command = exec.command ?? "exec plugin"
            ctx.auth = .exec(command: command, args: exec.args ?? [])
            ctx.status = .exec
            ctx.unsupportedReason = execReason(command: command, args: exec.args ?? [])
        } else if let provider = user?.authProvider {
            let n = provider.name ?? "unknown"
            ctx.auth = .authProvider(name: n)
            ctx.status = .authProvider
            ctx.unsupportedReason = n == "oidc"
                ? "Uses the legacy OIDC auth provider. Paste a current ID token instead."
                : "Uses the legacy “\(n)” auth provider, which no longer exists in Kubernetes clients. Use a ServiceAccount token instead."
        } else if let token = user?.token, !token.isEmpty {
            ctx.auth = .token(token)
        } else if let cert = decodeBase64PEM(user?.clientCertificateData), let key = decodeBase64PEM(user?.clientKeyData) {
            ctx.auth = .clientCertificate(certificatePEM: cert, keyPEM: key)
        } else {
            if let f = user?.tokenFile { missing.append(f) }
            if let f = user?.clientCertificate, user?.clientCertificateData == nil { missing.append(f) }
            if let f = user?.clientKey, user?.clientKeyData == nil { missing.append(f) }
            if user?.username != nil {
                ctx.auth = .basic(username: user?.username ?? "")
                ctx.status = .basicAuth
                ctx.unsupportedReason = "Username/password authentication is disabled by Kubernetes 1.19+ and not supported."
            } else if !missing.isEmpty {
                ctx.auth = .missingFiles(missing)
                ctx.status = .missingFile
                ctx.unsupportedReason = "File paths can’t be read from the sandbox — re-export with `kubectl config view --flatten --minify`."
            } else {
                ctx.auth = .none
            }
        }

        if ctx.status == .ready, !missing.isEmpty {
            ctx.status = .missingFile
            ctx.unsupportedReason = "The CA file path can’t be read — re-export with `kubectl config view --flatten`."
        }
        if ctx.status == .ready, isLocal(host: server?.host() ?? "") {
            ctx.status = .local
            ctx.unsupportedReason = "The server address (\(server?.host() ?? "")) is local to the computer that created this file and is not reachable from a phone."
        }
        return ctx
    }

    static func isLocal(host: String) -> Bool {
        let h = host.lowercased()
        return ["127.0.0.1", "localhost", "::1", "host.docker.internal", "0.0.0.0"].contains(h) || h.hasSuffix(".localhost")
    }

    private static func execReason(command: String, args: [String]) -> String {
        let base = (command as NSString).lastPathComponent
        let joined = ([base] + args.prefix(3)).joined(separator: " ")
        let detail: String
        switch base {
        case "aws", "aws-iam-authenticator": detail = "AWS EKS (`aws eks get-token`)"
        case "gke-gcloud-auth-plugin", "gcloud": detail = "Google GKE (`gke-gcloud-auth-plugin`)"
        case "kubelogin": detail = "Azure AKS / OIDC (`kubelogin`)"
        default: detail = "an exec plugin (`\(joined)`)"
        }
        return "Uses \(detail), which runs a local program iOS apps cannot start. Create a ServiceAccount token and add the cluster with it."
    }

    /// Commands the user can run (with a kubeconfig that works on their computer) to mint a long-lived ServiceAccount token.
    public static func serviceAccountTokenCommands(namespace: String = "kube-system", account: String = "wheelhouse", clusterRole: String = "view", duration: String = "8760h") -> String {
        """
        kubectl -n \(namespace) create serviceaccount \(account)
        kubectl create clusterrolebinding \(account) --clusterrole=\(clusterRole) --serviceaccount=\(namespace):\(account)
        kubectl -n \(namespace) create token \(account) --duration=\(duration)
        """
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
