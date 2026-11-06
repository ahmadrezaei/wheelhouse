import Foundation
import Network
import Observation

/// Tracks device connectivity for the global offline banner.
@MainActor @Observable
final class NetworkMonitor {
    private(set) var isOffline = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in if self?.isOffline != offline { self?.isOffline = offline } }
        }
        monitor.start(queue: DispatchQueue(label: "app.wheelhouse.network"))
    }

    deinit { monitor.cancel() }
}
