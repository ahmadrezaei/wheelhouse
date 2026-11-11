#if os(macOS)
import Foundation
import WheelhouseKit

/// `helm repo` and `helm pull` (ARCHITECTURE-MAC sections 5.2 and 5.3). No cluster and no Gangway: these touch helm's own configuration
/// and cache (the isolated `HELM_*` homes while the safety gate is active). A password travels only through `--password-stdin`.
public extension HelmCLI {
    func repoAddArguments(name: String, url: String, username: String?, usesPassword: Bool) -> [String] {
        var args = ["repo", "add", name, url, "--force-update"]
        if let username, !username.isEmpty {
            args += ["--username", username]
            if usesPassword { args.append("--password-stdin") }
        }
        return args
    }

    func repoUpdateArguments(names: [String]) -> [String] { ["repo", "update"] + names }
    func repoRemoveArguments(name: String) -> [String] { ["repo", "remove", name] }

    func pullArguments(chart: String, version: String?, destination: URL) -> [String] {
        var args = ["pull", chart, "--destination", destination.path]
        if let version, !version.isEmpty { args += ["--version", version] }
        return args
    }
}

/// A repository name or a chart reference that helm could read as an option, a path or something else than it was meant to be.
public enum HelmInputCheck {
    /// Repository names: letters, digits, `.`, `_`, `-`, as helm itself accepts.
    public static func isValidRepositoryName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 63 && !name.hasPrefix("-") && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
    /// A repository URL: https, http or oci, with a host.
    public static func isValidRepositoryURL(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["https", "http", "oci"].contains(scheme), let host = url.host(), !host.isEmpty else { return false }
        return true
    }
    /// A release name as helm allows it (a DNS label, at most 53 characters).
    public static func isValidReleaseName(_ name: String) -> Bool {
        guard (1...53).contains(name.count), name.first != "-", name.last != "-" else { return false }
        return name.allSatisfy { $0.isASCII && (($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-" || $0 == ".") }
    }
}

public struct HelmRepoRunner: Sendable {
    public let cli: HelmCLI
    public init(cli: HelmCLI) { self.cli = cli }

    private func run(_ args: [String], stdin: Data? = nil, timeout: Duration = .seconds(120)) async throws {
        var spec = cli.spec(arguments: args, kubeconfig: nil, timeout: timeout)
        spec.stdin = stdin
        let result = try await Subprocess.run(spec)
        guard result.exit.succeeded else { throw HelmCLIError.failed(code: result.exitCode, message: HelmRunner.message(result)) }
    }

    public func add(name: String, url: String, username: String?, password: String?) async throws {
        guard HelmInputCheck.isValidRepositoryName(name), HelmInputCheck.isValidRepositoryURL(url) else { throw HelmCLIError.unsupported("That repository name or URL is not valid.") }
        let usesPassword = !(password ?? "").isEmpty
        try await run(cli.repoAddArguments(name: name, url: url, username: username, usesPassword: usesPassword), stdin: usesPassword ? Data(password!.utf8) : nil)
    }

    public func update(names: [String] = []) async throws { try await run(cli.repoUpdateArguments(names: names), timeout: .seconds(300)) }
    public func remove(name: String) async throws { try await run(cli.repoRemoveArguments(name: name)) }

    /// Pulls a chart archive into `cache/<repo>/` and returns its path; the cache is then trimmed to `cap` bytes, oldest first.
    public func pull(chart: String, version: String, repository: String, cache: URL, cap: Int = HelmChartCache.defaultCap) async throws -> URL {
        let directory = cache.appending(path: repository, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await run(cli.pullArguments(chart: chart, version: version, destination: directory), timeout: .seconds(300))
        let name = chart.split(separator: "/").last.map(String.init) ?? chart
        let file = directory.appending(path: "\(name)-\(version).tgz")
        guard FileManager.default.fileExists(atPath: file.path) else { throw HelmCLIError.unreadableOutput }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        HelmChartCache.prune(cache, cap: cap)
        return file
    }
}

/// The chart cache (`…/charts/<repo>/<chart>-<version>.tgz`), least recently used first out, 1 GB by default.
public enum HelmChartCache {
    public static let defaultCap = 1 << 30

    public static func prune(_ directory: URL, cap: Int) {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        for case let url as URL in walker where url.pathExtension == "tgz" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > cap {
            try? manager.removeItem(at: file.url)
            total -= file.size
        }
    }
}
#endif
