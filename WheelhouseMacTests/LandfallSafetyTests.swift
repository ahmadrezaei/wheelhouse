import Testing
import WheelhouseDesktop
@testable import WheelhouseMac

/// The development gate keeps Landfall off in the shipped-for-testing builds (Debug, Profile): no cloud CLI, no `~/.kube/config` merge.
@Suite("Landfall safety")
struct LandfallSafetyTests {
    @Test func theRunningTestBuildHasLandfallAndTheMergeSwitchedOff() async throws {
        #expect(DevSafety.isActive)
        let gate = DevSafetyPolicy.current
        #expect(!gate.allowsCloudCLIs)
        #expect(!gate.allowsKubeconfigWrites)
        let runner = SubprocessCLIRunner(locator: { ExecutableLocator(searchPath: []) }, snapshot: { nil })
        await #expect(throws: CLIError.self) { _ = try await runner.run(.aws, ["--version"], environment: [:]) }
        #expect(throws: DevSafetyError.self) { _ = try LandfallMergeTarget.resolve(gate: gate) }
    }
}
