#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// The cloud-CLI runner: the gate, isolation, QoS and the 6-process limit. Nothing here touches ~/.aws, ~/.config/gcloud or ~/.azure:
/// specs are inspected through a spawn seam, and the one end-to-end test runs fake scripts with HOME inside a scratch folder.
@Suite("Landfall CLI runner")
struct LandfallRunnerTests {
    static func result(_ out: String = "") -> ProcessResult {
        ProcessResult(exit: ProcessExit(code: 0, signal: nil, timedOut: false, duration: .zero), stdout: Data(out.utf8), stderrTail: Data())
    }

    /// A scratch tools folder with fake `aws`, `gcloud` and `az`, and an isolated HOME.
    struct Sandbox {
        let scratch: Scratch
        let bin: URL
        let home: URL
        init() throws {
            scratch = try Scratch()
            bin = try scratch.dir("bin")
            home = try scratch.dir("isolated-home")
            let script = try #require(Bundle.module.url(forResource: "Fixtures/landfall/bin/fakecli", withExtension: "sh"))
            for name in ["aws", "gcloud", "az"] {
                let url = bin.appending(path: name)
                try FileManager.default.copyItem(at: script, to: url)
                chmod(url.path, 0o755)
            }
        }
        var isolation: CLIIsolation { CLIIsolation(home: home, allowedExecutableDirectory: bin) }
        var locator: ExecutableLocator { ExecutableLocator(searchPath: [bin.path]) }
    }

    final class Spawns: @unchecked Sendable {
        private let state = Mutex<[ProcessSpec]>([])
        var specs: [ProcessSpec] { state.withLock { $0 } }
        func record(_ s: ProcessSpec) { state.withLock { $0.append(s) } }
    }

    func runner(sandbox: Sandbox, gate: DevSafetyPolicy, spawns: Spawns, isolated: Bool = true, snapshot: ShellSnapshot? = nil,
                limiter: ConcurrencyLimiter = ConcurrencyLimiter(limit: 6),
                spawn: SubprocessCLIRunner.Spawn? = nil) -> SubprocessCLIRunner {
        SubprocessCLIRunner(gateProvider: { gate }, locator: { sandbox.locator }, snapshot: { snapshot },
                            paths: AppPaths(gateActive: true, bundleID: nil, home: sandbox.home), isolation: isolated ? sandbox.isolation : nil, limiter: limiter,
                            spawn: spawn ?? { spec in spawns.record(spec); return Self.result() })
    }

    @Test func nothingIsLocatedOrStartedWhileTheGateIsActive() async throws {
        let box = try Sandbox(); defer { box.scratch.cleanup() }
        let spawns = Spawns()
        let located = Mutex(0)
        let r = SubprocessCLIRunner(gateProvider: { activeGate(home: box.home) }, locator: { located.withLock { $0 += 1 }; return box.locator }, snapshot: { nil },
                                    paths: AppPaths(gateActive: true, bundleID: nil, home: box.home), isolation: box.isolation,
                                    spawn: { spawns.record($0); return Self.result() })
        for provider in CloudProvider.allCases {
            await #expect(throws: CLIError.self) { _ = try await r.run(provider, ["--version"], environment: [:]) }
        }
        #expect(spawns.specs.isEmpty)
        #expect(located.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: box.home.appending(path: "fake-cli.log").path))
    }

    @Test func anOpenPolicyAloneCannotStartARealCLIWhileTheProcessGateIsActive() async throws {
        // Under XCTest the process gate (`DevSafety.isActive`) is on. A policy built open in a test does not change that.
        #expect(DevSafety.isActive)
        let box = try Sandbox(); defer { box.scratch.cleanup() }
        let spawns = Spawns()
        let r = runner(sandbox: box, gate: openGate(home: box.home), spawns: spawns, isolated: false)
        await #expect(throws: CLIError.self) { _ = try await r.run(.aws, ["--version"], environment: [:]) }
        #expect(spawns.specs.isEmpty)
        // The default process gate is the real one.
        let real = SubprocessCLIRunner(gateProvider: { openGate(home: box.home) }, locator: { box.locator }, snapshot: { nil },
                                       paths: AppPaths(gateActive: true, bundleID: nil, home: box.home), spawn: { spawns.record($0); return Self.result() })
        await #expect(throws: CLIError.self) { _ = try await real.run(.gcp, ["version"], environment: [:]) }
        #expect(spawns.specs.isEmpty)
    }

