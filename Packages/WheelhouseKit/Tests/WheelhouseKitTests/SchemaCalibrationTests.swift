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

    /// The measuring runs in a forked child. A child has exactly one thread, so no other test's allocations (the runner executes suites
    /// in parallel) can move the heap between the two readings: the reading is the documents and nothing else.
    @Test(.timeLimit(.minutes(1))) func theEstimateIsNotBelowTheMeasuredHeap() throws {
        let b = BundledSchemas.standard
        _ = b.load(minor: "1.32")                      // warm up lazy tables and caches before the fork, so the child takes no lock another thread holds
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        let forkFunction = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork"))   // RTLD_DEFAULT; Swift marks `fork` unavailable
        let pid = unsafeBitCast(forkFunction, to: (@convention(c) () -> pid_t).self)()
        try #require(pid >= 0, "fork failed")
        if pid == 0 {
            // Child: measure, report two Ints through the pipe, and leave without running any exit handler of the test runner.
            alarm(30)
            let before = Self.heapInUse()
            let docs = b.load(minor: "1.32")
            let after = Self.heapInUse()               // the documents are alive here
            let estimated = (docs ?? [:]).values.reduce(0) { $0 + $1.cost }
            var result = [max(0, after - before), estimated]
            _ = result.withUnsafeMutableBytes { write(fds[1], $0.baseAddress, $0.count) }
            withExtendedLifetime(docs) {}
            _exit(0)
        }
        close(fds[1])
        defer { close(fds[0]) }
        var result = [0, 0]
        let got = result.withUnsafeMutableBytes { read(fds[0], $0.baseAddress, $0.count) }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        try #require(got == MemoryLayout<Int>.size * 2, "the measuring child did not report")
        let (held, estimated) = (result[0], result[1])
        let ratio = Double(held) / Double(max(1, estimated))
        print("SCHEMA calibration: estimated \(estimated / 1024) KB, held \(held / 1024) KB, ratio \(String(format: "%.2f", ratio))")
        #expect(estimated > 0 && held > 0, "nothing was measured")
        #expect(ratio <= 1.0, "the estimate is lower than the heap the documents hold (\(ratio)x)")
    }
}
#endif
