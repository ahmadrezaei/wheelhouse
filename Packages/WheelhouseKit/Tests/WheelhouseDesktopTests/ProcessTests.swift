#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

private func spec(_ exe: String, _ args: [String] = [], env: [String: String] = ["PATH": "/usr/bin:/bin"], stdin: Data? = nil,
                  timeout: Duration = .seconds(10)) -> ProcessSpec {
    ProcessSpec(executable: URL(fileURLWithPath: exe), arguments: args, environment: env, stdin: stdin, timeout: timeout)
}

@Suite("Subprocess")
struct SubprocessTests {
    @Test func runsWithoutAShellAndCapturesOutput() async throws {
        // A shell metacharacter in an argument is data: nothing interprets it.
        let r = try await Subprocess.run(spec("/bin/echo", ["a; touch /tmp/should-not-exist $(id)"]))
        #expect(r.exit.succeeded)
        #expect(r.stdoutString == "a; touch /tmp/should-not-exist $(id)\n")
    }

    @Test func exitCodeAndStderrTail() async throws {
        let r = try await Subprocess.run(spec("/bin/sh", ["-c", "echo oops >&2; exit 7"]))
        #expect(r.exit.code == 7)
        #expect(r.stderrString == "oops\n")
    }

    @Test func theEnvironmentIsExactlyTheOneGiven() async throws {
        let r = try await Subprocess.run(spec("/usr/bin/env", [], env: ["ONLY": "this"]))
        #expect(r.stdoutString == "ONLY=this\n")
    }

    @Test func stdinIsDevNullByDefaultAndPipedWhenGiven() async throws {
        let none = try await Subprocess.run(spec("/bin/cat"))
        #expect(none.stdout.isEmpty)
        let some = try await Subprocess.run(spec("/bin/cat", stdin: Data("hello".utf8)))
        #expect(some.stdoutString == "hello")
    }

    @Test func noDescriptorsLeakIntoTheChild() async throws {
        // Hold two descriptors open in this process at numbers above anything the child legitimately has (0-2 and the descriptor `ls`
        // itself opens), so the check does not depend on how many descriptors the test runner happens to have.
        let source = open("/dev/null", O_RDONLY)
        let mid = fcntl(source, F_DUPFD, 10)
        let high = fcntl(source, F_DUPFD, 100)
        defer { close(high); close(mid); close(source) }
        let r = try await Subprocess.run(spec("/bin/sh", ["-c", "ls /dev/fd | sort -n | tr '\\n' ' '"]))
        let fds = r.stdoutString.split(separator: " ").compactMap { Int($0) }
        #expect(!fds.contains(Int(mid)) && !fds.contains(Int(high)))
        #expect(fds.allSatisfy { $0 <= 4 })   // 0, 1, 2 and the descriptor `ls` itself opened
    }

    @Test func theChildLeadsItsOwnProcessGroup() async throws {
        let r = try await Subprocess.run(spec("/bin/sh", ["-c", "echo $$ $(ps -o pgid= -p $$)"]))
        let parts = r.stdoutString.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(parts.count == 2)
        #expect(parts[0] == parts[1])
        #expect(parts[1] != String(getpgrp()))
    }

