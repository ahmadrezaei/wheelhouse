#if os(macOS)
import Foundation

/// Builds the COMPLETE environment of a child process from an empty start (ARCHITECTURE-MAC §3.2): an allowlist, never the app's
/// own environment.
public struct EnvironmentBuilder: Sendable {
    /// Which per-tool variables are added on top of the base set.
    public enum ToolProfile: Sendable, Equatable {
        case none, kubectl, helm, aws, google, azure, docker, trivy

        /// The profile an exec plugin gets, chosen from its command name.
        public static func forPlugin(command: String) -> ToolProfile {
            switch (command as NSString).lastPathComponent {
            case "aws", "aws-iam-authenticator", "aws-vault": .aws
            case "gcloud", "gke-gcloud-auth-plugin": .google
            case "kubelogin", "az": .azure
            default: .none
            }
        }
    }

    public var snapshot: ShellSnapshot?
    public var paths: AppPaths
    public var home: URL

    public init(snapshot: ShellSnapshot?, paths: AppPaths = .current, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.snapshot = snapshot
        self.paths = paths
        self.home = home
    }

    static let baseKeys: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "__CF_USER_TEXT_ENCODING"]
    static let networkKeys: Set<String> = [
        "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "no_proxy", "all_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE",
    ]
    static let awsKeys: Set<String> = ["AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_REGION", "AWS_DEFAULT_REGION", "AWS_CONFIG_FILE",
                                       "AWS_SHARED_CREDENTIALS_FILE", "AWS_SDK_LOAD_CONFIG", "AWS_CA_BUNDLE"]
    static let googleKeys: Set<String> = ["CLOUDSDK_CONFIG", "CLOUDSDK_CORE_PROJECT", "GOOGLE_APPLICATION_CREDENTIALS", "USE_GKE_GCLOUD_AUTH_PLUGIN"]
    static let dockerKeys: Set<String> = ["DOCKER_CONFIG", "DOCKER_HOST"]

    /// Names that are never passed, whatever the profile.
    static func isNeverPassed(_ key: String) -> Bool {
        key.hasPrefix("DYLD_") || key.hasPrefix("XPC_") || key.hasPrefix("MallocStackLogging") || key == "__CFBundleIdentifier"
            || key.hasSuffix("_API_KEY") || key == "ANTHROPIC_API_KEY" || key.hasPrefix("WHEELHOUSE_") || key == "KUBECONFIG"
    }

    /// The allowlisted variables of `source` for a profile (a shell snapshot, or the app's own environment for the base keys).
    private func allowed(from source: [String: String], profile: ToolProfile) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in source where !Self.isNeverPassed(k) {
            if Self.baseKeys.contains(k) || k.hasPrefix("LC_") || Self.networkKeys.contains(k) { out[k] = v; continue }
            switch profile {
            case .aws: if Self.awsKeys.contains(k) { out[k] = v }
            case .google: if Self.googleKeys.contains(k) { out[k] = v }
            case .azure: if k.hasPrefix("AZURE_") { out[k] = v }
            case .helm:
                // An isolated build takes no HELM_* from the shell (plugins, drivers, homes): its own homes are set in `build`.
                guard !paths.isolated, k.hasPrefix("HELM_"), !k.hasPrefix("HELM_KUBE") else { break }
                if k == "HELM_DRIVER", !["secret", "secrets", "configmap", "configmaps"].contains(v) { break }
                out[k] = v
            case .docker: if Self.dockerKeys.contains(k) { out[k] = v }
            case .trivy: if k.hasPrefix("TRIVY_"), !Self.isTrivyCredential(k) { out[k] = v }
            case .none, .kubectl: break
            }
        }
        return out
    }

    static func isTrivyCredential(_ key: String) -> Bool {
        let upper = key.uppercased()
        return ["PASSWORD", "TOKEN", "SECRET", "USERNAME", "CREDENTIAL", "AUTH"].contains { upper.contains($0) }
    }

    /// `additions` are the explicit values for this run (a Gangway session `KUBECONFIG`, an exec plugin's `env` entries,
    /// `KUBERNETES_EXEC_INFO`); they win over everything and are not filtered.
    public func build(profile: ToolProfile = .none, additions: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [:]
        // Base values the shell does not export reliably come from this process; the rest from the snapshot.
        let own = ProcessInfo.processInfo.environment
        for (k, v) in allowed(from: own, profile: .none) where Self.baseKeys.contains(k) || k.hasPrefix("LC_") { env[k] = v }
        if env["HOME"] == nil { env["HOME"] = home.path }
        if let snapshot { env.merge(allowed(from: snapshot.vars, profile: profile)) { _, shell in shell } }
        env["PATH"] = snapshot?.path ?? ShellEnvironment.fallbackPath(home: home)
        // kubectl writes its discovery cache to ~/.kube/cache even with --kubeconfig: keep it under the app's own folder.
        env["KUBECACHEDIR"] = paths.root.appending(path: "kubectl-cache", directoryHint: .isDirectory).path
        // Helm keeps its own folders while isolated (Debug, Profile, local Release).
        if profile == .helm {
            env.merge(paths.helmEnvironment) { _, new in new }
            if paths.isolated { env["HELM_PLUGINS"] = paths.helmRoot.appending(path: "data/plugins", directoryHint: .isDirectory).path }
        }
        env.merge(additions) { _, new in new }
        return env
    }
}
#endif
