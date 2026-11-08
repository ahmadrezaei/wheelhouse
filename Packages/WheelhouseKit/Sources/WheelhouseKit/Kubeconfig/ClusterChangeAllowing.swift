import Foundation

/// The Mac's rule for leaving read-only in Cluster Settings (DESIGN-MAC, Actions: "Allow changes"). It applies to EVERY cluster on the
/// Mac, not only discovered ones: the device owner (Touch ID or the password) approves when the target or the current environment is
/// Production, or the cluster is Production-suggested. A cluster that Moorings manages (an added kubeconfig context) additionally
/// leaves read-only only through Moorings, with an explicitly chosen environment. iOS has no implementation (nil): it saves directly.
public protocol ClusterChangeAllowing: Sendable {
    /// True when Moorings owns this cluster's read-only flag and credentials (an added kubeconfig context). A Keychain cluster is not.
    func managesChanges(for id: ClusterID) -> Bool
    /// True when the environment of a managed cluster was picked by the user (not just suggested). Always true for other clusters.
    func environmentChosen(for id: ClusterID) -> Bool
    /// Asks the device owner when leaving read-only on `id`, or lowering Production, needs it. Changes nothing. Throws when the owner
    /// declines. The grant it returns is the only way to ``allowChanges(id:environment:grant:)`` without asking again.
    func authorizeLeavingReadOnly(id: ClusterID, currentEnvironment: ClusterEnvironment, environment: ClusterEnvironment) async throws -> ChangeGrant
    /// Commits "leave read-only" for a managed cluster with `environment` as the explicitly chosen one, using the grant of the prompt
    /// the owner just answered. Throws when the grant is not for this cluster and environment, was already used, or the cluster is gone.
    func allowChanges(id: ClusterID, environment: ClusterEnvironment, grant: ChangeGrant) async throws
}

/// Proof that the device owner answered the prompt for one cluster and environment. Only the package can mint one (an app target
/// cannot), and the service accepts each exactly once.
public struct ChangeGrant: Sendable, Equatable {
    public let id: ClusterID
    public let environment: ClusterEnvironment
    package let token: UUID
    package init(id: ClusterID, environment: ClusterEnvironment, token: UUID = UUID()) {
        self.id = id
        self.environment = environment
        self.token = token
    }
}

/// The save decision of the Edit Cluster screen, as a pure flow so it can be tested without a view.
public enum ClusterChangeSaver {
    /// The edits were saved but the cluster is still read-only.
    public struct ChangesStillOff: Error, LocalizedError {
        public let underlying: any Error
        public var errorDescription: String? {
            "Your other edits were saved, but changes are still off for this cluster: \(underlying.localizedDescription)"
        }
    }

    public enum Outcome: Equatable, Sendable {
        case saved
        /// The managed cluster's environment was never chosen: ask "Use <env> for <name>?" and call again with `environmentConfirmed`.
        case needsEnvironmentConfirmation
    }

    /// The secrets an edit writes: none for a managed cluster (they come from its kubeconfig file, and the draft's copy differs by a
    /// trailing newline of the CA), and none when nothing changed (a cluster whose credentials this build cannot read stays editable).
    public static func secretsToWrite(managed: Bool, existing: ClusterSecrets, edited: ClusterSecrets) -> ClusterSecrets? {
        managed || edited == existing ? nil : edited
    }

    /// - Parameters:
    ///   - current: the cluster as stored now. `target`: what the user wants saved.
    ///   - environmentConfirmed: the user changed the environment picker or confirmed the suggested one.
    ///   - persist: writes the config; `managed` says its secrets must not be written (a discovered cluster reads them from its file).
    ///
    /// Leaving read-only: the owner is asked FIRST (a refusal saves nothing), then the config is saved with read-only still on for a
    /// managed cluster, and only then Moorings commits the change. A failing save therefore leaves the cluster exactly as it was.
    @MainActor
    public static func save(allowing: (any ClusterChangeAllowing)?, current: ClusterConfig?, target: ClusterConfig, environmentConfirmed: Bool,
                            persist: (_ config: ClusterConfig, _ managed: Bool) throws -> Void) async throws -> Outcome {
        guard let allowing, let current else {
            try persist(target, false)
            return .saved
        }
        let id = target.id
        let managed = allowing.managesChanges(for: id)
        let leaving = current.readOnly && !target.readOnly
        // Lowering Production asks the owner whatever the read-only state, or two saves would get around the prompt: lower the
        // environment first, then leave read-only. A managed cluster's environment is lowered only by `allowChanges`, never by a save.
        let lowering = !managed && current.environment == .production && target.environment != .production
        guard leaving || lowering else {
            try persist(target, managed)
            return .saved
        }
        if leaving, managed, !allowing.environmentChosen(for: id), !environmentConfirmed { return .needsEnvironmentConfirmation }
        let grant = try await allowing.authorizeLeavingReadOnly(id: id, currentEnvironment: current.environment, environment: target.environment)
        var stored = target
        if managed { stored.readOnly = true }
        try persist(stored, managed)
        if leaving, managed {
            do { try await allowing.allowChanges(id: id, environment: target.environment, grant: grant) } catch { throw ChangesStillOff(underlying: error) }
        }
        return .saved
    }
}
