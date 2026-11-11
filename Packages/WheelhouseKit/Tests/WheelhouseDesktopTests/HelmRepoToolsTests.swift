#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

@Suite("Helm repositories and the chart cache")
struct HelmRepoToolsTests {
    private func cli(_ path: String = "/bin/helm") -> HelmCLI {
        HelmCLI(executable: URL(fileURLWithPath: path), version: HelmVersion(3, 14), environment: EnvironmentBuilder(snapshot: nil, home: URL(fileURLWithPath: "/tmp/h")))
    }

    @Test("argv")
    func argv() {
        let helm = cli()
        #expect(helm.repoAddArguments(name: "bitnami", url: "https://x.test", username: nil, usesPassword: false) == ["repo", "add", "bitnami", "https://x.test"])
        #expect(helm.repoAddArguments(name: "p", url: "https://x.test", username: "me", usesPassword: true)
            == ["repo", "add", "p", "https://x.test", "--username", "me", "--password-stdin"])
        #expect(helm.repoUpdateArguments(names: []) == ["repo", "update"])
        #expect(helm.repoUpdateArguments(names: ["a", "b"]) == ["repo", "update", "a", "b"])
        #expect(helm.repoRemoveArguments(name: "a") == ["repo", "remove", "a"])
        #expect(helm.pullArguments(chart: "r/c", version: "1.0.0", destination: URL(fileURLWithPath: "/c/r")) == ["pull", "r/c", "--destination", "/c/r", "--version", "1.0.0"])
    }

    @Test("names and URLs that helm could misread are refused")
    func validation() {
        #expect(HelmInputCheck.isValidRepositoryName("my-repo_1.0"))
        #expect(!HelmInputCheck.isValidRepositoryName("--force") && !HelmInputCheck.isValidRepositoryName("") && !HelmInputCheck.isValidRepositoryName("a b") && !HelmInputCheck.isValidRepositoryName("a/b"))
        #expect(HelmInputCheck.isValidRepositoryURL("https://charts.example.test/stable") && HelmInputCheck.isValidRepositoryURL("oci://registry.test/charts"))
        #expect(!HelmInputCheck.isValidRepositoryURL("file:///etc") && !HelmInputCheck.isValidRepositoryURL("charts") && !HelmInputCheck.isValidRepositoryURL("--version"))
        #expect(HelmInputCheck.isValidReleaseName("web-1") && !HelmInputCheck.isValidReleaseName("Web") && !HelmInputCheck.isValidReleaseName("-web") && !HelmInputCheck.isValidReleaseName(String(repeating: "a", count: 54)))
    }

    @Test("a password goes through stdin and never into argv")
    func passwordStdin() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-helm-fake-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "helm")
        let body = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(dir.path)/args'\ncat > '\(dir.path)/stdin'\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let runner = HelmRepoRunner(cli: cli(script.path))
        let secret = "pw-" + UUID().uuidString
        try await runner.add(name: "private", url: "https://charts.example.test", username: "me", password: secret)
        let args = try String(contentsOf: dir.appending(path: "args"), encoding: .utf8)
        #expect(args.contains("--password-stdin") && !args.contains(secret))
        #expect(try String(contentsOf: dir.appending(path: "stdin"), encoding: .utf8) == secret)
        await #expect(throws: HelmCLIError.self) { try await runner.add(name: "--bad", url: "https://x.test", username: nil, password: nil) }
        try await runner.remove(name: "private")
        #expect(try String(contentsOf: dir.appending(path: "args"), encoding: .utf8) == "repo\nremove\nprivate\n")
    }

    @Test("a failing helm is reported with its own message")
    func failure() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-helm-fail-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "helm")
        try "#!/bin/sh\necho 'Error: looks like x is not a valid chart repository' >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        await #expect(throws: HelmCLIError.failed(code: 1, message: "Error: looks like x is not a valid chart repository")) {
            try await HelmRepoRunner(cli: cli(script.path)).update()
        }
    }

    @Test("the chart cache drops the least recently used archives past its cap")
    func cachePrune() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-chart-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        let repo = dir.appending(path: "r", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (index, name) in ["old", "mid", "new"].enumerated() {
            let file = repo.appending(path: "\(name)-1.tgz")
            try Data(repeating: 1, count: 100).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + index))], ofItemAtPath: file.path)
        }
        HelmChartCache.prune(dir, cap: 250)
        let left = try FileManager.default.contentsOfDirectory(atPath: repo.path).sorted()
        #expect(left == ["mid-1.tgz", "new-1.tgz"])
    }
}
#endif
