#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

private let sandboxed = Edition(isSandboxed: true)
private let open = Edition(isSandboxed: false)

private func spec(_ exe: String, _ args: [String] = []) -> ProcessSpec {
    ProcessSpec(executable: URL(fileURLWithPath: exe), arguments: args, environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10))
}

@Suite("Edition: detection")
struct EditionDetectionTests {
    @Test func theEntitlementIsFinalWhenItCanBeRead() {
        #expect(Edition.decide(entitlement: .value(true), containerID: nil))
        #expect(Edition.decide(entitlement: .value(true), containerID: "x"))
        #expect(!Edition.decide(entitlement: .value(false), containerID: "x"))
    }

    @Test func anAbsentEntitlementIsNeverSandboxedWhateverTheEnvironmentSays() {
        // The GitHub edition must not be blocked by a variable somebody exported.
        #expect(!Edition.decide(entitlement: .absent, containerID: nil))
        #expect(!Edition.decide(entitlement: .absent, containerID: "com.ahmadrezaei.wheelhouse"))
    }

    @Test func aFailedReadFallsBackToTheSandboxVariable() {
        #expect(Edition.decide(entitlement: .error, containerID: "com.ahmadrezaei.wheelhouse"))
        #expect(!Edition.decide(entitlement: .error, containerID: nil))
        #expect(!Edition.decide(entitlement: .error, containerID: ""))
    }

    @Test func theTestProcessIsNotSandboxed() {
        #expect(!Edition.ofProcess.isSandboxed)
        #expect(!Edition.current.isSandboxed)
    }

    @Test func theOverrideAppliesInsideTheScopeOnly() async {
        #expect(Edition.withEdition(sandboxed) { Edition.current.isSandboxed })
        let inside = await Edition.withEdition(sandboxed) { await Task { Edition.current.isSandboxed }.value }
        #expect(inside)
        #expect(!Edition.current.isSandboxed)
    }
}

@Suite("Edition: the process layer fails closed")
struct EditionProcessTests {
    @Test func runThrowsTheTypedErrorBeforeAnythingElse() async {
        // A path that does not exist would otherwise give SubprocessError.launchFailed: the policy check comes first.
        let error = await #expect(throws: ProcessPolicyError.self) {
            try await Edition.withEdition(sandboxed) { try await Subprocess.run(spec("/nonexistent/aws")) }
        }
        #expect(error == .unavailableInAppStoreEdition(tool: "aws"))
        #expect(error?.localizedDescription.contains("`aws`") == true)
    }

    @Test func runStillWorksWhenNotSandboxed() async throws {
        let r = try await Edition.withEdition(open) { try await Subprocess.run(spec("/bin/echo", ["hi"])) }
        #expect(r.stdoutString == "hi\n")
        await #expect(throws: SubprocessError.self) {
            try await Edition.withEdition(open) { try await Subprocess.run(spec("/nonexistent/aws")) }
        }
    }

    @Test func systemToolsAreBlockedToo() async {
        // The sandbox itself lets /bin tools run, so the refusal must be explicit code.
        await #expect(throws: ProcessPolicyError.unavailableInAppStoreEdition(tool: "true")) {
            try await Edition.withEdition(sandboxed) { try await Subprocess.run(spec("/usr/bin/true")) }
        }
    }

    @Test func aSystemToolNeverTouchesTheFileSystemInTheSandboxedEdition() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let target = s.root.appending(path: "touched-by-system-tool")
        await #expect(throws: ProcessPolicyError.unavailableInAppStoreEdition(tool: "touch")) {
            try await Edition.withEdition(sandboxed) { try await Subprocess.run(spec("/usr/bin/touch", [target.path])) }
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        // Control: the same call outside the sandboxed edition does create it, so the assertion above means something.
        _ = try await Edition.withEdition(open) { try await Subprocess.run(spec("/usr/bin/touch", [target.path])) }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func streamFinishesWithTheTypedError() async {
        await #expect(throws: ProcessPolicyError.unavailableInAppStoreEdition(tool: "kubectl")) {
            try await Edition.withEdition(sandboxed) {
                for try await _ in Subprocess.stream(spec("/nonexistent/kubectl")) {}
            }
        }
    }

    @Test func ptyThrowsBeforeLookingForTheHelper() {
        #expect(throws: ProcessPolicyError.unavailableInAppStoreEdition(tool: "aws")) {
            try Edition.withEdition(sandboxed) {
                _ = try PTYProcess(spec: spec("/nonexistent/aws"), size: (80, 24), helper: URL(fileURLWithPath: "/nonexistent/wh-pty-exec"))
            }
        }
        #expect(throws: PTYError.self) {
            try Edition.withEdition(open) {
                _ = try PTYProcess(spec: spec("/nonexistent/aws"), size: (80, 24), helper: URL(fileURLWithPath: "/nonexistent/wh-pty-exec"))
            }
        }
    }

    @Test func theBeaconCommandRunnerThrowsBeforeHoppingToAnotherQueue() async {
        await #expect(throws: ProcessPolicyError.unavailableInAppStoreEdition(tool: "claude")) {
            try await Edition.withEdition(sandboxed) {
                _ = try await ProcessCommandRunner().run(URL(fileURLWithPath: "/nonexistent/claude"), arguments: [], currentDirectory: nil)
            }
        }
    }
}

