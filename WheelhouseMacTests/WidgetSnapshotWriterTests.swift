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
            make: { var s = box.snapshot; s.generatedAt = box.date; return s },
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

    @Test("An unchanged fleet is not written again, even long after the interval")
    func unchangedIsSkipped() {
        let box = Box()
        let w = writer(box)
        w.consider()
        box.date += 3_600
        #expect(!w.consider())
        #expect(box.written.count == 1)
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
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(),
                                       defaults: UserDefaults(suiteName: "wh.widget.tests") ?? .standard)
        let monitor = MacAlertMonitor(registry: registry, preferences: AppPreferences(defaults: UserDefaults(suiteName: "wh.widget.tests") ?? .standard))
        var checks = 0
        monitor.didCheck = { checks += 1 }
        await monitor.tick()
        #expect(checks == 1)
    }
}
