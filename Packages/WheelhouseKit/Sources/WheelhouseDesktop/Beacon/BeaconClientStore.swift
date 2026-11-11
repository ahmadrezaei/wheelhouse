#if os(macOS)
import Foundation
import Security
import Synchronization
import WheelhouseKit

/// An approved Beacon client (`beacon-clients.json`): its scope and what it is bound to. Never holds the secret.
public struct BeaconClientRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var createdAt: Date
    /// What the first approval saw: the `clientInfo.name` and the launcher identity (``BeaconLauncher/identityKey``). nil until claimed.
    public var boundName: String?
    public var launcherKey: String?
    public var launcherDescription: String?
    public var readClusters: Set<ClusterID>
    public var changeRequestClusters: Set<ClusterID>
    public var lastSeen: Date?

    public var scope: BeaconScope { BeaconScope(readClusters: readClusters, changeRequestClusters: changeRequestClusters.intersection(readClusters)) }
    public var isBound: Bool { launcherKey != nil }
}

/// Where client secrets live (the Mac-private keychain group in the app; a dictionary in tests).
public protocol BeaconSecretStoring: Sendable {
    func secret(for id: String) -> String?
    func save(_ secret: String, for id: String) throws
    func delete(id: String)
}

/// Approved clients and their scopes. Scope lives here (`beacon-clients.json`), not in `MacClusterSettings`.
///
/// Clients approved for one session only (an unknown secret, a different launcher) are kept in memory under `session-<UUID>`
/// ids and vanish with the connection or the app.
public final class BeaconClientStore: ToolboxClusterSettings, Sendable {
    struct File: Codable { var version = 1; var clients: [BeaconClientRecord] = [] }

    private let fileURL: URL
    private let secrets: any BeaconSecretStoring
    private let state: Mutex<File>
    private let sessionScopes = Mutex<[String: BeaconScope]>([:])
    private let changed = Mutex<(@Sendable () -> Void)?>(nil)

    public init(fileURL: URL, secrets: any BeaconSecretStoring) {
        self.fileURL = fileURL
        self.secrets = secrets
        self.state = Mutex(JSONFile.read(File.self, from: fileURL) ?? File())
    }

    /// Called after every change of a scope or of the client list (so sessions can announce `tools/list_changed`).
    public func onChange(_ handler: @escaping @Sendable () -> Void) { changed.withLock { $0 = handler } }

    public var records: [BeaconClientRecord] { state.withLock { $0.clients } }
    public func record(id: String) -> BeaconClientRecord? { state.withLock { $0.clients.first { $0.id == id } } }

    // MARK: ToolboxClusterSettings

    public func firstMateAccess(for cluster: ClusterConfig) -> ClusterAccess? { nil }

    public func beaconScope(client: String) -> BeaconScope {
        if let scope = sessionScopes.withLock({ $0[client] }) { return scope }
        return record(id: client)?.scope ?? BeaconScope()
    }

    // MARK: Session-only clients

    public func setSessionScope(_ scope: BeaconScope, for id: String) {
        sessionScopes.withLock { $0[id] = scope }
        changed.withLock { $0 }?()
    }

    public func dropSession(_ id: String) { sessionScopes.withLock { _ = $0.removeValue(forKey: id) } }

    // MARK: Records

    /// Creates a client slot with a fresh 256-bit secret. The secret is stored once (keychain) and returned once for the snippet.
    public func createClient(label: String) throws -> (record: BeaconClientRecord, secret: String) {
        let id = UUID().uuidString
        let secret = try Self.randomSecret()
        try secrets.save(secret, for: id)
        let record = BeaconClientRecord(id: id, label: BeaconClientRef.sanitize(label), createdAt: Date(), readClusters: [], changeRequestClusters: [])
        do { try persist { $0.clients.append(record) } } catch {
            secrets.delete(id: id)
            throw error
        }
        return (record, secret)
    }

    /// The secret of a client, for showing in a snippet.
    public func secret(for id: String) -> String? { record(id: id) == nil ? nil : secrets.secret(for: id) }

