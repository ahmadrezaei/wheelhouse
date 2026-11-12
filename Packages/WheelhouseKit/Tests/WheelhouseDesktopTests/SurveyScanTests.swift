#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// A fake trivy (Fixtures/trivy/fake-trivy.sh) that replays recorded-format JSON, in a scratch folder.
struct FakeTrivy {
    let scratch: Scratch
    let cli: TrivyCLI
    let options: TrivyOptions
    let paths: AppPaths
    var log: String { (try? String(contentsOf: options.cacheDirectory.appending(path: "fake-trivy.log"), encoding: .utf8)) ?? "" }

    init() throws {
        scratch = try Scratch()
        let dir = try scratch.dir("trivy-bin")
        for name in ["fake-trivy.sh", "image-report.json"] {
            let src = try #require(Bundle.module.url(forResource: "Fixtures/trivy/\(name.split(separator: ".")[0])", withExtension: String(name.split(separator: ".")[1])))
            try FileManager.default.copyItem(at: src, to: dir.appending(path: name))
        }
        chmod(dir.appending(path: "fake-trivy.sh").path, 0o755)
        let home = try scratch.home()
        paths = AppPaths(gateActive: false, bundleID: AppPaths.releaseBundleID, home: home, temporaryDirectory: scratch.root)
        options = TrivyOptions(cacheDirectory: try scratch.dir("trivy-cache"))
        cli = TrivyCLI(executable: dir.appending(path: "fake-trivy.sh"), environment: EnvironmentBuilder(snapshot: nil, paths: paths, home: home))
    }

