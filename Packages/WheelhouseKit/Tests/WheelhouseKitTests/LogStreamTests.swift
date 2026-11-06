import Foundation
import Testing
@testable import WheelhouseKit

// MARK: - Detection

@Suite("Log stream problems")
struct LogFailureDetectionTests {
    @Test func detectsKubeletFsnotifyLine() {
        let lines = ["2026-11-05T10:00:00.123456789Z hello", "failed to create fsnotify watcher: too many open files"]
        #expect(LogStreamProblem.detect(lines: lines) == .nodeWatchLimit(detail: "failed to create fsnotify watcher: too many open files"))
    }

    @Test func detectsWithTimestampPrefixAndWrapping() {
        let line = "2026-11-05T10:00:00.5Z Internal error occurred: failed to create fsnotify watcher: too many open files"
        #expect(LogStreamProblem.detect(lines: [line]) != nil)
    }

    @Test func detectsNoSpaceLeftForInotifyWatches() {
        #expect(LogStreamProblem.detect(lines: ["error: inotify_add_watch: no space left on device"]) != nil)
        #expect(LogStreamProblem.detect(lines: ["fsnotify: no space left on device (user limit on the total number of inotify watches reached)"]) != nil)
    }

    @Test func detectsFromServerError() {
        let status = Status(status: "Failure", message: "Get \"https://10.0.0.1:10250/containerLogs/ns/p/c?follow=true\": failed to create fsnotify watcher: too many open files", reason: "InternalError", code: 500)
        #expect(LogStreamProblem.detect(error: .server(status)) != nil)
        // A bare message in an *error* (never user output) also counts.
        #expect(LogStreamProblem.detect(error: .server(Status(status: "Failure", message: "too many open files", reason: nil, code: 500))) != nil)
        #expect(LogStreamProblem.detect(error: .unreachable(cause: "Timed out")) == nil)
        // Outside a server body the bare phrase is not enough.
        #expect(LogStreamProblem.detect(error: .unreachable(cause: "open /x: too many open files")) == nil)
        #expect(LogStreamProblem.detect(error: nil) == nil)
    }

    @Test func ignoresApplicationOutput() {
        // The app's own "too many open files" is not a node problem; neither is an old line in the middle of the stream.
        #expect(LogStreamProblem.detect(lines: ["2026-11-05T10:00:00Z open /etc/x: too many open files"]) == nil)
        let lines = ["failed to create fsnotify watcher: too many open files", "a", "b", "c", "d"]
        #expect(LogStreamProblem.detect(lines: lines) == nil)   // only the last three lines are examined
        #expect(LogStreamProblem.detect(lines: []) == nil)
    }

    @Test func fixTextHasTheCommands() {
        #expect(LogStreamProblem.sysctlCommands.contains("sysctl -w fs.inotify.max_user_instances=8192"))
        #expect(LogStreamProblem.sysctlCommands.contains("fs.inotify.max_user_watches=524288"))
        #expect(LogStreamProblem.persistentFix.contains("/etc/sysctl.d/"))
    }
}

// MARK: - Backoff and dedupe

@Suite("Log reconnect backoff")
struct LogBackoffTests {
    @Test func growsAndCaps() {
        var b = LogReconnectBackoff()
        var delays: [TimeInterval] = []
        while let d = b.nextDelay(afterRunning: 0.2) { delays.append(d) }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30])
        #expect(b.nextDelay(afterRunning: 0.1) == nil)          // gives up after a storm of short connections
    }

    @Test func healthyConnectionResets() {
        var b = LogReconnectBackoff()
        _ = b.nextDelay(afterRunning: 1); _ = b.nextDelay(afterRunning: 1); _ = b.nextDelay(afterRunning: 1)
        #expect(b.nextDelay(afterRunning: 60) == 1)             // stayed up for a minute: start over
    }
}

@Suite("Log polling dedupe")
struct LogPollDedupeTests {
    private func l(_ ts: String, _ msg: String) -> String { "\(ts) \(msg)" }

    @Test func dropsRepeatedBoundaryLine() {
        var d = LogPollDeduper()
        let first = [l("2026-11-05T10:00:00.100000000Z", "a"), l("2026-11-05T10:00:01.200000000Z", "b")]
        #expect(d.accept(first) == first)
        #expect(d.lastRawStamp == "2026-11-05T10:00:01.200000000Z")
        // sinceTime is inclusive: the next poll repeats "b" and adds "c".
        let second = [first[1], l("2026-11-05T10:00:02.000000000Z", "c")]
        #expect(d.accept(second) == [second[1]])
    }

