import Foundation

/// Stores per-cluster secrets (token, client cert/key, CA).
public protocol CredentialStoring: Sendable {
    func load(clusterID: ClusterID) throws -> ClusterSecrets
    /// `synchronizable == true` only for clusters that opted into iCloud Keychain sync.
    func save(_ secrets: ClusterSecrets, clusterID: ClusterID, synchronizable: Bool) throws
    func delete(clusterID: ClusterID) throws
}

/// Keychain-backed store: one generic-password item per cluster holding JSON, in the shared access group,
/// `AfterFirstUnlock(ThisDeviceOnly)` unless synchronized.
public struct KeychainCredentialStore: CredentialStoring {
    private static let service = "app.wheelhouse.credentials"
    private let backend: any KeychainBackend
    public init() { backend = SystemKeychain() }
    init(backend: any KeychainBackend) { self.backend = backend }

    public func load(clusterID: ClusterID) throws -> ClusterSecrets {
        guard let data = try KeychainAccess.read(service: Self.service, account: clusterID, in: backend) else { return ClusterSecrets() }
        return try JSONDecoder().decode(ClusterSecrets.self, from: data)
    }

    public func save(_ secrets: ClusterSecrets, clusterID: ClusterID, synchronizable: Bool) throws {
        try KeychainAccess.write(try JSONEncoder().encode(secrets), service: Self.service, account: clusterID, synchronizable: synchronizable, in: backend)
    }

    public func delete(clusterID: ClusterID) throws {
        try KeychainAccess.delete(service: Self.service, account: clusterID, in: backend)
        ClientIdentityBuilder.remove(label: ClientIdentityBuilder.label(for: clusterID))
    }
}

/// In-memory store for previews and tests.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClusterID: ClusterSecrets] = [:]
    public init() {}
    public func load(clusterID: ClusterID) throws -> ClusterSecrets { lock.withLock { items[clusterID] ?? ClusterSecrets() } }
    public func save(_ secrets: ClusterSecrets, clusterID: ClusterID, synchronizable: Bool) throws { lock.withLock { items[clusterID] = secrets } }
    public func delete(clusterID: ClusterID) throws { lock.withLock { items[clusterID] = nil } }
}

public extension ClusterSecrets {
    /// True when the cluster needs credentials but none are stored on this device (e.g. an iCloud-synced cluster whose
    /// Keychain item has not arrived, or was removed). Callers show "credentials not on this device" instead of
    /// building a client from empty secrets.
    func isMissingCredentials(for authKind: ClusterAuthKind) -> Bool {
        switch authKind {
        case .none: false
        case .token: (token ?? "").isEmpty
        case .clientCertificate: (clientCertificatePEM ?? "").isEmpty || (clientKeyPEM ?? "").isEmpty
        }
    }
}
