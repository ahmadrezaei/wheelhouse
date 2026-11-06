import Foundation
import Testing
@testable import WheelhouseKit

@Suite struct DemoCrashPodTests {
    static func crashPod(_ client: DemoKubeClient, selector: String? = nil) async throws -> Pod {
        let pods = try await client.list(Pod.self, namespace: "payments", options: ListOptions(fieldSelector: selector)).items
        return try #require(pods.first { $0.metadata.name.hasPrefix("payments-api") && $0.restartCount >= 14 })
    }

    @Test func listShowsCrashLoopWithContainers() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[0])
        let pod = try await Self.crashPod(client)
        let cs = try #require(pod.status?.containerStatuses.first)
        #expect(cs.restartCount == 14)
        #expect(cs.state?.waiting?.reason == "CrashLoopBackOff")
        let byName = try await Self.crashPod(client, selector: "metadata.name=\(pod.metadata.name)")
        #expect(byName.metadata.name == pod.metadata.name)
    }

    @Test func watchedCrashPodKeepsContainerStatusesAfterRestartTick() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[0])
        let name = try await Self.crashPod(client).metadata.name
        let stream = client.watch(Pod.self, kind: .pod, namespace: "payments", options: WatchOptions(fieldSelector: "metadata.name=\(name)"))
        let modified: Pod? = try await withThrowingTaskGroup(of: Pod?.self) { group in
            group.addTask {
                for try await event in stream { if case .modified(let p) = event { return p } }
                return nil
            }
            group.addTask { try await Task.sleep(for: .seconds(30)); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let pod = try #require(modified)
        #expect(pod.status?.containerStatuses.count == 1)
        #expect((pod.status?.containerStatuses.first?.restartCount ?? 0) >= 15)
        #expect(pod.status?.containerStatuses.first?.state?.waiting?.reason == "CrashLoopBackOff")
        let after = try await Self.crashPod(client, selector: "metadata.name=\(name)")
        #expect(after.status?.containerStatuses.count == 1)
    }
}