    @Test func isolatedRunsGetAnIsolatedHomeUtilityQoSAndNoCredentialVariables() async throws {
        let box = try Sandbox(); defer { box.scratch.cleanup() }
        let spawns = Spawns()
        let snapshot = ShellSnapshot(path: "/usr/bin", kubeconfig: nil, vars: [
            "GOOGLE_APPLICATION_CREDENTIALS": "/real/sa.json", "AZURE_CLIENT_SECRET": "hunter2", "AWS_PROFILE": "real-profile", "AWS_CONFIG_FILE": "/real/aws/config",
            "AWS_SHARED_CREDENTIALS_FILE": "/real/aws/credentials", "CLOUDSDK_CONFIG": "/real/gcloud", "AZURE_CONFIG_DIR": "/real/azure",
        ], shell: "/bin/zsh")
        let r = runner(sandbox: box, gate: openGate(home: box.home), spawns: spawns, snapshot: snapshot)
        _ = try await r.run(.aws, ["sts", "get-caller-identity", "--profile", "p"], environment: ["AWS_PROFILE": "p"])
        _ = try await r.run(.gcp, ["projects", "list"], environment: [:])
        _ = try await r.run(.azure, ["account", "list"], environment: [:])
        let specs = spawns.specs
        #expect(specs.count == 3)
        for spec in specs {
            #expect(spec.qos == .utility)
            #expect(spec.executable.path.hasPrefix(box.bin.path + "/"))
            #expect(spec.environment["HOME"] == box.home.path)
            #expect(spec.environment["AWS_CONFIG_FILE"] == box.home.path + "/.aws/config")
            #expect(spec.environment["AWS_SHARED_CREDENTIALS_FILE"] == box.home.path + "/.aws/credentials")
            #expect(spec.environment["CLOUDSDK_CONFIG"] == box.home.path + "/.config/gcloud")
            #expect(spec.environment["AZURE_CONFIG_DIR"] == box.home.path + "/.azure")
            #expect(spec.environment["GOOGLE_APPLICATION_CREDENTIALS"] == nil)
            #expect(spec.environment["AZURE_CLIENT_SECRET"] == nil)
            #expect(spec.environment["KUBECONFIG"] == nil)
            #expect(spec.environment["PATH"] == box.bin.path + ":/usr/bin:/bin")
            // Nothing in the environment points at the real home.
            #expect(!spec.environment.values.contains { $0.hasPrefix(DevSafetyPolicy.accountHome.path + "/.") })
        }
        #expect(specs[0].environment["AWS_PROFILE"] == "p")
        #expect(specs[0].arguments == ["sts", "get-caller-identity", "--profile", "p"])
    }

    @Test func anExecutableOutsideTheIsolatedFolderIsRefused() async throws {
        let box = try Sandbox(); defer { box.scratch.cleanup() }
        let elsewhere = try box.scratch.dir("elsewhere")
        let script = elsewhere.appending(path: "aws")
        try FileManager.default.copyItem(at: box.bin.appending(path: "aws"), to: script)
        chmod(script.path, 0o755)
        let spawns = Spawns()
        let r = SubprocessCLIRunner(gateProvider: { openGate(home: box.home) }, locator: { ExecutableLocator(searchPath: [elsewhere.path]) }, snapshot: { nil },
                                    paths: AppPaths(gateActive: true, bundleID: nil, home: box.home), isolation: box.isolation,
                                    spawn: { spawns.record($0); return Self.result() })
        await #expect(throws: CLIError.self) { _ = try await r.run(.aws, ["--version"], environment: [:]) }
        #expect(spawns.specs.isEmpty)
    }

