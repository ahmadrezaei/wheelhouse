#if os(macOS)
import Foundation
import Testing
import Darwin
@testable import WheelhouseKit

/// The schema cache budgets with ``JSONValue/estimatedMemoryCost``. This checks that the estimate is not below what a parsed
/// document really holds, so a 32 MB budget means 32 MB.
///
/// The measure is the malloc heap in use (`malloc_zone_statistics`) while the documents are alive, not the process footprint: a
/// footprint delta shrinks once freed pages are reused, so a later load can read almost nothing.
@Suite("Schema cache calibration", .serialized)
struct SchemaCalibrationTests {
    static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    @Test func theEstimateIsNotBelowTheMeasuredHeap() throws {
        let b = BundledSchemas.standard
        _ = b.load(minor: "1.32")                      // warm up lazy tables
        // Alone the reading is deterministic (0.85). Beside other tests the process heap also moves for reasons that are not the
        // documents: frees read low, allocations read high. A reading below half the estimate saw something else and is not used;
        // among the others noise only adds, so the smallest one is the truest.
        var valid: [Double] = []
        for run in 0..<15 {
            autoreleasepool {
                let before = Self.heapInUse()
                let docs = b.load(minor: "1.32")
                let after = Self.heapInUse()               // the documents are alive here
                let estimated = (docs ?? [:]).values.reduce(0) { $0 + $1.cost }
                let ratio = Double(max(0, after - before)) / Double(max(1, estimated))
                print("SCHEMA calibration run \(run): estimated \(estimated / 1024) KB, ratio \(String(format: "%.2f", ratio))")
                if ratio >= 0.5 { valid.append(ratio) }
                withExtendedLifetime(docs) {}
            }
            if valid.count >= 5 { break }
        }
        #expect(valid.count >= 1, "no reading measured the documents")
        #expect((valid.min() ?? 2) <= 1.0, "the estimate is lower than the heap the documents hold (\(valid.min() ?? 0)x)")
    }
}
#endif
