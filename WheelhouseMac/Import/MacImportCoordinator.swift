import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WheelhouseDesktop
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
        if locked { deferred = request } else { present(request) }
    }

    /// Shows the import. In the sandboxed edition the folders of the files the kubeconfig refers to are asked for first (never while
    /// locked, because the deferred request goes through here on unlock); elsewhere it is shown at once, as before.
    private func present(_ request: Request) {
        guard Edition.current.isSandboxed else { presented = request; return }
        Task { @MainActor in
            await askForReferencedFolders(of: request.url)
            presented = request
        }
    }

    /// The panel's own grant lasts for this run, and the inliner copies the data in at once: nothing is stored for a one-off import.
    private func askForReferencedFolders(of url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8) else { return }
        let inliner = KubeconfigFileInliner()
        let home = DevSafetyPolicy.accountHome
        for folder in inliner.foldersNeedingAccess(text, baseDirectory: url.resolvingSymlinksInPath().deletingLastPathComponent(), accountHome: home) {
            let shown = FolderGrantPolicy.tildePath(folder, home: home)
            guard let picked = await FolderGrantPanel.choose(
                startingAt: URL(fileURLWithPath: folder, isDirectory: true), title: "Grant access to \(shown)",
                message: "This kubeconfig refers to certificates or keys in \(shown). Choose it so they can be read.", prompt: "Grant Access")
            else { continue }
            // A pick that is the home folder or doesn't contain the files is not used; the import then names the folder again.
            guard (try? FolderGrantPolicy.validateAccessGrant(picked, needed: folder, home: home)) != nil else { continue }
            guard (try? DevSafetyPolicy.current.assertReadable(picked)) != nil else { continue }
            _ = picked.startAccessingSecurityScopedResource()
        }
    }

    /// Shows what arrived while locked (called on unlock).
    func presentDeferred() {
        guard let d = deferred else { return }
        deferred = nil
        present(d)
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
