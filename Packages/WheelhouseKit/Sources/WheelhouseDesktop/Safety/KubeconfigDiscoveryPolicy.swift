#if os(macOS)
import Foundation
import WheelhouseKit

/// Decides which kubeconfig files may be read at all (ARCHITECTURE-MAC §13.2). While the gate is active the ONLY source is the
/// explicit test file; home discovery (`~/.kube`, the shell's `KUBECONFIG`) happens only when the gate is off.
public struct KubeconfigDiscoveryPolicy: Sendable {
    public var gate: DevSafetyPolicy

    public init(gate: DevSafetyPolicy = .current) { self.gate = gate }

    /// The explicit test kubeconfig: `-WHKubeconfigPath <path>`, else `WH_KUBECONFIG_PATH`, else Info.plist
    /// `WHDefaultTestKubeconfig` (empty in Distribution). Nil when none is configured.
    public static func explicitTestKubeconfig(arguments: [String] = ProcessInfo.processInfo.arguments,
                                              environment: [String: String] = ProcessInfo.processInfo.environment,
                                              info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> URL? {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        if let i = arguments.firstIndex(of: "-WHKubeconfigPath"), arguments.indices.contains(i + 1), let p = clean(arguments[i + 1]) {
            return URL(fileURLWithPath: p)
        }
        if let p = clean(environment["WH_KUBECONFIG_PATH"]) { return URL(fileURLWithPath: p) }
        if let p = clean(info["WHDefaultTestKubeconfig"] as? String) { return URL(fileURLWithPath: p) }
        return nil
    }

    /// The kubeconfig files to read by default.
    ///
    /// - Gate active: only `explicitTest` (and never a file under `~/.kube`, even through a symlink: that throws).
    ///   The shell snapshot's `KUBECONFIG` is ignored entirely.
    /// - Gate off: `$KUBECONFIG` from the shell snapshot if set, else `~/.kube/config`.
    public func defaultSources(explicitTest: URL?, shellKubeconfig: String?) throws -> [URL] {
        if gate.isActive {
            guard let explicitTest else { return [] }
            try gate.assertReadable(explicitTest)
            return [explicitTest]
        }
        if let list = shellKubeconfig?.trimmingCharacters(in: .whitespaces), !list.isEmpty {
            return list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return [gate.home.appending(path: ".kube/config")]
    }

    /// The shell snapshot's `KUBECONFIG` as the rest of the app may see it: removed while the gate is active.
    public func sanitizedShellKubeconfig(_ value: String?) -> String? { gate.isActive ? nil : value }

    /// Reads the server hosts of the test kubeconfig and publishes them as the gate's allowed hosts. Throws when the file is
    /// under `~/.kube` or unreadable.
    public static func configureAllowedHosts(testKubeconfig url: URL, gate: DevSafetyPolicy = .current) throws -> Set<String> {
        try gate.assertReadable(url)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw DevSafetyError.invalidTestKubeconfig("it could not be read") }
        let parsed = try KubeconfigParser.parse(text)
        let servers = parsed.contexts.compactMap(\.server)
        return Set(servers.compactMap { $0.host()?.lowercased() })
    }
}
#endif
