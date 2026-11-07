#if os(macOS)
import CryptoKit
import Foundation
import WheelhouseKit

/// What can go wrong running a credential plugin. Messages never contain credentials (stderr is redacted).
public enum ExecCredentialError: Error, Equatable, Sendable, LocalizedError {
    /// The plugin is not on the PATH. Carries the kubeconfig's `installHint` and a known install command.
    case pluginMissing(command: String, installHint: String?, suggestion: String?)
    case unsupportedAPIVersion(String)
    case failed(command: String, exitCode: Int32?, stderrTail: String)
    case timedOut(command: String)
    case invalidOutput(String)
    /// `interactiveMode: Always`: the plugin needs the Sign-in sheet.
    case signInRequired(command: String)
    case cancelled
    case developmentBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .pluginMissing(let command, let hint, let suggestion):
            let base = (command as NSString).lastPathComponent
            return ["`\(base)` isn’t on your PATH.", hint, suggestion.map { "Install it with: \($0)" }].compactMap { $0 }.joined(separator: " ")
        case .unsupportedAPIVersion(let v): return "The credential plugin uses \(v), which is no longer supported. Update the plugin."
        case .failed(let command, let code, let tail):
            return "Credential plugin `\((command as NSString).lastPathComponent)` failed (exit \(code.map(String.init) ?? "signal")). \(tail)"
        case .timedOut(let command): return "Credential plugin `\((command as NSString).lastPathComponent)` did not answer in time."
        case .invalidOutput(let why): return "The credential plugin printed an invalid ExecCredential: \(why)"
        case .signInRequired(let command): return "`\((command as NSString).lastPathComponent)` needs you to sign in."
        case .cancelled: return "Sign-in was cancelled."
        case .developmentBlocked(let why): return why
        }
    }
}

/// A parsed `client.authentication.k8s.io` ExecCredential `status`.
public struct ExecCredential: Sendable, Equatable {
    public var token: String?
    public var clientCertificateData: String?
    public var clientKeyData: String?
    public var expirationTimestamp: Date?

    public var isClientCertificate: Bool { clientCertificateData != nil && clientKeyData != nil }

    static let maxOutput = 1 << 20

    /// Validates the plugin's stdout. The `apiVersion` must equal the requested one; the output is at most 1 MB; the status needs a
    /// token or a certificate with its key.
    public static func parse(_ stdout: Data, expectedAPIVersion: String, now: Date = Date()) throws -> ExecCredential {
        guard stdout.count <= maxOutput else { throw ExecCredentialError.invalidOutput("the output is larger than 1 MB") }
        guard let root = try? JSONValue.parse(stdout), let object = root.objectValue else {
            throw ExecCredentialError.invalidOutput("the output is not JSON")
        }
        guard object["kind"]?.stringValue == "ExecCredential" else { throw ExecCredentialError.invalidOutput("kind is not ExecCredential") }
        let version = object["apiVersion"]?.stringValue ?? ""
        guard version == expectedAPIVersion else {
            throw ExecCredentialError.invalidOutput("apiVersion \(version.isEmpty ? "is missing" : "is \(version)"), expected \(expectedAPIVersion)")
        }
        guard let status = object["status"]?.objectValue else { throw ExecCredentialError.invalidOutput("status is missing") }
        var credential = ExecCredential()
        if let t = status["token"]?.stringValue, !t.isEmpty { credential.token = t }
        if let c = status["clientCertificateData"]?.stringValue, !c.isEmpty { credential.clientCertificateData = c }
        if let k = status["clientKeyData"]?.stringValue, !k.isEmpty { credential.clientKeyData = k }
        if let e = status["expirationTimestamp"]?.stringValue, !e.isEmpty {
            guard let date = parseRFC3339(e) else { throw ExecCredentialError.invalidOutput("expirationTimestamp is not RFC 3339") }
            credential.expirationTimestamp = date
        }
        if credential.token == nil && !credential.isClientCertificate {
            throw ExecCredentialError.invalidOutput("status has neither a token nor a client certificate with its key")
        }
        return credential
    }