    @Test func keepsDistinctLinesSharingTheNewestTimestamp() {
        var d = LogPollDeduper()
        let t = "2026-11-05T10:00:00.5Z"
        #expect(d.accept([l(t, "x")]) == [l(t, "x")])
        #expect(d.accept([l(t, "x"), l(t, "y")]) == [l(t, "y")])
        #expect(d.accept([l(t, "x"), l(t, "y")]).isEmpty)
    }

    @Test func dropsOlderLinesAndKeepsUntimestamped() {
        var d = LogPollDeduper()
        _ = d.accept([l("2026-11-05T10:00:05Z", "new")])
        #expect(d.accept([l("2026-11-05T10:00:01Z", "old")]).isEmpty)
        #expect(d.accept(["no timestamp"]) == ["no timestamp"])
    }
}

// MARK: - Energy

@Suite("Energy policy")
struct EnergyPolicyTests {
    @Test func multipliers() {
        #expect(EnergyPolicy().refreshMultiplier == 1)
        #expect(EnergyPolicy(isLowPowerMode: true).refreshMultiplier == 2)
        #expect(EnergyPolicy(thermalState: .serious).refreshMultiplier == 2)
        #expect(EnergyPolicy(thermalState: .critical).refreshMultiplier == 4)
        #expect(EnergyPolicy(isLowPowerMode: true, thermalState: .critical).interval(30) == 240)
        #expect(EnergyPolicy(thermalState: .fair).refreshMultiplier == 1)
    }

    @Test func gates() {
        let nominal = EnergyPolicy()
        #expect(nominal.allowsLiveCharts && nominal.allowsLiveSampling && !nominal.suspendsHiddenWatches)
        let low = EnergyPolicy(isLowPowerMode: true)
        #expect(!low.allowsLiveCharts && !low.allowsLiveSampling && !low.suspendsHiddenWatches)
        let hot = EnergyPolicy(thermalState: .serious)
        #expect(!hot.allowsLiveCharts && hot.suspendsHiddenWatches && hot.publishInterval == 1.0)
    }

    @Test func downsamplingKeepsEndpointsAndBound() {
        let t0 = Date(timeIntervalSince1970: 0)
        let pts = (0..<5000).map { MetricPoint(time: t0.addingTimeInterval(Double($0)), value: Double($0)) }
        let d = pts.downsampled(to: 100)
        #expect(d.count == 100)
        #expect(d.last == pts.last)
        #expect(zip(d, d.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(Array(pts.prefix(50)).downsampled(to: 100).count == 50)
    }
}

// MARK: - LogStream behaviour

private func stamp(_ s: Int) -> String { String(format: "2026-11-05T10:00:%02d.000000000Z", s) }

@MainActor
private func waitUntil(timeout: Duration = .seconds(6), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(Double(timeout.components.seconds)))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Records every log request a stream makes.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [LogOptions] = []
    func add(_ o: LogOptions) { lock.withLock { all.append(o) } }
    var requests: [LogOptions] { lock.withLock { all } }
    var follows: Int { requests.filter(\.follow).count }
    var polls: [LogOptions] { requests.filter { !$0.follow } }
}