    func seedDB(downloadedAt: Date = Date()) throws {
        try FileManager.default.createDirectory(at: options.cacheDirectory.appending(path: "db"), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: downloadedAt)
        try Data(#"{"Version":2,"DownloadedAt":"\#(stamp)"}"#.utf8).write(to: options.cacheDirectory.appending(path: "db/metadata.json"))
    }
}

@Suite("TrivyCLI", .serialized)
struct TrivyCLITests {
    @Test func scanArgvIsPinned() {
        let o = TrivyOptions(cacheDirectory: URL(fileURLWithPath: "/c"), architecture: "arm64")
        #expect(TrivyCLI.scanArguments(target: "docker.io/library/nginx:latest", options: o) == [
            "image", "--format", "json", "--quiet", "--scanners", "vuln", "--skip-db-update", "--skip-java-db-update", "--image-src", "remote", "--cache-dir", "/c", "--timeout", "10m",
            "--parallel", "1", "--platform", "linux/arm64", "--", "docker.io/library/nginx:latest",
        ])
        var mirror = o
        mirror.dbRepository = "mirror.example.com/trivy-db"
        mirror.javaDBRepository = "mirror.example.com/trivy-java-db"
        mirror.architecture = "amd64"
        let args = TrivyCLI.scanArguments(target: "x/y:1", options: mirror)
        #expect(args.contains("linux/amd64") && args.contains("--db-repository") && args.contains("--java-db-repository"))
        #expect(args.suffix(2) == ["--", "x/y:1"])
        #expect(TrivyCLI.downloadDBArguments(options: o) == ["image", "--download-db-only", "--quiet", "--cache-dir", "/c"])
        #expect(TrivyCLI.downloadDBArguments(options: mirror, java: true) == ["image", "--download-java-db-only", "--quiet", "--cache-dir", "/c", "--java-db-repository", "mirror.example.com/trivy-java-db"])
    }

    @Test func specUsesTheRightQosTimeoutAndLimits() throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        let ref = try #require(ImageReference("registry.example.com/team/web:1"))
        let manual = fake.cli.scanSpec(image: ref, options: fake.options, trigger: .manual, dockerConfig: nil, cloud: [:])
        let scheduled = fake.cli.scanSpec(image: ref, options: fake.options, trigger: .scheduled, dockerConfig: nil, cloud: [:])
        #expect(manual.qos == .utility && scheduled.qos == .background)
        #expect(manual.timeout > .seconds(600))
        #expect(manual.stdoutLimit >= 128 << 20)
        #expect(manual.environment["TRIVY_NO_PROGRESS"] == "true")
    }

    @Test func replaysARecordedScan() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        let parsed = try await fake.cli.scan(#require(ImageReference("registry.example.com/team/web:1")), options: fake.options, trigger: .manual)
        #expect(parsed.vulnerabilities.count == 4)
        #expect(parsed.vulnerabilities.first?.cveID == "CVE-2026-0001")
        #expect(parsed.digest == "sha256:" + String(repeating: "1", count: 64))
        #expect(fake.log.contains("--skip-db-update"))
        #expect(try await fake.cli.version() == "Version: 0.99.0")
    }

    @Test func classifyDoesNotMistakeADigestForAnAuthFailure() {
        let noise = "FATAL scan error: sha256:a401b2c3 timestamp 12:00:01.401Z failed"
        let reg = "registry.example.com"
        #expect(TrivyCLI.classify(stderr: noise, code: 1, registry: reg) == .failed(code: 1, message: noise))
        #expect(TrivyCLI.classify(stderr: "GET https://registry.example.com/v2/x: 401 Unauthorized", code: 1, registry: reg) == .unauthorized(registry: reg))
        // Markers of real registries: ECR and GHCR/Docker Hub style refusals.
        #expect(TrivyCLI.classify(stderr: "Error: no basic auth credentials", code: 1, registry: reg) == .unauthorized(registry: reg))
        #expect(TrivyCLI.classify(stderr: "pull access denied for x, repository does not exist or may require authorization: denied: requested access to the resource is denied", code: 1, registry: reg) == .unauthorized(registry: reg))
        // A local permission error is not a registry refusal.
        #expect(TrivyCLI.classify(stderr: "open /x: permission denied", code: 1, registry: reg) == .failed(code: 1, message: "open /x: permission denied"))
        // The Java DB: its own registry may answer 401; that is a database problem, never "sign in to the image registry".
        #expect(TrivyCLI.classify(stderr: "FATAL --skip-java-db-update cannot be specified with the first run", code: 1, registry: reg) == .javaDatabaseMissing)
        // An unknown failure never prints "trivy failed:" with nothing after it.
        #expect(TrivyCLI.classify(stderr: "", code: 1, registry: reg) == .failed(code: 1, message: "exit code 1 and no error text"))
        #expect(TrivyCLI.classify(stderr: "boom while pulling registry.example.com/x", code: 2, registry: reg) == .failed(code: 2, message: "boom while pulling registry.example.com/x (registry registry.example.com)"))
    }

    @Test func mapsFailures() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        await #expect(throws: TrivyError.unauthorized(registry: "registry.example.com")) {
            _ = try await fake.cli.scan(#require(ImageReference("registry.example.com/unauth:1")), options: fake.options, trigger: .manual)
        }
        await #expect(throws: TrivyError.unreadableOutput) {
            _ = try await fake.cli.scan(#require(ImageReference("registry.example.com/broken:1")), options: fake.options, trigger: .manual)
        }
    }

    @Test func theCredentialEnvironmentIsScrubbed() throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        let env = fake.cli.processEnvironment(dockerConfig: URL(fileURLWithPath: "/tmp/scan-x"), cloud: ["AWS_PROFILE": "p"])
        #expect(env["DOCKER_CONFIG"] == "/tmp/scan-x" && env["AWS_PROFILE"] == "p")
        #expect(env["ANTHROPIC_API_KEY"] == nil && env["KUBECONFIG"] == nil)
        // While the development gate is on no real credentials are reachable: no cloud environment, an empty docker config.
        let isolated = AppPaths(gateActive: true, bundleID: nil, home: fake.paths.home, temporaryDirectory: fake.scratch.root)
        let dev = TrivyCLI(executable: fake.cli.executable, environment: EnvironmentBuilder(snapshot: nil, paths: isolated, home: isolated.home))
        let devEnv = dev.processEnvironment(dockerConfig: nil, cloud: ["AWS_PROFILE": "p"])
        #expect(devEnv["AWS_PROFILE"] == nil)
        #expect(devEnv["HOME"] != isolated.home.path && devEnv["HOME"]?.contains("trivy-home") == true)
        #expect(devEnv["AWS_EC2_METADATA_DISABLED"] == "true")
        #expect(devEnv["DOCKER_CONFIG"]?.contains("empty-docker-config") == true)
        #expect(TrivyCLI.defaultCacheDirectory(paths: isolated).path.contains("Caches/com.ahmadrezaei.wheelhouse.mac.debug/trivy"))
        #expect(TrivyCLI.defaultCacheDirectory(paths: fake.paths).path.hasSuffix("Library/Caches/trivy"))
    }
}

@Suite("Pull-secret DOCKER_CONFIG", .serialized)
struct PullSecretConfigTests {
    private func config(for registry: String) throws -> Data {
        let secret = #"{"auths":{"\#(registry)":{"username":"u","password":"p"},"other.example.com":{"auth":"b3Ro"}}}"#
        return try #require(DockerConfigBuilder.minimalConfig(fromDockerConfigJSON: Data(secret.utf8), registry: registry))
    }

