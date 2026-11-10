import Darwin
import Foundation
import os

/// Gives the memory of torn-down pane content back to the system (ARCHITECTURE-MAC section 12.3.4 item 9).
///
/// Closing a tab or a pane, or releasing a hidden window's content, frees a lot of small allocations at once: the screens' view graphs,
/// a 2,000-row table's row models, decoded lists. The allocator keeps those pages dirty for reuse, and dirty pages count in the physical
/// footprint, so the app looked as heavy after the soak cycle closed its tabs as while they were open (measured in M4a: live heap flat at
/// about 105 MB, "Malloc Small" climbing from 88 to 123 MB over the first cycles). Two seconds after the last such teardown, the zones are
/// asked to return their free pages (`malloc_zone_pressure_relief`, what the system's own memory-pressure handler calls), on a utility
/// queue so the main thread never waits for the zone locks.
@MainActor
enum MemoryRelief {
    static var delay: Duration = .seconds(2)
    /// Teardowns that asked for relief, and reliefs that ran (tests).
    private(set) static var requests = 0
    private(set) static var runs = 0
    private static var pending: Task<Void, Never>?
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Wheelhouse", category: "Memory")

    /// Called after pane content was torn down. Coalesced: a burst of closes (the soak cycle closes four tabs at once) runs one relief.
    static func schedule() {
        requests += 1
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            pending = nil
            runs += 1
            DispatchQueue.global(qos: .utility).async {
                let freed = malloc_zone_pressure_relief(nil, 0)
                log.notice("Pressure relief after a teardown returned \(freed / 1_048_576, privacy: .public) MB")
            }
        }
    }
}
