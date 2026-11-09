#if os(macOS)
import Foundation
import Testing
import Darwin
@testable import WheelhouseKit

/// The schema cache budgets with ``JSONValue/estimatedMemoryCost``. This checks that the estimate is not below what a parsed
/// document really holds (measured as the change in the process's physical footprint), so a 32 MB budget means 32 MB.
@Suite("Schema cache calibration", .serialized)
struct SchemaCalibrationTests {
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    @Test func theEstimateIsNotBelowTheMeasuredFootprint() throws {
        let b = BundledSchemas.standard
        _ = b.load(minor: "1.32")                      // warm up allocators and lazy tables
        var bestRatio = Double.infinity       // other tests allocate in parallel: noise only adds, so the smallest reading is the truest
        for _ in 0..<7 {
            let before = Self.footprint()
            let docs = try #require(b.load(minor: "1.32"))
            let after = Self.footprint()
            let estimated = docs.values.reduce(0) { $0 + $1.cost }
            let measured = max(0, after - before)
            print("SCHEMA calibration: estimated \(estimated / 1024) KB, measured \(measured / 1024) KB")
            bestRatio = min(bestRatio, Double(measured) / Double(estimated))
            withExtendedLifetime(docs) {}
        }
        #expect(bestRatio <= 1.0, "the estimate is lower than the measured footprint (\(bestRatio)x)")
    }
}
#endif