    @Test func theDirectoryExistsDuringTheScanAndIsGoneAfter() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        let sessions = fake.paths.sessions
        let config = try config(for: "registry.example.com")
        let cli = fake.cli, options = fake.options
        let ref = try #require(ImageReference("registry.example.com/team/web:1"))
        let used = try await ScanDockerConfig.with(config: config, in: sessions) { dir -> URL in
            _ = try await cli.scan(ref, options: options, trigger: .manual, dockerConfig: dir)
            return dir
        }
        // Proof it existed while trivy ran: the fake recorded its mode and content.
        let log = fake.log
        #expect(log.contains("DOCKER_CONFIG=\(used.path)"))
        #expect(log.contains("DIRMODE 700") && log.contains("FILEMODE 600"))
        #expect(log.contains("registry.example.com") && !log.contains("other.example.com"))
        #expect(!log.contains("credsStore"))
        #expect(!FileManager.default.fileExists(atPath: used.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sessions.path).isEmpty)
    }

    @Test func theDirectoryIsGoneAfterAFailedScan() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        let cli = fake.cli, options = fake.options
        let ref = try #require(ImageReference("registry.example.com/unauth:1"))
        var seen: URL?
        do {
            _ = try await ScanDockerConfig.with(config: try config(for: "registry.example.com"), in: fake.paths.sessions) { dir -> Int in
                _ = try await cli.scan(ref, options: options, trigger: .manual, dockerConfig: dir)
                return 1
            }
            Issue.record("expected a failure")
        } catch { seen = fake.paths.sessions }
        #expect(try FileManager.default.contentsOfDirectory(atPath: #require(seen).path).isEmpty)
    }

    @Test func theDirectoryIsGoneAfterACancelledScan() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        let cli = fake.cli, options = fake.options
        let sessions = fake.paths.sessions
        let config = try config(for: "registry.example.com")
        let ref = try #require(ImageReference("registry.example.com/slow:1"))
        let task = Task {
            try await ScanDockerConfig.with(config: config, in: sessions) { dir -> Int in
                _ = try await cli.scan(ref, options: options, trigger: .manual, dockerConfig: dir)
                return 1
            }
        }
        for _ in 0..<100 where ((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try !FileManager.default.contentsOfDirectory(atPath: sessions.path).isEmpty)       // present while the scan runs
        task.cancel()
        _ = await task.result
        #expect(try FileManager.default.contentsOfDirectory(atPath: sessions.path).isEmpty)
    }

    @Test func staleDirectoriesAreSweptAtFirstUse() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let sessions = try scratch.dir("sessions")
        try FileManager.default.createDirectory(at: sessions.appending(path: "scan-OLD"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions.appending(path: "shell-keep"), withIntermediateDirectories: true)
        #expect(ScanDockerConfig.sweepStale(in: sessions) == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sessions.path) == ["shell-keep"])
    }
}

/// A runner that records calls and can block, for the queue tests.
private actor RecordingRunner: ScanRunner {
    var scanned: [String] = []
    var triggers: [ScanTrigger] = []
    var blockOn: String?
    var started: [String] = []

    func setBlock(_ image: String?) { blockOn = image }

    func scan(_ item: ScanQueueItem, trigger: ScanTrigger) async throws -> ImageScanResult {
        started.append(item.image)
        triggers.append(trigger)
        if item.image == blockOn { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        scanned.append(item.image)
        return ImageScanResult(image: item.image, digest: nil, isMutable: true, dbVersion: "2", scannedAt: Date(), vulnerabilities: [])
    }
}

/// Counts how many scans overlap. A cancelled scan takes a moment to "exit", like a child process that must be killed.
private actor OverlapRunner: ScanRunner {
    var active = 0
    var maxActive = 0
    var started = 0
    func scan(_ item: ScanQueueItem, trigger: ScanTrigger) async throws -> ImageScanResult {
        active += 1
        started += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        do { try await Task.sleep(for: .milliseconds(started == 1 ? 5_000 : 50)) } catch {
            try? await Task.sleep(for: .milliseconds(300))          // the child is still exiting
            throw error
        }
        return ImageScanResult(image: item.image, digest: nil, isMutable: true, dbVersion: "2", scannedAt: Date(), vulnerabilities: [])
    }
}

private final class FakeObserver: ScanConditionsObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts = 0, _stops = 0, _active = false
    var starts: Int { lock.withLock { _starts } }
    var active: Bool { lock.withLock { _active } }
    func start(_ onChange: @escaping @Sendable () -> Void) { lock.withLock { _starts += 1; _active = true } }
    func stop() { lock.withLock { _stops += 1; _active = false } }
}

private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    var get: T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}

private func waitFor(_ what: String = "", _ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("timed out waiting for \(what)")
}

@Suite("Scan queue", .serialized)
struct ScanQueueTests {
    private func makeQueue(_ scratch: Scratch, runner: RecordingRunner, conditions: Box<ScanConditions>, observer: FakeObserver? = nil,
                           file: String = "survey.sqlite") async throws -> (ScanQueue, SurveyStore) {
        let store = try SurveyStore(url: scratch.root.appending(path: file))
        let queue = ScanQueue(store: store, runner: runner, conditions: { conditions.get }, observer: observer)
        return (queue, store)
    }

    private func images(_ n: Int) -> [(image: String, isMutable: Bool, clusters: [String])] {
        (0..<n).map { (image: "registry.example.com/app\($0):1", isMutable: true, clusters: ["c1"]) }
    }

