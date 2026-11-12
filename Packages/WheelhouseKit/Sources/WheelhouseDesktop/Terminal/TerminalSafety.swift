#if os(macOS)
import Darwin
import Foundation
import WheelhouseKit

/// Finds command lines that carry their own cluster address or credentials (ARCHITECTURE-MAC section 3.4, "Unguarded detection").
/// The reported line is a hint: this only ever narrows what Wheelhouse treats as guarded.
public enum UnguardedDetector {
    /// Flags that only ever mean "talk to this API server with these credentials".
    static let specificFlags = ["--kubeconfig", "--kube-apiserver", "--kube-token", "--kube-context", "--kube-as-user", "--kube-ca-file"]
    /// Flags that mean the same only for the Kubernetes tools (`--token` and `-s` are common elsewhere).
    static let toolFlags = ["--server", "--token"]
    static let tools: Set<String> = ["kubectl", "helm", "flux", "k9s", "kubecolor", "kubens", "kubectx", "stern", "argocd", "k"]

    /// Why the line bypasses the guard, or nil.
    public static func bypassReason(in line: String) -> String? {
        let tokens = CommandEligibility.tokenize(line) ?? fallbackTokens(line)
        // Leading `VAR=value` assignments and `env VAR=value` prefixes.
        var words = tokens[...]
        if words.first.map({ ($0 as NSString).lastPathComponent == "env" }) == true { words = words.dropFirst() }
        while let word = words.first, let eq = word.firstIndex(of: "="), !word.hasPrefix("-"), word[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            let name = String(word[..<eq])
            if name == "KUBECONFIG" || name == "KUBERNETES_MASTER" || name.hasPrefix("HELM_KUBE") { return "sets \(name)" }
            words = words.dropFirst()
        }
        let usesTool = tokens.contains { tools.contains(($0 as NSString).lastPathComponent) }
        for token in tokens {
            for flag in specificFlags where token == flag || token.hasPrefix(flag + "=") { return "uses \(flag)" }
            guard usesTool else { continue }
            for flag in toolFlags where token == flag || token.hasPrefix(flag + "=") { return "uses \(flag)" }
            if token == "-s" || token.hasPrefix("-s=") || (token.hasPrefix("-s") && !token.hasPrefix("--") && token.count > 2) { return "uses -s" }
        }
        return nil
    }

    /// An unbalanced quote still gets a word split, so a bypass flag is not hidden by a typo.
    private static func fallbackTokens(_ line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }
}

/// What `TerminalInserter` decided.
public enum InsertOutcome: Equatable, Sendable {
    /// Written as a bracketed paste. `removed` is the number of hidden characters taken out.
    case inserted(removed: Int)
    case refused(String)
}

/// Where inserted text goes.
@MainActor
public protocol TerminalInsertTarget: AnyObject {
    /// The cluster the terminal is guarded for (nil: none).
    var targetClusterID: ClusterID? { get }
    var targetClusterName: String { get }
    /// DECSET 2004 as the terminal emulator tracks it.
    var bracketedPasteEnabled: Bool { get }
    /// The shell is waiting at its prompt (not running a command, not inside another program).
    var isAtPrompt: Bool { get }
    func writeToShell(_ data: Data)
}

/// Inserts text into a terminal without ever running it (ARCHITECTURE-MAC section 3.4).
@MainActor
public enum TerminalInserter {
    /// Removes C0 and C1 controls (a TAB becomes a space), DEL, and Unicode format and bidi characters. Returns the text and how many
    /// characters went.
    public static func sanitize(_ text: String) -> (text: String, removed: Int) {
        var out = String.UnicodeScalarView()
        var removed = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x09 { out.append(" "); removed += 1; continue }
            if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || scalar.properties.generalCategory == .format
                || v == 0x2028 || v == 0x2029 || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200E || v == 0x200F || v == 0x061C {
                removed += 1
                continue
            }
            out.append(scalar)
        }
        return (String(out), removed)
    }

    /// Inserts `text` for a proposal or command whose target cluster is `cluster` (nil: any terminal will do).
    @discardableResult
    public static func insert(_ text: String, forCluster cluster: ClusterConfig?, into target: any TerminalInsertTarget) -> InsertOutcome {
        if let cluster, let have = target.targetClusterID, have != cluster.id {
            return .refused("This terminal is on \(target.targetClusterName); the command is for \(cluster.name). Open a terminal for \(cluster.name)?")
        }
        guard target.bracketedPasteEnabled else { return .refused("This shell does not support safe paste.") }
        guard target.isAtPrompt else { return .refused("The terminal is busy. Wait for the prompt first.") }
        let cleaned = sanitize(text)
        target.writeToShell(bracketed(cleaned.text))
        return .inserted(removed: cleaned.removed)
    }

    /// Compass `!<command>`: the text the person typed, sanitised, bracketed and followed by Return. The only code that writes a CR.
    @discardableResult
    public static func runTypedCommand(_ text: String, into target: any TerminalInsertTarget) -> InsertOutcome {
        guard target.bracketedPasteEnabled else { return .refused("This shell does not support safe paste.") }
        guard target.isAtPrompt else { return .refused("The terminal is busy. Wait for the prompt first.") }
        let cleaned = sanitize(text)
        target.writeToShell(bracketed(cleaned.text) + Data("\r".utf8))
        return .inserted(removed: cleaned.removed)
    }

    static func bracketed(_ text: String) -> Data {
        Data("\u{1B}[200~".utf8) + Data(text.utf8) + Data("\u{1B}[201~".utf8)
    }
}

