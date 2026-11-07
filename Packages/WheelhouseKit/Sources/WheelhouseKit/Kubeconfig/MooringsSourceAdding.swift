import Foundation

/// Adds a kubeconfig file or folder as a Moorings source (referenced in place, with its exec plugins). The import flow offers
/// "Add File as Moorings Source" through this seam. Unavailable until M3 provides the implementation.
public protocol MooringsSourceAdding: Sendable {
    /// False until Moorings exists; the import row then shows the action disabled.
    var isAvailable: Bool { get }
    /// Adds the file (by realpath) as a user file source.
    func addFileSource(_ url: URL) async throws
}

public struct UnavailableMooringsSourceAdder: MooringsSourceAdding {
    public init() {}
    public var isAvailable: Bool { false }
    public func addFileSource(_ url: URL) async throws {
        throw KubeError.unsupported("Moorings is not available in this build.")
    }
}
