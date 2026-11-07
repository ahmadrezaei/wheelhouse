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
    /// Desktop only: the exec credential plugin stanza (nil on iOS and for other auth kinds).
    public var exec: KubeconfigExecSpec? = nil
    /// Desktop only: files referenced by the context, resolved to absolute paths. Never read here.
    public var files: KubeconfigFileReferences? = nil

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

/// Which platform's rules ``KubeconfigParser`` applies.
public enum KubeconfigEnvironment: Sendable, Equatable {
    /// iOS (the default): file references cannot be read, `exec` and local servers are unsupported.
    case mobile
    /// macOS: `.local` is `ready`, file references resolve against `baseDirectory` (the kubeconfig's folder) and are kept for the
    /// caller to read, and `exec` is `ready` (a credential plugin is run by `WheelhouseDesktop`).
    case desktop(baseDirectory: URL)
}

/// An `exec` credential plugin stanza (`client.authentication.k8s.io`).
public struct KubeconfigExecSpec: Sendable, Hashable, Codable {
    public struct EnvVar: Sendable, Hashable, Codable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }
    /// As written: `client.authentication.k8s.io/v1` or `/v1beta1` (`v1alpha1` is rejected by the runner).
    public var apiVersion: String?
    public var command: String
    public var args: [String]
    public var env: [EnvVar]
    public var installHint: String?
    public var provideClusterInfo: Bool
    /// `Never`, `IfAvailable` or `Always`; nil when absent (v1beta1 then means `IfAvailable`).
    public var interactiveMode: String?
    /// `extensions[client.authentication.k8s.io/exec]` of the cluster, passed to the plugin when `provideClusterInfo` is true.
    public var clusterConfig: JSONValue?
    /// Directory of the file that defines the user, for a `command` containing `/` that is not absolute.
    public var baseDirectory: String?

    public init(apiVersion: String? = nil, command: String, args: [String] = [], env: [EnvVar] = [], installHint: String? = nil,
                provideClusterInfo: Bool = false, interactiveMode: String? = nil, clusterConfig: JSONValue? = nil, baseDirectory: String? = nil) {
        self.apiVersion = apiVersion
        self.command = command
        self.args = args
        self.env = env
        self.installHint = installHint
        self.provideClusterInfo = provideClusterInfo
        self.interactiveMode = interactiveMode
        self.clusterConfig = clusterConfig
        self.baseDirectory = baseDirectory
    }
}

