import Foundation
import Testing
import WheelhouseKit
@testable import WheelhouseMac

/// The widget snapshot writer with a recording sink: nothing here touches the app group, a real container or a cluster.
@Suite("Widget snapshot writer")
@MainActor
struct WidgetSnapshotWriterTests {
    final class Box: @unchecked Sendable {
        var snapshot = FleetSnapshot(clusters: [FleetSnapshot.ClusterEntry(id: "a", name: "alpha", environment: .production, status: .healthy)])
        var written: [FleetSnapshot] = []
        var reloads = 0
        var date = Date(timeIntervalSince1970: 1_000_000)
        var failWrites = false
    }

    struct SinkError: Error {}

    private func writer(_ box: Box) -> MacWidgetSnapshotWriter {
        MacWidgetSnapshotWriter(
            make: { _ in var s = box.snapshot; s.generatedAt = box.date; return s },
            write: { if box.failWrites { throw SinkError() }; box.written.append($0) },
            reload: { box.reloads += 1 },
            now: { box.date })
    }

    @Test("The first check writes and reloads the timelines")
    func firstWrite() {
        let box = Box()
        let w = writer(box)
        #expect(w.consider())
        #expect(box.written.count == 1)
        #expect(box.reloads == 1)
    }

    @Test("An unchanged fleet is not written again inside the heartbeat")
    func unchangedSkippedWithinHeartbeat() {
        let box = Box()
        let w = writer(box)
        w.consider()
        box.date += MacWidgetSnapshotWriter.heartbeat - 60
        #expect(!w.consider())
        #expect(box.written.count == 1)
    }

    @Test("An unchanged fleet is written again once the heartbeat is due, so the widget never goes stale")
    func heartbeatWrites() {
        let box = Box()
        let w = writer(box)
        w.consider()
        box.date += MacWidgetSnapshotWriter.heartbeat
        #expect(w.consider())
        #expect(box.written.count == 2)
        #expect(box.written[1].generatedAt > box.written[0].generatedAt)
    }

    @Test("A restart count changing alone is not a change")
    func restartsIgnored() {
        let box = Box()
        box.snapshot.clusters[0].failingPodList = [.init(name: "api", namespace: "shop", reason: "CrashLoopBackOff", restarts: 3)]
        let w = writer(box)
        w.consider()
        box.snapshot.clusters[0].failingPodList[0].restarts = 9
        box.date += MacWidgetSnapshotWriter.minimumInterval
        #expect(!w.consider())
    }

    @Test("Force skips the five-minute floor but never writes unchanged content")
    func forceSkipsFloorOnly() {
        let box = Box()
        let w = writer(box)
        w.consider()
        box.date += 10
        #expect(!w.consider(force: true))
        box.snapshot.clusters = []
        #expect(w.consider(force: true))
        #expect(box.written.last?.clusters.isEmpty == true)
    }

    @Test("Demo mode writes an empty snapshot, never the demo fleet")
    func demoWritesEmpty() {
        let box = Box()
        box.snapshot.isDemo = true
        let w = writer(box)
        #expect(w.consider())
        #expect(box.written[0].clusters.isEmpty)
        #expect(!box.written[0].isDemo)
    }

    @Test("The writer is handed the last written snapshot as the previous one")
    func previousPassedBack() {
        let box = Box()
        var seen: [FleetSnapshot?] = []
        let w = MacWidgetSnapshotWriter(make: { previous in seen.append(previous); return box.snapshot }, write: { box.written.append($0) },
                                        reload: {}, now: { box.date })
        w.consider()
        box.snapshot.clusters[0].status = .critical
        box.date += MacWidgetSnapshotWriter.minimumInterval
        w.consider()
        #expect(seen[0] == nil)
        #expect(seen[1]?.clusters.first?.status == .healthy)
    }

    @Test("A change inside five minutes waits, then goes out at the first check after the interval")
    func rateLimited() {
        let box = Box()
        let w = writer(box)
        w.consider()
        box.snapshot.clusters[0].status = .critical
        box.date += 120
        #expect(!w.consider())
        box.date += MacWidgetSnapshotWriter.minimumInterval
        #expect(w.consider())
        #expect(box.written.count == 2)
        #expect(box.written[1].clusters[0].status == .critical)
    }

    @Test("A failed write is retried and does not count as written")
    func failedWriteRetries() {
        let box = Box()
        let w = writer(box)
        box.failWrites = true
        #expect(!w.consider())
        #expect(w.writes == 0)
        #expect(box.reloads == 0)
        box.failWrites = false
        #expect(w.consider())
    }

    @Test("Only the generation time differing is not a change")
    func generationTimeIgnored() {
        var a = FleetSnapshot(clusters: [])
        var b = a
        a.generatedAt = Date(timeIntervalSince1970: 1)
        b.generatedAt = Date(timeIntervalSince1970: 2)
        #expect(MacWidgetSnapshotWriter.sameContent(a, b))
        b.isDemo = true
        #expect(!MacWidgetSnapshotWriter.sameContent(a, b))
    }

    @Test("The snapshot carries names, counts and fractions only: no secret or credential key")
    func noSecretFields() throws {
        let entry = FleetSnapshot.ClusterEntry(id: "a", name: "alpha", environment: .production, status: .warning, failingPods: 1, cpuFraction: 0.5,
                                               topIssue: "api CrashLoopBackOff", failingPodList: [.init(name: "api", namespace: "shop", reason: "CrashLoopBackOff", restarts: 4)])
        let data = try JSONEncoder().encode(FleetSnapshot(clusters: [entry]))
        let json = try #require(String(data: data, encoding: .utf8)).lowercased()
        for word in ["token", "secret", "password", "certificate", "kubeconfig", "server", "url"] { #expect(!json.contains(word), "\(word)") }
    }

    @Test("The snapshot survives the JSON encoding the store uses")
    func encodingRoundTrip() throws {
        let snapshot = FleetSnapshot(clusters: [FleetSnapshot.ClusterEntry(id: "a", name: "alpha", environment: .staging, status: .healthy)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(FleetSnapshot.self, from: encoder.encode(snapshot))
        #expect(MacWidgetSnapshotWriter.sameContent(back, snapshot))
    }

    @Test("The alert monitor reports every check to the writer hook")
    func monitorHook() async {
        let suite = "wh.widget.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(), defaults: defaults)
        let monitor = MacAlertMonitor(registry: registry, preferences: AppPreferences(defaults: defaults))
        var checks = 0
        monitor.didCheck = { checks += 1 }
        await monitor.tick()
        #expect(checks == 1)
    }

    @Test("Crow's Nest checks reach the writer, and the perf report publishes only when the gate is active")
    func fleetTickWiring() {
        let env = MacAppEnvironment.live()
        let box = Box()
        var published = 0
        env.wireFleetTick(snapshots: writer(box), publish: { published += 1 })
        env.fleet.didTick?()
        #expect(box.written.count == 1)
        #expect(published == (env.gateActive ? 1 : 0))
    }
}
