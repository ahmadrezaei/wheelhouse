import Foundation

/// Policy for importing on the Mac (ARCHITECTURE-MAC §4.8): read-only by default, explicit environment, `DevSafety` checks, exec
/// contexts offered as a Moorings source. M1a declares the type; M1b implements it.
struct MacImportPolicy: Sendable {
    /// Every imported row starts read-only.
    let defaultReadOnly = true
    /// iCloud sync starts off.
    let defaultICloudSync = false
}