    @Test func twentyImagesRunOneAtATimeAndFinish() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let runner = RecordingRunner()
        let (queue, store) = try await makeQueue(scratch, runner: runner, conditions: Box(ScanConditions()))
        try await queue.enqueue(images: images(20), trigger: .manual)
        await queue.start(trigger: .manual)
        try await waitFor("20 scans") { await queue.progress.scanned == 20 }
        try await waitFor("idle") { await queue.progress.state == .idle }
        #expect(await runner.scanned.count == 20)
        #expect(try await store.queueCount() == 0)
        #expect(await runner.triggers.allSatisfy { $0 == .manual })
        #expect(await queue.progress.eta == nil)
    }

    @Test func aScheduledScanPausesOnBatteryAndResumesOnPower() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let runner = RecordingRunner()
        let conditions = Box(ScanConditions(onBattery: true))          // the test hook: the Mac is on battery
        let (queue, store) = try await makeQueue(scratch, runner: runner, conditions: conditions)
        try await queue.enqueue(images: images(3), trigger: .scheduled)
        await queue.start(trigger: .scheduled)
        try await waitFor("pause") { await queue.progress.state == .paused(.onBattery) }
        #expect(await runner.started.isEmpty)                           // nothing ran
        #expect(try await store.queueCount() == 3)                      // nothing was lost
        conditions.set(ScanConditions(onBattery: false))
        await queue.conditionsChanged()
        try await waitFor("done") { await queue.progress.scanned == 3 }
    }

    @Test func manualOverridesBatteryLowPowerAndThermal() async throws {
        for c in [ScanConditions(onBattery: true), ScanConditions(lowPowerMode: true), ScanConditions(thermalState: .critical)] {
            let scratch = try Scratch()
            defer { scratch.cleanup() }
            let runner = RecordingRunner()
            let (queue, _) = try await makeQueue(scratch, runner: runner, conditions: Box(c))
            try await queue.enqueue(images: images(2), trigger: .scheduled)
            await queue.start(trigger: .manual)
            try await waitFor("manual run") { await queue.progress.scanned == 2 }
        }
        for c in [ScanConditions(onBattery: true), ScanConditions(lowPowerMode: true), ScanConditions(thermalState: .serious)] {
            let scratch = try Scratch()
            defer { scratch.cleanup() }
            let runner = RecordingRunner()
            let (queue, _) = try await makeQueue(scratch, runner: runner, conditions: Box(c))
            try await queue.enqueue(images: images(1), trigger: .scheduled)
            await queue.start(trigger: .scheduled)
            try await waitFor("pause") { if case .paused = await queue.progress.state { true } else { false } }
            #expect(await runner.started.isEmpty)
        }
    }

    @Test func conditionsTurningBadMidScanPutTheImageBack() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let runner = RecordingRunner()
        await runner.setBlock("registry.example.com/app0:1")
        let conditions = Box(ScanConditions())
        let (queue, store) = try await makeQueue(scratch, runner: runner, conditions: conditions)
        try await queue.enqueue(images: images(2), trigger: .scheduled)
        await queue.start(trigger: .scheduled)
        try await waitFor("first image running") { await runner.started.count == 1 }
        conditions.set(ScanConditions(onBattery: true))
        await queue.conditionsChanged()
        try await waitFor("paused") { await queue.progress.state == .paused(.onBattery) }
        #expect(await queue.progress.failed == 0)                         // not a failure
        #expect(try await store.queue().first?.image == "registry.example.com/app0:1")     // back at the head
        #expect(try await store.queueCount() == 2)
        await runner.setBlock(nil)
        conditions.set(ScanConditions())
        await queue.conditionsChanged()
        try await waitFor("both done") { await queue.progress.scanned == 2 }
    }

    @Test func aRestoredQueueNeverStartsByItself() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let store = try SurveyStore(url: scratch.root.appending(path: "survey.sqlite"))
        try await store.enqueue(image: "registry.example.com/app:1", isMutable: true, clusters: [], trigger: .scheduled)
        let runner = RecordingRunner()
        let observer = FakeObserver()
        let queue = ScanQueue(store: store, runner: runner, conditions: { ScanConditions() }, observer: observer)
        await queue.restore()
        try await Task.sleep(for: .milliseconds(300))
        let restored = await queue.progress
        #expect(restored.queued == 1 && restored.state == .idle)
        #expect(await runner.started.isEmpty)
        #expect(observer.starts == 0)                                        // an idle queue holds no observers
        await queue.start(trigger: .manual)
        try await waitFor("resume") { await queue.progress.scanned == 1 }
    }

    @Test func observersExistOnlyWhileImagesWaitAndTheUserHasNotPaused() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let runner = RecordingRunner()
        await runner.setBlock("registry.example.com/app0:1")
        let observer = FakeObserver()
        let (queue, _) = try await makeQueue(scratch, runner: runner, conditions: Box(ScanConditions()), observer: observer)
        #expect(!observer.active)
        try await queue.enqueue(images: images(2), trigger: .scheduled)
        #expect(!observer.active)
        await queue.start(trigger: .scheduled)
        try await waitFor("observing") { observer.active }
        await queue.pause()
        try await waitFor("user paused") { await queue.progress.state == .userPaused }
        #expect(!observer.active)
        await runner.setBlock(nil)
        await queue.resume(trigger: .scheduled)
        try await waitFor("finished \(await queue.progress)") { await queue.progress.scanned == 2 }
        try await waitFor("observer released") { !observer.active }
    }

    @Test func aFailedImageIsRecordedAndTheRunContinues() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        struct Failing: ScanRunner {
            func scan(_ item: ScanQueueItem, trigger: ScanTrigger) async throws -> ImageScanResult {
                if item.image.contains("bad") { throw TrivyError.unauthorized(registry: "registry.example.com") }
                return ImageScanResult(image: item.image, digest: nil, isMutable: true, dbVersion: "2", scannedAt: Date(), vulnerabilities: [])
            }
        }
        let store = try SurveyStore(url: scratch.root.appending(path: "survey.sqlite"))
        let queue = ScanQueue(store: store, runner: Failing(), conditions: { ScanConditions() })
        try await queue.enqueue(images: [(image: "registry.example.com/bad:1", isMutable: true, clusters: []), (image: "registry.example.com/ok:1", isMutable: true, clusters: [])], trigger: .manual)
        await queue.start(trigger: .manual)
        try await waitFor("done") { let p = await queue.progress; return p.state == .idle && p.scanned == 1 }
        #expect(await queue.progress.failed == 1)
        #expect(await queue.progress.lastError?.contains("registry.example.com") == true)
    }

    @Test func pauseThenResumeNeverRunsTwoScansAtOnce() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let runner = OverlapRunner()
        let store = try SurveyStore(url: scratch.root.appending(path: "survey.sqlite"))
        let queue = ScanQueue(store: store, runner: runner, conditions: { ScanConditions() })
        try await queue.enqueue(images: images(2), trigger: .manual)
        await queue.start(trigger: .manual)
        try await waitFor("first running") { await runner.started >= 1 }
        await queue.pause()
        await queue.resume(trigger: .manual)                           // at once: the cancelled child is still exiting
        try await waitFor("both done") { await queue.progress.scanned == 2 }
        #expect(await runner.maxActive == 1)
        #expect(await queue.progress.failed == 0)
    }

    @Test func theArchitectureComesFromTheQueueItem() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let store = try SurveyStore(url: scratch.root.appending(path: "survey.sqlite"))
        try await store.enqueue(image: "registry.example.com/app:1", isMutable: true, clusters: ["c"], trigger: .manual, architecture: "arm64")
        try await store.enqueue(image: "registry.example.com/other:1", isMutable: true, clusters: ["c"], trigger: .manual)
        let items = try await store.queue()
        #expect(items[0].architecture == "arm64" && items[1].architecture == nil)
    }

    @Test func anIdleQueueRegistersNoPeriodicTask() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let (queue, _) = try await makeQueue(scratch, runner: RecordingRunner(), conditions: Box(ScanConditions()))
        await queue.restore()
        #expect(await queue.progress.state == .idle)
        #expect(await !queue.isObserving)
    }
}

