import Testing
import Foundation
@testable import WheelhouseKit

@Suite("Dashboard logic")
struct DashboardTests {
    @Test func semVerParsing() {
        #expect(KubeSemVer("v1.31.4-eks-aeac579") == KubeSemVer(major: 1, minor: 31, patch: 4))
        #expect(KubeSemVer("v1.30.6+k3s1") == KubeSemVer(major: 1, minor: 30, patch: 6))
        #expect(KubeSemVer("garbage") == nil)
        #expect(KubeSemVer("v1.29.0")! < KubeSemVer("v1.30.0")!)
    }

    @Test func seriesSumAlignsBuckets() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let a = [MetricPoint(time: t, value: 1), MetricPoint(time: t.addingTimeInterval(60), value: 2)]
        let b = [MetricPoint(time: t, value: 10), MetricPoint(time: t.addingTimeInterval(60), value: 20)]
        let s = SeriesMath.sum([a, b], bucket: 30)
        #expect(s.map(\.value) == [11, 22])
    }

    @Test func nodeNames() {
        #expect(SeriesMath.shortNodeName("ip-10-2-22-85.eu-west-1.compute.internal") == "2-22-85")
        #expect(SeriesMath.shortNodeName("k3s-agent-1") == "k3s-agent-1")
    }

    @MainActor @Test func usageHistoryCapsAndDedupes() {
        let h = UsageHistory()
        let t = Date()
        for i in 0..<(UsageHistory.maxSamples + 10) {
            h.record(UsageSample(time: t.addingTimeInterval(Double(i) * 30), cpuUsage: 1, memUsage: 1, cpuAllocatable: 2, memAllocatable: 2), key: "a")
        }
        #expect(h.samples(for: "a").count == UsageHistory.maxSamples)
        h.record(UsageSample(time: t.addingTimeInterval(Double(UsageHistory.maxSamples + 9) * 30 + 1), cpuUsage: 5, memUsage: 1, cpuAllocatable: 2, memAllocatable: 2), key: "a")
        #expect(h.samples(for: "a").count == UsageHistory.maxSamples)
        #expect(h.samples(for: "a").last?.cpuUsage == 5)
    }

    @MainActor @Test func seenState() {
        let s = AlertsSeen()
        s.markSeen(["a", "b"])
        #expect(s.isSeen("a"))
        s.markUnseen("a")
        #expect(!s.isSeen("a"))
    }

    @Test func usageFractionsWithoutMetrics() {
        var u = ClusterUsage()
        u.cpuAllocatable = 4
        #expect(u.cpuFraction == nil)
        u.cpuUsage = 1
        #expect(u.cpuFraction == 0.25)
    }

    @Test func skewFlagsNewerKubelet() async {
        let nodes = await DemoFleet.sample(Node.self, cluster: DemoFleet.prodID)
        let ok = VersionSkew.analyze(apiVersion: "v1.31.4", nodes: nodes)
        #expect(ok.severity == nil)
        let bad = VersionSkew.analyze(apiVersion: "v1.28.0", nodes: nodes)
        #expect(bad.kubeletNewerThanAPI && bad.severity == .warning)
    }

    @Test func demoUsageComputesFractions() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[1])
        let nodes = try await client.list(Node.self).items
        let pods = try await client.list(Pod.self).items
        let u = ClusterUsage.compute(nodes: nodes, nodeMetrics: try await client.nodeMetrics(), pods: pods)
        #expect(u.cpuFraction != nil && (0...1).contains(u.cpuFraction ?? 2))
        #expect(u.memFraction != nil)
        #expect((u.cpuRequests ?? 0) > 0)
        #expect(PodPhaseBreakdown.compute(pods).total == pods.count)
    }
}
