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

    /// Where an exported or merged kubeconfig goes (MAS-EDITION §2): the sandboxed App Store edition has no write access to `~/.kube`,
    /// so the person chooses the destination in a Save panel; the GitHub edition keeps writing where it always did.
    public enum ExportMode: Sendable, Equatable {
        case mergeIntoHomeConfig
        case savePanel
    }

    public static func exportMode(edition: Edition = .current) -> ExportMode { edition.isSandboxed ? .savePanel : .mergeIntoHomeConfig }

    /// Throws in the sandboxed edition: the merge into `~/.kube/config` is a Save panel there.
    public static func assertMayMergeIntoHomeConfig(edition: Edition = .current) throws {
        guard exportMode(edition: edition) == .mergeIntoHomeConfig else { throw KubeconfigExportError.useSavePanel }
    }
}

public enum KubeconfigExportError: Error, Equatable, Sendable, LocalizedError {
    case useSavePanel
    public var errorDescription: String? { "The App Store edition can't write to ~/.kube. Choose where to save the file instead." }
}
#endif