@Suite("Trivy runner with the fake trivy", .serialized)
struct TrivyScanRunnerTests {
    @Test func downloadsTheDBOnceReusesResultsAndTriesTheNextCluster() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        let store = try SurveyStore(url: fake.scratch.root.appending(path: "survey.sqlite"))
        let runner = TrivyScanRunner(cli: fake.cli, options: fake.options, store: store, paths: fake.paths)
        let digest = "sha256:" + String(repeating: "1", count: 64)
        let item = ScanQueueItem(id: 1, image: "registry.example.com/team/web@\(digest)", isMutable: false, clusters: ["c1"])
        let first = try await runner.scan(item, trigger: .manual)
        #expect(first.vulnerabilities.count == 4 && first.dbVersion.hasPrefix("2") && first.digest == digest)
        #expect(fake.log.contains("--download-db-only"))                       // no DB yet: downloaded because a scan was requested
        let before = fake.log.components(separatedBy: "ARGS image --format").count
        _ = try await runner.scan(item, trigger: .manual)                      // same digest, same DB version: no process
        #expect(fake.log.components(separatedBy: "ARGS image --format").count == before)
        #expect(try await store.allScans().count == 1)
        // A fresh DB is not downloaded again.
        let dbCalls = fake.log.components(separatedBy: "--download-db-only").count
        let other = ScanQueueItem(id: 2, image: "registry.example.com/team/other:1", isMutable: true, clusters: ["c1"])
        _ = try await runner.scan(other, trigger: .manual)
        #expect(fake.log.components(separatedBy: "--download-db-only").count == dbCalls)
    }

    @Test func unauthorizedTriesEachClusterThenReportsSignIn() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        try fake.seedDB()
        let store = try SurveyStore(url: fake.scratch.root.appending(path: "survey.sqlite"))
        let tried = Box<[String]>([])
        let runner = TrivyScanRunner(cli: fake.cli, options: fake.options, store: store, paths: fake.paths,
                                     cloudEnvironment: { c in tried.set(tried.get + [c]); return [:] })
        let item = ScanQueueItem(id: 1, image: "registry.example.com/unauth:1", isMutable: true, clusters: ["c1", "c2"])
        await #expect(throws: TrivyError.unauthorized(registry: "registry.example.com")) { _ = try await runner.scan(item, trigger: .manual) }
        #expect(tried.get == ["c1", "c2"])
    }

    @Test func aPullSecretRunLeavesNoDirectoryBehind() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        try fake.seedDB()
        let store = try SurveyStore(url: fake.scratch.root.appending(path: "survey.sqlite"))
        let secret = #"{"auths":{"registry.example.com":{"auth":"dTpw"}}}"#
        let runner = TrivyScanRunner(cli: fake.cli, options: fake.options, store: store, paths: fake.paths,
                                     pullSecretConfig: { _, ref in DockerConfigBuilder.minimalConfig(fromDockerConfigJSON: Data(secret.utf8), registry: ref.registry) })
        let item = ScanQueueItem(id: 1, image: "registry.example.com/team/web:1", isMutable: true, clusters: ["c1"])
        _ = try await runner.scan(item, trigger: .manual)
        #expect(fake.log.contains("DIRMODE 700"))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: fake.paths.sessions.path)) ?? []
        #expect(left.isEmpty)
    }
}

