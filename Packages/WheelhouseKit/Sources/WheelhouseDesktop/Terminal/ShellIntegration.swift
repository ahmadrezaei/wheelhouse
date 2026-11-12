#if os(macOS)
import Darwin
import Foundation

public enum ShellKind: Equatable, Sendable {
    case zsh, bash, fish
    /// No integration: the per-request fallback applies (DESIGN-MAC section 6.2).
    case other

    public init(path: String) {
        switch (path as NSString).lastPathComponent {
        case "zsh": self = .zsh
        case "bash": self = .bash
        case "fish": self = .fish
        default: self = .other
        }
    }
}

/// How to start the shell of one session.
public struct ShellLaunch: Sendable {
    public var executable: URL
    public var arguments: [String]
    /// The variables the integration adds on top of the base environment.
    public var environment: [String: String]
    public var kind: ShellKind
    /// True when hooks are installed and a nonce was written.
    public var integrated: Bool
}

public enum ShellIntegrationError: Error, LocalizedError {
    case resourceMissing(String)
    case writeFailed(String)
    public var errorDescription: String? {
        switch self {
        case .resourceMissing(let name): "The shell integration file \(name) is missing from the app."
        case .writeFailed(let why): "The shell integration could not be written: \(why)"
        }
    }
}

/// Prepares a shell's startup without touching any of the user's files (ARCHITECTURE-MAC section 3.4): hooks live in the session
/// folder and are reached through the shell's own override (`ZDOTDIR` for zsh, `--rcfile` for bash, `--init-command` for fish). The
/// user's originals are sourced from a directory the app names explicitly, never guessed from `$HOME`.
public enum ShellIntegration {
    /// What the user's startup files are read from. In development builds and tests this is an empty folder.
    public struct UserFiles: Sendable {
        /// zsh: the directory that holds `.zshenv`, `.zshrc` and friends (`ZDOTDIR` or `HOME`).
        public var zshDirectory: URL
        /// bash: the home directory whose `.bash_profile`, `.bash_login` or `.profile` is sourced.
        public var bashHome: URL
        public init(zshDirectory: URL, bashHome: URL) {
            self.zshDirectory = zshDirectory
            self.bashHome = bashHome
        }
    }

    /// Writes the nonce (0400, created exclusively) and the hook files into `directory` (the Gangway session folder, 0700).
    public static func prepare(shell: URL, directory: URL, nonce: String, kubeconfig: URL, user: UserFiles, resources: URL? = nil) throws -> ShellLaunch {
        let kind = ShellKind(path: shell.path)
        var environment = ["WH_SESSION_DIR": directory.path, "WH_KUBECONFIG": kubeconfig.path]
        guard kind != .other else {
            return ShellLaunch(executable: shell, arguments: ["-l"], environment: ["WH_KUBECONFIG": kubeconfig.path], kind: .other, integrated: false)
        }
        let source = try resources ?? resourceFolder()
        switch kind {
        case .zsh:
            let zdotdir = directory.appending(path: "zdotdir", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, target) in [("zshenv", ".zshenv"), ("zprofile", ".zprofile"), ("zshrc", ".zshrc"), ("zlogin", ".zlogin")] {
                try copy(source.appending(path: name), to: zdotdir.appending(path: target))
            }
            environment["ZDOTDIR"] = zdotdir.path
            environment["WH_ORIG_ZDOTDIR"] = user.zshDirectory.path
        case .bash:
            try copy(source.appending(path: "bashrc"), to: directory.appending(path: "bashrc"))
            environment["WH_ORIG_HOME"] = user.bashHome.path
        case .fish:
            try copy(source.appending(path: "wh.fish"), to: directory.appending(path: "wh.fish"))
        case .other: break
        }
        try writeNonce(nonce, in: directory)
        let arguments: [String]
        switch kind {
        // `--rcfile` is ignored by a login bash, so this is an interactive non-login shell that emulates the login in the rc file.
        case .bash: arguments = ["--rcfile", directory.appending(path: "bashrc").path, "-i"]
        case .fish: arguments = ["--init-command", "source \(quoted(directory.appending(path: "wh.fish").path))", "-l"]
        default: arguments = ["-l"]
        }
        return ShellLaunch(executable: shell, arguments: arguments, environment: environment, kind: kind, integrated: true)
    }