/// The kubeconfig of a Direct (unguarded) shell: only the one cluster's entries, never the original file or its other contexts.
public enum DirectKubeconfig {
    public enum Availability: Equatable, Sendable {
        case available
        case unavailable(String)
    }

    /// Direct mode is for clusters that are neither Production nor read-only, and, while the safety gate is active, only for allowed test hosts.
    public static func availability(for cluster: ClusterConfig, hasKubeconfigContext: Bool, gate: DevSafetyPolicy = .current) -> Availability {
        if cluster.environment.requiresTypeToConfirm { return .unavailable("Direct mode is not available for Production clusters.") }
        if cluster.readOnly { return .unavailable("Direct mode is not available for read-only clusters.") }
        if !hasKubeconfigContext { return .unavailable("Direct mode needs a cluster from a kubeconfig file.") }
        if gate.isActive, !gate.isAllowed(server: cluster.server) { return .unavailable("Direct mode is unavailable in development builds for this cluster.") }
        return .available
    }

    /// The YAML-compatible JSON of a kubeconfig with just this context. Inline data is copied, file paths are already absolute, and an
    /// exec stanza is kept. `current-context` is set to it.
    public static func contents(for context: KubeconfigContext) throws -> Data {
        guard let server = context.server else { throw SessionKubeconfigError.writeFailed("the context has no server") }
        let files = context.files
        var cluster: [String: Any] = ["server": server.absoluteString]
        if let ca = context.caPEM { cluster["certificate-authority-data"] = Data(ca.utf8).base64EncodedString() }
        else if let path = files?.certificateAuthority { cluster["certificate-authority"] = path }
        if context.insecureSkipTLSVerify { cluster["insecure-skip-tls-verify"] = true }
        if let name = context.tlsServerName { cluster["tls-server-name"] = name }
        var user: [String: Any] = [:]
        switch context.auth {
        case .token(let token): user["token"] = token
        case .clientCertificate(let cert, let key):
            user["client-certificate-data"] = Data(cert.utf8).base64EncodedString()
            user["client-key-data"] = Data(key.utf8).base64EncodedString()
        case .exec(let command, let args):
            var exec: [String: Any] = ["command": command, "args": args, "apiVersion": context.exec?.apiVersion ?? "client.authentication.k8s.io/v1beta1"]
            if let spec = context.exec {
                exec["env"] = spec.env.map { ["name": $0.name, "value": $0.value] }
                if let mode = spec.interactiveMode { exec["interactiveMode"] = mode }
                exec["provideClusterInfo"] = spec.provideClusterInfo
            }
            user["exec"] = exec
        default: break
        }
        if let f = files {
            if let path = f.tokenFile { user["tokenFile"] = path }
            if let path = f.clientCertificate { user["client-certificate"] = path }
            if let path = f.clientKey { user["client-key"] = path }
            if let pem = f.inlineClientCertificatePEM { user["client-certificate-data"] = Data(pem.utf8).base64EncodedString() }
            if let pem = f.inlineClientKeyPEM { user["client-key-data"] = Data(pem.utf8).base64EncodedString() }
        }
        var ctx: [String: Any] = ["cluster": context.clusterName, "user": context.userName]
        if let namespace = context.namespace { ctx["namespace"] = namespace }
        let config: [String: Any] = [
            "apiVersion": "v1", "kind": "Config",
            "clusters": [["name": context.clusterName, "cluster": cluster]],
            "users": [["name": context.userName, "user": user]],
            "contexts": [["name": context.name, "context": ctx]],
            "current-context": context.name,
        ]
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Writes `<root>/direct/<uuid>/direct-kubeconfig` (0400, folder 0700). Direct folders are not Gangway sessions, so the Gangway
    /// sweep leaves them alone; ``removeAll(root:)`` clears them at launch and quit, and ``sweep(root:olderThan:)`` by age. A write that
    /// fails leaves nothing behind. `failAfterOpen` is a test seam.
    public static func write(_ context: KubeconfigContext, root: URL, id: UUID = UUID(), failAfterOpen: Bool = false) throws -> (file: URL, directory: URL) {
        let data = try contents(for: context)
        let parent = root.appending(path: "direct", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = parent.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
        guard mkdir(directory.path, 0o700) == 0 else { throw SessionKubeconfigError.writeFailed("mkdir: \(String(cString: strerror(errno)))") }
        let file = directory.appending(path: "direct-kubeconfig")
        do {
            let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o400)
            guard fd >= 0 else { throw SessionKubeconfigError.writeFailed("open: \(String(cString: strerror(errno)))") }
            defer { close(fd) }
            if failAfterOpen { throw SessionKubeconfigError.writeFailed("write failed") }
            let ok = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            guard ok else { throw SessionKubeconfigError.writeFailed("write failed") }
        } catch {
            remove(directory: directory)
            throw error
        }
        return (file, directory)
    }

    /// No Direct shell survives a restart, so at launch and at quit every Direct folder goes.
    public static func removeAll(root: URL) {
        let parent = root.appending(path: "direct", directoryHint: .isDirectory)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] {
            remove(directory: parent.appending(path: name, directoryHint: .isDirectory))
        }
    }

    public static func remove(directory: URL) { SessionKubeconfigWriter.remove(directory: directory) }

    /// Removes Direct folders older than `age` (a crashed run's leftovers).
    public static func sweep(root: URL, olderThan age: TimeInterval = 24 * 3600, now: Date = Date()) {
        let parent = root.appending(path: "direct", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names {
            let url = parent.appending(path: name, directoryHint: .isDirectory)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, now.timeIntervalSince(modified) > age else { continue }
            remove(directory: url)
        }
    }
}
#endif
