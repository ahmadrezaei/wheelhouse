import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WheelhouseKit

/// The one entry point for importing a kubeconfig on the Mac (ARCHITECTURE-MAC section 4.8). All four entry points call
/// `import(url:)`:
///
/// 1. **Import File…** (File menu, and Add Cluster ▸ Import File…) through `presentOpenPanel()`;
/// 2. **drag and drop** of a file onto a window (`MacShell` forwards the dropped URL);
/// 3. **⌘O** (Open File…), the same open panel;
/// 4. **Finder "Open With"** and double-click (`MacAppDelegate.application(_:open:)` and `.onOpenURL`).
///
/// None of them calls `KubeconfigParser` directly: `import(url:)` only records a request, and the window shows the shared
/// `KubeconfigImportView` with `MacImportPolicy` injected, which loads the file through the policy (dev-safety checks, file
/// references, read-only defaults, explicit environment).
@MainActor @Observable
final class MacImportCoordinator {
    /// "Add File as Moorings Source" goes through this; unavailable until M3.
    let moorings: any MooringsSourceAdding

    /// The import the front window should show as a sheet.
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let url: URL
    }

    var presented: Request?
    /// A file that arrived while the app was locked; shown after unlock.
    private(set) var deferred: Request?

    init(moorings: any MooringsSourceAdding = UnavailableMooringsSourceAdder()) {
        self.moorings = moorings
    }

    /// The policy every import sheet runs under.
    var policy: MacImportPolicy { MacImportPolicy(moorings: moorings) }

    /// True for the files this app imports through here: `.kubeconfig`, `.yaml`/`.yml` and `config`-named plain files.
    static func isImportable(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        return ["kubeconfig", "yaml", "yml", "conf", "cfg", ""].contains(ext) || url.lastPathComponent.lowercased().contains("kubeconfig")
    }

    func `import`(url: URL, whileLocked locked: Bool = false) {
        let request = Request(url: url)
        if locked { deferred = request } else { presented = request }
    }

    /// Shows what arrived while locked (called on unlock).
    func presentDeferred() {
        guard let d = deferred else { return }
        deferred = nil
        presented = d
    }

    func dismiss() { presented = nil }

    /// Import File… and ⌘O.
    func presentOpenPanel(whileLocked locked: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = "Import kubeconfig"
        panel.message = "Choose a kubeconfig file. Every context starts read-only."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.yaml, .plainText, .data, .item]
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.import(url: url, whileLocked: locked) }
        }
    }
}
