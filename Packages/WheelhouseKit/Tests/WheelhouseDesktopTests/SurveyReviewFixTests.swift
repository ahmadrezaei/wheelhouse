#if os(macOS)
import Foundation
import SQLite3
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

private final class Gate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    var get: T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}

private func settle(_ what: String, _ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("timed out waiting for \(what)")
}

/// A runner that blocks on the first image until released, and records the overlap.
private actor BlockingRunner: ScanRunner {
    var release = false
    var started: [String] = []
    var failure: Error?
    func setRelease(_ v: Bool) { release = v }
    func setFailure(_ e: Error?) { failure = e }
    func scan(_ item: ScanQueueItem, trigger: ScanTrigger) async throws -> ImageScanResult {
        started.append(item.image)
        if let failure { throw failure }
        while !release { try await Task.sleep(for: .milliseconds(20)) }
        return ImageScanResult(image: item.image, digest: nil, isMutable: true, dbVersion: "2", scannedAt: Date(), vulnerabilities: [])
    }
}

@Suite("Review fixes: scan queue", .serialized)
struct ScanQueueReviewTests {
    private func images(_ n: Int) -> [(image: String, isMutable: Bool, clusters: [String])] {
        (0..<n).map { (image: "registry.example.com/app\($0):1", isMutable: true, clusters: ["c1"]) }
    }

    @Test func aDatabaseFailureEndsTheRunAndKeepsTheQueue() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let runner = BlockingRunner()
        await runner.setFailure(TrivyError.databaseUnavailable("registry unreachable"))
        let store = try SurveyStore(url: scratch.root.appending(path: "survey.sqlite"))
        let queue = ScanQueue(store: store, runner: runner, conditions: { ScanConditions() })
        try await queue.enqueue(images: images(5), trigger: .manual)
        await queue.start(trigger: .manual)
        try await settle("run ended") { let p = await queue.progress; return p.state == .idle && p.lastError != nil }
        #expect(await runner.started.count == 1)                       // not one failure per image
        #expect(try await store.queueCount() == 5)                     // nothing was dropped
        let p = await queue.progress
        #expect(p.failed == 0 && p.queued == 5)
    }

    @Test func aScheduledStartNeverDowngradesARunningManualRun() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let runner = BlockingRunner()
        let conditions = Gate(ScanConditions(onBattery: true))
        let store = try SurveyStore(url: scratch.root.appending(path: "survey.sqlite"))
        let queue = ScanQueue(store: store, runner: runner, conditions: { conditions.get })
        try await queue.enqueue(images: images(2), trigger: .manual)
        await queue.start(trigger: .manual)
        try await settle("manual run started") { await runner.started.count == 1 }
        await queue.start(trigger: .scheduled)                         // the periodic request arrives mid-run
        await queue.conditionsChanged()                                // and the battery rule is evaluated
        #expect(await queue.progress.state == .running)                // the manual run was not paused
        await runner.setRelease(true)
        try await settle("both done") { await queue.progress.scanned == 2 }
    }

    @Test func aPauseReasonCanChangeWhilePaused() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let conditions = Gate(ScanConditions(onBattery: true))
        let store = try SurveyStore(url: scratch.root.appending(path: "survey.sqlite"))
        let queue = ScanQueue(store: store, runner: BlockingRunner(), conditions: { conditions.get })
        try await queue.enqueue(images: images(1), trigger: .scheduled)
        await queue.start(trigger: .scheduled)
        try await settle("battery pause") { await queue.progress.state == .paused(.onBattery) }
        conditions.set(ScanConditions(onBattery: true, thermalState: .serious))
        await queue.conditionsChanged()
        #expect(await queue.progress.state == .paused(.thermal))
        conditions.set(ScanConditions(onBattery: true))
        await queue.conditionsChanged()
        #expect(await queue.progress.state == .paused(.onBattery))
    }
}

