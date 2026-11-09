import Testing
import Foundation
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// The Mac side of local scanning, against a fake trivy that replays a small recorded-format report. Temporary home, no network.
@MainActor @Suite("Scan coordinator", .serialized)
struct ScanCoordinatorTests {
    private let report = """
    {"SchemaVersion":2,"ArtifactName":"x","Metadata":{"RepoDigests":[]},"Results":[{"Target":"t","Vulnerabilities":[
      {"VulnerabilityID":"CVE-2026-0001","PkgName":"openssl","InstalledVersion":"3.0.1","FixedVersion":"3.0.2","Severity":"HIGH"},
      {"VulnerabilityID":"CVE-2026-0002","PkgName":"zlib","InstalledVersion":"1.2","Severity":"LOW"}]}]}
    """

    private struct Env {
        let root: URL
        let paths: AppPaths
        let script: URL
        let log: URL
    }

    private func makeEnv(report: String) throws -> Env {
        let root = FileManager.default.temporaryDirectory.appending(path: "wh-scan-\(UUID().uuidString)", directoryHint: .isDirectory).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true)
        let paths = AppPaths(gateActive: true, bundleID: nil, home: root.appending(path: "home"), temporaryDirectory: root)
        let log = root.appending(path: "fake.log")
        let script = root.appending(path: "trivy")
        try Data(report.utf8).write(to: root.appending(path: "report.json"))
        let text = """
        #!/bin/sh
        here="$(cd "$(dirname "$0")" && pwd)"
        cache=""; prev=""
        for a in "$@"; do [ "$prev" = "--cache-dir" ] && cache="$a"; prev="$a"; done
        echo "RUN $*" >> "\(log.path)"
        for a in "$@"; do
          if [ "$a" = "--download-db-only" ]; then
            mkdir -p "$cache/db"; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '{"Version":2,"DownloadedAt":"%s"}' "$now" > "$cache/db/metadata.json"; exit 0
          fi
        done
        cat "$here/report.json"
        """
        try Data(text.utf8).write(to: script)
        chmod(script.path, 0o755)
        return Env(root: root, paths: paths, script: script, log: log)
    }

    private func demoSession() -> ClusterSession {
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(),
                                       defaults: UserDefaults(suiteName: "wh.scan.tests") ?? .standard)
        registry.enterDemoMode(persist: false)
        return registry.session(for: registry.clusters[0].id)!
    }

    private func waitIdle(_ c: ScanCoordinator, scanned: Int? = nil) async throws {
        for _ in 0..<200 {
            let p = c.progress
            if p.state == .idle, p.scanned > 0, scanned.map({ p.scanned >= $0 }) ?? true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the scan did not finish: \(c.progress)")
    }

    @Test func creatingTheCoordinatorTouchesNothing() throws {
        let env = try makeEnv(report: report)
        defer { try? FileManager.default.removeItem(at: env.root) }
        let c = ScanCoordinator(paths: env.paths, conditions: { ScanConditions() })
        #expect(c.progress.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: env.paths.root.appending(path: "survey.sqlite").path))     // no database until used
        #expect(c.source == .none)
    }

    @Test func aManualScanRunsAndStoresResultsOnBattery() async throws {
        let env = try makeEnv(report: report)
        defer { try? FileManager.default.removeItem(at: env.root) }
        UserDefaults.standard.set(env.script.path, forKey: SurveyScanSettings.trivyPath)
        defer { UserDefaults.standard.removeObject(forKey: SurveyScanSettings.trivyPath) }
        let c = ScanCoordinator(paths: env.paths, conditions: { ScanConditions(onBattery: true) })      // the test hook: on battery
        await c.prepare()
        #expect(c.source == .configured(env.script))
        await c.scan(sessions: [demoSession()], trigger: .manual)                                     // manual overrides the battery rule
        try await waitIdle(c)
        #expect(c.progress.scanned > 0 && c.progress.failed == 0)
        #expect(c.scans.count == c.progress.scanned)
        #expect(c.scans.allSatisfy { $0.vulnerabilities.count == 2 && $0.dbVersion.hasPrefix("2") })
        #expect(FileManager.default.fileExists(atPath: env.paths.root.appending(path: "survey.sqlite").path))
        #expect(!c.workloadsByImage.isEmpty)
        // Scans are by image only: no cluster credentials are read without the opt-in.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: env.paths.sessions.path)) ?? []
        #expect(left.filter { $0.hasPrefix("scan-") }.isEmpty)
    }

    @Test func aScheduledScanPausesOnBatteryAndRunsNothing() async throws {
        let env = try makeEnv(report: report)
        defer { try? FileManager.default.removeItem(at: env.root) }
        UserDefaults.standard.set(env.script.path, forKey: SurveyScanSettings.trivyPath)
        defer { UserDefaults.standard.removeObject(forKey: SurveyScanSettings.trivyPath) }
        let c = ScanCoordinator(paths: env.paths, conditions: { ScanConditions(onBattery: true) })
        await c.prepare()
        #expect(c.wouldPauseOnEnergy == .onBattery)
        await c.scan(sessions: [demoSession()], trigger: .scheduled)
        for _ in 0..<100 { if case .paused = c.progress.state { break }; try await Task.sleep(for: .milliseconds(50)) }
        #expect(c.progress.state == .paused(.onBattery))
        #expect(c.progress.queued > 0)
        #expect(!FileManager.default.fileExists(atPath: env.log.path))                                 // trivy was never started
        await c.clearQueue()
        #expect(c.progress.queued == 0)
    }

    @Test func aRestoredQueueWaitsForTheUser() async throws {
        let env = try makeEnv(report: report)
        defer { try? FileManager.default.removeItem(at: env.root) }
        UserDefaults.standard.set(env.script.path, forKey: SurveyScanSettings.trivyPath)
        defer { UserDefaults.standard.removeObject(forKey: SurveyScanSettings.trivyPath) }
        try FileManager.default.createDirectory(at: env.paths.root, withIntermediateDirectories: true)
        let seed = try SurveyStore(url: env.paths.root.appending(path: "survey.sqlite"))
        try await seed.enqueue(image: "docker.io/library/nginx:1.27", isMutable: true, clusters: [], trigger: .scheduled)
        let c = ScanCoordinator(paths: env.paths, conditions: { ScanConditions() })
        await c.prepare()
        try await Task.sleep(for: .milliseconds(400))
        #expect(c.progress.queued == 1 && c.progress.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: env.log.path))
        await c.resume(manual: true)
        try await waitIdle(c)
        #expect(c.progress.scanned == 1)
    }

    @Test func staleScanFoldersAreSweptWhenTheCoordinatorFirstOpens() async throws {
        let env = try makeEnv(report: report)
        defer { try? FileManager.default.removeItem(at: env.root) }
        let stale = env.paths.sessions.appending(path: "scan-LEFTOVER")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let c = ScanCoordinator(paths: env.paths, conditions: { ScanConditions() })
        await c.prepare()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func noPinnedReleaseMeansNoDownloadOffer() {
        let c = ScanCoordinator(paths: AppPaths(gateActive: true, bundleID: nil), conditions: { ScanConditions() }, pin: .unavailable("none"))
        #expect(c.managed.consent == nil)
    }
}

@MainActor @Suite("Vulnerabilities model", .serialized)
struct VulnerabilityModelTests {
    private func demoSession() -> ClusterSession {
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(),
                                       defaults: UserDefaults(suiteName: "wh.vuln.tests") ?? .standard)
        registry.enterDemoMode(persist: false)
        return registry.session(for: registry.clusters[0].id)!
    }

    @Test func nothingRunsUntilTheTabIsVisibleAndAClusterWithoutTheOperatorStartsNothing() async throws {
        let model = VulnerabilityModel(sessions: [demoSession()])
        #expect(model.runningStoreCount == 0 && !model.isWatching)
        model.retain()
        #expect(model.isWatching)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.runningStoreCount == 0)                              // the demo cluster has no Trivy Operator
        #expect(model.clusters.allSatisfy { !$0.detection.hasVulnerabilityReports })
        model.release()
        #expect(!model.isWatching)
    }

    @Test func aRiskChangedBeforeTheDatabaseOpensIsKeptAndSeveralQuickAcceptsAllPersist() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-hub2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appending(path: "risks.json")
        let hub = SurveyHub(riskFile: json)
        hub.acceptCVE("CVE-2026-1", clusterID: "a", reason: "r", days: 30)          // before attach: written to the JSON file
        let store = try SurveyStore(url: dir.appending(path: "survey.sqlite"))
        await hub.attach(store: store)
        #expect(hub.risks.risks.count == 1)
        for c in ["b", "c", "d"] { hub.acceptCVE("CVE-2026-2", clusterID: c, reason: "r", days: 30) }
        try await Task.sleep(for: .milliseconds(400))
        let stored = try await store.acceptedRisks()
        #expect(stored.risks.count == 4)
    }

    @Test func acceptedRisksMoveIntoTheDatabaseOnceAndSurviveAHubRestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-hub-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appending(path: "risks.json")
        let finding = SecurityFinding(ruleID: "WH-W07", severity: .low, clusterID: "c", namespace: "n", object: FindingObject(kind: "Deployment", namespace: "n", name: "d"),
                                      title: "t", evidence: [])
        let old = SurveyHub(riskFile: json)
        old.accept(finding, scope: .finding, reason: "legacy", days: 30)
        let store = try SurveyStore(url: dir.appending(path: "survey.sqlite"))
        let hub = SurveyHub(riskFile: json)
        await hub.attach(store: store)
        #expect(hub.risks.risks.count == 1)
        hub.acceptCVE("CVE-2026-1", clusterID: "c", reason: "r", days: 30)
        hub.removeRisk(hub.risks.risks.first { $0.cveID == nil }!.id)
        try await Task.sleep(for: .milliseconds(300))
        let again = SurveyHub(riskFile: json)
        await again.attach(store: store)
        #expect(again.risks.risks.count == 1 && again.risks.status(ofCVE: "CVE-2026-1", cluster: "c").isAccepted)   // the removed one did not come back
        #expect(FileManager.default.fileExists(atPath: json.path))
    }
}
