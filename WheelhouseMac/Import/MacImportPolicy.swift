import Foundation
import WheelhouseDesktop
import WheelhouseKit

/// Policy for importing on the Mac (ARCHITECTURE-MAC section 4.8). All four entry points (Import File…, drag and drop, ⌘O, Finder
/// "Open With") reach `KubeconfigImportView` through this policy, so none of them parses a file directly.
///
/// - Every row starts **read-only**, with iCloud sync **off**.
/// - The environment is pre-filled only from `EnvironmentSuggester` (with a reason); otherwise the user must choose, and Import
///   stays disabled until they do. The iOS substring suggestion is never used.
/// - While the safety gate is active a file under `~/.kube` is refused and contexts whose server host is not an allowed test host
///   are listed as "Blocked in development builds" and cannot be selected.
/// - Exec-plugin contexts are never imported with no credentials: their row offers "Add File as Moorings Source", disabled until M3.
/// - Allowing changes on a Production or Production-suggested row asks for Touch ID or the password.
struct MacImportPolicy: KubeconfigImportPolicy {
    /// Every imported row starts read-only.
    let defaultReadOnly = true
    /// iCloud sync starts off.
    let defaultICloud = false
    var gate: DevSafetyPolicy = .current
    var moorings: any MooringsSourceAdding = UnavailableMooringsSourceAdder()

    /// Larger than any real kubeconfig (a flattened file with a dozen clusters is under 100 KB).
    static let maxFileBytes = 2 * 1024 * 1024

    var mooringsSource: (any MooringsSourceAdding)? { moorings }

    // MARK: Environment

    func suggestion(for context: KubeconfigContext) -> EnvironmentSuggestion? {
        EnvironmentSuggester.suggest(SuggestionInput(contextName: context.name, clusterName: context.clusterName, userName: context.userName,
                                                     serverHost: context.server?.host()))
    }

    func suggestedEnvironment(for context: KubeconfigContext) -> ClusterEnvironment? { suggestion(for: context)?.environment }

    func requiresOwnerAuth(toAllowChangesOn context: KubeconfigContext, environment: ClusterEnvironment?) -> Bool {
        environment == .production || suggestion(for: context)?.environment == .production
    }

    // MARK: Safety

    func blockedReason(for context: KubeconfigContext) -> String? {
        guard gate.isActive, !gate.isAllowed(server: context.server) else { return nil }
        return "Blocked in development builds: \(context.server?.host() ?? "this server") is not a test cluster."
    }

    // MARK: Loading

    func loadFile(_ url: URL) throws -> (text: String, name: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let real = url.resolvingSymlinksInPath().standardizedFileURL
        do { try gate.assertReadable(real) } catch { throw ImportPolicyError.message(error.localizedDescription) }
        if let size = (try? FileManager.default.attributesOfItem(atPath: real.path))?[.size] as? Int, size > Self.maxFileBytes { throw ImportPolicyError.tooLarge }
        guard let text = try? String(contentsOf: real, encoding: .utf8) else { throw ImportPolicyError.unreadable }
        do {
            return (try KubeconfigFileInliner(gate: gate).inline(text, baseDirectory: real.deletingLastPathComponent()), url.lastPathComponent)
        } catch {
            throw ImportPolicyError.message(error.localizedDescription)
        }
    }

    /// The Mac can reach localhost, so a `local` context is simply ready; exec contexts point at Moorings.
    func parse(_ text: String) throws -> Kubeconfig {
        var kc = try KubeconfigParser.parse(text)
        kc.contexts = kc.contexts.map { ctx in
            var c = ctx
            switch c.status {
            case .local:
                c.status = .ready
                c.unsupportedReason = nil
            case .exec:
                c.unsupportedReason = "Uses a credential plugin. Wheelhouse can reference this file in place and run the plugin for you (Moorings). It is never copied into the Keychain."
            default: break
            }
            return c
        }
        return kc
    }
}
