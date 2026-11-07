#if os(macOS)
import Darwin
import Foundation
import WheelhouseKit

public enum CredentialResolveError: Error, Equatable, Sendable, LocalizedError {
    case fileRefused(path: String, reason: String)
    case missingFile(String)
    public var errorDescription: String? {
        switch self {
        case .fileRefused(let p, let why): "\((p as NSString).lastPathComponent) was not read: \(why)"
        case .missingFile(let p): "\(p) does not exist."
        }
    }
}

/// Resolves the secrets of a discovered context from the file each time (ARCHITECTURE-MAC §4.4). Nothing is copied: the result is
/// a transient `ClusterSecrets` held by the client. Referenced files must be regular files owned by the user, at most 1 MB.
public enum DiscoveredSecrets {
    public static let maxFileSize = 1 << 20

    /// Reads one referenced file. `uid` is injectable for tests.
    public static func readFile(_ path: String, uid: uid_t = getuid(), gate: DevSafetyPolicy = .current) throws -> String {
        let url = URL(fileURLWithPath: path)
        // Credential files must not sneak a ~/.kube read in while the gate is active either.
        try gate.assertReadable(url)
        var st = stat()
        guard stat(path, &st) == 0 else { throw CredentialResolveError.missingFile(path) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw CredentialResolveError.fileRefused(path: path, reason: "it is not a regular file") }
        guard st.st_uid == uid else { throw CredentialResolveError.fileRefused(path: path, reason: "it is not owned by you") }
        guard st.st_size <= maxFileSize else { throw CredentialResolveError.fileRefused(path: path, reason: "it is larger than 1 MB") }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw CredentialResolveError.fileRefused(path: path, reason: "it is not readable text")
        }
        return text
    }

    /// The token, CA, certificate and key of a context. A file that cannot be read is skipped; the caller sees missing credentials
    /// (`isMissingCredentials`) rather than a crash.
    public static func resolve(_ ctx: KubeconfigContext, gate: DevSafetyPolicy = .current) -> ClusterSecrets {
        var secrets = ClusterSecrets(caPEM: ctx.caPEM)
        let files = ctx.files
        if secrets.caPEM == nil, let p = files?.certificateAuthority { secrets.caPEM = try? readFile(p, gate: gate) }
        switch ctx.auth {
        case .token(let t): secrets.token = t
        case .clientCertificate(let c, let k): secrets.clientCertificatePEM = c; secrets.clientKeyPEM = k
        default: break
        }
        if secrets.token == nil, let p = files?.tokenFile, let t = try? readFile(p, gate: gate) {
            secrets.token = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if secrets.clientCertificatePEM == nil {
            secrets.clientCertificatePEM = files?.inlineClientCertificatePEM ?? files?.clientCertificate.flatMap { try? readFile($0, gate: gate) }
        }
        if secrets.clientKeyPEM == nil {
            secrets.clientKeyPEM = files?.inlineClientKeyPEM ?? files?.clientKey.flatMap { try? readFile($0, gate: gate) }
        }
        return secrets
    }

    /// The `ClusterAuthKind` a discovered context maps to. Exec contexts are `.none` (the token comes from the plugin).
    public static func authKind(of ctx: KubeconfigContext) -> ClusterAuthKind {
        if ctx.exec != nil { return .none }
        switch ctx.auth {
        case .token: return .token
        case .clientCertificate: return .clientCertificate
        default:
            if ctx.files?.tokenFile != nil { return .token }
            if ctx.files?.clientCertificate != nil || ctx.files?.clientKey != nil || ctx.files?.inlineClientCertificatePEM != nil { return .clientCertificate }
            return .none
        }
    }
}

/// Serves the token of a `tokenFile` credential: re-read on every use, because projected ServiceAccount tokens rotate.
public struct TokenFileProvider: BearerTokenProviding {
    public var path: String
    public var gate: DevSafetyPolicy
    public init(path: String, gate: DevSafetyPolicy = .current) {
        self.path = path
        self.gate = gate
    }
    public func authorization() async throws -> String? {
        try DiscoveredSecrets.readFile(path, gate: gate).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func invalidate() async {}
}

// MARK: - Server comparison (duplicates, sync blocks)

public enum ServerURL {
    /// Scheme, lower-cased host, port with defaults applied and path (no trailing slash): equal means the same API server.
    public static func normalized(_ url: URL) -> String {
        let scheme = (url.scheme ?? "https").lowercased()
        let host = (url.host() ?? "").lowercased()
        let port = url.port ?? (scheme == "http" ? 80 : 443)
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host):\(port)\(path)"
    }

    /// `127.0.0.0/8`, `::1`, `localhost` and `*.localhost`: another device cannot reach such a server.
    public static func isLoopback(_ url: URL) -> Bool {
        let host = (url.host() ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
        let parts = host.split(separator: ".")
        if parts.count == 4, let first = Int(parts[0]), first == 127, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return true }
        return false
    }
}

public enum DuplicateMatcher {
    /// A discovered context duplicates a Keychain cluster when the normalised server and the identity are equal: the same token
    /// SHA-256, the same client-certificate SHA-256 or the same exec spec hash.
    public static func isDuplicate(discoveredServer: URL, discoveredSecrets: ClusterSecrets, discoveredExecHash: String?,
                                   keychainServer: URL, keychainSecrets: ClusterSecrets, keychainExecHash: String?) -> Bool {
        guard ServerURL.normalized(discoveredServer) == ServerURL.normalized(keychainServer) else { return false }
        if let a = discoveredExecHash, let b = keychainExecHash { return a == b }
        if let a = discoveredSecrets.token, let b = keychainSecrets.token, !a.isEmpty { return a.sha256Hex == b.sha256Hex }
        if let a = discoveredSecrets.clientCertificatePEM, let b = keychainSecrets.clientCertificatePEM { return a.sha256Hex == b.sha256Hex }
        return false
    }
}
#endif