    @Test func aMissingToolIsReportedNotStarted() async throws {
        let box = try Sandbox(); defer { box.scratch.cleanup() }
        let r = SubprocessCLIRunner(gateProvider: { openGate(home: box.home) }, locator: { ExecutableLocator(searchPath: []) }, snapshot: { nil },
                                    paths: AppPaths(gateActive: true, bundleID: nil, home: box.home), isolation: box.isolation)
        await #expect(throws: CLIError.notInstalled("aws")) { _ = try await r.run(.aws, ["--version"], environment: [:]) }
    }

    @Test func noMoreThanSixProcessesRunAtOnce() async throws {
        let box = try Sandbox(); defer { box.scratch.cleanup() }
        let limiter = ConcurrencyLimiter(limit: SubprocessCLIRunner.maxParallel)
        let current = Mutex(0), peak = Mutex(0)
        let r = runner(sandbox: box, gate: openGate(home: box.home), spawns: Spawns(), limiter: limiter, spawn: { _ in
            let now = current.withLock { $0 += 1; return $0 }
            peak.withLock { $0 = max($0, now) }
            try await Task.sleep(for: .milliseconds(40))
            current.withLock { $0 -= 1 }
            return Self.result()
        })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { _ = try? await r.run(.aws, ["eks", "list-clusters"], environment: [:]) } }
        }
        #expect(SubprocessCLIRunner.maxParallel == 6)
        #expect(peak.withLock { $0 } == 6)
        #expect(await limiter.peak == 6)
        #expect(current.withLock { $0 } == 0)
    }

    @Test func aCancelledWaiterLeavesTheQueueAndTheSlotIsReusable() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        try await limiter.acquire()
        let waiter = Task { try await limiter.acquire() }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await limiter.release()
        try await limiter.acquire()                 // would hang if the cancelled waiter still held a place
        await limiter.release()
    }

    @Test func realProcessesRunWithTheIsolatedHomeAndAreLoggedThere() async throws {
        let box = try Sandbox(); defer { box.scratch.cleanup() }
        let r = SubprocessCLIRunner(gateProvider: { openGate(home: box.home) }, locator: { box.locator }, snapshot: { nil },
                                    paths: AppPaths(gateActive: true, bundleID: nil, home: box.home), isolation: box.isolation)
        #expect(await AWSCLI(runner: r).status() == .installed(version: "2.17.0"))
        #expect(try await AWSCLI(runner: r).accounts().map(\.accountID) == ["default", "platform-prod"])
        #expect(await GCloudCLI(runner: r).status() != .notFound(installHint: "x"))
        let log = try String(contentsOf: box.home.appending(path: "fake-cli.log"), encoding: .utf8)
        #expect(log.contains("aws --version | HOME=\(box.home.path) AWS_CONFIG_FILE=\(box.home.path)/.aws/config"))
        #expect(log.contains("CLOUDSDK_CONFIG=\(box.home.path)/.config/gcloud"))
        // The run created nothing outside the scratch folder: every line of the log names the isolated home.
        for line in log.split(separator: "\n") { #expect(line.contains("HOME=\(box.home.path) ")) }
    }

    @Test func failureWordingIsClassified() {
        func f(_ s: String) -> CLIFailure { CLIFailure.classify(CLIError.failed(exitCode: 1, stderr: s)) }
        #expect(f("Error loading SSO Token: Token for x has expired") == .signedOut)
        #expect(f("ERROR: (gcloud.auth.print-access-token) There was a problem refreshing your current auth tokens: Reauthentication failed. Please run: gcloud auth login") == .signedOut)
        #expect(f("ERROR: Please run 'az login' to setup account.") == .signedOut)
        #expect(f("User is not authorized to perform: eks:ListClusters") == .accessDenied(action: "eks:ListClusters"))
        #expect(f("something else") == .other("something else"))
    }
}
#endif