    @Test func timeoutTerminatesTheWholeGroup() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "wh-grandchild-\(UUID().uuidString)")
        let started = ContinuousClock.now
        await #expect(throws: SubprocessError.self) {
            // A grandchild that would outlive its parent writes the marker after 3 s unless it is killed with the group.
            _ = try await Subprocess.run(spec("/bin/sh", ["-c", "(sleep 3; touch \(marker.path)) & sleep 30"], timeout: .milliseconds(500)))
        }
        #expect(started.duration(to: .now) < .seconds(8))
        try await Task.sleep(for: .seconds(3.5))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func outputOverTheLimitTerminatesTheRun() async throws {
        var s = spec("/bin/sh", ["-c", "yes | head -c 5000000"])
        s.stdoutLimit = 100_000
        await #expect(throws: SubprocessError.outputTooLarge(100_000)) { _ = try await Subprocess.run(s) }
    }

    @Test func stderrKeepsTheTail() async throws {
        var s = spec("/bin/sh", ["-c", "i=0; while [ $i -lt 2000 ]; do echo line-$i >&2; i=$((i+1)); done"])
        s.stderrLimit = 1000
        let r = try await Subprocess.run(s)
        #expect(r.stderrTail.count <= 1000)
        #expect(r.stderrString.hasSuffix("line-1999\n"))
    }

    @Test func cancellationKillsTheChild() async throws {
        let task = Task { try await Subprocess.run(spec("/bin/sleep", ["30"], timeout: .seconds(60))) }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(started.duration(to: .now) < .seconds(6))
    }

    @Test func aMissingOrRelativeExecutableIsRefused() async {
        await #expect(throws: SubprocessError.self) { _ = try await Subprocess.run(spec("/nonexistent/program")) }
        await #expect(throws: SubprocessError.self) { _ = try await Subprocess.run(spec("echo")) }
    }

    @Test func streamYieldsEventsThenTheExit() async throws {
        var out = ""
        var exit: ProcessExit?
        for try await e in Subprocess.stream(spec("/bin/sh", ["-c", "echo one; echo two >&2"])) {
            switch e {
            case .stdout(let d): out += String(decoding: d, as: UTF8.self)
            case .stderr: break
            case .exit(let x): exit = x
            }
        }
        #expect(out == "one\n")
        #expect(exit?.code == 0)
    }

    @Test func manyConcurrentRunsAllFinish() async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<20 { group.addTask { try await Subprocess.run(spec("/bin/echo", ["\(i)"])).stdoutString } }
            var seen = Set<String>()
            for try await s in group { seen.insert(s) }
            #expect(seen.count == 20)
        }
    }
}

@Suite("ShellEnvironment")
struct ShellEnvironmentTests {
    private func fakeShell(_ scratch: Scratch, body: String) throws -> URL {
        let url = try scratch.write("fake-shell.sh", "#!/bin/sh\n\(body)\n", mode: 0o755)
        return url
    }

    @Test func parsesOnlyBetweenTheMarkersAndRunsLoginInteractive() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let argsFile = s.root.appending(path: "args.txt")
        // The rc file prints a banner before and after; the fake shell records its arguments.
        let shell = try fakeShell(s, body: """
        printf '%s\\n' "$@" > \(argsFile.path)
        echo "Welcome banner"
        printf '\\000WH_ENV_BEGIN\\000'
        printf 'PATH=/custom/bin:/usr/bin\\000KUBECONFIG=/a.yaml:/b.yaml\\000AWS_PROFILE=prod\\000'
        printf '\\000WH_ENV_END\\000'
        echo "after banner"
        """)
        let env = ShellEnvironment(gate: openGate(home: s.root), home: s.root, shell: shell.path)
        let snap = await env.reload()
        #expect(snap.path == "/custom/bin:/usr/bin")
        #expect(snap.kubeconfig == "/a.yaml:/b.yaml")
        #expect(snap.vars["AWS_PROFILE"] == "prod")
        #expect(snap.failure == nil)
        let args = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(Array(args.prefix(3)) == ["-l", "-i", "-c"])
        #expect(args[3].contains("WH_ENV_BEGIN") && args[3].contains("/usr/bin/env -0"))
    }

    @Test func theGateRemovesKUBECONFIGFromTheSnapshot() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let shell = try fakeShell(s, body: "printf '\\000WH_ENV_BEGIN\\000PATH=/x\\000KUBECONFIG=/home/.kube/config\\000\\000WH_ENV_END\\000'")
        let snap = await ShellEnvironment(gate: activeGate(home: s.root), home: s.root, shell: shell.path).reload()
        #expect(snap.kubeconfig == nil)
        #expect(snap.vars["KUBECONFIG"] == nil)
    }

    @Test func aTimeoutFallsBackToTheFixedPathWithABanner() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let shell = try fakeShell(s, body: "sleep 30")
        let env = ShellEnvironment(gate: openGate(home: s.root), home: s.root, timeout: .milliseconds(400), shell: shell.path)
        let snap = await env.reload()
        #expect(snap.failure?.contains("could not be read") == true)
        #expect(snap.path == ShellEnvironment.fallbackPath(home: s.root))
        #expect(snap.path.hasPrefix("/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:"))
        #expect(snap.path.contains("\(s.root.path)/.krew/bin"))
    }

    @Test func noMarkersMeansFallback() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let shell = try fakeShell(s, body: "echo 'PATH=/nope'")
        let snap = await ShellEnvironment(gate: openGate(home: s.root), home: s.root, shell: shell.path).reload()
        #expect(snap.failure != nil)
        #expect(snap.path == ShellEnvironment.fallbackPath(home: s.root))
    }

    @Test func parseHandlesEmptyValuesAndValuesWithEquals() {
        var data = ShellEnvironment.beginMarker
        data.append(Data("A=\0B=x=y\0C=\0".utf8))
        data.append(ShellEnvironment.endMarker)
        #expect(ShellEnvironment.parse(data) == ["A": "", "B": "x=y", "C": ""])
        #expect(ShellEnvironment.parse(Data("A=1".utf8)) == nil)
    }
}

