import SwiftUI
import WheelhouseKit

/// What differs between importing a kubeconfig on iOS and on the Mac (ARCHITECTURE-MAC section 1.6 row 7 and section 4.8).
/// `KubeconfigImportView` asks its policy; it never parses a file or picks a default on its own.
protocol KubeconfigImportPolicy: Sendable {
    /// Every imported row starts read-only (the "Read-only" switch is on).
    var defaultReadOnly: Bool { get }
    /// iCloud sync starts on for every imported row.
    var defaultICloud: Bool { get }
    /// The environment pre-filled for a context; nil means the user must choose before importing.
    func suggestedEnvironment(for context: KubeconfigContext) -> ClusterEnvironment?
    /// Why a context cannot be selected at all ("Blocked in development builds"), or nil.
    func blockedReason(for context: KubeconfigContext) -> String?
    /// Reads and checks a kubeconfig file (security scope, size, dev-safety, file references). Throws a user-readable error.
    func loadFile(_ url: URL) throws -> (text: String, name: String)
    /// Parses kubeconfig text into contexts.
    func parse(_ text: String) throws -> Kubeconfig
    /// Offered on exec-plugin rows ("Add File as Moorings Source"); nil hides the action.
    var mooringsSource: (any MooringsSourceAdding)? { get }
    /// True when turning off read-only on this row needs the owner (Touch ID or the password): a Production or Production-suggested row.
    func requiresOwnerAuth(toAllowChangesOn context: KubeconfigContext, environment: ClusterEnvironment?) -> Bool
}

/// iOS: exactly what the import screen did before the policy existed.
struct IOSImportPolicy: KubeconfigImportPolicy {
    var defaultReadOnly: Bool { false }
    var defaultICloud: Bool { false }
    func suggestedEnvironment(for context: KubeconfigContext) -> ClusterEnvironment? { context.suggestedEnvironment }
    func blockedReason(for context: KubeconfigContext) -> String? { nil }

    func loadFile(_ url: URL) throws -> (text: String, name: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ImportPolicyError.unreadable }
        return (text, url.lastPathComponent)
    }

    func parse(_ text: String) throws -> Kubeconfig { try KubeconfigParser.parse(text) }
    var mooringsSource: (any MooringsSourceAdding)? { nil }
    func requiresOwnerAuth(toAllowChangesOn context: KubeconfigContext, environment: ClusterEnvironment?) -> Bool { false }
}

enum ImportPolicyError: LocalizedError, Equatable {
    case unreadable
    case tooLarge
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "That file isn’t readable text."
        case .tooLarge: "That file is too large to be a kubeconfig."
        case .message(let m): m
        }
    }
}

private struct KubeconfigImportPolicyKey: EnvironmentKey { static let defaultValue: any KubeconfigImportPolicy = IOSImportPolicy() }

extension EnvironmentValues {
    var kubeconfigImportPolicy: any KubeconfigImportPolicy {
        get { self[KubeconfigImportPolicyKey.self] }
        set { self[KubeconfigImportPolicyKey.self] = newValue }
    }
}
