#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// A temporary directory, resolved through symlinks (so path comparisons are exact), removed by `cleanup()`.
final class Scratch: @unchecked Sendable {
    let root: URL
    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "wh-m3-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url.resolvingSymlinksInPath()
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func dir(_ name: String) throws -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @discardableResult
    func write(_ name: String, _ text: String, mode: Int = 0o600) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, mode_t(mode))
        return url.resolvingSymlinksInPath()
    }

    /// A fake home with `.kube/`.
    func home() throws -> URL {
        let h = try dir("home")
        try FileManager.default.createDirectory(at: h.appending(path: ".kube"), withIntermediateDirectories: true)
        return h
    }

    /// The plugin fixture, copied somewhere writable and made executable.
    func installPlugin(named name: String = "plugin.sh") throws -> URL {
        let src = try #require(Bundle.module.url(forResource: "Fixtures/plugins/plugin", withExtension: "sh"))
        let url = root.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: src, to: url)
        chmod(url.path, 0o755)
        return url.resolvingSymlinksInPath()
    }
}

/// A kubeconfig file with one context.
func kubeconfigText(context: String = "ctx", server: String = "https://prod-eu.example.test:6443", user: String = "    token: tok",
                    clusterName: String? = nil) -> String {
    let cluster = clusterName ?? "\(context)-cluster"
    return """
    apiVersion: v1
    kind: Config
    current-context: \(context)
    clusters:
    - name: \(cluster)
      cluster:
        server: \(server)
    users:
    - name: \(context)-user
      user:
    \(user)
    contexts:
    - name: \(context)
      context:
        cluster: \(cluster)
        user: \(context)-user
    """
}

/// An inactive gate that allows everything but still knows the home directory, and an active one with allowed hosts.
func openGate(home: URL) -> DevSafetyPolicy { DevSafetyPolicy(isActive: false, home: home) }
func activeGate(home: URL, hosts: Set<String> = []) -> DevSafetyPolicy { DevSafetyPolicy(isActive: true, allowedHosts: hosts, home: home) }

func rfc3339(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

/// Waits (without polling the system under test more than every 20 ms) until `condition` holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
#endif