    static func parseRFC3339(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// When to fetch a new credential: 60 s before expiry, or at 80 % of the lifetime when that is sooner. nil without an expiry.
    public func refreshDate(obtainedAt: Date) -> Date? {
        guard let expiry = expirationTimestamp else { return nil }
        let early = expiry.addingTimeInterval(-60)
        let lifetime = expiry.timeIntervalSince(obtainedAt)
        guard lifetime > 0 else { return obtainedAt }
        return min(early, obtainedAt.addingTimeInterval(lifetime * 0.8))
    }

    /// The PEM certificate and key for a client-certificate credential.
    public var certificateMaterial: ClientCertificateMaterial? {
        guard let c = clientCertificateData, let k = clientKeyData else { return nil }
        return ClientCertificateMaterial(certificatePEM: c, keyPEM: k)
    }
}

/// The cluster facts passed to a plugin that sets `provideClusterInfo`.
public struct ExecClusterInfo: Sendable, Hashable {
    public var server: String
    public var tlsServerName: String?
    /// Base64 of the CA PEM.
    public var certificateAuthorityData: String?
    public var insecureSkipTLSVerify: Bool
    public init(server: String, tlsServerName: String? = nil, certificateAuthorityData: String? = nil, insecureSkipTLSVerify: Bool = false) {
        self.server = server
        self.tlsServerName = tlsServerName
        self.certificateAuthorityData = certificateAuthorityData
        self.insecureSkipTLSVerify = insecureSkipTLSVerify
    }
}

/// Everything that decides whether two plugin runs may share a credential.
struct ExecRequest: Sendable {
    var spec: KubeconfigExecSpec
    var cluster: ExecClusterInfo?
    var kubeconfigPath: String

    /// The API version the runner asks for (`v1beta1` defaults apply when the stanza omits it).
    var apiVersion: String { spec.apiVersion ?? "client.authentication.k8s.io/v1" }

    /// SHA-256 of the canonical exec stanza, the server and the kubeconfig path (hex, 20 characters).
    var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hasher = SHA256()
        hasher.update(data: (try? encoder.encode(spec)) ?? Data())
        hasher.update(data: Data([0]))
        hasher.update(data: Data((cluster?.server ?? "").utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(kubeconfigPath.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(20).description
    }

    /// `KUBERNETES_EXEC_INFO`.
    func execInfo(interactive: Bool) -> String {
        var spec: [String: JSONValue] = ["interactive": .bool(interactive)]
        if self.spec.provideClusterInfo, let c = cluster {
            var cluster: [String: JSONValue] = ["server": .string(c.server), "insecure-skip-tls-verify": .bool(c.insecureSkipTLSVerify)]
            if let n = c.tlsServerName { cluster["tls-server-name"] = .string(n) }
            if let ca = c.certificateAuthorityData { cluster["certificate-authority-data"] = .string(ca) }
            if let config = self.spec.clusterConfig { cluster["config"] = config }
            spec["cluster"] = .object(cluster)
        }
        let root: JSONValue = .object(["apiVersion": .string(apiVersion), "kind": .string("ExecCredential"), "spec": .object(spec)])
        return (try? root.data()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Removes anything that looks like a credential from plugin stderr before it is shown or copied.
public enum StderrRedactor {
    private static let patterns: [(NSRegularExpression, String)] = {
        let raw: [(String, String)] = [
            (#"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]*"#, "[redacted]"),                 // JWTs
            (#"k8s-aws-v1\.[A-Za-z0-9_\-=]+"#, "[redacted]"),                                               // EKS tokens
            (#"(?i)(bearer|authorization:?)\s+[A-Za-z0-9._~+/=\-]{8,}"#, "$1 [redacted]"),
            (#"(?i)((?:access[_-]?token|id[_-]?token|refresh[_-]?token|token|secret|password|passwd|client[_-]?secret|api[_-]?key)["']?\s*[:=]\s*["']?)[^\s"',}]{4,}"#, "$1[redacted]"),
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#, "[redacted key]"),
            (#"[A-Za-z0-9+/_\-]{48,}={0,2}"#, "[redacted]"),                                                 // long opaque strings
        ]
        return raw.compactMap { p, t in (try? NSRegularExpression(pattern: p)).map { ($0, t) } }
    }()

    /// The last `lines` lines, redacted.
    public static func tail(_ stderr: Data, lines: Int = 20) -> String {
        let text = String(decoding: stderr, as: UTF8.self)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
        return redact(kept)
    }

    public static func redact(_ text: String) -> String {
        var out = text
        for (regex, template) in patterns {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}

/// Install commands for the plugins people commonly lack (ARCHITECTURE-MAC §4.5).
public enum ExecPluginAdvice {
    public static func installCommand(for command: String) -> String? {
        switch (command as NSString).lastPathComponent {
        case "aws-iam-authenticator": "brew install aws-iam-authenticator"
        case "gke-gcloud-auth-plugin": "gcloud components install gke-gcloud-auth-plugin"
        case "kubelogin": "brew install Azure/kubelogin/kubelogin"
        case "aws": "brew install awscli"
        case "kubectl-oidc_login", "kubectl-oidc-login": "brew install int128/kubelogin/kubelogin"
        default: nil
        }
    }
}
#endif
