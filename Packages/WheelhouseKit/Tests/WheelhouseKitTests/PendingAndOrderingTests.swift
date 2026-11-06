import Foundation
import Synchronization
import Testing
@testable import WheelhouseKit

@Suite struct PendingPodCountTests {
    static func pendingUnscheduled() throws -> Pod {
        try HealthTests.pod("pend", json: #""status":{"phase":"Pending","conditions":[{"type":"PodScheduled","status":"False","reason":"Unschedulable"}]}"#)
    }
    static func creating() throws -> Pod {
        try HealthTests.pod("creating", json: #""status":{"phase":"Pending","containerStatuses":[{"name":"app","ready":false,"restartCount":0,"state":{"waiting":{"reason":"ContainerCreating"}}}]}"#)
    }
    static func imagePull() throws -> Pod {
        try HealthTests.pod("img", json: #""status":{"phase":"Pending","containerStatuses":[{"name":"app","ready":false,"restartCount":0,"state":{"waiting":{"reason":"ImagePullBackOff"}}}]}"#)
    }

    @Test func pendingPodHasWarningSeverityButCountsAsPending() throws {
        let p = try Self.pendingUnscheduled()
        let s = p.stateSummary()
        #expect(s.reason == "Pending" && s.severity == .warning)
        #expect(p.isPendingForCounts(s))
        #expect(!(try Self.imagePull()).isPendingForCounts(try Self.imagePull().stateSummary()))
    }

    @Test func healthEvaluatorCountsPendingNotFailing() throws {
        var input = ClusterHealthInput(clusterID: "c", environment: .development)
        input.pods = [try Self.pendingUnscheduled(), try Self.creating(), try Self.imagePull(), try HealthTests.crashPod(),
                      try HealthTests.runningPod("a"), try HealthTests.runningPod("b")]
        let counts = HealthEvaluator.evaluate(input, now: HealthTests.now).counts
        #expect(counts.podsPending == 2)
        #expect(counts.podsFailing == 2)   // ImagePullBackOff + CrashLoopBackOff
        #expect(counts.podsRunning == 2)
    }

    @Test func widgetFailingPodsExcludesPending() throws {
        // The widget's `failingPods` is `ClusterCounts.podsFailing` (ClusterRegistry.makeSnapshot).
        var input = ClusterHealthInput(clusterID: "c", environment: .development)
        input.pods = [try Self.pendingUnscheduled(), try HealthTests.runningPod("a")]
        let counts = HealthEvaluator.evaluate(input, now: HealthTests.now).counts
        let entry = FleetSnapshot.ClusterEntry(id: "c", name: "c", environment: .development, status: .healthy, podsRunning: counts.podsRunning,
                                               podsTotal: counts.podsTotal, failingPods: counts.podsFailing)
        #expect(entry.failingPods == 0)
        #expect(counts.podsPending == 1)
    }

    @Test func phaseBreakdownBucketsPendingSeparately() throws {
        let b = PodPhaseBreakdown.compute([try Self.pendingUnscheduled(), try Self.creating(), try Self.imagePull(), try HealthTests.crashPod(), try HealthTests.runningPod()])
        #expect(b.pending == 2)
        #expect(b.crashing == 2)
        #expect(b.healthy == 1)
    }
}

@Suite struct OrderedFrameWriterTests {
    final class Sink: Sendable {
        let frames = Mutex<[Data]>([])
        let failAt: Int?
        init(failAt: Int? = nil) { self.failAt = failAt }
        func write(_ d: Data) async throws {
            // Reentrancy bait: a slow, varying delay would reorder unstructured per-write tasks.
            let n = frames.withLock { $0.count }
            try await Task.sleep(for: .microseconds(n % 3 == 0 ? 300 : 10))
            if let failAt, n == failAt { throw URLError(.networkConnectionLost) }
            frames.withLock { $0.append(d) }
        }
    }

    @Test func manySmallChunksArriveInOrder() async throws {
        let sink = Sink()
        let writer = OrderedFrameWriter(send: { try await sink.write($0) }, onFailure: { _ in })
        let count = 500
        for i in 0..<count { writer.enqueue(Data("\(i)".utf8)) }
        for _ in 0..<400 where sink.frames.withLock({ $0.count }) < count { try await Task.sleep(for: .milliseconds(25)) }
        let got = sink.frames.withLock { $0 }.map { String(decoding: $0, as: UTF8.self) }
        #expect(got == (0..<count).map(String.init))
        writer.cancel()
    }

    @Test func firstSentFiresOnceAndFailureStopsLaterFrames() async throws {
        let sink = Sink(failAt: 2)
        let firsts = Mutex(0), failures = Mutex(0)
        let writer = OrderedFrameWriter(send: { try await sink.write($0) }, onFirstSent: { firsts.withLock { $0 += 1 } },
                                        onFailure: { _ in failures.withLock { $0 += 1 } })
        for i in 0..<6 { writer.enqueue(Data([UInt8(i)])) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(firsts.withLock { $0 } == 1)
        #expect(failures.withLock { $0 } == 1)
        #expect(sink.frames.withLock { $0.map { $0[0] } } == [0, 1])
        writer.cancel()
    }

    @Test func execSessionSendWithoutSocketIsNoOp() {
        let s = ExecSession(client: StubLogClient(lines: []), namespace: "shop", pod: "p", options: ExecOptions(command: ["/bin/sh"], tty: true, stdin: true))
        s.send(Data("x".utf8)); s.resize(cols: 80, rows: 24)   // synchronous, no socket yet: dropped, no crash
    }
}
