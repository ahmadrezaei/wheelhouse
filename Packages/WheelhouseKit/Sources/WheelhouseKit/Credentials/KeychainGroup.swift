import Foundation
import Security

/// Which keychain access group a store lives in (ARCHITECTURE-MAC §1.5, §1.8).
public enum KeychainGroup: Sendable, Hashable {
    /// The group shared with iOS: the iCloud mirror, per-cluster credentials and Prometheus tokens.
    /// Suffix from Info.plist `WHKeychainGroupSuffix`, else `com.ahmadrezaei.wheelhouse.shared`.
    case shared
    /// Mac-only secrets (Anthropic key, First Mate conversation key, Argo CD tokens, Beacon client secrets, Helm repository
    /// passwords). Suffix from `WHKeychainPrivateGroupSuffix`, else `com.ahmadrezaei.wheelhouse.mac`. Never synchronizable.
    case macPrivate

    public static let defaultPrivateSuffix = "com.ahmadrezaei.wheelhouse.mac"

    /// The group suffix for this case.
    public func suffix(in bundle: Bundle = .main) -> String {
        switch self {
        case .shared:
            return KeychainAccess.groupSuffix(in: bundle)
        case .macPrivate:
            if bundle === Bundle.main, let o = IsolationOverride.current { return o.privateKeychainSuffix }
            guard let custom = bundle.object(forInfoDictionaryKey: "WHKeychainPrivateGroupSuffix") as? String else { return Self.defaultPrivateSuffix }
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.defaultPrivateSuffix : trimmed
        }
    }

    /// `<TeamPrefix>.<suffix>`.
    public func accessGroup(teamPrefix: String, bundle: Bundle = .main) -> String { "\(teamPrefix).\(suffix(in: bundle))" }

    /// The access group on this machine, or nil when the app is unsigned and the team prefix cannot be discovered.
    public var resolved: String? {
        KeychainAccess.teamPrefix.map { accessGroup(teamPrefix: $0) }
    }
}

/// Which Mac-private secret a service name holds.
public enum MacPrivateService: String, CaseIterable, Sendable {
    case anthropicKey = "app.wheelhouse.mac.anthropic"
    case firstMateConversationKey = "app.wheelhouse.mac.firstmate"
    case argoToken = "app.wheelhouse.mac.argocd"
    case beaconClientSecret = "app.wheelhouse.mac.beacon"
    case helmRepositoryPassword = "app.wheelhouse.mac.helm"
}

/// Backend for every Mac-private item. Items are always in ``KeychainGroup/macPrivate``, `kSecAttrSynchronizable = false` and
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so they never enter the shared or synced group. The `synchronizable`
/// argument required by ``KeychainBackend`` is ignored: this backend cannot write a synchronizable item.
struct MacPrivateKeychain: KeychainBackend {
    var accessGroup: String? = KeychainGroup.macPrivate.resolved

    /// The attributes every query of this backend carries (exposed for `KeychainGroupTests`).
    static func baseQuery(service: String, account: String, accessGroup: String?) -> [CFString: Any] {
        var q = KeychainAccess.baseQuery(service: service, account: account, accessGroup: accessGroup)
        q[kSecAttrSynchronizable] = false
        return q
    }

    static func addAttributes(data: Data) -> [CFString: Any] {
        [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    }

    func read(service: String, account: String) throws -> Data? {
        var q = Self.baseQuery(service: service, account: account, accessGroup: accessGroup)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    func readAll(service: String, account: String) throws -> [Data] {
        try read(service: service, account: account).map { [$0] } ?? []
    }

    func upsert(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
        let q = Self.baseQuery(service: service, account: account, accessGroup: accessGroup)
        var add = q
        add.merge(Self.addAttributes(data: data)) { $1 }
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(q as CFDictionary, Self.addAttributes(data: data) as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func delete(service: String, account: String, synchronizable: Bool?) throws {
        let q = Self.baseQuery(service: service, account: account, accessGroup: accessGroup)
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

/// A named Mac-private secret store (one string per account). The only way Mac code stores a Mac-private secret.
public struct MacPrivateSecretStore: Sendable {
    public let service: MacPrivateService
    private let backend: any KeychainBackend

    public init(_ service: MacPrivateService) {
        self.service = service
        self.backend = MacPrivateKeychain()
    }

    init(_ service: MacPrivateService, backend: any KeychainBackend) {
        self.service = service
        self.backend = backend
    }

    public func read(account: String) throws -> String? {
        try backend.read(service: service.rawValue, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func write(_ secret: String, account: String) throws {
        try backend.upsert(Data(secret.utf8), service: service.rawValue, account: account, synchronizable: false)
    }

    public func delete(account: String) throws {
        try backend.delete(service: service.rawValue, account: account, synchronizable: nil)
    }
}