    /// The client that owns `secret`. Every stored secret is compared in constant time, with no early exit.
    public func match(secret presented: String) -> BeaconClientRecord? {
        var found: BeaconClientRecord?
        for record in records {
            let stored = secrets.secret(for: record.id) ?? ""
            if Self.constantTimeEquals(stored, presented), !stored.isEmpty { found = record }
        }
        return found
    }

    public func bind(id: String, name: String, launcher: BeaconLauncher, readClusters: Set<ClusterID>) throws {
        try persist { file in
            guard let i = file.clients.firstIndex(where: { $0.id == id }) else { return }
            file.clients[i].boundName = name
            file.clients[i].launcherKey = launcher.identityKey
            file.clients[i].launcherDescription = launcher.description
            file.clients[i].readClusters = readClusters
            file.clients[i].changeRequestClusters = file.clients[i].changeRequestClusters.intersection(readClusters)
        }
        changed.withLock { $0 }?()
    }

    public func setScope(id: String, read: Set<ClusterID>, changeRequests: Set<ClusterID>) throws {
        try persist { file in
            guard let i = file.clients.firstIndex(where: { $0.id == id }) else { return }
            file.clients[i].readClusters = read
            file.clients[i].changeRequestClusters = changeRequests.intersection(read)
        }
        changed.withLock { $0 }?()
    }

    public func touch(id: String, now: Date = Date()) { try? persist { file in file.clients.indices.filter { file.clients[$0].id == id }.forEach { file.clients[$0].lastSeen = now } } }

    /// Removes the client and its secret.
    public func revoke(id: String) throws {
        try persist { $0.clients.removeAll { $0.id == id } }
        secrets.delete(id: id)
        changed.withLock { $0 }?()
    }

    /// A cluster that no longer exists is removed from every scope.
    public func reconcile(existing: Set<ClusterID>) {
        let stale = records.contains { !$0.readClusters.isSubset(of: existing) || !$0.changeRequestClusters.isSubset(of: existing) }
        guard stale else { return }
        try? persist { file in
            for i in file.clients.indices {
                file.clients[i].readClusters.formIntersection(existing)
                file.clients[i].changeRequestClusters.formIntersection(existing)
            }
        }
        changed.withLock { $0 }?()
    }

    private func persist(_ change: (inout File) -> Void) throws {
        let file = state.withLock { s -> File in
            change(&s)
            return s
        }
        try JSONFile.write(file, to: fileURL)
    }

    // MARK: Secrets

    static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw KeychainError.status(errSecAllocate) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = x.count ^ y.count
        for i in 0..<max(x.count, y.count) { difference |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)) }
        return difference == 0
    }
}

/// Client secrets in the Mac-private keychain group: this device only, available when unlocked, never synchronizable.
public struct KeychainBeaconSecrets: BeaconSecretStoring {
    static let service = "app.wheelhouse.beacon.client-secret"
    private let accessGroup: String?
    public init(accessGroup: String? = KeychainGroup.macPrivate.accessGroup(teamPrefix: DevSafety.teamID)) { self.accessGroup = accessGroup }

    private func query(_ id: String) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: id,
                                  kSecUseDataProtectionKeychain: true, kSecAttrSynchronizable: false]
        if let accessGroup { q[kSecAttrAccessGroup] = accessGroup }
        return q
    }

    public func secret(for id: String) -> String? {
        var q = query(id)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ secret: String, for id: String) throws {
        SecItemDelete(query(id) as CFDictionary)
        var q = query(id)
        q[kSecValueData] = Data(secret.utf8)
        q[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func delete(id: String) { SecItemDelete(query(id) as CFDictionary) }
}

/// In-memory secrets for tests and previews.
public final class InMemoryBeaconSecrets: BeaconSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func secret(for id: String) -> String? { lock.withLock { values[id] } }
    public func save(_ secret: String, for id: String) throws { lock.withLock { values[id] = secret } }
    public func delete(id: String) { lock.withLock { _ = values.removeValue(forKey: id) } }
}
#endif