/// Files a desktop context references, resolved to absolute paths (relative paths resolve against the defining file's folder).
public struct KubeconfigFileReferences: Sendable, Hashable, Codable {
    public var certificateAuthority: String?
    public var clientCertificate: String?
    public var clientKey: String?
    public var tokenFile: String?
    /// Inline halves when the other half is a file (a mixed certificate and key).
    public var inlineClientCertificatePEM: String?
    public var inlineClientKeyPEM: String?
    public var isEmpty: Bool { certificateAuthority == nil && clientCertificate == nil && clientKey == nil && tokenFile == nil }
    public init(certificateAuthority: String? = nil, clientCertificate: String? = nil, clientKey: String? = nil, tokenFile: String? = nil,
                inlineClientCertificatePEM: String? = nil, inlineClientKeyPEM: String? = nil) {
        self.certificateAuthority = certificateAuthority
        self.clientCertificate = clientCertificate
        self.clientKey = clientKey
        self.tokenFile = tokenFile
        self.inlineClientCertificatePEM = inlineClientCertificatePEM
        self.inlineClientKeyPEM = inlineClientKeyPEM
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

    struct File: Decodable, Sendable {
        var currentContext: String?
        var clusters: [Named<ClusterEntry>]?
        var users: [Named<UserEntry>]?
        var contexts: [Named<ContextEntry>]?
        enum CodingKeys: String, CodingKey {
            case currentContext = "current-context", clusters, users, contexts
        }
    }
    struct Named<T: Decodable & Sendable>: Decodable, Sendable {
        var name: String
        var value: T?
        enum CodingKeys: String, CodingKey { case name, cluster, user, context }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            value = try c.decodeIfPresent(T.self, forKey: .cluster) ?? c.decodeIfPresent(T.self, forKey: .user) ?? c.decodeIfPresent(T.self, forKey: .context)
        }
    }
    struct ClusterEntry: Decodable, Sendable {
        var server: String?
        var certificateAuthorityData: String?
        var certificateAuthority: String?
        var insecureSkipTLSVerify: Bool?
        var tlsServerName: String?
        var proxyURL: String?
        /// `extensions[client.authentication.k8s.io/exec].extension`, for exec plugins that ask for cluster info.
        var execExtension: JSONValue?
        enum CodingKeys: String, CodingKey {
            case server
            case tlsServerName = "tls-server-name"
            case proxyURL = "proxy-url"
            case certificateAuthorityData = "certificate-authority-data"
            case certificateAuthority = "certificate-authority"
            case insecureSkipTLSVerify = "insecure-skip-tls-verify"
            case extensions
        }
        struct ExtensionEntry: Decodable {
            var name: String?
            var value: JSONValue?
            enum CodingKeys: String, CodingKey { case name, `extension` }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try? c.decodeIfPresent(String.self, forKey: .name)
                value = try? c.decodeIfPresent(JSONValue.self, forKey: .extension)
            }
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            server = try c.decodeIfPresent(String.self, forKey: .server)
            tlsServerName = try c.decodeIfPresent(String.self, forKey: .tlsServerName)
            proxyURL = try c.decodeIfPresent(String.self, forKey: .proxyURL)
            certificateAuthorityData = try c.decodeIfPresent(String.self, forKey: .certificateAuthorityData)
            certificateAuthority = try c.decodeIfPresent(String.self, forKey: .certificateAuthority)
            insecureSkipTLSVerify = try c.decodeIfPresent(Bool.self, forKey: .insecureSkipTLSVerify)
            // Never makes a file fail to parse.
            let extensions = (try? c.decodeIfPresent([ExtensionEntry].self, forKey: .extensions)) ?? nil
            execExtension = extensions?.first { $0.name == "client.authentication.k8s.io/exec" }?.value
        }
    }
    struct ExecEntry: Decodable, Sendable {
        var command: String?
        var args: [String]?
        var apiVersion: String?
        var env: [KubeconfigExecSpec.EnvVar]?
        var installHint: String?
        var provideClusterInfo: Bool?
        var interactiveMode: String?
        enum CodingKeys: String, CodingKey { case command, args, apiVersion, env, installHint, provideClusterInfo, interactiveMode }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decodeIfPresent(String.self, forKey: .command)
            args = try c.decodeIfPresent([String].self, forKey: .args)
            // The desktop-only keys never make a file fail to parse.
            apiVersion = try? c.decodeIfPresent(String.self, forKey: .apiVersion)
            env = (try? c.decodeIfPresent([EnvEntry].self, forKey: .env))?.compactMap { $0.value.map { KubeconfigExecSpec.EnvVar(name: $0.name, value: $0.value) } }
            installHint = try? c.decodeIfPresent(String.self, forKey: .installHint)
            provideClusterInfo = try? c.decodeIfPresent(Bool.self, forKey: .provideClusterInfo)
            interactiveMode = try? c.decodeIfPresent(String.self, forKey: .interactiveMode)
        }
        struct EnvEntry: Decodable {
            var value: (name: String, value: String)?  // tuple: Sendable by element types
            enum CodingKeys: String, CodingKey { case name, value }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let n = try? c.decode(String.self, forKey: .name) { value = (n, (try? c.decode(String.self, forKey: .value)) ?? "") }
            }
        }
    }
    struct ProviderEntry: Decodable, Sendable { var name: String? }
    struct UserEntry: Decodable, Sendable {
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
    struct ContextEntry: Decodable, Sendable { var cluster: String?; var user: String?; var namespace: String? }

    // MARK: Parsing

    public static func parse(_ text: String, environment: KubeconfigEnvironment = .mobile) throws -> Kubeconfig {
        let base: URL?
        if case .desktop(let dir) = environment { base = dir } else { base = nil }
        let doc = try parseDocument(text, baseDirectory: base)
        let contexts: [KubeconfigContext]
        if base == nil {
            // iOS: exactly the original single-file behaviour (a context is listed once per entry, in file order).
            let clusters = Dictionary((doc.file.clusters ?? []).compactMap { n in n.value.map { (n.name, $0) } }, uniquingKeysWith: { a, _ in a })
            let users = Dictionary((doc.file.users ?? []).compactMap { n in n.value.map { (n.name, $0) } }, uniquingKeysWith: { a, _ in a })
            contexts = (doc.file.contexts ?? []).compactMap { named -> KubeconfigContext? in
                guard let ctx = named.value else { return nil }
                return makeContext(name: named.name, entry: ctx, cluster: ctx.cluster.flatMap { clusters[$0] }, user: ctx.user.flatMap { users[$0] },
                                   desktop: false, clusterBase: nil, userBase: nil)
            }
        } else {
            contexts = merge([doc], desktop: true).contexts.map(\.context)
        }
        guard !contexts.isEmpty else { throw KubeconfigError.empty }
        return Kubeconfig(currentContext: doc.file.currentContext, contexts: contexts,
                          clusterCount: Set(doc.file.clusters?.filter { $0.value != nil }.map(\.name) ?? []).count,
                          userCount: Set(doc.file.users?.filter { $0.value != nil }.map(\.name) ?? []).count)
    }

    /// One decoded file, ready to be merged with others by ``merge(_:desktop:)``.
    public struct Document: Sendable {
        let file: File
        /// The file's folder (desktop only), used to resolve relative paths of the entries this file defines.
        let baseDirectory: URL?
        public var currentContext: String? { file.currentContext }
        public var contextNames: [String] { (file.contexts ?? []).map(\.name) }
    }

    public static func parseDocument(_ text: String, baseDirectory: URL?) throws -> Document {
        let file: File
        do {
            file = try YAMLDecoder().decode(File.self, from: text)
        } catch let e as DecodingError {
            if case .keyNotFound = e { throw KubeconfigError.notAKubeconfig }
            throw KubeconfigError.notAKubeconfig
        } catch {
            throw KubeconfigError.notYAML
        }
        // A desktop file may define only users (kubectl merges such files into a set); iOS needs contexts or clusters.
        guard file.contexts != nil || file.clusters != nil || (baseDirectory != nil && file.users != nil) else { throw KubeconfigError.notAKubeconfig }
        return Document(file: file, baseDirectory: baseDirectory)
    }

    public struct MergedContext: Sendable {
        public var context: KubeconfigContext
        /// Index in the `documents` array of the file that defines the context.
        public var fileIndex: Int
    }
    public struct ShadowedContext: Sendable, Equatable {
        public var name: String
        public var fileIndex: Int
        public var shadowedByFileIndex: Int
    }
    public struct MergedKubeconfig: Sendable {
        public var contexts: [MergedContext]
        /// Contexts hidden by an earlier file that defines the same name (kubectl would not use them).
        public var shadowed: [ShadowedContext]
        /// `current-context` of the first file that sets one.
        public var currentContext: String?
    }

    /// client-go's loading rules for a set of files: for `clusters`, `users` and `contexts` the first file that defines a name wins;
    /// a context resolves its cluster and user against the merged maps; `current-context` comes from the first file that sets it.
    public static func merge(_ documents: [Document], desktop: Bool) -> MergedKubeconfig {
        var clusters: [String: (entry: ClusterEntry, base: URL?)] = [:]
        var users: [String: (entry: UserEntry, base: URL?)] = [:]
        var definedContexts: [String: (entry: ContextEntry, file: Int)] = [:]
        var order: [String] = []
        var shadowed: [ShadowedContext] = []
        for (i, doc) in documents.enumerated() {
            for n in doc.file.clusters ?? [] { if let v = n.value, clusters[n.name] == nil { clusters[n.name] = (v, doc.baseDirectory) } }
            for n in doc.file.users ?? [] { if let v = n.value, users[n.name] == nil { users[n.name] = (v, doc.baseDirectory) } }
            var seenInThisFile: Set<String> = []
            for n in doc.file.contexts ?? [] {
                guard let v = n.value else { continue }
                if let first = definedContexts[n.name] {
                    if first.file != i, !seenInThisFile.contains(n.name) {
                        shadowed.append(ShadowedContext(name: n.name, fileIndex: i, shadowedByFileIndex: first.file))
                    }
                    continue
                }
                definedContexts[n.name] = (v, i)
                seenInThisFile.insert(n.name)
                order.append(n.name)
            }
        }
        let contexts = order.compactMap { name -> MergedContext? in
            guard let d = definedContexts[name] else { return nil }
            let c = d.entry.cluster.flatMap { clusters[$0] }
            let u = d.entry.user.flatMap { users[$0] }
            let ctx = makeContext(name: name, entry: d.entry, cluster: c?.entry, user: u?.entry, desktop: desktop,
                                  clusterBase: c?.base, userBase: u?.base)
            return MergedContext(context: ctx, fileIndex: d.file)
        }
        return MergedKubeconfig(contexts: contexts, shadowed: shadowed, currentContext: documents.compactMap { $0.file.currentContext }.first { !$0.isEmpty })
    }

    private static func decodeBase64PEM(_ b64: String?) -> String? {
        guard let b64, let data = Data(base64Encoded: b64.filter { !$0.isWhitespace }) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func makeContext(name: String, entry: ContextEntry, cluster: ClusterEntry?, user: UserEntry?, desktop: Bool,
                                    clusterBase: URL?, userBase: URL?) -> KubeconfigContext {
        if desktop { return makeDesktopContext(name: name, entry: entry, cluster: cluster, user: user, clusterBase: clusterBase, userBase: userBase) }
        return makeMobileContext(name: name, entry: entry, cluster: cluster, user: user)
    }

    /// Absolute path of a file reference: relative paths resolve against the folder of the file that defines the entry.
    static func resolvePath(_ path: String, base: URL?) -> String {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        guard let base else { return path }
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
    }

    private static func makeDesktopContext(name: String, entry: ContextEntry, cluster: ClusterEntry?, user: UserEntry?,
                                           clusterBase: URL?, userBase: URL?) -> KubeconfigContext {
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
        var files = KubeconfigFileReferences()
        if ctx.caPEM == nil, let path = cluster?.certificateAuthority, !path.isEmpty { files.certificateAuthority = resolvePath(path, base: clusterBase) }

        if let exec = user?.exec {
            let command = exec.command ?? ""
            ctx.auth = .exec(command: command, args: exec.args ?? [])
            ctx.exec = KubeconfigExecSpec(apiVersion: exec.apiVersion, command: command, args: exec.args ?? [], env: exec.env ?? [],
                                          installHint: exec.installHint, provideClusterInfo: exec.provideClusterInfo ?? false,
                                          interactiveMode: exec.interactiveMode, clusterConfig: cluster?.execExtension,
                                          baseDirectory: userBase?.path)
            if command.isEmpty {
                ctx.status = .invalid
                ctx.unsupportedReason = "The exec credential plugin has no command."
            }
        } else if let provider = user?.authProvider {
            let n = provider.name ?? "unknown"
            ctx.auth = .authProvider(name: n)
            ctx.status = .authProvider
            ctx.unsupportedReason = n == "oidc"
                ? "Uses the legacy OIDC auth provider. Use an exec plugin such as kubelogin (oidc-login) instead."
                : "Uses the legacy “\(n)” auth provider, which no longer exists in Kubernetes clients. Use an exec plugin or a ServiceAccount token instead."
        } else if let token = user?.token, !token.isEmpty {
            ctx.auth = .token(token)
        } else if user?.username != nil, user?.clientCertificate == nil, user?.clientCertificateData == nil {
            ctx.auth = .basic(username: user?.username ?? "")
            ctx.status = .basicAuth
            ctx.unsupportedReason = "Username/password authentication is disabled by Kubernetes 1.19+ and not supported."
        } else {
            if let f = user?.tokenFile, !f.isEmpty { files.tokenFile = resolvePath(f, base: userBase) }
            let inlineCert = decodeBase64PEM(user?.clientCertificateData)
            let inlineKey = decodeBase64PEM(user?.clientKeyData)
            if let inlineCert, let inlineKey {
                ctx.auth = .clientCertificate(certificatePEM: inlineCert, keyPEM: inlineKey)
            } else {
                if inlineCert == nil, let f = user?.clientCertificate, !f.isEmpty { files.clientCertificate = resolvePath(f, base: userBase) }
                if inlineKey == nil, let f = user?.clientKey, !f.isEmpty { files.clientKey = resolvePath(f, base: userBase) }
                files.inlineClientCertificatePEM = inlineCert
                files.inlineClientKeyPEM = inlineKey
            }
        }
        ctx.files = files.isEmpty && files.inlineClientCertificatePEM == nil && files.inlineClientKeyPEM == nil ? nil : files
        return ctx
    }

    private static func makeMobileContext(name: String, entry: ContextEntry, cluster: ClusterEntry?, user: UserEntry?) -> KubeconfigContext {
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