@Suite("ExecutableLocator")
struct ExecutableLocatorTests {
    @Test func findsTheFirstExecutableRegularFileOnThePath() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let a = try s.dir("a"), b = try s.dir("b")
        try s.write("a/tool", "#!/bin/sh\n", mode: 0o644)           // not executable: skipped
        let real = try s.write("b/tool", "#!/bin/sh\n", mode: 0o755)
        try FileManager.default.createDirectory(at: a.appending(path: "dir-tool"), withIntermediateDirectories: true)
        let locator = ExecutableLocator(searchPath: [a.path, b.path])
        #expect(locator.find("tool") == real)
        #expect(locator.find("dir-tool") == nil)
        #expect(locator.find("missing") == nil)
        #expect(locator.find("../tool") == nil)
    }

    @Test func snapshotPathComesFirstThenTheFallbackDirectories() {
        let snap = ShellSnapshot(path: "/snap/bin:/usr/bin", kubeconfig: nil, vars: [:], shell: "/bin/zsh")
        let locator = ExecutableLocator(snapshot: snap, home: URL(fileURLWithPath: "/Users/x"))
        #expect(locator.searchPath.first == "/snap/bin")
        #expect(locator.searchPath.contains("/opt/homebrew/bin"))
        #expect(Set(locator.searchPath).count == locator.searchPath.count)
    }

    @Test func commandWithASlashResolvesRelativeToTheKubeconfigFolder() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let tool = try s.write("bin/plugin", "#!/bin/sh\n", mode: 0o755)
        let locator = ExecutableLocator(searchPath: [])
        #expect(locator.resolve(command: "bin/plugin", baseDirectory: s.root.path) == tool)
        #expect(locator.resolve(command: tool.path, baseDirectory: nil) == tool)
        #expect(locator.resolve(command: "./missing", baseDirectory: s.root.path) == nil)
    }

    @Test func overridesWin() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let mine = try s.write("mine/kubectl", "#!/bin/sh\n", mode: 0o755)
        let locator = ExecutableLocator(searchPath: ["/usr/bin"], overrides: ["kubectl": mine.path])
        #expect(locator.find("kubectl") == mine)
    }
}

@Suite("EnvironmentBuilder")
struct EnvironmentBuilderTests {
    private func builder(vars: [String: String] = [:], isolated: Bool = true) -> EnvironmentBuilder {
        let snap = ShellSnapshot(path: "/snap/bin:/usr/bin", kubeconfig: nil, vars: vars, shell: "/bin/zsh")
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        return EnvironmentBuilder(snapshot: snap, paths: AppPaths(gateActive: isolated, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: home), home: home)
    }

    @Test func startsFromEmptyAndKeepsOnlyAllowlistedNames() {
        let env = builder(vars: [
            "HTTPS_PROXY": "http://p:3128", "LC_ALL": "en_US.UTF-8", "SSL_CERT_FILE": "/c.pem",
            "AWS_PROFILE": "prod", "AWS_SECRET_ACCESS_KEY": "nope", "GOOGLE_APPLICATION_CREDENTIALS": "/g.json",
            "RANDOM_VAR": "x", "EDITOR": "vim", "KUBECONFIG": "/home/.kube/config",
        ]).build(profile: .aws)
        #expect(env["HTTPS_PROXY"] == "http://p:3128")
        #expect(env["LC_ALL"] == "en_US.UTF-8")
        #expect(env["SSL_CERT_FILE"] == "/c.pem")
        #expect(env["AWS_PROFILE"] == "prod")
        #expect(env["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(env["GOOGLE_APPLICATION_CREDENTIALS"] == nil)       // another tool's profile
        #expect(env["RANDOM_VAR"] == nil)
        #expect(env["EDITOR"] == nil)
        #expect(env["KUBECONFIG"] == nil)                           // only ever an explicit addition
        #expect(env["PATH"] == "/snap/bin:/usr/bin")
    }

