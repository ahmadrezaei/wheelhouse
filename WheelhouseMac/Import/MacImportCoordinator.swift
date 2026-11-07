import Foundation
import WheelhouseKit

/// The one entry point for importing a kubeconfig on the Mac (Import File…, drag and drop, ⌘O, Finder "Open With"). M1a ships
/// the seam with the Moorings hand-off; M1b implements the flow with `MacImportPolicy`. No entry point calls
/// `KubeconfigParser` directly (ARCHITECTURE-MAC §4.8).
@MainActor
final class MacImportCoordinator {
    /// "Add File as Moorings Source" goes through this; unavailable until M3.
    let moorings: any MooringsSourceAdding

    init(moorings: any MooringsSourceAdding = UnavailableMooringsSourceAdder()) {
        self.moorings = moorings
    }

    /// Placeholder: M1b presents the shared `KubeconfigImportView` with `MacImportPolicy` injected.
    func `import`(url: URL) {}
}
