#if os(macOS)
import Foundation
import IOKit.ps

/// Whether the Mac runs on battery. Event-driven through `IOPSNotificationCreateRunLoopSource`, never polled. Used by Survey and
/// §12.3.4 item 8. M1a ships the seam; M1b wires it.
public final class PowerSourceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var source: CFRunLoopSource?
    private var handler: (@Sendable (Bool) -> Void)?

    public init() {}

    /// The current state (a single IOKit read, not a poll).
    public static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    /// Starts observing on the main run loop. `handler` receives `onBattery` after each change.
    public func start(_ handler: @escaping @Sendable (Bool) -> Void) {
        stop()
        lock.withLock { self.handler = handler }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanaged = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(ctx).takeUnretainedValue()
            let h = monitor.lock.withLock { monitor.handler }
            h?(PowerSourceMonitor.onBattery)
        }, context) else { return }
        let rls = unmanaged.takeRetainedValue()
        lock.withLock { source = rls }
        CFRunLoopAddSource(CFRunLoopGetMain(), rls, .defaultMode)
    }

    public func stop() {
        let s = lock.withLock { () -> CFRunLoopSource? in defer { source = nil; handler = nil }; return source }
        if let s { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) }
    }

    deinit { stop() }
}
#endif