    static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func resourceFolder() throws -> URL {
        guard let url = Bundle.module.url(forResource: "zshrc", withExtension: nil, subdirectory: "Resources/shell") else {
            throw ShellIntegrationError.resourceMissing("shell")
        }
        return url.deletingLastPathComponent()
    }

    private static func copy(_ from: URL, to: URL) throws {
        guard let data = try? Data(contentsOf: from) else { throw ShellIntegrationError.resourceMissing(from.lastPathComponent) }
        try create(file: to, data: data, mode: 0o600)
    }

    /// 128 random bits in `nonce` (0400). `O_EXCL | O_NOFOLLOW`: an existing file or a planted symlink fails instead of being followed.
    static func writeNonce(_ nonce: String, in directory: URL) throws {
        try create(file: directory.appending(path: "nonce"), data: Data(nonce.utf8), mode: 0o400)
    }

    private static func create(file: URL, data: Data, mode: mode_t) throws {
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw ShellIntegrationError.writeFailed("\(file.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard ok else { throw ShellIntegrationError.writeFailed("\(file.lastPathComponent): short write") }
    }
}

/// The environment of a terminal shell (ARCHITECTURE-MAC section 3.2 and 3.4): the user's shell environment, minus what could route
/// a tool around Gangway or leak the app's internals, plus the Wheelhouse variables.
public enum TerminalEnvironment {
    /// Names that are never passed. `HELM_KUBE*` and `KUBERNETES_MASTER` would let helm and client-go reach an API server directly.
    static func isStripped(_ key: String) -> Bool {
        key == "KUBECONFIG" || key == "KUBERNETES_MASTER" || key.hasPrefix("HELM_KUBE") || key.hasPrefix("WHEELHOUSE_") || key.hasPrefix("DYLD_")
            || key.hasPrefix("XPC_") || key == "__CFBundleIdentifier" || key.hasPrefix("MallocStackLogging") || key == "WH_ORIG_ZDOTDIR"
            || key == "WH_ORIG_HOME" || key == "WH_SESSION_DIR" || key == "WH_KUBECONFIG" || key == "KUBECACHEDIR"
    }

    public struct Session: Sendable {
        public var clusterID: String
        public var clusterName: String
        public var environmentName: String
        public var sessionID: String
        public init(clusterID: String, clusterName: String, environmentName: String, sessionID: String) {
            self.clusterID = clusterID
            self.clusterName = clusterName
            self.environmentName = environmentName
            self.sessionID = sessionID
        }
    }

    /// `base` is the shell snapshot's variables (or, without one, the few base variables of the app). Returns the complete environment.
    public static func build(base: [String: String], kubeconfig: URL, kubeCacheDir: URL, session: Session, helm: [String: String] = [:],
                             home: URL? = nil, version: String = "1") -> (environment: [String: String], userZdotdir: String?) {
        var env = base.filter { !isStripped($0.key) }
        let userZdotdir = env.removeValue(forKey: "ZDOTDIR")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Wheelhouse"
        env["TERM_PROGRAM_VERSION"] = version
        env["KUBECONFIG"] = kubeconfig.path
        env["KUBECACHEDIR"] = kubeCacheDir.path
        env["WHEELHOUSE_CLUSTER"] = session.clusterName
        env["WHEELHOUSE_ENV"] = session.environmentName
        env["WHEELHOUSE_SESSION"] = session.sessionID
        if let home { env["HOME"] = home.path }
        env.merge(helm) { _, new in new }
        return (env, userZdotdir)
    }
}
#endif
