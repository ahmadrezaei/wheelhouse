#if os(macOS)
import Darwin
import Foundation
import WheelhouseKit

/// What the login-shell probe found (ARCHITECTURE-MAC §3.1).
public struct ShellSnapshot: Sendable, Equatable {
    public var path: String
    /// `KUBECONFIG` from the shell. Always nil while the safety gate is active (removed before anything can read it).
    public var kubeconfig: String?
    /// The shell's environment. `KUBECONFIG` is removed while the gate is active.
    public var vars: [String: String]
    public var shell: String
    public var probedAt: Date
    /// Why the probe failed (the fallback PATH is used then); shown as a banner in Settings → Moorings.
    public var failure: String?

    public init(path: String, kubeconfig: String?, vars: [String: String], shell: String, probedAt: Date = Date(), failure: String? = nil) {
        self.path = path
        self.kubeconfig = kubeconfig
        self.vars = vars
        self.shell = shell
        self.probedAt = probedAt
        self.failure = failure
    }
}

/// Runs the user's login shell once per launch (and on Reload Shell Environment) to learn `PATH`, `KUBECONFIG` and the cloud CLI
/// variables. Many people export those in `.zshrc`, which only an interactive shell reads, so the probe is `-l -i -c`.
public actor ShellEnvironment {
    public static let beginMarker = Data("\0WH_ENV_BEGIN\0".utf8)
    public static let endMarker = Data("\0WH_ENV_END\0".utf8)

    private let gate: DevSafetyPolicy
    private let home: URL
    private let timeout: Duration
    private let shellOverride: String?
    private let etcShells: String
    public private(set) var snapshot: ShellSnapshot?

    /// `shell` is for tests (a fake shell script); nil resolves the user's shell.
    public init(gate: DevSafetyPolicy = .current, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                timeout: Duration = .seconds(5), shell: String? = nil, etcShells: String = "/etc/shells") {
        self.gate = gate
        self.home = home
        self.timeout = timeout
        self.shellOverride = shell
        self.etcShells = etcShells
    }

    /// The fallback PATH used when the probe times out or fails.
    public static func fallbackPath(home: URL) -> String {
        let h = home.path
        return ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(h)/.local/bin", "\(h)/bin", "\(h)/.krew/bin", "\(h)/go/bin",
                "\(h)/.rd/bin", "\(h)/.orbstack/bin", "/opt/homebrew/share/google-cloud-sdk/bin", "\(h)/google-cloud-sdk/bin",
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    }

    /// The shell: the passwd entry, else `$SHELL`, else `/bin/zsh`. It must be listed in `/etc/shells` or be an absolute executable.
    func resolveShell() -> String {
        func usable(_ s: String?) -> String? {
            guard let s, s.hasPrefix("/") else { return nil }
            if access(s, X_OK) == 0 { return s }
            return nil
        }
        if let o = shellOverride { return usable(o) ?? "/bin/zsh" }
        var pwShell: String?
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { pwShell = String(cString: sh) }
        let listed = (try? String(contentsOfFile: etcShells, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        for candidate in [pwShell, ProcessInfo.processInfo.environment["SHELL"]] {
            if let c = usable(candidate), listed.contains(c) || candidate == c { return c }
        }
        return "/bin/zsh"
    }

    /// Runs the probe and stores the snapshot. Never throws: a failure yields the fallback snapshot with `failure` set.
    @discardableResult
    public func reload() async -> ShellSnapshot {
        let shell = resolveShell()
        let script = "printf '\\0WH_ENV_BEGIN\\0'; /usr/bin/env -0; printf '\\0WH_ENV_END\\0'"
        // The probe's own environment is minimal: the shell rebuilds the rest from its startup files.
        let env = ["HOME": home.path, "USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": shell, "TERM": "dumb",
                   "WHEELHOUSE_ENV_PROBE": "1", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        let spec = ProcessSpec(executable: URL(fileURLWithPath: shell), arguments: ["-l", "-i", "-c", script], environment: env,
                               currentDirectory: home, timeout: timeout, stdoutLimit: 4 << 20, stderrLimit: 16 << 10, qos: .userInitiated)
        let result: ShellSnapshot
        do {
            let r = try await Subprocess.run(spec)
            if let vars = Self.parse(r.stdout) {
                result = makeSnapshot(shell: shell, vars: vars)
            } else {
                result = fallback(shell: shell, why: "the shell printed no environment (exit \(r.exit.code.map(String.init) ?? "signal"))")
            }
        } catch SubprocessError.timedOut {
            result = fallback(shell: shell, why: "\(shell) did not finish within \(timeout.components.seconds) s")
        } catch {
            result = fallback(shell: shell, why: error.localizedDescription)
        }
        snapshot = result
        return result
    }

    /// The current snapshot, probing first when there is none.
    public func current() async -> ShellSnapshot {
        if let snapshot { return snapshot }
        return await reload()
    }

    private func makeSnapshot(shell: String, vars: [String: String]) -> ShellSnapshot {
        var vars = vars
        // The gate: the shell's KUBECONFIG is removed before anything else can see it.
        if gate.isActive { vars["KUBECONFIG"] = nil }
        let path = vars["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackPath(home: home)
        return ShellSnapshot(path: path, kubeconfig: vars["KUBECONFIG"].flatMap { $0.isEmpty ? nil : $0 }, vars: vars, shell: shell)
    }

    private func fallback(shell: String, why: String) -> ShellSnapshot {
        ShellSnapshot(path: Self.fallbackPath(home: home), kubeconfig: nil, vars: [:], shell: shell, failure: "Shell environment could not be read: \(why)")
    }

    /// The `KEY=VALUE` entries between the markers (rc files may print banners before and after). Nil without both markers.
    public static func parse(_ output: Data) -> [String: String]? {
        guard let begin = output.range(of: beginMarker) else { return nil }
        guard let end = output.range(of: endMarker, options: [], in: begin.upperBound..<output.endIndex) else { return nil }
        let body = output[begin.upperBound..<end.lowerBound]
        var vars: [String: String] = [:]
        for entry in body.split(separator: 0) {
            guard let eq = entry.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = String(decoding: entry[entry.startIndex..<eq], as: UTF8.self)
            guard !key.isEmpty else { continue }
            vars[key] = String(decoding: entry[entry.index(after: eq)...], as: UTF8.self)
        }
        return vars
    }
}
#endif