    @Test func neverPassesDyldApiKeysOrInternals() {
        let env = builder(vars: ["DYLD_INSERT_LIBRARIES": "/evil.dylib", "ANTHROPIC_API_KEY": "sk", "OPENAI_API_KEY": "sk", "XPC_FLAGS": "1",
                                 "__CFBundleIdentifier": "x", "MallocStackLogging": "1", "HOME": "/Users/tester"]).build(profile: .aws)
        for key in ["DYLD_INSERT_LIBRARIES", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "XPC_FLAGS", "__CFBundleIdentifier", "MallocStackLogging"] {
            #expect(env[key] == nil, "\(key) leaked")
        }
        #expect(env["HOME"] == "/Users/tester")
    }

    @Test func toolProfilesAddOnlyTheirOwnVariables() {
        let vars = ["AZURE_CONFIG_DIR": "/az", "CLOUDSDK_CONFIG": "/gc", "HELM_NAMESPACE": "x", "HELM_KUBEAPISERVER": "https://prod", "HELM_KUBETOKEN": "t",
                    "DOCKER_CONFIG": "/d", "TRIVY_CACHE_DIR": "/t", "TRIVY_PASSWORD": "pw", "TRIVY_REGISTRY_TOKEN": "tk"]
        let b = builder(vars: vars)
        #expect(b.build(profile: .azure)["AZURE_CONFIG_DIR"] == "/az")
        #expect(b.build(profile: .azure)["CLOUDSDK_CONFIG"] == nil)
        #expect(b.build(profile: .google)["CLOUDSDK_CONFIG"] == "/gc")
        // An isolated (Debug or Profile) build takes no HELM_* from the shell; an ordinary build passes the non-credential ones.
        #expect(b.build(profile: .helm)["HELM_NAMESPACE"] == nil)
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let ordinary = EnvironmentBuilder(snapshot: ShellSnapshot(path: "/usr/bin", kubeconfig: nil, vars: vars, shell: "/bin/zsh"),
                                          paths: AppPaths(gateActive: false, bundleID: AppPaths.releaseBundleID, home: home), home: home)
        let helm = ordinary.build(profile: .helm)
        #expect(helm["HELM_NAMESPACE"] == "x")
        #expect(helm["HELM_KUBEAPISERVER"] == nil && helm["HELM_KUBETOKEN"] == nil)
        #expect(b.build(profile: .docker)["DOCKER_CONFIG"] == "/d")
        let trivy = b.build(profile: .trivy)
        #expect(trivy["TRIVY_CACHE_DIR"] == "/t")
        #expect(trivy["TRIVY_PASSWORD"] == nil && trivy["TRIVY_REGISTRY_TOKEN"] == nil)
        #expect(b.build(profile: .none)["AZURE_CONFIG_DIR"] == nil)
    }

    @Test func kubecacheDirIsAlwaysSetUnderTheAppFolderWhileTheGateIsActive() {
        for profile in [EnvironmentBuilder.ToolProfile.none, .kubectl, .helm, .aws] {
            let env = builder().build(profile: profile)
            #expect(env["KUBECACHEDIR"] == "/Users/tester/Library/Application Support/Wheelhouse-Debug/kubectl-cache")
        }
    }

    @Test func helmFoldersAreIsolatedWhileTheGateIsActive() {
        let env = builder().build(profile: .helm)
        #expect(env["HELM_CONFIG_HOME"]?.contains("Wheelhouse-Debug/helm/config") == true)
        #expect(builder().build(profile: .kubectl)["HELM_CONFIG_HOME"] == nil)
    }

    @Test func additionsWinAndAreNotFiltered() {
        let env = builder().build(profile: .none, additions: ["KUBECONFIG": "/session/kc", "KUBERNETES_EXEC_INFO": "{}", "PATH": "/forced"])
        #expect(env["KUBECONFIG"] == "/session/kc")
        #expect(env["KUBERNETES_EXEC_INFO"] == "{}")
        #expect(env["PATH"] == "/forced")
    }

    @Test func pluginProfileFollowsTheCommandName() {
        #expect(EnvironmentBuilder.ToolProfile.forPlugin(command: "/usr/local/bin/aws") == .aws)
        #expect(EnvironmentBuilder.ToolProfile.forPlugin(command: "gke-gcloud-auth-plugin") == .google)
        #expect(EnvironmentBuilder.ToolProfile.forPlugin(command: "kubelogin") == .azure)
        #expect(EnvironmentBuilder.ToolProfile.forPlugin(command: "tsh") == .none)
    }
}
#endif