@Suite("survey.sqlite", .serialized)
struct SurveyStoreTests {
    @Test func scansRoundTripAndTheFileIsPrivate() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = scratch.root.appending(path: "sub/survey.sqlite")
        let store = try SurveyStore(url: url)
        let scan = ImageScanResult(image: "r/a:1", digest: nil, isMutable: true, dbVersion: "2", scannedAt: Date(timeIntervalSince1970: 1_000),
                                   vulnerabilities: [ImageVulnerability(cveID: "CVE-1", severity: .high, package: "p", installedVersion: "1", fixedVersion: "2")])
        try await store.save(scan)
        #expect(try await store.scan(id: "r/a:1") == scan)
        #expect(try await store.scan(id: "missing") == nil)
        #expect(try await store.userVersion() == SurveyStore.schemaVersion)
        var st = stat()
        stat(url.path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        try await store.prune(olderThan: 10, now: Date(timeIntervalSince1970: 2_000))
        #expect(try await store.allScans().isEmpty)
        // Reopening keeps the data and the version.
        let again = try SurveyStore(url: url)
        #expect(try await again.userVersion() == SurveyStore.schemaVersion)
    }

    @Test func legacyRisksImportOnceAndRemovedRisksStayRemoved() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let legacy = scratch.root.appending(path: "survey-accepted-risks.json")
        var book = AcceptedRiskBook()
        let f = SecurityFinding(ruleID: "WH-W01", severity: .critical, clusterID: "c", namespace: "n", object: FindingObject(kind: "Deployment", namespace: "n", name: "d"), title: "t", evidence: [])
        book.accept(f, scope: .finding, reason: "legacy", days: 30)
        try AcceptedRiskStorage.save(book, to: legacy)
        let store = try SurveyStore(url: scratch.root.appending(path: "survey.sqlite"))
        #expect(try await store.importLegacyRisksOnce(from: legacy))
        #expect(try await store.acceptedRisks().risks.count == 1)
        try await store.saveAcceptedRisks(AcceptedRiskBook())             // the user removed the last risk
        #expect(try await !store.importLegacyRisksOnce(from: legacy))
        #expect(try await store.acceptedRisks().risks.isEmpty)           // it did not come back
        #expect(FileManager.default.fileExists(atPath: legacy.path))     // the file is left in place
    }

    @Test func cveRisksAndPullSecretOptInPersist() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = scratch.root.appending(path: "survey.sqlite")
        let store = try SurveyStore(url: url)
        var book = AcceptedRiskBook()
        book.acceptCVE("CVE-2026-1", clusterID: "c1", reason: "r", days: 30)
        try await store.saveAcceptedRisks(book)
        #expect(try await store.usesPullSecrets(clusterID: "c1") == false)      // off by default
        try await store.setUsesPullSecrets(true, clusterID: "c1")
        let again = try SurveyStore(url: url)
        #expect(try await again.acceptedRisks().status(ofCVE: "CVE-2026-1", cluster: "c1").isAccepted)
        #expect(try await again.usesPullSecrets(clusterID: "c1"))
        try await again.setUsesPullSecrets(false, clusterID: "c1")
        #expect(try await !again.usesPullSecrets(clusterID: "c1"))
    }

    @Test func aFileThatIsNotADatabaseFailsToOpen() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let bad = try scratch.write("survey.sqlite", String(repeating: "not sqlite ", count: 200))
        #expect(throws: SurveyStoreError.self) { _ = try SurveyStore(url: bad) }
    }
}

@Suite("Managed Trivy download", .serialized)
struct ManagedTrivyTests {
    /// A `.tar.gz` with one executable `trivy` script, and the pin that matches it.
    private struct Fixture {
        let scratch: Scratch
        let archive: URL
        var pin: TrivyPin
        let paths: AppPaths

