import Foundation
import Observation

/// What the device can afford right now. A tiny value type anything can query (`EnergyPolicy.current`), plus an
/// observable monitor (`EnergyMonitor.shared`) that SwiftUI and long-lived loops can watch for changes.
///
/// - Low Power Mode: refresh intervals double; live charts and live sampling are off.
/// - Thermal state `.serious` / `.critical`: refresh intervals double / quadruple, live charts and sampling are off and
///   watches that are not on screen are suspended.
public struct EnergyPolicy: Sendable, Equatable {
    public var isLowPowerMode: Bool
    public var thermalState: ProcessInfo.ThermalState

    public init(isLowPowerMode: Bool = false, thermalState: ProcessInfo.ThermalState = .nominal) {
        self.isLowPowerMode = isLowPowerMode
        self.thermalState = thermalState
    }

    /// The live device state.
    public static var current: EnergyPolicy {
        let p = ProcessInfo.processInfo
        return EnergyPolicy(isLowPowerMode: p.isLowPowerModeEnabled, thermalState: p.thermalState)
    }

    public var isThermallyConstrained: Bool { thermalState == .serious || thermalState == .critical }
    public var isConstrained: Bool { isLowPowerMode || isThermallyConstrained }

    /// Factor applied to every polling / auto-refresh interval.
    public var refreshMultiplier: Double {
        var m = 1.0
        if isLowPowerMode { m *= 2 }
        switch thermalState {
        case .serious: m *= 2
        case .critical: m *= 4
        default: break
        }
        return m
    }

    /// Scales a base interval (seconds) for the current state.
    public func interval(_ base: TimeInterval) -> TimeInterval { base * refreshMultiplier }

    /// Live (continuously appending) charts and client-side usage sampling.
    public var allowsLiveCharts: Bool { !isConstrained }
    public var allowsLiveSampling: Bool { !isConstrained }
    /// Watches whose screen is not visible should be suspended.
    public var suspendsHiddenWatches: Bool { isThermallyConstrained }
    /// Minimum spacing (seconds) between UI publishes of a watch / log stream.
    public var publishInterval: TimeInterval { isThermallyConstrained ? 1.0 : (isLowPowerMode ? 0.4 : 0.1) }

    /// Posted on the main thread whenever Low Power Mode or the thermal state changes.
    public static let didChange = Notification.Name("WheelhouseEnergyPolicyDidChange")
}

/// Observable mirror of ``EnergyPolicy/current`` that follows `NSProcessInfoPowerStateDidChange` and thermal changes.
@MainActor @Observable
public final class EnergyMonitor {
    public static let shared = EnergyMonitor()
    public private(set) var policy = EnergyPolicy.current

    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        tokens.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: update))
        tokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: update))
    }

    /// Re-reads the device state (also call when the app becomes active).
    public func refresh() {
        let now = EnergyPolicy.current
        guard now != policy else { return }
        policy = now
        NotificationCenter.default.post(name: EnergyPolicy.didChange, object: nil)
    }
}
