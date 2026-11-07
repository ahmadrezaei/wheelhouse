#if os(macOS)
import Foundation

/// The only code that may write a kubeconfig file (Export Context, Landfall's `landfall.yaml`, the optional merge into
/// `~/.kube/config`). M1a ships the gate: every write is refused while development safety is active. M10 adds the writers.
public struct KubeconfigWriter: Sendable {
    public var gate: DevSafetyPolicy
    public init(gate: DevSafetyPolicy = .current) { self.gate = gate }

    /// Throws ``DevSafetyError/disabledInDevelopment(_:)`` while the gate is active.
    public func assertMayWrite() throws {
        try gate.require(gate.allowsKubeconfigWrites, feature: "Writing kubeconfig files")
    }
}
#endif