        init(entryName: String = "trivy", symlink: Bool = false) throws {
            scratch = try Scratch()
            let src = try scratch.dir("src")
            if symlink {
                try FileManager.default.createSymbolicLink(at: src.appending(path: entryName), withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
            } else {
                try Data("#!/bin/sh\necho trivy\n".utf8).write(to: src.appending(path: entryName))
                chmod(src.appending(path: entryName).path, 0o755)
            }
            archive = scratch.root.appending(path: "trivy_9.9.9_macOS-ARM64.tar.gz")
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-czf", archive.path, "-C", src.path, entryName]
            try tar.run()
            tar.waitUntilExit()
            let size = ((try FileManager.default.attributesOfItem(atPath: archive.path)[.size]) as? NSNumber)?.int64Value ?? 0
            let binarySHA = symlink ? String(repeating: "0", count: 64) : try ManagedTrivy.sha256(of: src.appending(path: entryName))
            pin = TrivyPin(version: "9.9.9", archiveName: archive.lastPathComponent, url: URL(string: "https://example.invalid/trivy_9.9.9_macOS-ARM64.tar.gz")!,
                           archiveSHA256: try ManagedTrivy.sha256(of: archive), archiveSize: size, binarySHA256: binarySHA)
            paths = AppPaths(gateActive: false, bundleID: AppPaths.releaseBundleID, home: try scratch.home(), temporaryDirectory: scratch.root)
        }
    }

    /// Serves the fixture archive from disk (a fake downloader: nothing touches the network).
    private struct FileDownloader: TrivyDownloader {
        var source: URL
        func download(_ url: URL, to destination: URL, maxBytes: Int64) async throws { try FileManager.default.copyItem(at: source, to: destination) }
    }

    @Test func consentShowsEverythingBeforeAnyDownload() throws {
        let f = try Fixture()
        defer { f.scratch.cleanup() }
        let managed = ManagedTrivy(paths: f.paths, pin: .available(f.pin), downloader: FileDownloader(source: f.archive))
        let c = try #require(managed.consent)
        #expect(c.fileName == f.pin.archiveName && c.url == f.pin.url && c.size == f.pin.archiveSize && c.sha256 == f.pin.archiveSHA256)
        #expect(c.installLocation.path.hasSuffix("Wheelhouse/tools/trivy/9.9.9"))
        #expect(managed.verifiedExecutable() == nil)
    }

    @Test func installsAndVerifies() async throws {
        let f = try Fixture()
        defer { f.scratch.cleanup() }
        let managed = ManagedTrivy(paths: f.paths, pin: .available(f.pin), downloader: FileDownloader(source: f.archive))
        let exe = try await managed.install()
        #expect(managed.verifiedExecutable() == exe)
        var st = stat()
        stat(exe.path, &st)
        #expect(st.st_mode & 0o777 == 0o755)
        // The installed file really runs.
        let r = try await Subprocess.run(ProcessSpec(executable: exe, environment: ["PATH": "/usr/bin:/bin"]))
        #expect(r.stdoutString == "trivy\n")
        // A replaced file no longer verifies.
        try Data("#!/bin/sh\necho evil\n".utf8).write(to: exe)
        #expect(managed.verifiedExecutable() == nil)
        managed.remove()
        #expect(!FileManager.default.fileExists(atPath: exe.path))
    }

    @Test func aWrongArchiveChecksumIsRefusedAndNothingIsInstalled() async throws {
        var f = try Fixture()
        defer { f.scratch.cleanup() }
        f.pin.archiveSHA256 = String(repeating: "a", count: 64)
        let managed = ManagedTrivy(paths: f.paths, pin: .available(f.pin), downloader: FileDownloader(source: f.archive))
        await #expect(throws: ManagedTrivyError.checksumMismatch(what: "download")) { try await managed.install() }
        #expect(!FileManager.default.fileExists(atPath: try #require(managed.executableURL).path))
    }

    @Test func aWrongBinaryChecksumIsRefused() async throws {
        var f = try Fixture()
        defer { f.scratch.cleanup() }
        f.pin.binarySHA256 = String(repeating: "b", count: 64)
        let managed = ManagedTrivy(paths: f.paths, pin: .available(f.pin), downloader: FileDownloader(source: f.archive))
        await #expect(throws: ManagedTrivyError.checksumMismatch(what: "program")) { try await managed.install() }
        #expect(!FileManager.default.fileExists(atPath: try #require(managed.executableURL).path))
    }

    @Test func aTruncatedDownloadIsRefused() async throws {
        var f = try Fixture()
        defer { f.scratch.cleanup() }
        f.pin.archiveSize += 10
        let managed = ManagedTrivy(paths: f.paths, pin: .available(f.pin), downloader: FileDownloader(source: f.archive))
        await #expect(throws: ManagedTrivyError.self) { try await managed.install() }
    }

    @Test func aSymlinkEntryIsRefused() async throws {
        let f = try Fixture(symlink: true)
        defer { f.scratch.cleanup() }
        let managed = ManagedTrivy(paths: f.paths, pin: .available(f.pin), downloader: FileDownloader(source: f.archive))
        await #expect(throws: ManagedTrivyError.notARegularFile) { try await managed.install() }
    }

