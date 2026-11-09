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
        // The exact bound is structural: 4 connections hold exactly 4 deadline tasks, started once and never again while idle (a polling
        // task or a repeating timer would keep starting them or keep waking). The rusage numbers above are the isolated measurement
        // (perf/baselines/M5a.json); this suite runs next to others in one process, so they only get a loose bound here.
        #expect(rig.service.context.idleTasksStarted == 4, "one deadline task per connection, none re-created while idle")
        #expect(with.interrupt <= base.interrupt + 5.0, "4 idle sessions added \(with.interrupt - base.interrupt) interrupt wakeups per second")
        #expect(with.idle <= base.idle + 5.0, "4 idle sessions added \(with.idle - base.idle) idle wakeups per second")
        clients.forEach { $0.close() }
    }

    @Test("the cost of the TLS handshake on the loopback leg (a new connection and its first request) is small and recorded")
    func handshakeCost() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let (_, token) = try await rig.open()
        let port = try #require(rig.service.port)
        let der = try #require(rig.service.context.tlsCertificateDER)
        var millis: [Double] = []
        for i in 0..<60 {
            let start = ContinuousClock.now
            let c = try await RawClient(port: port, certificateDER: der)
            try await c.send(rig.request("GET", "/version", token: token))
            _ = try #require(await c.readResponse())
            if i >= 5 { millis.append((ContinuousClock.now - start).microseconds / 1000) }
            c.close()
        }
        millis.sort()
        print("GANGWAY-HANDSHAKE new TLS connection + first request p50_ms=\(millis[millis.count / 2]) p95_ms=\(millis[millis.count * 95 / 100]) samples=\(millis.count)")
        #expect(millis[millis.count / 2] < 50)
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
        // 200 requests on one connection: one upstream, and ONE deadline task. The deadline is re-slept for the remainder, never re-created.
        #expect(rig.upstream.connections == 1)
        #expect(rig.service.context.idleTasksStarted == 1)
    }
}
#endif
