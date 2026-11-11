#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// M6b perf gate (ARCHITECTURE-MAC section 15.1): after a helm run the footprint returns to within 5 MB of its value before the runs.
/// A fake helm (a shell script that prints and exits) stands in for the binary so the measurement covers what the app owns: the Gangway
/// session, its kubeconfig, the object grant, the suspended spawn, the output stream and the grant plan. Run with `WH_PERF_PRINT=1` to print
/// the numbers that go into `perf/baselines/M6b.json`.
@Suite("Helm run footprint", .serialized)
struct HelmRunFootprintTests {
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    @Test("twenty helm runs leave the footprint within 5 MB of where it started")
    func footprintReturns() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let dir = rig.scratch.root.appending(path: "fake-helm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appending(path: "helm")
        // 100 KB of output per run, like a chatty --wait.
        try "#!/bin/sh\ni=0\nwhile [ $i -lt 1000 ]; do echo 'Waiting for resources to be ready: 1 resource(s) not ready ................................................'; i=$((i+1)); done\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cli = HelmCLI(executable: script, version: HelmVersion(4, 0, 0), environment: EnvironmentBuilder(snapshot: nil, paths: rig.service.paths, home: rig.scratch.root))
        let runner = HelmRunner(cli: cli, gangway: rig.service)
        let op = HelmOperation.upgrade(release: "web", chart: "./c", version: nil, namespace: "shop", strategy: .reset)
        let plan = HelmGrantPlan(objects: [GrantedObject(resource: "configmaps", namespace: "shop", name: "web")], hooks: [], warnings: [])
        func run() async throws {
            let sink = Sink()
            let exit = try await runner.apply(op, plan: plan, cluster: rig.clusterID, valuesYAML: "replicas: 1\n", options: HelmApplyOptions(), output: sink.append)
            #expect(exit.succeeded)
            #expect(sink.text.utf8.count > 90_000)
        }
        for _ in 0..<5 { try await run() }                         // warm-up: allocator pools, the TLS identity, thread stacks
        let before = Self.footprint()
        for _ in 0..<20 { try await run() }
        let after = Self.footprint()
        let growthMB = Double(after - before) / 1_048_576
        if ProcessInfo.processInfo.environment["WH_PERF_PRINT"] == "1" { print("HELM-FOOTPRINT beforeMB=\(Double(before) / 1_048_576) afterMB=\(Double(after) / 1_048_576) growthMB=\(growthMB)") }
        #expect(growthMB < 5, "the footprint grew by \(growthMB) MB over 20 helm runs")
        #expect(rig.service.registry.sessions.isEmpty, "every run closed its session")
    }
}
#endif