@MainActor
@Suite("LogStream", .serialized)
struct LogStreamBehaviourTests {
    @Test func inotifyExhaustionSwitchesToPollingWithoutReconnectStorm() async throws {
        let client = ScriptedClient()
        let log = RequestLog()
        let counter = Counter()
        client.logsHandler = { o in
            log.add(o)
            return AsyncThrowingStream { c in
                if o.follow {
                    c.yield("\(stamp(1)) first"); c.yield("\(stamp(2)) second")
                    c.yield("failed to create fsnotify watcher: too many open files")
                    c.finish()
                } else {
                    counter.bump()
                    // Inclusive of sinceTime: repeats the last known line, then one new line per poll.
                    c.yield("\(stamp(2)) second")
                    c.yield("\(stamp(2 + counter.value)) new-\(counter.value)")
                    c.finish()
                }
            }
        }
        let stream = LogStream(capacity: 1000)
        stream.pollInterval = 0.05
        stream.start(client: client, namespace: "ns", pod: "p", containers: ["c"], options: LogOptions(follow: true, tailLines: 100), scope: "t1")

        #expect(await waitUntil { stream.mode == .polling && stream.buffer.lines.contains { $0.message == "new-2" } })
        #expect(stream.problem == .nodeWatchLimit(detail: "failed to create fsnotify watcher: too many open files"))
        #expect(stream.state == .streaming)
        #expect(log.follows == 1)                                     // no reconnect of the follow
        let first = try #require(log.polls.first)
        #expect(first.follow == false && first.sinceTime == stamp(2) && first.tailLines == nil)
        // Dedupe: "second" appears exactly once although every poll repeats it.
        let messages = stream.buffer.lines.filter { $0.kind == .line }.map(\.message)
        #expect(messages.filter { $0 == "second" }.count == 1)
        #expect(messages.contains("new-1") && messages.contains("new-2"))
        #expect(LogFollowRegistry.shared.activeFollowCount == 0)      // polling holds no follow connection
        stream.stop(to: .idle)
        let pollsAfterStop = log.polls.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.polls.count == pollsAfterStop)                    // stopping stops the polling
    }

    @Test func serverErrorBodyAlsoTriggersPolling() async {
        let client = ScriptedClient()
        let log = RequestLog()
        client.logsHandler = { o in
            log.add(o)
            return AsyncThrowingStream { c in
                if o.follow { c.finish(throwing: KubeError.server(Status(status: "Failure", message: "failed to create fsnotify watcher: too many open files", reason: nil, code: 500))) }
                else { c.yield("2026-11-05T10:00:09.000000000Z polled"); c.finish() }
            }
        }
        let stream = LogStream(capacity: 100)
        stream.pollInterval = 0.05
        stream.start(client: client, namespace: "ns", pod: "p", containers: [nil], options: LogOptions(follow: true), scope: "t2")
        #expect(await waitUntil { stream.buffer.lines.contains { $0.message == "polled" } })
        #expect(stream.mode == .polling && log.follows == 1)
        stream.stop(to: .idle)
    }

    @Test func transientErrorsBackOffInsteadOfSpinning() async throws {
        let client = ScriptedClient()
        let log = RequestLog()
        client.logsHandler = { o in
            log.add(o)
            return AsyncThrowingStream { $0.finish(throwing: KubeError.unreachable(cause: "Connection lost")) }
        }
        let stream = LogStream(capacity: 100)
        stream.start(client: client, namespace: "ns", pod: "p", containers: [nil], options: LogOptions(follow: true), scope: "t3")
        try await Task.sleep(for: .milliseconds(1500))
        // Delays are 1 s, 2 s, 4 s …: at most 2 requests in 1.5 s (a fixed 100 ms spin would make ~15).
        #expect(log.follows <= 2)
        #expect(stream.state == .connecting)
        stream.stop(to: .idle)
    }

    @Test func onlyOneFollowPerPodContainerAndOldestClosedFirst() async {
        let client = ScriptedClient()
        let log = RequestLog()
        client.logsHandler = { o in log.add(o); return AsyncThrowingStream { _ in } }   // stays open
        let a = LogStream(capacity: 100), b = LogStream(capacity: 100)
        a.start(client: client, namespace: "ns", pod: "same", containers: ["c"], options: LogOptions(follow: true), scope: "t4")
        #expect(LogFollowRegistry.shared.activeFollowCount == 1)
        b.start(client: client, namespace: "ns", pod: "same", containers: ["c"], options: LogOptions(follow: true), scope: "t4")
        #expect(a.state == .paused && a.pauseReason == .preempted)    // the old stream was cancelled
        #expect(b.isLive)
        #expect(LogFollowRegistry.shared.activeFollowCount == 1)
        // A different cluster with the same pod name is a different pod.
        let c = LogStream(capacity: 100)
        c.start(client: client, namespace: "ns", pod: "same", containers: ["c"], options: LogOptions(follow: true), scope: "other")
        #expect(b.isLive && c.isLive)
        #expect(LogFollowRegistry.shared.activeFollowCount == 2)
        b.stop(to: .idle); c.stop(to: .idle)
        #expect(LogFollowRegistry.shared.activeFollowCount == 0)
    }

    @Test func globalCapClosesTheOldestFollow() async {
        let registry = LogFollowRegistry.shared
        let saved = registry.maxConcurrentFollows
        registry.maxConcurrentFollows = 2
        defer { registry.maxConcurrentFollows = saved }
        let client = ScriptedClient()
        client.logsHandler = { _ in AsyncThrowingStream { _ in } }
        let s = (0..<3).map { _ in LogStream(capacity: 50) }
        for (i, x) in s.enumerated() {
            x.start(client: client, namespace: "ns", pod: "p\(i)", containers: [nil], options: LogOptions(follow: true), scope: "t5")
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(s[0].pauseReason == .preempted && s[0].state == .paused)
        #expect(s[1].isLive && s[2].isLive)
        #expect(registry.activeFollowCount == 2)
        s.forEach { $0.stop(to: .idle) }
        #expect(registry.activeFollowCount == 0)
    }

    @Test func suspendAndResumeByReason() async {
        let client = ScriptedClient()
        let log = RequestLog()
        client.logsHandler = { o in log.add(o); return AsyncThrowingStream { _ in } }
        let s = LogStream(capacity: 50)
        s.start(client: client, namespace: "ns", pod: "p", containers: [nil], options: LogOptions(follow: true), scope: "t6")
        s.suspend(reason: .background)
        #expect(s.state == .paused && s.pauseReason == .background && s.openFollowCount == 0)
        #expect(LogFollowRegistry.shared.activeFollowCount == 0)
        s.resume()
        #expect(s.isLive && s.pauseReason == nil && log.follows == 2)
        s.stop(to: .idle)
    }

    @Test func siblingErrorBacksOffAndSuspendCancelsPendingReconnect() async throws {
        let client = ScriptedClient()
        let log = RequestLog()
        client.logsHandler = { o in
            log.add(o)
            return AsyncThrowingStream { c in
                if o.container == "a" { c.finish(throwing: KubeError.unreachable(cause: "Connection lost")) }   // "b" stays open
            }
        }
        let stream = LogStream(capacity: 100)
        stream.start(client: client, namespace: "ns", pod: "p", containers: ["a", "b"], options: LogOptions(follow: true), scope: "t7")
        try await Task.sleep(for: .milliseconds(400))
        #expect(stream.state == .connecting)                         // not .finished by the cancelled sibling
        stream.suspend(reason: .screenLeft)
        #expect(stream.state == .paused && stream.pauseReason == .screenLeft)
        try await Task.sleep(for: .milliseconds(1600))
        #expect(log.follows == 2)                                    // the pending reconnect was cancelled
        #expect(stream.state == .paused)
    }

    @Test func nonTransientFailureStaysFailed() async throws {
        let client = ScriptedClient()
        client.logsHandler = { o in
            AsyncThrowingStream { c in if o.container == "a" { c.finish(throwing: KubeError.forbidden(verb: "get", resource: "pods/log", namespace: "ns", message: "forbidden")) } }
        }
        let stream = LogStream(capacity: 100)
        stream.start(client: client, namespace: "ns", pod: "p", containers: ["a", "b"], options: LogOptions(follow: true), scope: "t8")
        #expect(await waitUntil { if case .failed = stream.state { true } else { false } })
        try await Task.sleep(for: .milliseconds(200))
        if case .failed = stream.state {} else { Issue.record("state was overwritten: \(stream.state)") }
        #expect(LogFollowRegistry.shared.activeFollowCount == 0)
    }

    @Test func detectionUsesTheEndingContainersOwnLines() async throws {
        let client = ScriptedClient()
        let log = RequestLog()
        client.logsHandler = { o in
            log.add(o)
            return AsyncThrowingStream { c in
                if o.container == "b" { c.yield("failed to create fsnotify watcher: too many open files") }   // b stays open
                else { c.yield("\(stamp(1)) fine"); c.finish() }                                            // a ends cleanly
            }
        }
        let stream = LogStream(capacity: 100)
        stream.start(client: client, namespace: "ns", pod: "p", containers: ["a", "b"], options: LogOptions(follow: true), scope: "t9")
        try await Task.sleep(for: .milliseconds(400))
        #expect(stream.mode == .follow && stream.problem == nil)
        stream.stop(to: .idle)
    }

    @Test func failedFirstPollKeepsTheBoundedRequest() async throws {
        let client = ScriptedClient()
        let log = RequestLog()
        client.logsHandler = { o in
            log.add(o)
            return AsyncThrowingStream { c in
                if o.follow { c.yield("failed to create fsnotify watcher: too many open files"); c.finish() }
                else if log.polls.count == 1 { c.finish(throwing: KubeError.unreachable(cause: "Connection lost")) }
                else { c.yield("\(stamp(5)) polled"); c.finish() }
            }
        }
        let stream = LogStream(capacity: 100)
        stream.pollInterval = 0.05
        stream.start(client: client, namespace: "ns", pod: "p", containers: [nil], options: LogOptions(follow: true, tailLines: 100), scope: "t10")
        #expect(await waitUntil(timeout: .seconds(8)) { log.polls.count >= 3 })
        let polls = log.polls
        #expect(polls[1].tailLines == 100 && polls[1].sinceTime == nil)      // still bounded after a failed poll
        #expect(polls[2].sinceTime == stamp(5) && polls[2].tailLines == nil)
        stream.stop(to: .idle)
    }

    @Test func forbiddenPollStopsPolling() async throws {
        let client = ScriptedClient()
        let log = RequestLog()
        client.logsHandler = { o in
            log.add(o)
            return AsyncThrowingStream { c in
                if o.follow { c.yield("failed to create fsnotify watcher: too many open files"); c.finish() }
                else { c.finish(throwing: KubeError.notFound(message: nil)) }
            }
        }
        let stream = LogStream(capacity: 100)
        stream.pollInterval = 0.05
        stream.start(client: client, namespace: "ns", pod: "p", containers: [nil], options: LogOptions(follow: true), scope: "t11")
        #expect(await waitUntil { if case .failed = stream.state { true } else { false } })
        let n = log.polls.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(log.polls.count == n && n == 1)
    }

    @Test func truncatedSecondReturnsAllLinesWithoutDuplicatesOrDrops() async throws {
        let client = ScriptedClient()
        let log = RequestLog()
        let l = ["2026-11-05T10:00:02.100000000Z a", "2026-11-05T10:00:02.500000000Z b", "2026-11-05T10:00:02.900000000Z c",
                 "2026-11-05T10:00:02.950000000Z d", "2026-11-05T10:00:03.100000000Z e"]
        client.logsHandler = { o in
            log.add(o)
            return AsyncThrowingStream { c in
                if o.follow { for x in l.prefix(3) { c.yield(x) }; c.yield("failed to create fsnotify watcher: too many open files"); c.finish() }
                else if log.polls.count == 1 { for x in l.prefix(4) { c.yield(x) }; c.finish() }   // whole second 02, plus a new line
                else { for x in l { c.yield(x) }; c.finish() }                                      // whole second again, plus one more
            }
        }
        let stream = LogStream(capacity: 100)
        stream.pollInterval = 0.05
        stream.start(client: client, namespace: "ns", pod: "p", containers: [nil], options: LogOptions(follow: true), scope: "t12")
        #expect(await waitUntil { stream.buffer.lines.contains { $0.message == "e" } })
        try await Task.sleep(for: .milliseconds(200))
        let msgs = stream.buffer.lines.filter { $0.kind == .line }.map(\.message)
        #expect(msgs.filter { ["a", "b", "c", "d", "e"].contains($0) } == ["a", "b", "c", "d", "e"])
        stream.stop(to: .idle)
    }

    @Test func morethanTheCapContainersAreClamped() async {
        let registry = LogFollowRegistry.shared
        let saved = registry.maxConcurrentFollows
        registry.maxConcurrentFollows = 2
        defer { registry.maxConcurrentFollows = saved }
        let client = ScriptedClient()
        let log = RequestLog()
        client.logsHandler = { o in log.add(o); return AsyncThrowingStream { _ in } }
        let stream = LogStream(capacity: 100)
        stream.start(client: client, namespace: "ns", pod: "p", containers: ["a", "b", "c"], options: LogOptions(follow: true), scope: "t13")
        #expect(log.follows == 2)
        #expect(stream.buffer.count == 0)   // marker is still pending a flush; request count is the contract
        stream.stop(to: .idle)
    }
}