    @Test func noPinMeansNoDownload() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let paths = AppPaths(gateActive: false, bundleID: AppPaths.releaseBundleID, home: try scratch.home(), temporaryDirectory: scratch.root)
        let managed = ManagedTrivy(paths: paths, pin: .unavailable("none"), downloader: URLSessionTrivyDownloader())
        #expect(managed.consent == nil)
        await #expect(throws: ManagedTrivyError.unavailable) { try await managed.install() }
    }

    @Test func thePinIsCompleteOrEmpty() throws {
        // The shipped pin: either fully filled and valid, or unavailable. Never half filled.
        switch TrivyPin.bundled {
        case .available(let p): #expect(p.isValid)
        case .unavailable: break
        }
        let half = Data(#"{"version":"1.0.0","archiveName":"trivy.tar.gz"}"#.utf8)
        #expect(TrivyPin.parse(half) == .unavailable(TrivyPin.unavailableMessage))
        let http = Data(#"{"version":"1.0.0","archiveName":"t.tar.gz","url":"http://example.com/t.tar.gz","archiveSHA256":"\#(String(repeating: "a", count: 64))","archiveSize":1,"binarySHA256":"\#(String(repeating: "b", count: 64))"}"#.utf8)
        #expect(TrivyPin.parse(http) == .unavailable(TrivyPin.unavailableMessage))
        let good = Data(#"{"version":"1.0.0","archiveName":"t.tar.gz","url":"https://example.com/t.tar.gz","archiveSHA256":"\#(String(repeating: "a", count: 64))","archiveSize":1,"binarySHA256":"\#(String(repeating: "b", count: 64))"}"#.utf8)
        if case .unavailable = TrivyPin.parse(good) { Issue.record("a complete pin must parse") }
    }

    @Test func theRealDownloaderRefusesAnythingButHTTPS() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        for url in [URL(string: "http://example.com/x")!, URL(fileURLWithPath: "/etc/hosts")] {
            await #expect(throws: ManagedTrivyError.insecureURL) {
                try await URLSessionTrivyDownloader().download(url, to: scratch.root.appending(path: "x"), maxBytes: 1_000)
            }
        }
    }

    /// Serves `body` in 64 KB chunks; a host starting with "missing" answers 404.
    final class ChunkedProtocol: URLProtocol, @unchecked Sendable {
        static let body = Mutex(Data())
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!
            let status = url.host()?.hasPrefix("missing") == true ? 404 : 200
            let body = Self.body.withLock { $0 }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(body.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var offset = 0
            while offset < body.count {
                let end = min(body.count, offset + 65_536)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @Test(.timeLimit(.minutes(1))) func theRealDownloaderWritesTheBodyWithinTheLimitAndStopsOverIt() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let downloader = URLSessionTrivyDownloader(protocolClasses: [ChunkedProtocol.self])
        let body = Data((0..<300_000).map { UInt8($0 % 251) })
        ChunkedProtocol.body.withLock { $0 = body }
        let target = scratch.root.appending(path: "ok.tgz")
        try await downloader.download(URL(string: "https://ok.test/t.tgz")!, to: target, maxBytes: Int64(body.count))
        #expect(try Data(contentsOf: target) == body)
        var st = stat()
        #expect(stat(target.path, &st) == 0 && (st.st_mode & 0o777) == 0o600)
        // Over the limit: stopped, and nothing is left at the destination.
        let big = scratch.root.appending(path: "big.tgz")
        await #expect(throws: ManagedTrivyError.tooLarge(limit: 100_000)) {
            try await downloader.download(URL(string: "https://ok.test/t.tgz")!, to: big, maxBytes: 100_000)
        }
        #expect(!FileManager.default.fileExists(atPath: big.path))
        // A failing status is an error, not a file.
        await #expect(throws: URLError.self) {
            try await downloader.download(URL(string: "https://missing.test/t.tgz")!, to: big, maxBytes: 1_000_000)
        }
        #expect(!FileManager.default.fileExists(atPath: big.path))
    }

    @Test func anUnsignedProgramIsAcceptedOnItsPinnedHashAndTheSizeCapIsPassedToTheDownloader() async throws {
        let f = try Fixture()
        defer { f.scratch.cleanup() }
        final class Capture: TrivyDownloader, @unchecked Sendable {
            let source: URL
            nonisolated(unsafe) var seenMax: Int64 = 0
            init(_ source: URL) { self.source = source }
            func download(_ url: URL, to destination: URL, maxBytes: Int64) async throws {
                seenMax = maxBytes
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
        let capture = Capture(f.archive)
        let managed = ManagedTrivy(paths: f.paths, pin: .available(f.pin), downloader: capture)
        _ = try await managed.install()                      // the script is unsigned: the pinned hash is the trust anchor
        #expect(capture.seenMax == f.pin.archiveSize)
        #expect(await managed.verifiedExecutableOffMain() != nil)
    }
}
#endif
