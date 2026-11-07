import Testing
import Foundation
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// `App.init` (through `MacAppEnvironment.live()`) must not read the test kubeconfig and must not call Security: either can block the
/// main thread behind a macOS prompt (a file under ~/Documents) or a Security main-thread warning, and the app then never launches.
@Suite("Launch path", .serialized)
@MainActor
struct LaunchPathTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(path: String, onMain: Bool)] = []
        var calls: [(path: String, onMain: Bool)] { lock.withLock { _calls } }
        func read(_ url: URL) throws -> String {
            lock.withLock { _calls.append((url.path, Thread.isMainThread)) }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func waitReady(_ env: MacAppEnvironment) async {
        for _ in 0..<300 where !env.isReady { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func liveDoesNoSynchronousFileReadOfTheTestKubeconfig() async {
        let recorder = Recorder()
        let env = MacAppEnvironment.live(reader: recorder.read)
        #expect(recorder.calls.isEmpty, "App.init read a file: \(recorder.calls)")
        // The kubeconfig is read after launch, off the main thread, exactly once.
        env.start()
        await waitReady(env)
        #expect(env.isReady)
        if env.hostsState != .notConfigured {
            #expect(recorder.calls.count == 1)
            #expect(recorder.calls.allSatisfy { !$0.onMain }, "the read ran on the main thread")
        }
    }

    @Test func aFailedReadIsReportedInlineAndNeverRetried() async {
        defer { DevSafety.setHostConfigurationError(nil) }
        struct Denied: Error, LocalizedError { var errorDescription: String? { "Operation not permitted" } }
        let counter = Recorder()
        let env = MacAppEnvironment.live(reader: { url in _ = try? counter.read(url); throw Denied() })
        env.start()
        await waitReady(env)
        guard env.hostsState != .notConfigured else { return }
        if case .failed(let message) = env.hostsState { #expect(message.contains("couldn't be read")) } else { Issue.record("expected a failure, got \(env.hostsState)") }
        #expect(DevSafety.hostConfigurationError != nil)
        #expect(counter.calls.count == 1)                                    // one attempt, no loop
        // The import UI says why a host is blocked instead of hanging.
        let policy = MacImportPolicy(gate: DevSafetyPolicy(isActive: true, allowedHosts: []))
        let ctx = try? KubeconfigParser.parse("clusters:\n- name: a\n  cluster: { server: 'https://203.0.113.9:6443' }\ncontexts:\n- name: a\n  context: { cluster: a, user: u }\nusers:\n- name: u\n  user: { token: t }\n").contexts.first
        if let ctx { #expect(policy.blockedReason(for: ctx)?.contains("couldn't be read") == true) }
    }

    @Test func untilTheHostsAreKnownNoHostIsAllowed() {
        // Fail closed: the allowed set starts empty, so only the reserved fixture names pass while the file is still being read.
        let pending = DevSafetyPolicy(isActive: true, allowedHosts: [])
        #expect(!pending.isAllowed(server: URL(string: "https://127.0.0.1:6443")))
        #expect(pending.isAllowed(server: URL(string: "https://x.test")))
    }
}