private final class CountingRunner: ExecPluginRunning {
    let calls = Mutex(0)
    func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        calls.withLock { $0 += 1 }
        throw SubprocessError.launchFailed("never")
    }
}

@Suite("Edition: exec credential plugins")
struct EditionExecTests {
    private func provider(runner: CountingRunner, interactiveMode: String? = nil) -> ExecCredentialProvider {
        let broker = ExecCredentialBroker(locator: { ExecutableLocator(searchPath: ["/usr/bin", "/bin"]) }, environment: { EnvironmentBuilder(snapshot: nil) },
                                          runner: runner, gate: DevSafetyPolicy(isActive: false))
        let spec = KubeconfigExecSpec(apiVersion: "client.authentication.k8s.io/v1", command: "aws", args: ["eks", "get-token"], env: [],
                                      provideClusterInfo: false, interactiveMode: interactiveMode)
        return ExecCredentialProvider(spec: spec, cluster: nil, kubeconfigPath: "/tmp/none.yaml", broker: broker)
    }

    @Test func theErrorCarriesThePluginCommandAndRunsNothing() async {
        let runner = CountingRunner()
        let p = provider(runner: runner)
        let error = await #expect(throws: ExecCredentialError.self) {
            try await Edition.withEdition(sandboxed) { try await p.authorization() }
        }
        #expect(error == .unavailableInEdition(command: "aws"))
        #expect(error?.localizedDescription == "Uses `aws` (exec plugin). The App Store edition can’t run credential plugins.")
        #expect(runner.calls.withLock { $0 } == 0)
    }

    @Test func anAlwaysInteractivePluginIsNotOfferedASignIn() async {
        let p = provider(runner: CountingRunner(), interactiveMode: "Always")
        await #expect(throws: ExecCredentialError.unavailableInEdition(command: "aws")) {
            try await Edition.withEdition(sandboxed) { try await p.authorization() }
        }
        await #expect(throws: ExecCredentialError.unavailableInEdition(command: "aws")) {
            try await Edition.withEdition(sandboxed) { _ = try await p.interactiveSpec() }
        }
    }

    @Test func whenNotSandboxedThePluginIsLookedUpAsBefore() async {
        let p = provider(runner: CountingRunner(), interactiveMode: "Always")
        await #expect(throws: ExecCredentialError.signInRequired(command: "aws")) {
            try await Edition.withEdition(open) { try await p.authorization() }
        }
    }
}

@Suite("Edition: DevSafety identities")
struct EditionDevSafetyTests {
    private let team = DevSafety.teamID
    private let off: [String: Any] = ["WHDevSafety": "NO"]
    private let github = "com.ahmadrezaei.wheelhouse.mac"
    private let store = "com.ahmadrezaei.wheelhouse"

    @Test func theStoreBundleWithAStoreSignatureOfTheTeamTurnsTheGateOff() {
        #expect(!DevSafety.evaluate(info: off, bundleID: store, signature: .macAppStore(team: team)))
    }

    @Test func theStoreBundleWithAnyOtherSignatureKeepsTheGateOn() {
        for signature in [CodeSignature.developerID(team: team), .appleDevelopment, .adHoc, .unsigned, .macAppStore(team: "OTHERTEAM1")] {
            #expect(DevSafety.evaluate(info: off, bundleID: store, signature: signature))
        }
    }