@Suite("Review fixes: runner and store", .serialized)
struct RunnerReviewTests {
    @Test func theJavaDBIsFetchedOnlyWhenNeededAndTheScanRetried() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        try fake.seedDB()
        let store = try SurveyStore(url: fake.scratch.root.appending(path: "survey.sqlite"))
        let runner = TrivyScanRunner(cli: fake.cli, options: fake.options, store: store, paths: fake.paths)
        // An ordinary image never triggers a Java DB download.
        _ = try await runner.scan(ScanQueueItem(id: 1, image: "registry.example.com/team/web:1", isMutable: true, clusters: ["c1"]), trigger: .manual)
        #expect(!fake.log.contains("--download-java-db-only"))
        #expect(fake.log.contains("--skip-java-db-update"))
        // An image with JARs: trivy says the Java DB is missing, the runner downloads it and retries once.
        let result = try await runner.scan(ScanQueueItem(id: 2, image: "registry.example.com/team/jarapp:1", isMutable: true, clusters: ["c1"]), trigger: .manual)
        #expect(result.vulnerabilities.count == 4)
        #expect(fake.log.contains("--download-java-db-only"))
        #expect(FileManager.default.fileExists(atPath: fake.options.cacheDirectory.appending(path: "java-db/metadata.json").path))
    }

    @Test func aFailedJavaDBDownloadIsADatabaseProblemNotARegistryRefusal() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        try fake.seedDB()
        try Data().write(to: fake.options.cacheDirectory.appending(path: "java-download-fails"))
        let store = try SurveyStore(url: fake.scratch.root.appending(path: "survey.sqlite"))
        let runner = TrivyScanRunner(cli: fake.cli, options: fake.options, store: store, paths: fake.paths)
        let tried = Gate<[String]>([])
        let r2 = TrivyScanRunner(cli: fake.cli, options: fake.options, store: store, paths: fake.paths, cloudEnvironment: { c in tried.set(tried.get + [c]); return [:] })
        _ = runner
        do {
            _ = try await r2.scan(ScanQueueItem(id: 1, image: "registry.example.com/team/jarapp:1", isMutable: true, clusters: ["c1", "c2"]), trigger: .manual)
            Issue.record("expected a failure")
        } catch let error as TrivyError {
            guard case .databaseUnavailable = error else { Issue.record("wrong error \(error)"); return }
        }
        #expect(tried.get == ["c1"])                                  // the next cluster's credentials were NOT tried
    }

    @Test func aStaleJavaDBIsRefreshedUnderTheSame24HourRule() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        try fake.seedDB()
        let java = fake.options.cacheDirectory.appending(path: "java-db")
        try FileManager.default.createDirectory(at: java, withIntermediateDirectories: true)
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86_400))
        try Data(#"{"Version":1,"DownloadedAt":"\#(old)","UpdatedAt":"\#(old)"}"#.utf8).write(to: java.appending(path: "metadata.json"))
        let store = try SurveyStore(url: fake.scratch.root.appending(path: "survey.sqlite"))
        let runner = TrivyScanRunner(cli: fake.cli, options: fake.options, store: store, paths: fake.paths)
        _ = try await runner.scan(ScanQueueItem(id: 1, image: "registry.example.com/team/web:1", isMutable: true, clusters: ["c1"]), trigger: .manual)
        #expect(fake.log.contains("--download-java-db-only"))
    }

    @Test func aScanIsReusedOnlyWithinOneDBUpdate() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        try fake.seedDB()
        let store = try SurveyStore(url: fake.scratch.root.appending(path: "survey.sqlite"))
        let digest = "sha256:" + String(repeating: "1", count: 64)
        let item = ScanQueueItem(id: 1, image: "registry.example.com/team/web@\(digest)", isMutable: false, clusters: ["c1"])
        let runner = TrivyScanRunner(cli: fake.cli, options: fake.options, store: store, paths: fake.paths)
        _ = try await runner.scan(item, trigger: .manual)
        let runs = { fake.log.components(separatedBy: "ARGS image --format").count }
        let before = runs()
        _ = try await runner.scan(item, trigger: .manual)
        #expect(runs() == before)                                       // same DB: reused
        // The daily DB update changes UpdatedAt while Version stays 2.
        let next = ISO8601DateFormatter().string(from: Date().addingTimeInterval(120))
        try Data(#"{"Version":2,"UpdatedAt":"\#(next)","DownloadedAt":"\#(ISO8601DateFormatter().string(from: Date()))"}"#.utf8)
            .write(to: fake.options.cacheDirectory.appending(path: "db/metadata.json"))
        _ = try await runner.scan(item, trigger: .manual)
        #expect(runs() == before + 1)                                   // new DB: scanned again
    }

    @Test func aScanRemembersItsClustersAndMergesThemOnReuse() async throws {
        let fake = try FakeTrivy()
        defer { fake.scratch.cleanup() }
        try fake.seedDB()
        let store = try SurveyStore(url: fake.scratch.root.appending(path: "survey.sqlite"))
        let digest = "sha256:" + String(repeating: "1", count: 64)
        let runner = TrivyScanRunner(cli: fake.cli, options: fake.options, store: store, paths: fake.paths)
        _ = try await runner.scan(ScanQueueItem(id: 1, image: "registry.example.com/team/web@\(digest)", isMutable: false, clusters: ["a"]), trigger: .manual)
        #expect(try await store.allScans().first?.clusters == ["a"])
        _ = try await runner.scan(ScanQueueItem(id: 2, image: "registry.example.com/team/web@\(digest)", isMutable: false, clusters: ["b"]), trigger: .manual)
        #expect(try await store.allScans().first?.clusters == ["a", "b"])
    }

    @Test func aVersionOneDatabaseMigratesToTwoAndKeepsItsData() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let path = scratch.root.appending(path: "survey.sqlite").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let v1 = """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE scans (id TEXT PRIMARY KEY, image TEXT NOT NULL, digest TEXT, mutable INTEGER NOT NULL, db_version TEXT NOT NULL, scanned_at REAL NOT NULL, vulns BLOB NOT NULL);
        CREATE TABLE queue (id INTEGER PRIMARY KEY AUTOINCREMENT, image TEXT NOT NULL, mutable INTEGER NOT NULL, clusters TEXT NOT NULL, trigger TEXT NOT NULL, arch TEXT);
        CREATE TABLE accepted_risks (id TEXT PRIMARY KEY, body BLOB NOT NULL);
        CREATE TABLE pull_secret_optin (cluster_id TEXT PRIMARY KEY);
        INSERT INTO scans VALUES ('r/a:1', 'r/a:1', NULL, 1, '2', 1000, x'5b5d');
        PRAGMA user_version = 1;
        """
        #expect(sqlite3_exec(db, v1, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = try SurveyStore(url: URL(fileURLWithPath: path))
        #expect(try await store.userVersion() == 2)
        let scans = try await store.allScans()
        #expect(scans.count == 1 && scans[0].clusters.isEmpty)          // the old row survived, with no clusters
        try await store.save(ImageScanResult(image: "r/b:1", digest: nil, isMutable: true, dbVersion: "2", scannedAt: Date(), vulnerabilities: [], clusters: ["c"]))
        #expect(try await store.scan(id: "r/b:1")?.clusters == ["c"])
    }

    @Test func theWriteAheadFilesAreOwnerOnly() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = scratch.root.appending(path: "survey.sqlite")
        let store = try SurveyStore(url: url)
        try await store.save(ImageScanResult(image: "r/a:1", digest: nil, isMutable: true, dbVersion: "2", scannedAt: Date(), vulnerabilities: []))
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            var st = stat()
            stat(url.path + suffix, &st)
            #expect(st.st_mode & 0o777 == 0o600, "\(suffix)")
        }
    }

    @Test func terminateAllStopsOnlyTheChildrenOfItsGroup() async throws {
        let group = "test-\(UUID().uuidString)"
        let mine = Task {
            try await Subprocess.run(ProcessSpec(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: ["PATH": "/usr/bin:/bin"],
                                                 timeout: .seconds(60), quitGroup: group))
        }
        let bystander = Task {
            try await Subprocess.run(ProcessSpec(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], environment: ["PATH": "/usr/bin:/bin"],
                                                 timeout: .seconds(60), quitGroup: "other-\(group)"))
        }
        try await settle("child alive") { !SpawnedProcess.live.snapshot(group: group).isEmpty }
        let started = ContinuousClock.now
        Subprocess.terminateAll(group: group)
        let result = try await mine.value
        #expect(result.exit.signal == SIGTERM)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(SpawnedProcess.live.snapshot(group: group).isEmpty)
        let other = try await bystander.value                          // another group's child was left alone and finished by itself
        #expect(other.exit.code == 0)
    }
}
#endif
