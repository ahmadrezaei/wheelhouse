import Foundation
import Observation

/// App lock for the Mac (ARCHITECTURE-MAC §1.6 row 2). M1a ships the type; M1b implements locking on timeout after deactivation,
/// screen lock (`com.apple.screenIsLocked`), sleep, and **Lock Wheelhouse**, with the overlay in every workspace window.
@MainActor @Observable
final class MacLockCoordinator {
    private(set) var isLocked = false
    init() {}
}
