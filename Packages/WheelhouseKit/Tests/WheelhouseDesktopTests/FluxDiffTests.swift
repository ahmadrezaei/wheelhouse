#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// M9 add-on: `flux diff kustomization` under a dry-run-only Gangway session. A fake flux (a shell script) stands in for the binary.
@Suite("Flux diff", .serialized)
struct FluxDiffTests {
    /// A rig with a mapped folder and a fake flux whose body is `script`.
    struct Fixture {
        let rig: GangwayRig
        let folder: URL
        let flux: URL
        let environment: EnvironmentBuilder

        init(script: String, snapshot: ShellSnapshot? = nil) async throws {
            rig = try await GangwayRig()
            let dir = rig.scratch.root.appending(path: "fake-flux", directoryHint: .isDirectory)
            folder = rig.scratch.root.appending(path: "repo/apps", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            flux = dir.appending(path: "flux")
            try ("#!/bin/sh\n" + script).write(to: flux, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flux.path)
            environment = EnvironmentBuilder(snapshot: snapshot, paths: rig.service.paths, home: rig.scratch.root)
        }

        func runner(timeout: Duration = .seconds(30)) -> FluxDiffRunner {
            FluxDiffRunner(cli: FluxCLI(executable: flux, environment: environment), gangway: rig.service, timeout: timeout)
        }

        func diff(timeout: Duration = .seconds(30)) async throws -> FluxDiffOutput {
            try await runner(timeout: timeout).diff(kustomization: "apps", namespace: "flux-system", folder: folder, cluster: rig.clusterID)
        }
    }

    // MARK: argv

    @Test("the argv is exactly flux diff kustomization <name> --path <folder> --namespace <ns>")
    func argvGolden() throws {
        let cli = FluxCLI(executable: URL(fileURLWithPath: "/usr/local/bin/flux"), environment: EnvironmentBuilder(snapshot: nil, paths: .current))
        let args = try cli.diffArguments(name: "apps", namespace: "flux-system", folder: URL(fileURLWithPath: "/Users/me/repo/clusters/prod", isDirectory: true))
        #expect(args == ["diff", "kustomization", "apps", "--path", "/Users/me/repo/clusters/prod", "--namespace", "flux-system", "--progress-bar=false"])
    }

    @Test("a name or namespace that reads as an option, or is empty, is refused")
    func refusesOptionNames() {
        let cli = FluxCLI(executable: URL(fileURLWithPath: "/usr/local/bin/flux"), environment: EnvironmentBuilder(snapshot: nil, paths: .current))
        let folder = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        #expect(throws: FluxDiffError.invalidName("--all")) { try cli.diffArguments(name: "--all", namespace: "flux-system", folder: folder) }
        #expect(throws: FluxDiffError.invalidName("-n")) { try cli.diffArguments(name: "apps", namespace: "-n", folder: folder) }
        #expect(throws: FluxDiffError.invalidName("")) { try cli.diffArguments(name: "", namespace: "flux-system", folder: folder) }
    }

    // MARK: Locating

    @Test("flux is found by the locator, and its absence is reported")
    func locating() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flux-locate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = EnvironmentBuilder(snapshot: nil, paths: .current)
        #expect(FluxCLI.locate(ExecutableLocator(searchPath: [root.path]), environment: environment) == nil)
        let flux = root.appending(path: "flux")
        try "#!/bin/sh\n".write(to: flux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flux.path)
        #expect(FluxCLI.locate(ExecutableLocator(searchPath: [root.path]), environment: environment)?.executable.lastPathComponent == "flux")
    }

    // MARK: Outcomes

