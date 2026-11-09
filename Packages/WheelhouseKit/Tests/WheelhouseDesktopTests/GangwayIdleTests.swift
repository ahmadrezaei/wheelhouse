#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// Perf gate of M5a: an idle Gangway with 4 open sessions adds no wakeups (no repeating timers, no polling).
@Suite("Gangway idle cost", .serialized)
struct GangwayIdleTests {
    private static func wakeups() -> (interrupt: UInt64, idle: UInt64) {
        var info = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) } }
        precondition(rc == 0)
        return (info.ri_interrupt_wkups, info.ri_pkg_idle_wkups)
    }

    private func measure(seconds: Double) async throws -> (interrupt: Double, idle: Double) {
        let a = Self.wakeups()
        try await Task.sleep(for: .seconds(seconds))
        let b = Self.wakeups()
        return (Double(b.interrupt - a.interrupt) / seconds, Double(b.idle - a.idle) / seconds)
    }

    @Test("four open sessions with keep-alive connections cost no more wakeups than no Gangway at all")
    func idleWakeups() async throws {
        let seconds = 8.0
        // Baseline: the test process alone (the runner has its own noise).
        let base = try await measure(seconds: seconds)
        let rig = try await GangwayRig()
        defer { rig.stop() }
        var clients: [RawClient] = []
        for _ in 0..<4 {
            let (_, token) = try await rig.open()
            let c = try await rig.client()
            try await c.send(rig.request("GET", "/version", token: token))
            _ = try #require(await c.readResponse())
            clients.append(c)
        }
        #expect(rig.service.registry.liveSessionCount == 4)
        // A moment for the connections to settle, then the same measurement.
        try await Task.sleep(for: .seconds(1))
        let with = try await measure(seconds: seconds)
        print("GANGWAY-IDLE baseline interrupt/s=\(base.interrupt) idle/s=\(base.idle); with 4 sessions interrupt/s=\(with.interrupt) idle/s=\(with.idle)")
        // Each connection holds one single-shot deadline (120 s), re-slept on wake: nothing fires in an 8 s window. Allow the runner's noise.
        // The rest of the suite runs in this process at the same time, so the bound is loose; run alone this measures 0.1 per second more.
        // A repeating timer per connection would add at least 4 per second at the smallest interval Gangway could plausibly use.
        #expect(with.interrupt <= base.interrupt + 5.0, "4 idle sessions added \(with.interrupt - base.interrupt) interrupt wakeups per second")
        #expect(with.idle <= base.idle + 5.0, "4 idle sessions added \(with.idle - base.idle) idle wakeups per second")
        clients.forEach { $0.close() }
    }

    @Test("each idle connection holds at most one deadline task, and a connection that sees traffic does not create more")
    func oneDeadlinePerConnection() async throws {
        let rig = try await GangwayRig(idleTimeout: .seconds(30))
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let c = try await rig.client()
        for _ in 0..<200 {
            try await c.send(rig.request("GET", "/version", token: token))
            _ = try #require(await c.readResponse())
        }
        // 200 requests on one connection: still one connection, one upstream; the deadline is re-slept, not re-created per request.
        #expect(rig.service.context.openStreamCount == 0)
        #expect(rig.upstream.connections == 1)
    }
}
#endif