    @Test func theStoreBundleNeedsWHDevSafetyToBeExactlyNO() {
        let sig = CodeSignature.macAppStore(team: team)
        #expect(DevSafety.evaluate(info: [:], bundleID: store, signature: sig))
        for value in ["YES", "no", " NO", ""] { #expect(DevSafety.evaluate(info: ["WHDevSafety": value], bundleID: store, signature: sig)) }
    }

    @Test func theMasDebugBundleAlwaysKeepsTheGateOn() {
        for id in ["com.ahmadrezaei.wheelhouse.mas.debug", "com.ahmadrezaei.wheelhouse.mas"] {
            #expect(DevSafety.evaluate(info: off, bundleID: id, signature: .macAppStore(team: team)))
            #expect(DevSafety.evaluate(info: off, bundleID: id, signature: .developerID(team: team)))
        }
    }

    @Test func theTwoIdentitiesNeverCross() {
        #expect(DevSafety.evaluate(info: off, bundleID: github, signature: .macAppStore(team: team)))
        #expect(!DevSafety.evaluate(info: off, bundleID: github, signature: .developerID(team: team)))
        #expect(DevSafety.evaluate(info: off, bundleID: github + ".debug", signature: .developerID(team: team)))
    }

    @Test func bothDistributionBundlesAreCandidatesAndNothingElseIs() {
        #expect(DevSafety.isDistributionCandidate(info: off, bundleID: github))
        #expect(DevSafety.isDistributionCandidate(info: off, bundleID: store))
        for id in [nil, "com.ahmadrezaei.wheelhouse.mas.debug", github + ".debug", "x"] {
            #expect(!DevSafety.isDistributionCandidate(info: off, bundleID: id))
        }
        #expect(!DevSafety.isDistributionCandidate(info: [:], bundleID: store))
    }

    @Test func theRunningTestProcessHasNoStoreSignature() {
        #expect(CodeSignature.ofRunningAppMacAppStore() == .unsigned)
        #expect(CodeSignature.macAppStoreRequirement == "identifier \"com.ahmadrezaei.wheelhouse\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists")
    }

    @Test func theAccountHomeComesFromThePasswordDatabase() {
        // In the sandboxed edition NSHomeDirectory() is the container; getpwuid_r still names the real account home.
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        #expect(getpwuid_r(getuid(), &pwd, &buffer, buffer.count, &result) == 0)
        #expect(DevSafetyPolicy.accountHome.path == String(cString: pwd.pw_dir))
    }
}

@Suite("Edition: AppPaths")
struct EditionAppPathsTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private let tmp = URL(fileURLWithPath: "/var/folders/xx/T", isDirectory: true)

    @Test func theGitHubBundlesKeepTheirCacheFolders() {
        let release = AppPaths(gateActive: false, bundleID: "com.ahmadrezaei.wheelhouse.mac", home: home, temporaryDirectory: tmp)
        #expect(release.caches.path == "/Users/someone/Library/Caches/com.ahmadrezaei.wheelhouse.mac")
        let debug = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: home, temporaryDirectory: tmp)
        #expect(debug.caches.path == "/Users/someone/Library/Caches/com.ahmadrezaei.wheelhouse.mac.debug")
        for id in [nil, "com.apple.dt.xctest.tool", "x.debug"] {
            let p = AppPaths(gateActive: true, bundleID: id, home: home, temporaryDirectory: tmp)
            #expect(p.caches.path == "/Users/someone/Library/Caches/com.ahmadrezaei.wheelhouse.mac.debug")
        }
    }

    @Test func theStoreBundlesNameTheirOwnCacheFolders() {
        let store = AppPaths(gateActive: false, bundleID: "com.ahmadrezaei.wheelhouse", home: home, temporaryDirectory: tmp)
        #expect(store.caches.path == "/Users/someone/Library/Caches/com.ahmadrezaei.wheelhouse")
        let debug = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mas.debug", home: home, temporaryDirectory: tmp)
        #expect(debug.caches.path == "/Users/someone/Library/Caches/com.ahmadrezaei.wheelhouse.mas.debug")
    }
}
#endif