    @Test("exit 0 is no difference, exit 1 with output is a diff, and the argv and environment are exact")
    func outcomes() async throws {
        let snapshot = ShellSnapshot(path: "/usr/bin:/bin", kubeconfig: "/Users/real/.kube/config", vars: ["KUBECONFIG": "/Users/real/.kube/config", "AWS_PROFILE": "prod"], shell: "/bin/zsh")
        let same = try await Fixture(script: "echo \"$@\" > \"$0.argv\"\necho \"$KUBECONFIG\" > \"$0.kubeconfig\"\nenv > \"$0.env\"\nexit 0\n", snapshot: snapshot)
        defer { same.rig.stop() }
        let none = try await same.diff()
        #expect(!none.hasChanges)
        let argv = try String(contentsOf: URL(fileURLWithPath: same.flux.path + ".argv"), encoding: .utf8)
        #expect(argv.trimmingCharacters(in: .whitespacesAndNewlines) == "diff kustomization apps --path \(same.folder.path) --namespace flux-system --progress-bar=false")
        let kubeconfig = try String(contentsOf: URL(fileURLWithPath: same.flux.path + ".kubeconfig"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(kubeconfig.hasPrefix(same.rig.scratch.root.path), "the session file: \(kubeconfig)")
        #expect(!kubeconfig.contains("/.kube/config"))
        let env = try String(contentsOf: URL(fileURLWithPath: same.flux.path + ".env"), encoding: .utf8)
        #expect(!env.contains("/Users/real"), "the shell's KUBECONFIG never reaches flux")
        #expect(!env.contains("AWS_PROFILE"))
        #expect(same.rig.service.registry.sessions.isEmpty)

        let changed = try await Fixture(script: "echo '--- a'\necho '+++ b'\nexit 1\n")
        defer { changed.rig.stop() }
        let output = try await changed.diff()
        #expect(output.hasChanges)
        #expect(output.text.contains("+++ b"))
    }

    @Test("exit 0 is no change even when flux printed progress lines on stdout")
    func progressNoise() async throws {
        let f = try await Fixture(script: "echo '* building'\nexit 0\n")
        defer { f.rig.stop() }
        #expect(try await !f.diff().hasChanges)
    }

    @Test("more output than the cap is reported as such")
    func tooLarge() async throws {
        let f = try await Fixture(script: "yes 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' | head -c 9500000\nexit 1\n")
        defer { f.rig.stop() }
        await #expect(throws: FluxDiffError.outputTooLarge) { try await f.diff() }
        #expect(f.rig.service.registry.sessions.isEmpty)
    }

    @Test("a failure surfaces stderr; exit 1 without a diff and exit 2 are both failures")
    func failures() async throws {
        let one = try await Fixture(script: "echo 'kustomization not found' >&2\nexit 1\n")
        defer { one.rig.stop() }
        await #expect(throws: FluxDiffError.failed(code: 1, message: "kustomization not found")) { try await one.diff() }
        let two = try await Fixture(script: "echo '--- a'\nexit 2\n")
        defer { two.rig.stop() }
        await #expect(throws: FluxDiffError.failed(code: 2, message: "exit code 2")) { try await two.diff() }
        #expect(two.rig.service.registry.sessions.isEmpty)
    }

    @Test("a mapped folder that is gone is reported before any session opens")
    func folderGone() async throws {
        let f = try await Fixture(script: "exit 0\n")
        defer { f.rig.stop() }
        let gone = f.folder.appending(path: "missing", directoryHint: .isDirectory)
        await #expect(throws: FluxDiffError.folderMissing(gone.path)) {
            try await f.runner().diff(kustomization: "apps", namespace: "flux-system", folder: gone, cluster: f.rig.clusterID)
        }
        #expect(f.rig.upstream.received.isEmpty)
    }

    @Test("a program that cannot be started is a failure, not a crash")
    func launchFailure() async throws {
        let f = try await Fixture(script: "exit 0\n")
        defer { f.rig.stop() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.flux.path)
        await #expect(throws: FluxDiffError.self) { try await f.diff() }
        #expect(f.rig.service.registry.sessions.isEmpty)
    }

    // MARK: The dry-run-only session

    @Test("a change sent by the flux process is refused and never reaches the cluster; reads and dry runs pass")
    func mutationRefused() async throws {
        let script = """
        cfg=$(tr -d ' \\n' < "$KUBECONFIG")
        token=$(echo "$cfg" | sed -n 's/.*"token":"\\([^"]*\\)".*/\\1/p')
        server=$(echo "$cfg" | sed -n 's/.*"server":"\\([^"]*\\)".*/\\1/p')
        call() { curl -sk -o /dev/null -w '%{http_code}' -X "$1" -H "Authorization: Bearer $token" -H 'Content-Type: application/merge-patch+json' ${3:+-d "$3"} "$server$2"; }
        echo "read=$(call GET /api/v1/pods)"
        echo "dryrun=$(call PATCH '/api/v1/namespaces/a/configmaps/b?dryRun=All' '{}')"
        echo "patch=$(call PATCH /api/v1/namespaces/a/configmaps/b '{}')"
        echo "delete=$(call DELETE /api/v1/namespaces/a/configmaps/b)"
        echo "proxy=$(call GET /api/v1/namespaces/a/pods/p/proxy/x)"
        exit 1

        """
        let f = try await Fixture(script: script)
        defer { f.rig.stop() }
        let output = try await f.diff()
        #expect(output.text.contains("read=200"), "\(output.text)")
        #expect(output.text.contains("dryrun=200"))
        #expect(output.text.contains("patch=403"))
        #expect(output.text.contains("delete=403"))
        #expect(output.text.contains("proxy=403"))
        let methods = f.rig.upstream.received.map { "\($0.method) \($0.path)" }
        #expect(methods.contains { $0.hasPrefix("GET /api/v1/pods") })
        #expect(!methods.contains { $0.hasPrefix("DELETE") })
        #expect(!methods.contains { $0.contains("configmaps/b") && !$0.contains("dryRun=All") }, "no real change reached the cluster: \(methods)")
        #expect(f.rig.service.registry.sessions.isEmpty)
    }

    // MARK: Timeout and cancel

    @Test("a flux that runs past the timeout is stopped and reported, and the session closes")
    func timeout() async throws {
        let f = try await Fixture(script: "sleep 30\n")
        defer { f.rig.stop() }
        let started = ContinuousClock.now
        await #expect(throws: FluxDiffError.timedOut(1)) { try await f.diff(timeout: .seconds(1)) }
        #expect(ContinuousClock.now - started < .seconds(15))
        #expect(f.rig.service.registry.sessions.isEmpty)
    }

    @Test("cancelling the run stops flux and closes the session")
    func cancel() async throws {
        let f = try await Fixture(script: "echo $$ > \"$0.pid\"\nsleep 30\n")
        defer { f.rig.stop() }
        let task = Task { try await f.diff() }
        let pidFile = URL(fileURLWithPath: f.flux.path + ".pid")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(50)) }
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(f.rig.service.registry.sessions.isEmpty)
        for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(kill(pid, 0) != 0, "flux is gone")
    }

    // MARK: Mappings

    @Test("a folder mapping is kept per cluster, namespace and name, and can be cleared")
    func mappings() throws {
        let suite = "flux-mapping-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let maps = FluxFolderMappings(defaults: defaults)
        #expect(maps.folder(cluster: "c1", namespace: "flux-system", name: "apps") == nil)
        maps.set(URL(fileURLWithPath: "/Users/me/repo/apps/../apps", isDirectory: true), cluster: "c1", namespace: "flux-system", name: "apps")
        #expect(maps.folder(cluster: "c1", namespace: "flux-system", name: "apps")?.path == "/Users/me/repo/apps")
        #expect(maps.folder(cluster: "c2", namespace: "flux-system", name: "apps") == nil)
        #expect(maps.folder(cluster: "c1", namespace: "other", name: "apps") == nil)
        maps.set(nil, cluster: "c1", namespace: "flux-system", name: "apps")
        #expect(maps.folder(cluster: "c1", namespace: "flux-system", name: "apps") == nil)
    }

    @Test("every error has a readable message")
    func messages() {
        let all: [FluxDiffError] = [.notInstalled, .outputTooLarge, .folderMissing("/x"), .invalidName("-x"), .timedOut(5), .failed(code: 1, message: "boom")]
        for e in all { #expect(!(e.errorDescription ?? "").isEmpty) }
    }
}
#endif
